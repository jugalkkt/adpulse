import asyncio
import json
import os
from pathlib import Path

import pytest

from healer.engine import Healer, Rule, RunResult, load_rules

REPO = Path(__file__).resolve().parents[2]
# In the image these come from ENV; in a repo checkout from the layout.
RULES_FILE = Path(os.environ.get("HEALER_RULES", REPO / "healer" / "healing.yml"))
PLAYBOOKS = Path(os.environ.get("HEALER_PLAYBOOK_DIR", REPO / "ansible" / "playbooks" / "heal"))


class Clock:
    def __init__(self):
        self.now = 1_000.0

    def __call__(self):
        return self.now


class FakeRunner:
    def __init__(self, ok=True, result="success", delay=0.0):
        self.calls = []
        self.ok, self.result, self.delay = ok, result, delay

    async def __call__(self, playbook, extra_vars):
        self.calls.append((playbook, dict(extra_vars)))
        if self.delay:
            await asyncio.sleep(self.delay)
        return RunResult(ok=self.ok, result=self.result, duration_s=0.1)


def alert(name="AdPulseDatabaseDown", env="staging", status="firing", fp="fp1", **labels):
    return {"status": status, "fingerprint": fp, "labels": {"alertname": name, "env": env, **labels}}


def make(rules=None, runner=None, clock=None, dry_run=False):
    escalations, results = [], []

    async def on_escalate(d):
        escalations.append(d)

    async def on_result(d, r):
        results.append((d, r))

    rules = rules or {
        "AdPulseDatabaseDown": Rule("AdPulseDatabaseDown", "restart_db", cooldown_seconds=30),
        "AdPulseApiReplicaDown": Rule(
            "AdPulseApiReplicaDown", "restart_api", extra_vars={"instance": "instance", "reason": "reason"}
        ),
        "AdPulseHighErrorRate": Rule(
            "AdPulseHighErrorRate",
            "restart_api",
            static_vars={"mode": "rolling"},
            max_attempts=1,
            attempt_window_seconds=600,
            cooldown_seconds=0,
        ),
        "ApiContainerHighCPU": Rule("ApiContainerHighCPU", "scale_api", on_resolved="scale_down_api"),
        "BackupStale": Rule("BackupStale", None),
    }
    h = Healer(
        rules,
        runner or FakeRunner(),
        dry_run=dry_run,
        clock=clock or Clock(),
        on_result=on_result,
        on_escalate=on_escalate,
    )
    return h, escalations, results


# ---------------------------------------------------------------- mapping
def test_real_rules_file_loads_and_every_playbook_exists():
    rules = load_rules(RULES_FILE, PLAYBOOKS)
    assert rules["AdPulseDatabaseDown"].playbook == "restart_db"
    assert rules["AdPulseHighLatencyP95"].playbook == "diagnose_latency"
    assert rules["AdPulseServingFallbackAds"].playbook is None
    assert rules["ApiContainerHighCPU"].on_resolved == "scale_down_api"
    assert rules["AdPulseHighErrorRate"].max_attempts == 1


def test_rules_reject_unknown_or_malicious_playbooks(tmp_path):
    (tmp_path / "ok.yml").write_text("- hosts: localhost\n")
    bad = tmp_path / "bad.yml"
    bad.write_text("alerts:\n  X:\n    playbook: ../../etc/passwd\n")
    with pytest.raises(ValueError, match="invalid playbook name"):
        load_rules(bad, tmp_path)
    missing = tmp_path / "missing.yml"
    missing.write_text("alerts:\n  X:\n    playbook: nope\n")
    with pytest.raises(ValueError, match="not found"):
        load_rules(missing, tmp_path)


def test_labels_map_to_extra_vars():
    h, _, _ = make()
    d = h.decide(alert("AdPulseApiReplicaDown", instance="172.28.10.11:8000", reason="unreachable"))
    assert d.kind == "run" and d.playbook == "restart_api"
    assert d.extra_vars == {
        "env": "staging",
        "alertname": "AdPulseApiReplicaDown",
        "instance": "172.28.10.11:8000",
        "reason": "unreachable",
    }
    d2 = h.decide(alert("AdPulseHighErrorRate", fp="fp2"))
    assert d2.extra_vars["mode"] == "rolling"


def test_unmapped_and_no_action_alerts_are_ignored():
    h, _, _ = make()
    assert h.decide(alert("SomethingElse")).reason == "no_rule"
    assert h.decide(alert("BackupStale")).reason == "no_action"


# ---------------------------------------------------------------- resolved
def test_resolved_ignored_unless_on_resolved():
    h, _, _ = make()
    assert h.decide(alert(status="resolved")).reason == "resolved"
    d = h.decide(alert("ApiContainerHighCPU", status="resolved"))
    assert d.kind == "run" and d.playbook == "scale_down_api"


# ---------------------------------------------------------------- dedupe + cooldown
def test_duplicate_webhook_while_in_progress_is_ignored():
    h, _, _ = make()
    assert h.decide(alert()).kind == "run"
    assert h.decide(alert()).reason == "in_progress"


async def test_cooldown_blocks_repeat_then_allows():
    clock = Clock()
    h, _, _ = make(clock=clock)
    d = h.decide(alert())
    await h.execute(d)
    clock.now += 10
    assert h.decide(alert()).reason == "cooldown"
    clock.now += 25  # 35s > 30s cooldown
    assert h.decide(alert()).kind == "run"


# ---------------------------------------------------------------- attempts + escalation
async def test_max_attempts_then_escalate_once():
    clock = Clock()
    h, esc, _ = make(clock=clock)
    for _ in range(3):
        d = h.decide(alert())
        assert d.kind == "run"
        await h.execute(d)
        clock.now += 31
    d = h.decide(alert())
    assert d.kind == "escalate" and d.reason == "max_attempts"
    await h.execute(d)
    assert len(esc) == 1
    clock.now += 31
    assert h.decide(alert()).reason == "already_escalated"


async def test_attempt_window_expires():
    clock = Clock()
    h, _, _ = make(clock=clock)
    for _ in range(3):
        await h.execute(h.decide(alert()))
        clock.now += 31
    clock.now += 900
    assert h.decide(alert()).kind == "run"


async def test_error_rate_refiring_within_10_minutes_escalates():
    clock = Clock()
    h, esc, _ = make(clock=clock)
    await h.execute(h.decide(alert("AdPulseHighErrorRate")))
    clock.now += 300
    d = h.decide(alert("AdPulseHighErrorRate"))
    assert d.kind == "escalate"
    clock.now += 601
    assert h.decide(alert("AdPulseHighErrorRate")).kind == "run"


async def test_failed_playbook_escalates():
    h, esc, results = make(runner=FakeRunner(ok=False, result="failed"))
    await h.execute(h.decide(alert()))
    assert results[0][1].result == "failed"
    assert len(esc) == 1 and esc[0].reason == "playbook_failed"


# ---------------------------------------------------------------- dry run
async def test_dry_run_never_calls_the_runner():
    runner = FakeRunner()
    h, _, results = make(runner=runner, dry_run=True)
    await h.execute(h.decide(alert()))
    assert runner.calls == []
    assert results[0][1].result == "dry_run"


# ---------------------------------------------------------------- per-env lock
async def test_one_action_at_a_time_per_env():
    runner = FakeRunner(delay=0.05)
    h, _, _ = make(runner=runner)
    active, peak = 0, 0
    orig = runner.__call__

    async def tracking(pb, ev):
        nonlocal active, peak
        active += 1
        peak = max(peak, active)
        try:
            return await orig(pb, ev)
        finally:
            active -= 1

    h.runner = tracking
    d1 = h.decide(alert("AdPulseDatabaseDown", fp="a"))
    d2 = h.decide(alert("AdPulseApiReplicaDown", fp="b"))
    d3 = h.decide(alert("AdPulseDatabaseDown", env="prod", fp="c"))
    await asyncio.gather(h.execute(d1), h.execute(d2), h.execute(d3))
    assert peak == 2  # staging actions serialized; prod ran alongside


# ---------------------------------------------------------------- webhook (dry run)
def test_webhook_dry_run_logs_intended_playbook(tmp_path):
    os.environ["HEALER_NO_AUTOAPP"] = "1"
    from fastapi.testclient import TestClient

    from healer.app import Settings, create_app

    s = Settings()
    s.rules_file, s.playbook_dir, s.data_dir, s.dry_run, s.grafana_token = RULES_FILE, PLAYBOOKS, tmp_path, True, ""
    payload = {
        "version": "4",
        "status": "firing",
        "receiver": "healer",
        "alerts": [
            {
                "status": "firing",
                "fingerprint": "abc",
                "labels": {"alertname": "AdPulseDatabaseDown", "env": "staging"},
            },
            {"status": "firing", "fingerprint": "def", "labels": {"alertname": "BackupStale", "env": "staging"}},
        ],
    }
    with TestClient(create_app(s)) as client:
        r = client.post("/alertmanager", json=payload)
        assert r.status_code == 200
        kinds = [(d["alertname"], d["kind"], d["playbook"]) for d in r.json()["decisions"]]
        assert kinds == [("AdPulseDatabaseDown", "run", "restart_db"), ("BackupStale", "ignore", None)]
        client.get("/healthz")  # let the background task finish
        metrics = client.get("/metrics").text
    lines = [json.loads(x) for x in (tmp_path / "heal-log.jsonl").read_text().splitlines()]
    assert lines[0]["action"] == "restart_db" and lines[0]["result"] == "dry_run"
    assert 'adpulse_heal_actions_total{alertname="AdPulseDatabaseDown",env="staging",result="dry_run"} 1.0' in metrics
