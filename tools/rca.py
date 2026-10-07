#!/usr/bin/env python3
"""Generate an RCA skeleton from a chaos run, and the incident summary table.

    python3 tools/rca.py incidents/<id>            # -> docs/rca/<date>-<scenario>-<env>.md
    python3 tools/rca.py incidents/<id> --force    # overwrite (loses hand-written narrative!)
    python3 tools/rca.py --summary                 # -> docs/rca/SUMMARY.md from every timeline.json

Auto-filled from data: Impact, Timeline, Detection numbers, Resolution numbers,
Evidence (peak 5xx ratio and peak p95 via the Prometheus query_range API).
Narrative sections are left as TODO markers to be written from that data.
"""

import argparse
import json
import sys
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RCA_DIR = ROOT / "docs" / "rca"
PROM = "http://127.0.0.1:9090"
TODO = "_TODO: written from the recorded data below._"


def ts(s: str) -> float:
    return datetime.fromisoformat(s.replace("Z", "+00:00")).timestamp()


def prom_range(query: str, start: float, end: float, step: int = 5) -> list[tuple[float, float]]:
    q = urllib.parse.urlencode({"query": query, "start": start, "end": end, "step": step})
    with urllib.request.urlopen(f"{PROM}/api/v1/query_range?{q}", timeout=15) as r:  # noqa: S310
        res = json.load(r)["data"]["result"]
    points = []
    for series in res:
        points += [(float(t), float(v)) for t, v in series["values"] if v not in ("NaN", "+Inf", "-Inf")]
    return points


def prom_instant(query: str, at: float) -> float | None:
    q = urllib.parse.urlencode({"query": query, "time": at})
    with urllib.request.urlopen(f"{PROM}/api/v1/query?{q}", timeout=15) as r:  # noqa: S310
        res = json.load(r)["data"]["result"]
    return float(res[0]["value"][1]) if res else None


def evidence(tl: dict) -> dict:
    env = tl["env"]
    start = ts(tl["window"]["start"]) - 60
    end = ts(tl["window"]["end"]) + 60
    window_s = int(end - start)
    q = {
        "peak_5xx_ratio": f'env:adpulse_http_5xx:ratio_rate1m{{env="{env}"}}',
        "peak_p95_s": f'env:adpulse_http_request_duration_seconds:p95_1m{{env="{env}"}}',
        "requests": f'sum(increase(adpulse_http_requests_total{{env="{env}", route="/v1/ad"}}[{window_s}s]))',
        "requests_5xx": (
            f'sum(increase(adpulse_http_requests_total{{env="{env}", route="/v1/ad", status=~"5.."}}[{window_s}s]))'
        ),
        "fallback_ads": f'sum(increase(adpulse_fallback_total{{env="{env}"}}[{window_s}s]))',
        "cache_errors": f'sum(increase(adpulse_cache_requests_total{{env="{env}", result="error"}}[{window_s}s]))',
    }
    out = {"window": {"start": start, "end": end}, "queries": q, "values": {}}
    for key in ("peak_5xx_ratio", "peak_p95_s"):
        pts = prom_range(q[key], start, end)
        out["values"][key] = max((v for _, v in pts), default=None)
    for key in ("requests", "requests_5xx", "fallback_ads", "cache_errors"):
        out["values"][key] = prom_instant(q[key], end)
    return out


def fmt(v, unit="", digits=3):
    if v is None:
        return "n/a"
    if isinstance(v, float):
        return f"{v:.{digits}f}{unit}"
    return f"{v}{unit}"


def rca_path(tl: dict) -> Path:
    date = tl["id"][:8]
    return RCA_DIR / f"{date[:4]}-{date[4:6]}-{date[6:8]}-{tl['scenario']}-{tl['env']}.md"


def render(tl: dict, ev: dict, incident_dir: Path) -> str:
    v = ev["values"]
    events = {e["event"]: e for e in tl["events"]}
    fired = "alert_firing" in events
    p = tl["probes"]
    total = v.get("requests") or 0
    pct_5xx = (v["requests_5xx"] or 0) / total * 100 if total else None
    pct_fb = (v["fallback_ads"] or 0) / total * 100 if total else None
    sev = (
        "critical"
        if tl["expected_alert"]
        in ("AdPulseApiReplicaDown", "AdPulseHighErrorRate", "AdPulseDatabaseDown", "AdPulseCacheDown")
        else "warning"
    )
    heal = tl["heal"][0] if tl["heal"] else None
    rows = [f"| {e['ts']} | T+{e['t_plus_s']}s | {e['event']} |" for e in tl["events"]]
    rows += [
        f"| {a['first_seen']} | T+{a['t_plus_s']}s | other alert seen: {a['alertname']} |" for a in tl["other_alerts"]
    ]
    rows.sort()
    duration = None
    if "recovered" in events:
        duration = events["recovered"]["t_plus_s"]

    lines = [
        f"# RCA: {tl['scenario']} in {tl['env']}   (Blameless)",
        f"- **Date:** {tl['events'][0]['ts'][:10]} · **Env:** {tl['env']} · **Scenario:** `{tl['scenario']}` "
        f"({tl['layer']}) · **Severity:** {sev}",
        "- **Status:** Resolved",
        f"- **Injection:** {tl['description']}",
        f"- **Data:** `{incident_dir.relative_to(ROOT)}/timeline.json`",
        "",
        "## Summary",
        TODO,
        "",
        "## Impact",
        f"- Duration (injection → recovered): **{fmt(duration, 's', 1)}**",
        f"- User probes through nginx (1/s): {p['total']} total, **{p['failed_non_200']} failed (non-200)**, "
        f"**{p['fallback']} fallback ads**, {p['slow_over_250ms']} slower than 250 ms, max latency {fmt(p['max_latency_s'], ' s')}",
        f"- API-side traffic in the window (loadgen + probes): {fmt(total, '', 0)} requests, "
        f"{fmt(v['requests_5xx'], '', 0)} 5xx ({fmt(pct_5xx, '%', 2)}), "
        f"{fmt(v['fallback_ads'], '', 0)} fallback ads ({fmt(pct_fb, '%', 2)}), cache errors {fmt(v['cache_errors'], '', 0)}",
        "- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.",
        "",
        "## Timeline (UTC)",
        "| Time | Offset | Event |",
        "|---|---|---|",
        *rows,
        "",
        "## Detection",
        f"- Expected alert: `{tl['expected_alert']}` → "
        + (f"**fired**, MTTD **{tl['mttd_s']} s**." if fired else "**did not fire** in this run."),
        "- Other alerts seen: "
        + (", ".join(f"`{a['alertname']}` (T+{a['t_plus_s']}s)" for a in tl["other_alerts"]) or "none"),
        "- Was it the right alert? " + TODO,
        "",
        "## Root cause",
        TODO,
        "",
        "## 5 Whys",
        "1. " + TODO,
        "",
        "## Resolution",
        (
            f"- Healer: `{heal['action']}` → **{heal['result']}** in {heal['duration_s']} s "
            f"(attempt {heal['attempt']}, vars `{json.dumps(heal.get('extra_vars', {}))}`)."
            if heal
            else "- Healer: no heal action recorded for the expected alert."
        ),
        f"- Expected heal: {tl['expected_heal']}."
        + (" The fault was removed by a human step (this tool)." if tl.get("human_stop") else ""),
        f"- **MTTR: {fmt(tl['mttr_s'], ' s', 1)}** (injection → system healthy and 3 consecutive good probes).",
        "",
        "## What went well / What went badly / Where we got lucky",
        TODO,
        "",
        "## Action items",
        "| Action | Type | Owner | Status |",
        "|---|---|---|---|",
        f"| {TODO} | | | |",
        "",
        "## Evidence",
        f"Window: {datetime.fromtimestamp(ev['window']['start'], UTC):%H:%M:%S}–"
        f"{datetime.fromtimestamp(ev['window']['end'], UTC):%H:%M:%S} UTC (incident ±60 s).",
        "",
        "| Value | Result | PromQL |",
        "|---|---|---|",
        f"| peak 5xx ratio (1m) | {fmt(v['peak_5xx_ratio'])} | `max over window of {ev['queries']['peak_5xx_ratio']}` |",
        f"| peak p95 latency (1m) | {fmt(v['peak_p95_s'], ' s')} | `max over window of {ev['queries']['peak_p95_s']}` |",
        f"| requests | {fmt(v['requests'], '', 0)} | `{ev['queries']['requests']}` |",
        f"| 5xx requests | {fmt(v['requests_5xx'], '', 0)} | `{ev['queries']['requests_5xx']}` |",
        f"| fallback ads | {fmt(v['fallback_ads'], '', 0)} | `{ev['queries']['fallback_ads']}` |",
        f"| cache errors | {fmt(v['cache_errors'], '', 0)} | `{ev['queries']['cache_errors']}` |",
        "",
        "Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), "
        "*AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer "
        "(*Infrastructure* or *Database & Cache*).",
        "",
    ]
    if heal and heal.get("stdout_tail"):
        lines += [
            "<details><summary>Healer playbook output (tail)</summary>",
            "",
            "```",
            heal["stdout_tail"].strip(),
            "```",
            "</details>",
            "",
        ]
    return "\n".join(lines)


def summary() -> Path:
    rows = []
    for f in sorted((ROOT / "incidents").glob("*/timeline.json")):
        tl = json.loads(f.read_text())
        heal = tl["heal"][0] if tl["heal"] else None
        fired = any(e["event"] == "alert_firing" for e in tl["events"])
        rca = rca_path(tl)
        rows.append(
            f"| {tl['scenario']} | {tl['env']} | {tl['layer']} | "
            f"{tl['expected_alert'] if fired else 'not detected (' + tl['expected_alert'] + ' did not fire)'} | "
            f"{(heal['action'] + ' (' + heal['result'] + ')') if heal else ('human' if tl.get('human_stop') else 'none')} | "
            f"{fmt(tl['mttd_s'], ' s', 1)} | {fmt(tl['mttr_s'], ' s', 1)} | "
            f"{tl['probes']['failed_non_200']} / {tl['probes']['fallback']} / {tl['probes']['slow_over_250ms']} "
            f"of {tl['probes']['total']} | [{rca.name}]({rca.name}) |"
        )
    out = RCA_DIR / "SUMMARY.md"
    out.write_text(
        "\n".join(
            [
                "# Incident summary (chaos experiments)",
                "",
                "Generated by `tools/rca.py --summary` from `incidents/*/timeline.json`. Every number is measured "
                "(plan rule R13). MTTD = alert firing − injection; MTTR = recovered (system healthy + 3 consecutive "
                "good probes) − injection. User impact = probes through nginx at 1/s: failed (non-200) / fallback ads / "
                "slower than 250 ms.",
                "",
                "| Scenario | Env | Layer | Detected by | Healed by | MTTD | MTTR | User impact (failed / fallback / slow) | RCA |",
                "|---|---|---|---|---|---|---|---|---|",
                *rows,
                "",
            ]
        )
    )
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("incident", nargs="?")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--summary", action="store_true")
    a = ap.parse_args()
    RCA_DIR.mkdir(parents=True, exist_ok=True)
    if a.summary:
        print(f"wrote {summary().relative_to(ROOT)}")
        return 0
    if not a.incident:
        ap.error("incident directory required")
    d = Path(a.incident).resolve()
    tl = json.loads((d / "timeline.json").read_text())
    out = rca_path(tl)
    if out.exists() and not a.force:
        print(f"{out.relative_to(ROOT)} exists (use --force to overwrite the narrative)")
        return 1
    out.write_text(render(tl, evidence(tl), d))
    print(f"wrote {out.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
