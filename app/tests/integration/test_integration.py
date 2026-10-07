"""Against real Postgres and Redis from tests/compose.test.yml (make test)."""

import os
import time
from pathlib import Path

import psycopg
import pytest
from fastapi.testclient import TestClient

from adpulse.config import Settings
from adpulse.main import create_app
from adpulse.migrate import DEFAULT_DIR, migrate

pytestmark = [
    pytest.mark.integration,
    pytest.mark.skipif(os.environ.get("ADPULSE_INTEGRATION") != "1", reason="set ADPULSE_INTEGRATION=1"),
]


@pytest.fixture(scope="module")
def settings():
    s = Settings()
    migrate(s, Path(DEFAULT_DIR), wait_seconds=60)
    return s


def test_migrations_are_idempotent(settings):
    assert migrate(settings, Path(DEFAULT_DIR)) == []
    with psycopg.connect(settings.db_conninfo) as conn:
        versions = [r[0] for r in conn.execute("SELECT version FROM schema_migrations ORDER BY version")]
        ads = conn.execute("SELECT count(*) FROM ads").fetchone()[0]
        advertisers = conn.execute("SELECT count(*) FROM advertisers").fetchone()[0]
    assert versions == ["001_init", "002_seed"]
    assert ads == 60 and advertisers == 10


def test_serving_path_db_then_cache_and_impressions(settings):
    with TestClient(create_app(settings)) as client:
        assert client.get("/readyz").status_code == 200
        params = {"category": "finance", "segment": "parent"}
        # Clear the key first so the first call must come from the DB.
        import redis

        redis.Redis(host=settings.redis_host, port=settings.redis_port, password=settings.redis_password).delete(
            "ads:finance:parent"
        )
        first = client.get("/v1/ad", params=params).json()
        second = client.get("/v1/ad", params=params).json()
        assert first["source"] == "db"
        assert second["source"] == "cache"
        ad_ids = {first["ad"]["id"], second["ad"]["id"]}

    deadline = time.monotonic() + 3
    while time.monotonic() < deadline:
        with psycopg.connect(settings.db_conninfo) as conn:
            n = conn.execute(
                "SELECT count(*) FROM impressions "
                "WHERE category = 'finance' AND segment = 'parent' AND ad_id = ANY(%s)",
                (list(ad_ids),),
            ).fetchone()[0]
        if n >= 2:
            break
        time.sleep(0.1)
    assert n >= 2


def test_every_category_segment_has_candidates(settings):
    from adpulse.selection import Category, Segment

    with TestClient(create_app(settings)) as client:
        for category in Category.__args__:
            for segment in Segment.__args__:
                r = client.get("/v1/ad", params={"category": category, "segment": segment})
                assert r.status_code == 200
                assert r.json()["source"] in ("db", "cache"), (category, segment)
