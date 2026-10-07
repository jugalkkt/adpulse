import random
from collections import Counter

import pytest

from adpulse.metrics import Metrics
from adpulse.selection import FALLBACK_AD, AdSelector, choose_weighted
from tests.conftest import ADS, FakeCache, FakeDB


def test_weighted_selection_follows_bid_cpm():
    rng = random.Random(42)
    counts = Counter(choose_weighted(ADS, rng)["id"] for _ in range(20_000))
    # bid_cpm 1.0 vs 3.0 -> expected share 25% / 75%
    assert counts[2] / 20_000 == pytest.approx(0.75, abs=0.02)


def test_weighted_selection_is_deterministic_with_injected_rng():
    a = [choose_weighted(ADS, random.Random(1))["id"] for _ in range(5)]
    b = [choose_weighted(ADS, random.Random(1))["id"] for _ in range(5)]
    assert a == b


def test_single_candidate_always_chosen():
    assert choose_weighted(ADS[:1], random.Random())["id"] == 1


def _selector(cache, db):
    metrics = Metrics()
    return AdSelector(cache, db, metrics, random.Random(3)), metrics


def _m(metrics, name, **labels):
    return metrics.registry.get_sample_value(name, labels or None) or 0.0


async def test_cache_hit_skips_db():
    cache, db = FakeCache("hit"), FakeDB()
    sel, m = _selector(cache, db)
    ad, source = await sel.select("sports", "student")
    assert source == "cache" and ad["id"] in (1, 2)
    assert db.selects == 0
    assert _m(m, "adpulse_cache_requests_total", result="hit") == 1
    assert _m(m, "adpulse_ad_served_total", source="cache") == 1


async def test_cache_miss_loads_db_and_refills_cache():
    cache, db = FakeCache("miss"), FakeDB()
    sel, m = _selector(cache, db)
    _, source = await sel.select("tech", "parent")
    assert source == "db"
    assert db.selects == 1
    assert cache.sets and cache.sets[0][:2] == ("tech", "parent")
    assert _m(m, "adpulse_cache_requests_total", result="miss") == 1


async def test_cache_error_falls_through_to_db_without_refill():
    cache, db = FakeCache("error"), FakeDB()
    sel, m = _selector(cache, db)
    _, source = await sel.select("food", "retiree")
    assert source == "db"
    assert cache.sets == []
    assert _m(m, "adpulse_cache_requests_total", result="error") == 1


async def test_fallback_when_cache_and_db_both_fail():
    cache, db = FakeCache("error"), FakeDB(fail=True)
    sel, m = _selector(cache, db)
    ad, source = await sel.select("travel", "all")
    assert source == "fallback"
    assert ad == FALLBACK_AD
    assert _m(m, "adpulse_fallback_total") == 1
    assert _m(m, "adpulse_db_errors_total", op="select") == 1


async def test_fallback_when_cache_misses_and_db_fails():
    sel, _ = _selector(FakeCache("miss"), FakeDB(fail=True))
    _, source = await sel.select("travel", "all")
    assert source == "fallback"
