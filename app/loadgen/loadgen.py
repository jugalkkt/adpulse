"""Steady synthetic traffic against nginx (python -m loadgen.loadgen).

Env: LOADGEN_TARGET (base URL), LOADGEN_RPS, LOADGEN_TIMEOUT_SECONDS, APP_ENV.
Logs one JSON summary line every LOADGEN_REPORT_SECONDS (default 30).
"""

import asyncio
import logging
import os
import random
import time
from collections import Counter

import httpx

from adpulse.logging_setup import setup_logging

CATEGORIES = {"sports": 25, "tech": 20, "fashion": 15, "travel": 15, "finance": 10, "food": 15}
SEGMENTS = {"student": 30, "young_professional": 30, "parent": 20, "retiree": 10, "all": 10}

log = logging.getLogger("adpulse.loadgen")


def pick(rng: random.Random, weights: dict[str, int]) -> str:
    return rng.choices(list(weights), weights=list(weights.values()), k=1)[0]


def p95(values: list[float]) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(0.95 * len(ordered)))]


class Stats:
    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.status: Counter = Counter()
        self.source: Counter = Counter()
        self.latencies: list[float] = []

    def summary(self) -> dict:
        return {
            "requests": sum(self.status.values()),
            "status": dict(self.status),
            "source": dict(self.source),
            "p95_ms": round(p95(self.latencies) * 1000, 1),
        }


async def one_request(client: httpx.AsyncClient, rng: random.Random, stats: Stats) -> None:
    params = {"category": pick(rng, CATEGORIES), "segment": pick(rng, SEGMENTS)}
    start = time.perf_counter()
    try:
        resp = await client.get("/v1/ad", params=params)
        stats.status[str(resp.status_code)] += 1
        if resp.status_code == 200:
            stats.source[resp.json().get("source", "?")] += 1
    except httpx.HTTPError as exc:
        stats.status[type(exc).__name__] += 1
    stats.latencies.append(time.perf_counter() - start)


async def run() -> None:
    target = os.environ.get("LOADGEN_TARGET", "http://localhost:8080")
    rps = float(os.environ.get("LOADGEN_RPS", "10"))
    timeout = float(os.environ.get("LOADGEN_TIMEOUT_SECONDS", "3"))
    report_every = float(os.environ.get("LOADGEN_REPORT_SECONDS", "30"))
    rng = random.Random()
    stats = Stats()
    in_flight: set[asyncio.Task] = set()
    log.info("loadgen started", extra={"target": target, "rps": rps})
    async with httpx.AsyncClient(base_url=target, timeout=timeout) as client:
        interval = 1.0 / rps
        next_tick = time.monotonic()
        next_report = next_tick + report_every
        while True:
            if len(in_flight) < 200:  # bound concurrency if the target is hanging
                task = asyncio.create_task(one_request(client, rng, stats))
                in_flight.add(task)
                task.add_done_callback(in_flight.discard)
            next_tick += interval
            now = time.monotonic()
            if now >= next_report:
                log.info("loadgen summary", extra={"window_s": report_every, **stats.summary()})
                stats.reset()
                next_report = now + report_every
            await asyncio.sleep(max(0.0, next_tick - time.monotonic()))


def main() -> None:
    setup_logging(os.environ.get("APP_ENV", "dev"), os.environ.get("LOG_LEVEL", "INFO"))
    asyncio.run(run())


if __name__ == "__main__":
    main()
