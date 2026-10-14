"""Connection pool + schema handling for the bank app.

The app never names a base table directly. It reads the schema to use from
BANK_SCHEMA (default ``bank``) and interpolates it into SQL. Pointing
BANK_SCHEMA at a facade schema (``bank_app``) is what makes the rollout a
config change instead of an application change.
"""

from __future__ import annotations

import os
import re

from psycopg.rows import dict_row
from psycopg_pool import ConnectionPool

_IDENT = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def schema() -> str:
    name = os.environ.get("BANK_SCHEMA", "bank")
    if not _IDENT.match(name):
        raise ValueError(f"BANK_SCHEMA is not a valid identifier: {name!r}")
    return name


def endpoint_label() -> str:
    return os.environ.get("BANK_ENDPOINT", schema())


def make_pool() -> ConnectionPool:
    dsn = os.environ["BANK_DSN"]
    return ConnectionPool(
        conninfo=dsn,
        min_size=int(os.environ.get("BANK_POOL_MIN", "2")),
        max_size=int(os.environ.get("BANK_POOL_MAX", "16")),
        kwargs={"row_factory": dict_row},
        open=False,
    )


OP_SCHEMA = "bank_op"
