"""Ad selection: cache -> database -> static house ad (graceful degradation)."""

import logging
import random
from typing import Literal

from .metrics import Metrics

Category = Literal["sports", "tech", "fashion", "travel", "finance", "food"]
Segment = Literal["student", "young_professional", "parent", "retiree", "all"]
Source = Literal["cache", "db", "fallback"]

FALLBACK_AD = {
    "id": 0,
    "advertiser": "AdPulse",
    "title": "Advertise with AdPulse",
    "image_url": "https://cdn.adpulse.example/house/default.png",
    "click_url": "https://adpulse.example/advertise",
    "bid_cpm": 0.0,
}

log = logging.getLogger("adpulse.selection")


def choose_weighted(candidates: list[dict], rng: random.Random) -> dict:
    """Pick one candidate with probability proportional to bid_cpm."""
    weights = [float(c["bid_cpm"]) for c in candidates]
    return rng.choices(candidates, weights=weights, k=1)[0]


class AdSelector:
    def __init__(self, cache, db, metrics: Metrics, rng: random.Random | None = None) -> None:
        self.cache = cache
        self.db = db
        self.metrics = metrics
        self.rng = rng or random.Random()

    async def select(self, category: str, segment: str) -> tuple[dict, Source]:
        candidates: list[dict] | None = None
        source: Source = "fallback"

        try:
            candidates = await self.cache.get_candidates(category, segment)
            cache_result = "hit" if candidates else "miss"
        except Exception as exc:  # any cache failure must not break serving
            cache_result = "error"
            log.warning("cache get failed", extra={"error": type(exc).__name__})
        self.metrics.cache_requests.labels(result=cache_result).inc()

        if candidates:
            source = "cache"
        else:
            try:
                candidates = await self.db.fetch_candidates(category, segment)
                source = "db"
            except Exception as exc:
                candidates = None
                self.metrics.db_errors.labels(op="select").inc()
                log.warning("db select failed", extra={"error": type(exc).__name__})
            # Refill the cache only when it answered (a broken cache would just add latency).
            if candidates and cache_result == "miss":
                try:
                    await self.cache.set_candidates(category, segment, candidates)
                except Exception as exc:
                    log.warning("cache set failed", extra={"error": type(exc).__name__})

        if not candidates:
            self.metrics.fallback.inc()
            self.metrics.ad_served.labels(source="fallback").inc()
            return dict(FALLBACK_AD), "fallback"

        self.metrics.ad_served.labels(source=source).inc()
        return choose_weighted(candidates, self.rng), source
