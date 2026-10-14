"""Continuous request simulator for the bank app.

Hammers the running application with a configurable read/write mix and, crucially,
*validates* every response, so the migration can be judged while it happens:
zero failures (outside a declared cutover window) means the app stayed healthy.

  python traffic.py --base-url http://bankapp:8090 --rps 100 --mix 80:20 --duration 0

Only HTTP is used — the simulator never touches the database, so it is a fair
client of the application exactly as production would be.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import random
import signal
import statistics
import time
import uuid
from collections import Counter

import httpx

READY = asyncio.Event()


class Stats:
    def __init__(self) -> None:
        self.sent = 0
        self.ok = 0
        self.rejected = 0          # expected business rejections (e.g. 409 insufficient funds)
        self.failed = 0
        self.reasons: Counter[str] = Counter()
        self.latencies: list[float] = []   # ms
        self.started = time.monotonic()

    def record(self, ms: float, outcome: str, reason: str = "") -> None:
        self.sent += 1
        self.latencies.append(ms)
        if outcome == "ok":
            self.ok += 1
        elif outcome == "rejected":
            self.rejected += 1
        else:
            self.failed += 1
            self.reasons[reason] += 1

    def summary(self) -> dict:
        elapsed = time.monotonic() - self.started
        lat = sorted(self.latencies) or [0.0]

        def pct(p: float) -> float:
            return lat[min(len(lat) - 1, int(len(lat) * p))]

        return {
            "elapsed_s": round(elapsed, 1),
            "sent": self.sent,
            "ok": self.ok,
            "rejected": self.rejected,
            "failed": self.failed,
            "achieved_rps": round(self.sent / elapsed, 1) if elapsed else 0,
            "latency_ms": {"p50": round(pct(0.50), 2), "p95": round(pct(0.95), 2), "p99": round(pct(0.99), 2)},
            "failure_reasons": dict(self.reasons),
        }


class RateLimiter:
    """Token bucket with a linear ramp-in over the first ``ramp`` seconds."""

    def __init__(self, rps: float, ramp: float) -> None:
        self.rps = rps
        self.ramp = ramp
        self.start = time.monotonic()
        self.tokens = 0.0
        self.last = self.start

    async def acquire(self) -> None:
        while True:
            now = time.monotonic()
            rate = self.rps * (min(1.0, (now - self.start) / self.ramp) if self.ramp > 0 else 1.0)
            self.tokens = min(self.tokens + (now - self.last) * rate, max(rate, 1.0))
            self.last = now
            if self.tokens >= 1:
                self.tokens -= 1
                return
            await asyncio.sleep(0.005)


def parse_args() -> argparse.Namespace:
    ap = argparse.ArgumentParser()
    ap.add_argument("--base-url", default=os.environ.get("BANK_BASE_URL", "http://127.0.0.1:8090"))
    ap.add_argument("--rps", type=float, default=100)
    ap.add_argument("--concurrency", type=int, default=40)
    ap.add_argument("--mix", default="80:20", help="read:write")
    ap.add_argument("--duration", type=float, default=0, help="seconds; 0 = run until stopped")
    ap.add_argument("--ramp", type=float, default=30, help="seconds to ramp 0 -> rps")
    ap.add_argument("--report-every", type=float, default=5)
    ap.add_argument("--out", default=os.environ.get("BANK_OUT", "/srv/bank/out"))
    ap.add_argument("--seed", type=int, default=1)
    return ap.parse_args()


def one_read(client: httpx.AsyncClient, ids: dict) -> tuple[str, str]:
    choice = random.random()
    if choice < 0.4:
        return f"/customers/{random.randint(1, ids['max_customer_id'])}", "customer"
    if choice < 0.7:
        return f"/customers/{random.randint(1, ids['max_customer_id'])}/summary", "summary"
    if choice < 0.9:
        return f"/accounts/{random.randint(1, ids['max_account_id'])}", "account"
    return f"/accounts/{random.randint(1, ids['max_account_id'])}/statement?limit=10", "statement"


async def one_write(client: httpx.AsyncClient, ids: dict) -> httpx.Response:
    if random.random() < 0.85:
        src = random.randint(1, ids["max_account_id"])
        dst = random.randint(1, ids["max_account_id"])
        while dst == src:
            dst = random.randint(1, ids["max_account_id"])
        return await client.post(
            "/transfers",
            json={"src_account": src, "dst_account": dst, "amount": round(random.uniform(1, 500), 2)},
            headers={"Idempotency-Key": str(uuid.uuid4())},
        )
    return await client.post(
        f"/accounts/{random.randint(1, ids['max_account_id'])}/deposit",
        json={"amount": round(random.uniform(1, 500), 2)},
        headers={"Idempotency-Key": str(uuid.uuid4())},
    )


async def run_one(client: httpx.AsyncClient, ids: dict, read_pct: float, stats: Stats) -> None:
    t0 = time.perf_counter()
    try:
        if random.random() * 100 < read_pct:
            path, _ = one_read(client, ids)
            r = await client.get(path)
            body = r.json() if r.headers.get("content-type", "").startswith("application/json") else None
            if r.status_code == 200 and body is not None:
                outcome, reason = "ok", ""
            else:
                outcome, reason = "fail", f"read {r.status_code}"
        else:
            r = await one_write(client, ids)
            endp = r.headers.get("x-db-endpoint")
            if r.status_code == 201 and r.json().get("transfer_id", True) is not None and endp:
                outcome, reason = "ok", ""
            elif r.status_code in (404, 409):
                outcome, reason = "rejected", f"write {r.status_code}"
            else:
                outcome, reason = "fail", f"write {r.status_code}"
    except Exception as exc:  # noqa: BLE001 - we want every failure classified
        outcome, reason = "fail", type(exc).__name__
    stats.record((time.perf_counter() - t0) * 1000, outcome, reason)


async def reporter(stats: Stats, every: float, stop: asyncio.Event) -> None:
    last = 0
    while not stop.is_set():
        await asyncio.sleep(every)
        s = stats.summary()
        rate = s["sent"] - last
        last = s["sent"]
        print(
            f"[traffic] t={s['elapsed_s']:>6.0f}s sent={s['sent']:>8} ok={s['ok']:>8} "
            f"rej={s['rejected']:>6} fail={s['failed']:>5} "
            f"win_rps={rate / every:6.1f} avg_rps={s['achieved_rps']:6.1f} p95={s['latency_ms']['p95']:6.1f}ms",
            flush=True,
        )


async def main() -> int:
    args = parse_args()
    read_pct, write_pct = (float(x) for x in args.mix.split(":"))
    read_pct = read_pct / (read_pct + write_pct) * 100
    random.seed(args.seed)

    stop = asyncio.Event()

    def _stop(*_):
        stop.set()

    loop = asyncio.get_running_loop()
    for sig in (signal.SIGINT, signal.SIGTERM):
        loop.add_signal_handler(sig, _stop)

    stats = Stats()
    async with httpx.AsyncClient(base_url=args.base_url, timeout=30, limits=httpx.Limits(max_connections=args.concurrency + 10)) as client:
        # wait for the app, then learn the id space
        for _ in range(60):
            try:
                r = await client.get("/ranges")
                if r.status_code == 200:
                    ids = r.json()
                    ids.setdefault("max_customer_id", 1)
                    ids.setdefault("max_account_id", 1)
                    break
            except Exception:  # noqa: BLE001
                pass
            await asyncio.sleep(1)
        else:
            print("[traffic] app never became ready", flush=True)
            return 2

        print(f"[traffic] ready: base={args.base_url} rps={args.rps} mix={read_pct:.0f}:{100 - read_pct:.0f} ids={ids}", flush=True)
        limiter = RateLimiter(args.rps, args.ramp)
        asyncio.create_task(reporter(stats, args.report_every, stop))

        pending: set[asyncio.Task] = set()
        deadline = time.monotonic() + args.duration if args.duration else None
        while not stop.is_set() and (deadline is None or time.monotonic() < deadline):
            await limiter.acquire()
            t = asyncio.create_task(run_one(client, ids, read_pct, stats))
            pending.add(t)
            t.add_done_callback(pending.discard)
            while len(pending) >= args.concurrency:
                await asyncio.sleep(0.002)
        if pending:
            await asyncio.gather(*pending, return_exceptions=True)

        summary = stats.summary()
        os.makedirs(args.out, exist_ok=True)
        path = os.path.join(args.out, f"traffic-{int(time.time())}.json")
        with open(path, "w", encoding="utf-8") as fh:
            json.dump({"args": vars(args), "ids": ids, "summary": summary}, fh, indent=2)
        print(f"[traffic] done: {json.dumps(summary)}", flush=True)
        print(f"[traffic] wrote {path}", flush=True)
        return 0 if summary["failed"] == 0 else 1


if __name__ == "__main__":
    raise SystemExit(asyncio.run(main()))
