"""Healer web service (plan Section 11).

POST /alertmanager  Alertmanager webhook v4 -> decisions -> playbooks (background)
GET  /healthz       liveness
GET  /metrics       Prometheus metrics
"""

import asyncio
import json
import logging
import os
import sys
import time
from contextlib import asynccontextmanager
from datetime import UTC, datetime
from pathlib import Path

import httpx
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, Response
from prometheus_client import CONTENT_TYPE_LATEST, CollectorRegistry, Counter, Gauge, Histogram, generate_latest

from .engine import Decision, Healer, RunResult, load_rules

log = logging.getLogger("healer")


class Settings:
    def __init__(self) -> None:
        env = os.environ.get
        self.rules_file = Path(env("HEALER_RULES", "/opt/adpulse/healer/healing.yml"))
        self.playbook_dir = Path(env("HEALER_PLAYBOOK_DIR", "/opt/adpulse/heal"))
        self.data_dir = Path(env("HEALER_DATA_DIR", "/data"))
        self.dry_run = env("HEALER_DRY_RUN", "false").lower() == "true"
        self.timeout_s = float(env("HEALER_PLAYBOOK_TIMEOUT", "120"))
        self.grafana_url = env("GRAFANA_URL", "http://grafana:3000")
        self.grafana_token = env("GRAFANA_SA_TOKEN", "")
        self.escalation_webhook = env("ALERT_WEBHOOK_URL", "")


class Metrics:
    def __init__(self) -> None:
        r = self.registry = CollectorRegistry()
        self.actions = Counter(
            "adpulse_heal_actions_total", "Heal actions by result", ["alertname", "env", "result"], registry=r
        )
        self.duration = Histogram(
            "adpulse_heal_duration_seconds",
            "Duration of heal playbooks",
            ["playbook"],
            buckets=(1, 2, 5, 10, 20, 30, 60, 90, 120),
            registry=r,
        )
        # Label "alert" (not "alertname"): Prometheus would overwrite alertname
        # with the HealerEscalated rule's own name.
        self.escalations = Counter(
            "adpulse_heal_escalations_total", "Escalations to a human", ["alert", "env", "reason"], registry=r
        )
        self.in_progress = Gauge("adpulse_heal_in_progress", "Heal playbooks running now", registry=r)
        self.decisions = Counter(
            "adpulse_heal_decisions_total", "Webhook alert decisions", ["alertname", "kind", "reason"], registry=r
        )


def setup_logging() -> None:
    class Json(logging.Formatter):
        def format(self, rec: logging.LogRecord) -> str:
            base = {
                "ts": datetime.fromtimestamp(rec.created, UTC).isoformat(timespec="milliseconds"),
                "level": rec.levelname,
                "logger": rec.name,
                "msg": rec.getMessage(),
            }
            base.update(getattr(rec, "fields", {}))
            return json.dumps(base, default=str)

    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(Json())
    logging.getLogger().handlers[:] = [h]
    logging.getLogger().setLevel(logging.INFO)
    logging.getLogger("httpx").setLevel(logging.WARNING)


def make_runner(settings: Settings, metrics: Metrics):
    async def run(playbook: str, extra_vars: dict) -> RunResult:
        path = settings.playbook_dir / f"{playbook}.yml"
        start = time.monotonic()
        metrics.in_progress.inc()
        try:
            proc = await asyncio.create_subprocess_exec(
                "ansible-playbook",
                str(path),
                "-e",
                json.dumps(extra_vars),
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.STDOUT,
                cwd=str(settings.playbook_dir),
            )
            try:
                out, _ = await asyncio.wait_for(proc.communicate(), timeout=settings.timeout_s)
                ok = proc.returncode == 0
                result = "success" if ok else "failed"
            except TimeoutError:
                proc.kill()
                out, _ = await proc.communicate()
                ok, result = False, "timeout"
        finally:
            metrics.in_progress.dec()
        duration = time.monotonic() - start
        metrics.duration.labels(playbook=playbook).observe(duration)
        tail = (out or b"").decode(errors="replace")[-2000:]
        return RunResult(ok=ok, result=result, duration_s=round(duration, 2), stdout_tail=tail)

    return run


class Reporter:
    """Heal log (JSON lines), metrics, Grafana annotations, escalation."""

    def __init__(self, settings: Settings, metrics: Metrics) -> None:
        self.s = settings
        self.m = metrics
        self.log_path = settings.data_dir / "heal-log.jsonl"
        self._write_lock = asyncio.Lock()

    async def write(self, entry: dict) -> None:
        line = json.dumps({"ts": datetime.now(UTC).isoformat(timespec="milliseconds"), **entry}) + "\n"
        async with self._write_lock:
            try:
                self.log_path.parent.mkdir(parents=True, exist_ok=True)
                with self.log_path.open("a") as f:
                    f.write(line)
            except OSError as exc:
                log.warning("cannot write heal log", extra={"fields": {"error": str(exc)}})

    async def annotate(self, decision: Decision, text: str) -> None:
        if not self.s.grafana_token:
            return
        body = {
            "time": int(time.time() * 1000),
            "tags": ["heal", decision.env, decision.alertname],
            "text": text,
        }
        try:
            async with httpx.AsyncClient(timeout=5) as c:
                r = await c.post(
                    f"{self.s.grafana_url}/api/annotations",
                    json=body,
                    headers={"Authorization": f"Bearer {self.s.grafana_token}"},
                )
                r.raise_for_status()
        except httpx.HTTPError as exc:
            log.warning("grafana annotation failed", extra={"fields": {"error": str(exc)}})

    async def on_result(self, d: Decision, r: RunResult) -> None:
        self.m.actions.labels(alertname=d.alertname, env=d.env, result=r.result).inc()
        entry = {
            "alertname": d.alertname,
            "env": d.env,
            "fingerprint": d.fingerprint,
            "action": d.playbook,
            "trigger": d.reason,
            "attempt": d.attempt,
            "result": r.result,
            "duration_s": r.duration_s,
            "extra_vars": d.extra_vars,
            "stdout_tail": r.stdout_tail,
        }
        await self.write(entry)
        level = logging.INFO if r.ok else logging.ERROR
        log.log(level, "heal action finished", extra={"fields": {k: v for k, v in entry.items() if k != "stdout_tail"}})
        await self.annotate(d, f"healer: {d.playbook} for {d.alertname} ({d.env}) -> {r.result} in {r.duration_s}s")

    async def on_escalate(self, d: Decision) -> None:
        self.m.escalations.labels(alert=d.alertname, env=d.env, reason=d.reason).inc()
        entry = {
            "alertname": d.alertname,
            "env": d.env,
            "fingerprint": d.fingerprint,
            "action": "escalate",
            "trigger": d.reason,
            "attempt": d.attempt,
            "result": "escalated",
            "duration_s": 0,
        }
        await self.write(entry)
        log.error("ESCALATION: human action needed", extra={"fields": entry})
        await self.annotate(d, f"healer ESCALATED {d.alertname} ({d.env}): {d.reason}")
        if self.s.escalation_webhook:
            try:
                async with httpx.AsyncClient(timeout=5) as c:
                    await c.post(
                        self.s.escalation_webhook,
                        json={"content": f"AdPulse healer escalation: {d.alertname} ({d.env}) - {d.reason}"},
                    )
            except httpx.HTTPError as exc:
                log.warning("escalation webhook failed", extra={"fields": {"error": str(exc)}})


def create_app(settings: Settings | None = None, healer: Healer | None = None) -> FastAPI:
    settings = settings or Settings()
    metrics = Metrics()
    reporter = Reporter(settings, metrics)
    if healer is None:
        rules = load_rules(settings.rules_file, settings.playbook_dir)
        healer = Healer(
            rules,
            make_runner(settings, metrics),
            dry_run=settings.dry_run,
            on_result=reporter.on_result,
            on_escalate=reporter.on_escalate,
        )
    tasks: set[asyncio.Task] = set()

    @asynccontextmanager
    async def lifespan(app: FastAPI):
        log.info(
            "healer started",
            extra={
                "fields": {
                    "dry_run": settings.dry_run,
                    "rules": len(healer.rules),
                    "grafana": bool(settings.grafana_token),
                }
            },
        )
        yield
        for t in tasks:
            t.cancel()

    app = FastAPI(title="AdPulse healer", lifespan=lifespan, docs_url=None, redoc_url=None)
    app.state.healer = healer
    app.state.tasks = tasks

    @app.post("/alertmanager")
    async def alertmanager(request: Request):
        payload = await request.json()
        decisions = []
        for alert in payload.get("alerts", []):
            d = healer.decide(alert)
            metrics.decisions.labels(alertname=d.alertname, kind=d.kind, reason=d.reason).inc()
            log.info("decision", extra={"fields": {**d.as_dict(), "dry_run": healer.dry_run}})
            decisions.append(d.as_dict())
            if d.kind in ("run", "escalate"):
                t = asyncio.create_task(healer.execute(d))
                tasks.add(t)
                t.add_done_callback(tasks.discard)
        return JSONResponse({"received": len(decisions), "decisions": decisions})

    @app.get("/healthz")
    async def healthz():
        return {"status": "ok", "dry_run": healer.dry_run}

    @app.get("/metrics")
    async def metrics_endpoint():
        return Response(generate_latest(metrics.registry), media_type=CONTENT_TYPE_LATEST)

    return app


def _default_app() -> FastAPI:
    setup_logging()
    return create_app()


app = _default_app() if os.environ.get("HEALER_NO_AUTOAPP") != "1" else None
