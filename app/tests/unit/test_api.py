import asyncio
import time

import pytest

from tests.conftest import FakeCache, FakeDB, metric


def test_get_ad_returns_contract(make_client):
    client, parts = make_client(cache=FakeCache("hit"))
    r = client.get("/v1/ad", params={"category": "sports", "segment": "student"})
    assert r.status_code == 200
    body = r.json()
    assert set(body) == {"request_id", "ad", "source", "env"}
    assert set(body["ad"]) == {"id", "advertiser", "title", "image_url", "click_url", "bid_cpm"}
    assert body["source"] == "cache" and body["env"] == "test"


def test_request_id_is_propagated(make_client):
    client, _ = make_client()
    r = client.get("/v1/ad", params={"category": "tech", "segment": "all"}, headers={"X-Request-ID": "req-42"})
    assert r.json()["request_id"] == "req-42"
    assert r.headers["X-Request-ID"] == "req-42"


@pytest.mark.parametrize(
    "params",
    [
        {"category": "cars", "segment": "student"},
        {"category": "sports", "segment": "aliens"},
        {"category": "sports"},
        {},
    ],
)
def test_invalid_params_return_422(make_client, params):
    client, _ = make_client()
    assert client.get("/v1/ad", params=params).status_code == 422


def test_fallback_served_with_200_when_dependencies_down(make_client):
    client, parts = make_client(cache=FakeCache("error"), db=FakeDB(fail=True))
    r = client.get("/v1/ad", params={"category": "food", "segment": "parent"})
    assert r.status_code == 200
    assert r.json()["source"] == "fallback"
    assert metric(parts, "adpulse_fallback_total") == 1


def test_impressions_are_written_asynchronously(make_client):
    client, parts = make_client(cache=FakeCache("hit"))
    for _ in range(3):
        client.get("/v1/ad", params={"category": "sports", "segment": "student"})
    deadline = time.monotonic() + 2
    while len(parts["db"].impressions) < 3 and time.monotonic() < deadline:
        time.sleep(0.01)
    assert len(parts["db"].impressions) == 3


class BlockingDB(FakeDB):
    """Impression writes never finish, so the queue fills up."""

    async def insert_impression(self, *args):
        await asyncio.Event().wait()


def test_full_impression_queue_drops_instead_of_blocking(make_client):
    client, parts = make_client(cache=FakeCache("hit"), db=BlockingDB(), impression_queue_size=1)
    start = time.monotonic()
    for _ in range(3):
        r = client.get("/v1/ad", params={"category": "sports", "segment": "student"})
        assert r.status_code == 200
    assert time.monotonic() - start < 2  # serving never waits on impression writes
    # Worker holds at most 1 item and the queue 1 more, so at least 1 of 3 is dropped.
    assert metric(parts, "adpulse_impressions_dropped_total") >= 1


def test_healthz_ok_without_db(make_client):
    client, _ = make_client(cache=FakeCache("error"), db=FakeDB(fail=True))
    assert client.get("/healthz").status_code == 200


def test_readyz(make_client):
    client, _ = make_client()
    assert client.get("/readyz").status_code == 200
    client, _ = make_client(db=FakeDB(fail=True))
    r = client.get("/readyz")
    assert r.status_code == 503 and r.json()["checks"]["db"].startswith("error")


def test_readyz_broken_release(make_client):
    client, _ = make_client(broken_release=True)
    r = client.get("/readyz")
    assert r.status_code == 503
    assert r.json()["checks"]["release"] == "BROKEN_RELEASE=true"


def test_metrics_endpoint(make_client):
    client, _ = make_client()
    client.get("/v1/ad", params={"category": "tech", "segment": "all"})
    text = client.get("/metrics").text
    assert 'adpulse_build_info{env="test",git_sha="abc123",version="0.1.0"} 1.0' in text
    assert 'adpulse_http_requests_total{method="GET",route="/v1/ad",status="200"}' in text
    assert "adpulse_http_request_duration_seconds_bucket" in text
