import time

from adpulse.chaos import ChaosState
from adpulse.metrics import Metrics
from tests.conftest import FakeClock, metric

TOKEN = {"X-Chaos-Token": "s3cret"}
AD = {"category": "sports", "segment": "student"}


def test_mode_expires_after_its_duration():
    clock, metrics = FakeClock(), Metrics()
    chaos = ChaosState(metrics, clock=clock)
    chaos.activate("error_rate", 10, pct=50)
    assert chaos.active("error_rate") == {"pct": 50}
    assert metrics.registry.get_sample_value("adpulse_chaos_active", {"mode": "error_rate"}) == 1
    clock.now += 9.9
    assert chaos.active("error_rate") is not None
    clock.now += 0.2
    assert chaos.active("error_rate") is None
    assert metrics.registry.get_sample_value("adpulse_chaos_active", {"mode": "error_rate"}) == 0


def test_reset_clears_all_modes():
    clock = FakeClock()
    chaos = ChaosState(Metrics(), clock=clock)
    chaos.activate("latency", 60, ms=100)
    chaos.activate("hang", 60)
    chaos.reset()
    assert chaos.snapshot() == {}


def test_chaos_routes_are_404_when_disabled(make_client):
    client, _ = make_client(chaos_enabled=False)
    assert client.post("/admin/chaos/error_rate", headers=TOKEN).status_code == 404
    assert client.delete("/admin/chaos", headers=TOKEN).status_code == 404


def test_chaos_requires_valid_token(make_client):
    client, _ = make_client(chaos_enabled=True)
    assert client.post("/admin/chaos/error_rate").status_code == 403
    assert client.post("/admin/chaos/error_rate", headers={"X-Chaos-Token": "nope"}).status_code == 403


def test_chaos_rejects_everything_when_token_unset(make_client):
    client, _ = make_client(chaos_enabled=True, chaos_token="")
    assert client.post("/admin/chaos/error_rate", headers={"X-Chaos-Token": ""}).status_code == 403


def test_error_rate_injects_500s_then_expires(make_client):
    client, parts = make_client(chaos_enabled=True)
    r = client.post("/admin/chaos/error_rate", params={"pct": 100, "seconds": 30}, headers=TOKEN)
    assert r.status_code == 200
    assert client.get("/v1/ad", params=AD).status_code == 500
    parts["clock"].now += 31
    assert client.get("/v1/ad", params=AD).status_code == 200
    assert metric(parts, "adpulse_chaos_active", mode="error_rate") == 0


def test_delete_resets_chaos(make_client):
    client, parts = make_client(chaos_enabled=True)
    client.post("/admin/chaos/error_rate", params={"pct": 100, "seconds": 300}, headers=TOKEN)
    assert client.delete("/admin/chaos", headers=TOKEN).status_code == 200
    assert client.get("/v1/ad", params=AD).status_code == 200


def test_chaos_param_validation(make_client):
    client, _ = make_client(chaos_enabled=True)
    assert client.post("/admin/chaos/error_rate", params={"pct": 150}, headers=TOKEN).status_code == 422
    assert client.post("/admin/chaos/hang", params={"seconds": 0}, headers=TOKEN).status_code == 422
    assert client.post("/admin/chaos/memory_leak", params={"mb_per_sec": 500}, headers=TOKEN).status_code == 422


def test_memory_leak_allocates_and_is_freed_on_reset(make_client):
    client, parts = make_client(chaos_enabled=True)
    client.post("/admin/chaos/memory_leak", params={"mb_per_sec": 1, "seconds": 60}, headers=TOKEN)
    chaos = parts["app"].state.chaos
    deadline = time.monotonic() + 2
    while chaos.leaked_bytes < 1024 * 1024 and time.monotonic() < deadline:
        time.sleep(0.01)
    assert chaos.leaked_bytes >= 1024 * 1024
    client.delete("/admin/chaos", headers=TOKEN)
    assert chaos.leaked_bytes == 0
