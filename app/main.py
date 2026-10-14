"""Bank application — the workload the migration must not break.

Reads and writes flow to whatever schema ``BANK_SCHEMA`` names. Before cutover
that is the source; after cutover it is the target (or a facade that fronts it).
The application code itself never changes.

Every response carries:
  X-Db-Endpoint  which database/schema answered (proof across a cutover)
  X-Latency-Ms   server-side handling time

Writes are idempotent: pass an ``Idempotency-Key`` header and a retry (e.g. one
issued while a connection is being repointed) will replay the first response
instead of double-applying money movement.
"""

from __future__ import annotations

import os
import time
import uuid
from contextlib import asynccontextmanager
from decimal import Decimal
from typing import Any

import psycopg
from fastapi import FastAPI, Header, HTTPException, Request
from fastapi.encoders import jsonable_encoder
from fastapi.responses import JSONResponse
from pydantic import BaseModel, Field
from psycopg.types.json import Jsonb

from . import db

SCHEMA = db.schema()
ENDPOINT = db.endpoint_label()
OP = db.OP_SCHEMA
POOL = db.make_pool()


@asynccontextmanager
async def lifespan(app: FastAPI):
    POOL.open()
    with POOL.connection() as conn:
        conn.execute(f"CREATE SCHEMA IF NOT EXISTS {OP}")
        conn.execute(
            f"CREATE TABLE IF NOT EXISTS {OP}.idempotency ("
            "  key text PRIMARY KEY,"
            "  status int,"
            "  body jsonb,"
            "  created_at timestamptz NOT NULL DEFAULT now())"
        )
    yield
    POOL.close()


app = FastAPI(title="bank-app", lifespan=lifespan)


@app.middleware("http")
async def stamp(request: Request, call_next):
    t0 = time.perf_counter()
    resp = await call_next(request)
    resp.headers["X-Db-Endpoint"] = ENDPOINT
    resp.headers["X-Latency-Ms"] = f"{(time.perf_counter() - t0) * 1000:.2f}"
    return resp


# ── models ──────────────────────────────────────────────────────────────────
class TransferIn(BaseModel):
    src_account: int
    dst_account: int
    amount: float = Field(gt=0)


class DepositIn(BaseModel):
    amount: float = Field(gt=0)


class CustomerIn(BaseModel):
    full_name: str
    national_id: str
    email: str | None = None
    phone: str | None = None
    dob: str = "1970-01-01"
    tier: str = "standard"


# ── idempotency helpers ─────────────────────────────────────────────────────
def _claim(conn, key: str) -> bool:
    row = conn.execute(
        f"INSERT INTO {OP}.idempotency (key) VALUES (%s) ON CONFLICT (key) DO NOTHING RETURNING key",
        (key,),
    ).fetchone()
    return row is not None


def _stored(conn, key: str):
    return conn.execute(f"SELECT status, body FROM {OP}.idempotency WHERE key = %s", (key,)).fetchone()


def _store(conn, key: str, status: int, body: dict[str, Any]) -> None:
    conn.execute(
        f"UPDATE {OP}.idempotency SET status = %s, body = %s WHERE key = %s",
        (status, Jsonb(body), key),
    )


def _replay(conn, key: str):
    row = _stored(conn, key)
    if row and row["status"]:
        return JSONResponse(jsonable_encoder(row["body"]), status_code=row["status"])
    return None


# ── reads ───────────────────────────────────────────────────────────────────
@app.get("/healthz")
def healthz() -> dict[str, Any]:
    with POOL.connection() as conn:
        row = conn.execute(
            f"SELECT (SELECT count(*) FROM {SCHEMA}.customers) AS customers,"
            f"       (SELECT count(*) FROM {SCHEMA}.accounts)  AS accounts,"
            f"       (SELECT count(*) FROM {SCHEMA}.transfers) AS transfers"
        ).fetchone()
    return {"ok": True, "endpoint": ENDPOINT, "schema": SCHEMA, **row}


@app.get("/ranges")
def ranges() -> dict[str, Any]:
    with POOL.connection() as conn:
        return conn.execute(
            f"SELECT (SELECT max(id) FROM {SCHEMA}.customers) AS max_customer_id,"
            f"       (SELECT max(id) FROM {SCHEMA}.accounts)  AS max_account_id"
        ).fetchone()


@app.get("/customers/{cid}")
def get_customer(cid: int) -> dict[str, Any]:
    with POOL.connection() as conn:
        row = conn.execute(
            f"SELECT c.id, c.full_name, c.email, c.tier, c.created_at,"
            f"       a.line1, a.city, a.country"
            f"  FROM {SCHEMA}.customers c"
            f"  LEFT JOIN {SCHEMA}.addresses a ON a.customer_id = c.id AND a.is_primary"
            f" WHERE c.id = %s",
            (cid,),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "customer not found")
    return row


@app.get("/customers/{cid}/summary")
def customer_summary(cid: int) -> dict[str, Any]:
    with POOL.connection() as conn:
        accounts = conn.execute(
            f"SELECT a.id, a.currency, a.status, b.available, b.ledger"
            f"  FROM {SCHEMA}.accounts a"
            f"  LEFT JOIN {SCHEMA}.account_balances b ON b.account_id = a.id"
            f" WHERE a.customer_id = %s",
            (cid,),
        ).fetchall()
        counts = conn.execute(
            f"SELECT (SELECT count(*) FROM {SCHEMA}.cards WHERE customer_id = %s) AS cards,"
            f"       (SELECT count(*) FROM {SCHEMA}.loan_accounts WHERE customer_id = %s) AS loans",
            (cid, cid),
        ).fetchone()
    return {"customer_id": cid, "accounts": accounts, **counts}


@app.get("/accounts/{aid}")
def get_account(aid: int) -> dict[str, Any]:
    with POOL.connection() as conn:
        row = conn.execute(
            f"SELECT a.id, a.customer_id, a.currency, a.status, a.opened_at,"
            f"       b.available, b.ledger, b.updated_at"
            f"  FROM {SCHEMA}.accounts a"
            f"  LEFT JOIN {SCHEMA}.account_balances b ON b.account_id = a.id"
            f" WHERE a.id = %s",
            (aid,),
        ).fetchone()
    if row is None:
        raise HTTPException(404, "account not found")
    return row


@app.get("/accounts/{aid}/statement")
def statement(aid: int, limit: int = 20) -> dict[str, Any]:
    limit = max(1, min(limit, 200))
    with POOL.connection() as conn:
        rows = conn.execute(
            f"SELECT id, transfer_id, direction, amount, posted_at"
            f"  FROM {SCHEMA}.ledger_entries"
            f" WHERE account_id = %s ORDER BY id DESC LIMIT %s",
            (aid, limit),
        ).fetchall()
    return {"account_id": aid, "entries": rows}


# ── writes ──────────────────────────────────────────────────────────────────
@app.post("/transfers", status_code=201)
def transfer(body: TransferIn, idempotency_key: str | None = Header(None, alias="Idempotency-Key")):
    key = idempotency_key or str(uuid.uuid4())
    with POOL.connection() as conn:
        with conn.transaction():
            if not _claim(conn, key):
                replay = _replay(conn, key)
                if replay is not None:
                    return replay
                raise HTTPException(409, "duplicate request in progress")
            debit = conn.execute(
                f"UPDATE {SCHEMA}.account_balances"
                f"   SET available = available - %s, ledger = ledger - %s, updated_at = now()"
                f" WHERE account_id = %s AND available >= %s RETURNING available",
                (body.amount, body.amount, body.src_account, body.amount),
            ).fetchone()
            if debit is None:
                exists = conn.execute(f"SELECT 1 FROM {SCHEMA}.accounts WHERE id = %s", (body.src_account,)).fetchone()
                raise HTTPException(409 if exists else 404,
                                    "insufficient funds" if exists else "source account not found")
            credit = conn.execute(
                f"UPDATE {SCHEMA}.account_balances"
                f"   SET available = available + %s, ledger = ledger + %s, updated_at = now()"
                f" WHERE account_id = %s RETURNING available",
                (body.amount, body.amount, body.dst_account),
            ).fetchone()
            if credit is None:
                raise HTTPException(404, "destination account not found")
            tr = conn.execute(
                f"INSERT INTO {SCHEMA}.transfers (src_account, dst_account, amount, currency, status)"
                f" VALUES (%s, %s, %s, %s, 'settled') RETURNING id, created_at",
                (body.src_account, body.dst_account, body.amount, "GBP"),
            ).fetchone()
            conn.execute(
                f"INSERT INTO {SCHEMA}.ledger_entries (transfer_id, account_id, direction, amount)"
                f" VALUES (%s, %s, 'D', %s)",
                (tr["id"], body.src_account, body.amount),
            )
            conn.execute(
                f"INSERT INTO {SCHEMA}.ledger_entries (transfer_id, account_id, direction, amount)"
                f" VALUES (%s, %s, 'C', %s)",
                (tr["id"], body.dst_account, body.amount),
            )
            resp = {
                "transfer_id": tr["id"],
                "src_account": body.src_account,
                "dst_account": body.dst_account,
                "amount": body.amount,
                "src_available": float(debit["available"]),
                "dst_available": float(credit["available"]),
                "created_at": tr["created_at"].isoformat(),
            }
            _store(conn, key, 201, resp)
            return JSONResponse(resp, status_code=201)


@app.post("/accounts/{aid}/deposit", status_code=201)
def deposit(aid: int, body: DepositIn, idempotency_key: str | None = Header(None, alias="Idempotency-Key")):
    key = idempotency_key or str(uuid.uuid4())
    with POOL.connection() as conn:
        with conn.transaction():
            if not _claim(conn, key):
                replay = _replay(conn, key)
                if replay is not None:
                    return replay
                raise HTTPException(409, "duplicate request in progress")
            credit = conn.execute(
                f"UPDATE {SCHEMA}.account_balances"
                f"   SET available = available + %s, ledger = ledger + %s, updated_at = now()"
                f" WHERE account_id = %s RETURNING available",
                (body.amount, body.amount, aid),
            ).fetchone()
            if credit is None:
                raise HTTPException(404, "account not found")
            conn.execute(
                f"INSERT INTO {SCHEMA}.ledger_entries (transfer_id, account_id, direction, amount)"
                f" VALUES (NULL, %s, 'C', %s)",
                (aid, body.amount),
            )
            resp = {"account_id": aid, "amount": body.amount, "available": float(credit["available"])}
            _store(conn, key, 201, resp)
            return JSONResponse(resp, status_code=201)


@app.post("/customers", status_code=201)
def create_customer(body: CustomerIn, idempotency_key: str | None = Header(None, alias="Idempotency-Key")):
    key = idempotency_key or str(uuid.uuid4())
    with POOL.connection() as conn:
        with conn.transaction():
            if not _claim(conn, key):
                replay = _replay(conn, key)
                if replay is not None:
                    return replay
                raise HTTPException(409, "duplicate request in progress")
            cust = conn.execute(
                f"INSERT INTO {SCHEMA}.customers (full_name, national_id, email, phone, dob, tier)"
                f" VALUES (%s, %s, %s, %s, %s::date, %s) RETURNING id, created_at",
                (body.full_name, body.national_id, body.email, body.phone, body.dob, body.tier),
            ).fetchone()
            cid = cust["id"]
            conn.execute(
                f"INSERT INTO {SCHEMA}.addresses (customer_id, line1, city, country, postcode, is_primary)"
                f" VALUES (%s, %s, %s, %s, %s, true)",
                (cid, "1 New Street", "London", "GB", "00000"),
            )
            if body.email:
                conn.execute(
                    f"INSERT INTO {SCHEMA}.contacts (customer_id, kind, value, verified)"
                    f" VALUES (%s, 'email', %s, false)",
                    (cid, body.email),
                )
            resp = {"customer_id": cid, "tier": body.tier, "created_at": cust["created_at"].isoformat()}
            _store(conn, key, 201, resp)
            return JSONResponse(resp, status_code=201)
