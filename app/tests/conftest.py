import random

import pytest
from fastapi.testclient import TestClient

from adpulse.config import Settings
from adpulse.main import create_app
from adpulse.metrics import Metrics

ADS = [
    {"id": 1, "advertiser": "A", "title": "t1", "image_url": "i1", "click_url": "c1", "bid_cpm": 1.0},
    {"id": 2, "advertiser": "B", "title": "t2", "image_url": "i2", "click_url": "c2", "bid_cpm": 3.0},
]


class FakeCache:
    def __init__(self, mode: str = "miss", data=None) -> None:
        self.mode = mode  # hit | miss | error
        self.data = data if data is not None else ADS
        self.sets: list = []

    async def get_candidates(self, category, segment):
        if self.mode == "error":
            raise ConnectionError("cache down")
        return list(self.data) if self.mode == "hit" else None

    async def set_candidates(self, category, segment, candidates):
        if self.mode == "error":
            raise ConnectionError("cache down")
        self.sets.append((category, segment, candidates))

    async def ping(self):
        if self.mode == "error":
            raise ConnectionError("cache down")

    async def close(self):
        pass


class FakeDB:
    def __init__(self, fail: bool = False, rows=None) -> None:
        self.fail = fail
        self.rows = rows if rows is not None else ADS
        self.selects = 0
        self.impressions: list = []

    async def open(self):
        pass

    async def close(self):
        pass

    async def fetch_candidates(self, category, segment):
        self.selects += 1
        if self.fail:
            raise ConnectionError("db down")
        return list(self.rows)

    async def insert_impression(self, *args):
        if self.fail:
            raise ConnectionError("db down")
        self.impressions.append(args)

    async def ping(self):
        if self.fail:
            raise ConnectionError("db down")


class FakeClock:
    def __init__(self) -> None:
        self.now = 1000.0

    def __call__(self) -> float:
        return self.now


@pytest.fixture
def make_client():
    """Build a TestClient around create_app with fakes; returns (client, parts)."""
    clients = []

    def _make(cache=None, db=None, clock=None, **settings_kw):
        settings = Settings(**{"app_env": "test", "git_sha": "abc123", "chaos_token": "s3cret", **settings_kw})
        parts = {
            "cache": cache or FakeCache(),
            "db": db or FakeDB(),
            "metrics": Metrics(),
            "clock": clock or FakeClock(),
        }
        app = create_app(
            settings,
            db=parts["db"],
            cache=parts["cache"],
            metrics=parts["metrics"],
            rng=random.Random(7),
            chaos_clock=parts["clock"],
        )
        client = TestClient(app)
        client.__enter__()
        clients.append(client)
        parts["app"] = app
        return client, parts

    yield _make
    for c in clients:
        c.__exit__(None, None, None)


def metric(parts, name: str, **labels) -> float:
    value = parts["metrics"].registry.get_sample_value(name, labels or None)
    return value or 0.0
