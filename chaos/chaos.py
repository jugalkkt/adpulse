#!/usr/bin/env python3
"""AdPulse chaos tool: inject a fault, watch detection and healing, record a timeline.

    python3 chaos/chaos.py list
    python3 chaos/chaos.py run <scenario> --env staging [--duration 600]
    python3 chaos/chaos.py run db-down --env prod --confirm-prod
    python3 chaos/chaos.py stop --env staging          # emergency cleanup

Each run writes incidents/<UTC ts>-<scenario>-<env>/timeline.json (+ raw/probes.jsonl):
  injected, first_failed_probe, alert_firing, heal_started, heal_finished,
  recovered (system healthy + 3 consecutive good probes), injection_removed.
  MTTD = alert_firing - injected;  MTTR = recovered - injected.
Cleanup always runs (finally). Prod needs --confirm-prod.
Standard library only; talks to Docker via the docker CLI.
"""

import argparse
import json
import os
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
INCIDENTS = ROOT / "incidents"
HEAL_LOG = INCIDENTS / "heal-log.jsonl"
ALERTMANAGER = "http://127.0.0.1:9093"
PROMETHEUS = "http://127.0.0.1:9090"
NGINX_PORT = {"staging": 8081, "prod": 8080}
GOOD_LATENCY_S = 0.25
CHAOS_LABELS = ["--label", "com.adpulse.project=adpulse", "--label", "com.adpulse.role=chaos"]


# ---------------------------------------------------------------- helpers
def now() -> float:
    return time.time()


def iso(ts: float) -> str:
    return datetime.fromtimestamp(ts, UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


def sh(*args: str, check: bool = True, capture: bool = True) -> str:
    r = subprocess.run(list(args), capture_output=capture, text=True, timeout=120)  # noqa: S603
    if check and r.returncode != 0:
        raise RuntimeError(f"{' '.join(args)} failed: {r.stderr.strip()[:300]}")
    return (r.stdout or "").strip()


def http_json(url: str, method: str = "GET", timeout: float = 5):
    req = urllib.request.Request(url, method=method)  # noqa: S310 - fixed local URLs
    with urllib.request.urlopen(req, timeout=timeout) as r:  # noqa: S310
        body = r.read()
    return json.loads(body) if body else None


def env_file_value(name: str) -> str:
    for line in (ROOT / ".env").read_text().splitlines():
        if line.startswith(name + "="):
            return line.split("=", 1)[1]
    raise KeyError(name)


def container_health(name: str) -> str:
    out = sh(
        "docker",
        "inspect",
        "-f",
        "{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}",
        name,
        check=False,
    )
    return out or "missing/none"


def api_replicas(env: str) -> list[str]:
    out = sh(
        "docker",
        "ps",
        "-a",
        "--filter",
        f"label=com.adpulse.env={env}",
        "--filter",
        "label=com.adpulse.role=api",
        "--format",
        "{{.Names}}",
        check=False,
    )
    return sorted(n for n in out.split() if n.startswith(f"api-{env}-") and n.rsplit("-", 1)[1].isdigit())


def chaos_api(container: str, method: str, path: str) -> str:
    """Call the replica's chaos endpoint from inside the container (it is not exposed via nginx)."""
    token = env_file_value("CHAOS_TOKEN")
    return sh(
        "docker",
        "exec",
        container,
        "curl",
        "-s",
        "-X",
        method,
        "-H",
        f"X-Chaos-Token: {token}",
        f"http://127.0.0.1:8000{path}",
        check=False,
    )


def prom_value(query: str) -> float | None:
    try:
        res = http_json(f"{PROMETHEUS}/api/v1/query?" + urllib.parse.urlencode({"query": query}))
        r = res["data"]["result"]
        return float(r[0]["value"][1]) if r else None
    except (urllib.error.URLError, KeyError, ValueError, IndexError):
        return None


def active_alerts(env: str) -> list[dict]:
    try:
        alerts = http_json(f"{ALERTMANAGER}/api/v2/alerts?active=true&silenced=false&inhibited=true")
    except urllib.error.URLError:
        return []
    return [a for a in alerts if a["labels"].get("env") in (env, "host")]


# ---------------------------------------------------------------- probe
@dataclass
class Probe:
    env: str
    path: Path
    samples: list = field(default_factory=list)
    _stop: threading.Event = field(default_factory=threading.Event)

    def start(self) -> None:
        self.path.parent.mkdir(parents=True, exist_ok=True)
        threading.Thread(target=self._run, daemon=True).start()

    def stop(self) -> None:
        self._stop.set()

    def _run(self) -> None:
        url = f"http://127.0.0.1:{NGINX_PORT[self.env]}/v1/ad?category=tech&segment=student"
        with self.path.open("a") as f:
            while not self._stop.is_set():
                t0 = now()
                rec = {"ts": t0, "status": 0, "latency_s": None, "source": None}
                try:
                    with urllib.request.urlopen(url, timeout=3) as r:  # noqa: S310
                        body = json.loads(r.read())
                        rec.update(status=r.status, source=body.get("source"))
                except urllib.error.HTTPError as e:
                    rec["status"] = e.code
                except Exception as e:  # noqa: BLE001 - any failure is a failed probe
                    rec["error"] = type(e).__name__
                rec["latency_s"] = round(now() - t0, 4)
                rec["good"] = (
                    rec["status"] == 200 and rec["source"] in ("cache", "db") and rec["latency_s"] < GOOD_LATENCY_S
                )
                rec["failed"] = rec["status"] != 200
                self.samples.append(rec)
                f.write(json.dumps(rec) + "\n")
                f.flush()
                self._stop.wait(max(0.0, 1.0 - (now() - t0)))

    def last_good(self, n: int = 3) -> bool:
        s = self.samples[-n:]
        return len(s) == n and all(x["good"] for x in s)


# ---------------------------------------------------------------- scenarios
class Scenario:
    name = ""
    layer = ""
    description = ""
    expected_alert = ""
    expected_heal = ""
    chaos_endpoints = False  # needs CHAOS_ENABLED (staging only)
    human_stop = False  # healing is diagnostics only; a human removes the fault
    heavy = False

    def __init__(self, env: str) -> None:
        self.env = env

    def inject(self) -> None:
        raise NotImplementedError

    def tick(self) -> None:
        """Called every second while the run is active (for repeating injections)."""

    def remove(self) -> None:
        """Undo the injection (idempotent; also used by the emergency stop)."""

    def healthy(self) -> bool:
        raise NotImplementedError


class ReplicaDown(Scenario):
    name, layer = "replica-down", "software"
    description = "docker stop api-<env>-1 (manual stop: Docker's restart policy will not restart it)"
    expected_alert, expected_heal = "AdPulseApiReplicaDown", "restart_api"

    def inject(self):
        sh("docker", "stop", f"api-{self.env}-1")

    def remove(self):
        if not container_health(f"api-{self.env}-1").startswith("running"):
            sh("docker", "start", f"api-{self.env}-1", check=False)

    def healthy(self):
        return all(container_health(r) == "running/healthy" for r in api_replicas(self.env))


class ApiHang(Scenario):
    name, layer = "api-hang", "software"
    description = "chaos endpoint hang on api-<env>-1: every route stops answering (scrape and health time out)"
    expected_alert, expected_heal = "AdPulseApiReplicaDown", "restart_api"
    chaos_endpoints = True

    def inject(self):
        chaos_api(f"api-{self.env}-1", "POST", "/admin/chaos/hang?seconds=600")

    def remove(self):
        for r in api_replicas(self.env):
            chaos_api(r, "DELETE", "/admin/chaos")

    def healthy(self):
        return all(container_health(r) == "running/healthy" for r in api_replicas(self.env))


class MemLeak(Scenario):
    name, layer = "mem-leak", "hardware (container memory)"
    description = (
        "chaos endpoint memory_leak on api-<env>-1: 10 MB/s, plateau at 190 MB "
        "(~94% of the 256 MiB limit; uncapped it would OOM before the alert window)"
    )
    expected_alert, expected_heal = "ApiContainerMemoryHigh", "restart_api"
    chaos_endpoints = True

    def inject(self):
        chaos_api(f"api-{self.env}-1", "POST", "/admin/chaos/memory_leak?mb_per_sec=10&max_mb=190&seconds=600")

    def remove(self):
        for r in api_replicas(self.env):
            chaos_api(r, "DELETE", "/admin/chaos")

    def healthy(self):
        mem = prom_value(
            f'max(container_memory_working_set_bytes{{role="api", container="api-{self.env}-1"}})'
            f' / max(container_spec_memory_limit_bytes{{role="api", container="api-{self.env}-1"}})'
        )
        return container_health(f"api-{self.env}-1") == "running/healthy" and mem is not None and mem < 0.5


class ErrorBurst(Scenario):
    name, layer = "error-burst", "software"
    description = "chaos endpoint error_rate 50% on every replica"
    expected_alert, expected_heal = "AdPulseHighErrorRate", "restart_api (rolling)"
    chaos_endpoints = True

    def inject(self):
        for r in api_replicas(self.env):
            chaos_api(r, "POST", "/admin/chaos/error_rate?pct=50&seconds=600")

    def remove(self):
        for r in api_replicas(self.env):
            chaos_api(r, "DELETE", "/admin/chaos")

    def healthy(self):
        for r in api_replicas(self.env):
            state = chaos_api(r, "GET", "/admin/chaos")
            if '"error_rate"' in state or container_health(r) != "running/healthy":
                return False
        return True


class DbDown(Scenario):
    name, layer = "db-down", "database"
    description = "docker stop postgres-<env>"
    expected_alert, expected_heal = "AdPulseDatabaseDown", "restart_db"

    def inject(self):
        sh("docker", "stop", f"postgres-{self.env}")

    def remove(self):
        if not container_health(f"postgres-{self.env}").startswith("running"):
            sh("docker", "start", f"postgres-{self.env}", check=False)

    def healthy(self):
        return container_health(f"postgres-{self.env}") == "running/healthy"


class CacheDown(Scenario):
    name, layer = "cache-down", "database (cache)"
    description = "docker stop redis-<env>"
    expected_alert, expected_heal = "AdPulseCacheDown", "restart_cache"

    def inject(self):
        sh("docker", "stop", f"redis-{self.env}")

    def remove(self):
        if not container_health(f"redis-{self.env}").startswith("running"):
            sh("docker", "start", f"redis-{self.env}", check=False)

    def healthy(self):
        return container_health(f"redis-{self.env}") == "running/healthy"


class CpuHog(Scenario):
    name, layer = "cpu-hog", "hardware (host)"
    description = "adpulse-chaos-stress (stress-ng, workers = nproc, role=chaos), hard limit 180s"
    expected_alert, expected_heal = "HostHighCPU", "kill_noisy_neighbor"
    heavy = True
    container = "adpulse-chaos-stress"

    def inject(self):
        workers = str(os.cpu_count() or 2)
        sh(
            "docker",
            "run",
            "-d",
            "--rm",
            "--name",
            self.container,
            *CHAOS_LABELS,
            "--label",
            f"com.adpulse.env={self.env}",
            "--memory",
            "128m",
            "--read-only",
            "--security-opt",
            "no-new-privileges",
            "--cap-drop",
            "ALL",
            "adpulse-chaos-stress:dev",
            "--cpu",
            workers,
            "--timeout",
            "180s",
        )

    def remove(self):
        sh("docker", "rm", "-f", self.container, check=False)

    def healthy(self):
        running = sh("docker", "ps", "-q", "--filter", f"name=^{self.container}$", check=False)
        busy = prom_value('1 - avg(rate(node_cpu_seconds_total{job="node", mode="idle"}[15s]))')
        return not running and busy is not None and busy < 0.85


class NetLatency(Scenario):
    name, layer = "net-latency", "network"
    description = "Toxiproxy latency toxic 300ms (jitter 100) on the redis proxy (plan's version)"
    expected_alert, expected_heal = "AdPulseHighLatencyP95", "diagnose_latency (human removes the fault)"
    human_stop = True
    proxies = ("redis",)

    def inject(self):
        for p in self.proxies:
            sh(
                "docker",
                "exec",
                f"toxiproxy-{self.env}",
                "/toxiproxy-cli",
                "toxic",
                "add",
                "-t",
                "latency",
                "-a",
                "latency=300",
                "-a",
                "jitter=100",
                "-n",
                f"chaos_latency_{p}",
                p,
            )

    def remove(self):
        remove_toxics(self.env)

    def healthy(self):
        return not list_toxics(self.env)


class NetLatencyDatapath(NetLatency):
    name = "net-latency-datapath"
    description = "Toxiproxy latency toxic 300ms (jitter 100) on BOTH the redis and postgres proxies"
    proxies = ("redis", "postgres")


class DiskQuota(Scenario):
    name, layer = "disk-quota", "trend / capacity"
    description = "write 20 MB junk files every 15s into backups-<env> (stops once the healer has acted)"
    expected_alert, expected_heal = "BackupQuotaWillFillSoon", "cleanup_backups"

    def __init__(self, env):
        super().__init__(env)
        self.last_write = 0.0
        self.n = 0
        self.writing = True

    def _write(self):
        self.n += 1
        sh(
            "docker",
            "exec",
            f"backup-agent-{self.env}",
            "sh",
            "-c",
            f"head -c 20000000 /dev/zero > /backups/chaos-junk-{self.n:03d}.bin",
        )
        self.last_write = now()

    def inject(self):
        self._write()

    def tick(self):
        if self.writing and now() - self.last_write >= 15:
            self._write()

    def stop_writing(self):
        self.writing = False

    def remove(self):
        self.writing = False
        sh("docker", "exec", f"backup-agent-{self.env}", "sh", "-c", "rm -f /backups/chaos-junk-*.bin", check=False)

    def healthy(self):
        junk = sh(
            "docker",
            "exec",
            f"backup-agent-{self.env}",
            "sh",
            "-c",
            "ls /backups/chaos-junk-*.bin 2>/dev/null | wc -l",
            check=False,
        )
        return junk.strip() == "0" and not any(
            a["labels"]["alertname"] == self.expected_alert for a in active_alerts(self.env)
        )


SCENARIOS = {
    s.name: s
    for s in [
        CpuHog,
        MemLeak,
        ApiHang,
        ErrorBurst,
        ReplicaDown,
        DbDown,
        CacheDown,
        NetLatency,
        NetLatencyDatapath,
        DiskQuota,
    ]
}


def list_toxics(env: str) -> list[str]:
    out = []
    for proxy in ("redis", "postgres"):
        txt = sh("docker", "exec", f"toxiproxy-{env}", "/toxiproxy-cli", "inspect", proxy, check=False)
        out += [line.split()[0] for line in txt.splitlines() if line.strip().startswith("chaos_")]
    return out


def remove_toxics(env: str) -> list[str]:
    removed = []
    for proxy in ("redis", "postgres"):
        txt = sh("docker", "exec", f"toxiproxy-{env}", "/toxiproxy-cli", "inspect", proxy, check=False)
        for line in txt.splitlines():
            name = line.strip().split(":")[0].split()[0] if line.strip() else ""
            if name.startswith(("chaos_", "probe_")):
                sh(
                    "docker",
                    "exec",
                    f"toxiproxy-{env}",
                    "/toxiproxy-cli",
                    "toxic",
                    "remove",
                    "-n",
                    name,
                    proxy,
                    check=False,
                )
                removed.append(f"{proxy}/{name}")
    return removed


# ---------------------------------------------------------------- run
def heal_entries_since(ts: float, env: str, alertname: str) -> list[dict]:
    if not HEAL_LOG.exists():
        return []
    out = []
    for line in HEAL_LOG.read_text().splitlines():
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        t = datetime.fromisoformat(e["ts"]).timestamp()
        if t >= ts and e.get("alertname") == alertname and e.get("env") in (env, "host"):
            e["_t"] = t
            out.append(e)
    return out


def wait_quiet(env: str, timeout: float = 180) -> None:
    deadline = now() + timeout
    while now() < deadline:
        if not active_alerts(env):
            return
        time.sleep(3)
    names = sorted({a["labels"]["alertname"] for a in active_alerts(env)})
    raise SystemExit(f"refusing to start: alerts still active for {env}: {names}")


def run(scenario_name: str, env: str, duration: float, confirm_prod: bool) -> Path:
    if env in ("prod", "aws-prod") and not confirm_prod:
        raise SystemExit(f"refusing to run chaos against {env} without --confirm-prod")
    cls = SCENARIOS[scenario_name]
    sc = cls(env)
    if cls.chaos_endpoints and env != "staging":
        raise SystemExit(f"{scenario_name} needs chaos endpoints, which are enabled only in staging")
    if cls.heavy:
        print("WARNING: cpu-hog loads every CPU core for up to 3 minutes; the laptop will be sluggish.")

    wait_quiet(env)
    started = now()
    run_id = f"{datetime.fromtimestamp(started, UTC).strftime('%Y%m%dT%H%M%SZ')}-{scenario_name}-{env}"
    out = INCIDENTS / run_id
    probe = Probe(env, out / "raw" / "probes.jsonl")
    events: dict[str, float] = {}
    other_alerts: dict[str, float] = {}

    def mark(name: str, ts: float | None = None) -> None:
        if name not in events:
            events[name] = ts or now()
            print(f"  T+{events[name] - events.get('injected', events[name]):6.1f}s  {name}")

    print(f"[{run_id}] {sc.description}")
    probe.start()
    time.sleep(5)  # baseline probes
    try:
        sc.inject()
        mark("injected")
        deadline = events["injected"] + duration
        while now() < deadline:
            sc.tick()
            t = now()
            if "first_failed_probe" not in events:
                bad = [s for s in probe.samples if s["ts"] >= events["injected"] and not s["good"]]
                if bad:
                    mark("first_failed_probe", bad[0]["ts"])
            for a in active_alerts(env):
                n = a["labels"]["alertname"]
                if n == sc.expected_alert and a["status"]["state"] == "active":
                    mark("alert_firing")
                elif n not in other_alerts and n != sc.expected_alert:
                    other_alerts[n] = t
            heals = heal_entries_since(events["injected"], env, sc.expected_alert)
            if heals and "heal_finished" not in events:
                h = heals[0]
                mark("heal_started", h["_t"] - float(h.get("duration_s") or 0))
                mark("heal_finished", h["_t"])
                if isinstance(sc, DiskQuota):
                    sc.stop_writing()
                    mark("injection_stopped")
            if sc.human_stop and "heal_finished" in events and "injection_removed" not in events:
                # The healer only gathers evidence for latency; the "human" (this tool) acts.
                sc.remove()
                mark("injection_removed")
            degraded = "alert_firing" in events or "first_failed_probe" in events
            if degraded and "recovered" not in events and probe.last_good(3) and sc.healthy():
                mark("recovered")
                break
            time.sleep(1)
    finally:
        sc.remove()
        mark("injection_removed")
        time.sleep(3)
        probe.stop()

    # wait (bounded) for the alert to resolve, for the record
    resolve_deadline = now() + 120
    while now() < resolve_deadline:
        if not any(a["labels"]["alertname"] == sc.expected_alert for a in active_alerts(env)):
            mark("alert_resolved")
            break
        time.sleep(2)

    inj = events["injected"]
    after = [s for s in probe.samples if s["ts"] >= inj]
    timeline = {
        "id": run_id,
        "scenario": scenario_name,
        "layer": cls.layer,
        "env": env,
        "description": sc.description,
        "expected_alert": cls.expected_alert,
        "expected_heal": cls.expected_heal,
        "human_stop": cls.human_stop,
        "events": [
            {"event": k, "ts": iso(v), "t_plus_s": round(v - inj, 1)}
            for k, v in sorted(events.items(), key=lambda kv: kv[1])
        ],
        "other_alerts": [
            {"alertname": k, "first_seen": iso(v), "t_plus_s": round(v - inj, 1)}
            for k, v in sorted(other_alerts.items(), key=lambda kv: kv[1])
        ],
        "mttd_s": round(events["alert_firing"] - inj, 1) if "alert_firing" in events else None,
        "mttr_s": round(events["recovered"] - inj, 1) if "recovered" in events else None,
        "heal": heal_entries_since(inj, env, cls.expected_alert)[:3],
        "probes": {
            "interval_s": 1,
            "total": len(after),
            "failed_non_200": sum(1 for s in after if s["failed"]),
            "fallback": sum(1 for s in after if s["source"] == "fallback"),
            "slow_over_250ms": sum(1 for s in after if s["status"] == 200 and s["latency_s"] >= GOOD_LATENCY_S),
            "max_latency_s": max((s["latency_s"] for s in after), default=None),
        },
        "window": {"start": iso(inj), "end": iso(events.get("alert_resolved", now()))},
    }
    for h in timeline["heal"]:
        h.pop("_t", None)
        h["stdout_tail"] = h.get("stdout_tail", "")[-600:]
    out.mkdir(parents=True, exist_ok=True)
    (out / "timeline.json").write_text(json.dumps(timeline, indent=2) + "\n")
    print(f"  MTTD={timeline['mttd_s']}s MTTR={timeline['mttr_s']}s probes={timeline['probes']}")
    print(f"  -> {out.relative_to(ROOT)}/timeline.json")
    return out


def emergency_stop(env: str) -> None:
    """Remove every fault the tool can inject. Safe to run any time."""
    done = []
    removed = remove_toxics(env)
    done += [f"toxic {t}" for t in removed]
    ids = sh("docker", "ps", "-aq", "--filter", "label=com.adpulse.role=chaos", check=False).split()
    if ids:
        sh("docker", "rm", "-f", *ids, check=False)
        done.append(f"{len(ids)} role=chaos container(s) removed")
    if env == "staging":
        for r in api_replicas(env):
            if container_health(r).startswith("running"):
                chaos_api(r, "DELETE", "/admin/chaos")
        done.append("chaos modes reset on staging replicas")
    junk = sh(
        "docker",
        "exec",
        f"backup-agent-{env}",
        "sh",
        "-c",
        "ls /backups/chaos-junk-*.bin 2>/dev/null | wc -l; rm -f /backups/chaos-junk-*.bin",
        check=False,
    )
    if junk.strip() not in ("", "0"):
        done.append(f"{junk.strip()} junk backup file(s) deleted")
    for c in [f"postgres-{env}", f"redis-{env}", *api_replicas(env)]:
        if container_health(c).startswith("exited"):
            sh("docker", "start", c, check=False)
            done.append(f"started {c}")
    print("chaos stop:", "; ".join(done) if done else "nothing to clean up")
    leftovers = (
        list_toxics(env) + sh("docker", "ps", "-aq", "--filter", "label=com.adpulse.role=chaos", check=False).split()
    )
    print("leftover faults:", leftovers or "none")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("list")
    r = sub.add_parser("run")
    r.add_argument("scenario", choices=sorted(SCENARIOS))
    r.add_argument("--env", default="staging", choices=["staging", "prod"])
    r.add_argument("--duration", type=float, default=600, help="max seconds to wait for recovery")
    r.add_argument("--confirm-prod", action="store_true")
    s = sub.add_parser("stop")
    s.add_argument("--env", default="staging", choices=["staging", "prod"])
    args = ap.parse_args()

    if args.cmd == "list":
        for name, cls in SCENARIOS.items():
            print(f"{name:22} {cls.layer:28} alert={cls.expected_alert:24} heal={cls.expected_heal}")
        return 0
    if args.cmd == "stop":
        emergency_stop(args.env)
        return 0
    run(args.scenario, args.env, args.duration, args.confirm_prod)
    return 0


if __name__ == "__main__":
    sys.exit(main())
