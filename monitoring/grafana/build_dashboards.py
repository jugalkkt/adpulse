#!/usr/bin/env python3
"""Generate the five AdPulse Grafana dashboards as JSON (dashboards as code).

    python3 monitoring/grafana/build_dashboards.py   # writes monitoring/grafana/dashboards/*.json

Colour rules (validated with the dataviz palette validator, docs/DECISIONS.md D037):
  - series colours are fixed per entity, never cycled: slot 1 blue, slot 2 orange,
    slot 3 aqua (the first three slots validate all-pairs, light and dark);
  - status colours (good/warning/critical) are only used for thresholds and states;
  - one y-axis per chart; legends only when a chart has two or more series.
"""

import json
from pathlib import Path

OUT = Path(__file__).resolve().parent / "dashboards"
DS = {"type": "prometheus", "uid": "prometheus"}

SLOT = {1: "#3987e5", 2: "#d95926", 3: "#199e70"}
GOOD, WARNING, CRITICAL = "#0ca30c", "#fab219", "#d03b3b"
NEUTRAL = "#8e8d87"  # reference lines (quota), not a series identity


# ---------------------------------------------------------------- helpers
def target(expr, legend="", ref="A", instant=False):
    t = {
        "datasource": DS,
        "expr": expr,
        "legendFormat": legend or "__auto",
        "refId": ref,
        "range": not instant,
    }
    if instant:
        t["instant"] = True
    return t


def thresholds(*steps):
    """steps: (value, color) with the first value None (base)."""
    return {"mode": "absolute", "steps": [{"value": v, "color": c} for v, c in steps]}


def color_override(name, color, extra=None):
    props = [{"id": "color", "value": {"mode": "fixed", "fixedColor": color}}]
    props += extra or []
    return {"matcher": {"id": "byName", "options": name}, "properties": props}


def timeseries(
    title,
    targets,
    unit,
    pos,
    series_colors=None,
    single_color=SLOT[1],
    stack=False,
    threshold_line=None,
    desc="",
    min_=None,
    max_=None,
    overrides=None,
    legend=None,
):
    multi = legend if legend is not None else len(series_colors or {}) >= 2
    custom = {
        "drawStyle": "line",
        "lineWidth": 2,
        "fillOpacity": 25 if stack else 0,
        "showPoints": "never",
        "spanNulls": False,
        "axisBorderShow": False,
        "gradientMode": "none",
        "stacking": {"mode": "normal" if stack else "none", "group": "A"},
        "thresholdsStyle": {"mode": "dashed" if threshold_line is not None else "off"},
    }
    defaults = {"unit": unit, "custom": custom}
    if min_ is not None:
        defaults["min"] = min_
    if max_ is not None:
        defaults["max"] = max_
    if threshold_line is not None:
        defaults["thresholds"] = thresholds((None, "transparent"), (threshold_line, CRITICAL))
    if not multi:
        defaults["color"] = {"mode": "fixed", "fixedColor": single_color}
    ovr = [color_override(n, c) for n, c in (series_colors or {}).items()] + (overrides or [])
    return {
        "type": "timeseries",
        "title": title,
        "description": desc,
        "datasource": DS,
        "gridPos": pos,
        "targets": targets,
        "fieldConfig": {"defaults": defaults, "overrides": ovr},
        "options": {
            "legend": {
                "showLegend": multi,
                "displayMode": "list",
                "placement": "bottom",
            },
            "tooltip": {"mode": "multi" if multi else "single", "sort": "desc"},
        },
    }


def stat(title, expr, unit, pos, steps, desc="", decimals=None, instant=True):
    defaults = {
        "unit": unit,
        "thresholds": thresholds(*steps),
        "color": {"mode": "thresholds"},
    }
    if decimals is not None:
        defaults["decimals"] = decimals
    return {
        "type": "stat",
        "title": title,
        "description": desc,
        "datasource": DS,
        "gridPos": pos,
        "targets": [target(expr, instant=instant)],
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "colorMode": "value",
            "graphMode": "none",
            "textMode": "value",
            "justifyMode": "center",
            "orientation": "auto",
        },
    }


def bargauge(title, expr, legend, unit, pos, steps, desc="", max_=None):
    defaults = {
        "unit": unit,
        "min": 0,
        "thresholds": thresholds(*steps),
        "color": {"mode": "thresholds"},
    }
    if max_ is not None:
        defaults["max"] = max_
    return {
        "type": "bargauge",
        "title": title,
        "description": desc,
        "datasource": DS,
        "gridPos": pos,
        "targets": [target(expr, legend, instant=True)],
        "fieldConfig": {"defaults": defaults, "overrides": []},
        "options": {
            "displayMode": "basic",
            "orientation": "horizontal",
            "showUnfilled": True,
            "valueMode": "text",
            "namePlacement": "left",
            "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": False},
            "minVizHeight": 16,
            "maxVizHeight": 22,
            "sizing": "manual",
        },
    }


def state_timeline(title, targets, pos, desc="", mappings=None):
    return {
        "type": "state-timeline",
        "title": title,
        "description": desc,
        "datasource": DS,
        "gridPos": pos,
        "targets": targets,
        "fieldConfig": {
            "defaults": {
                "color": {"mode": "thresholds"},
                "thresholds": thresholds((None, CRITICAL), (1, GOOD)),
                "mappings": mappings or [],
                "custom": {"fillOpacity": 80, "lineWidth": 0},
            },
            "overrides": [],
        },
        "options": {
            "showValue": "never",
            "rowHeight": 0.8,
            "mergeValues": True,
            "alignValue": "left",
            "legend": {"showLegend": False},
            "tooltip": {"mode": "single"},
        },
    }


def text(content, pos):
    return {
        "type": "text",
        "title": "",
        "gridPos": pos,
        "options": {"mode": "markdown", "content": content},
    }


def env_variable():
    return {
        "name": "env",
        "label": "Environment",
        "type": "custom",
        "query": "staging,prod",
        "current": {"text": "staging", "value": "staging"},
        "options": [
            {"text": "staging", "value": "staging", "selected": True},
            {"text": "prod", "value": "prod", "selected": False},
        ],
        "multi": False,
        "includeAll": False,
    }


HEAL_ANNOTATIONS = {
    "datasource": {"type": "grafana", "uid": "-- Grafana --"},
    "enable": True,
    "iconColor": SLOT[3],
    "name": "Healer actions",
    "target": {"type": "tags", "tags": ["heal"], "limit": 100, "matchAny": False},
}

ALERT_ANNOTATIONS = {
    "datasource": DS,
    "enable": True,
    "iconColor": CRITICAL,
    "name": "Firing alerts",
    "expr": 'ALERTS{alertstate="firing", env=~"$env|host"}',
    "step": "15s",
    "titleFormat": "{{alertname}}",
    "textFormat": "{{env}} {{severity}}",
    "useValueForTime": False,
}


def dashboard(uid, title, panels, desc, env_var=True, refresh="10s", time_from="now-1h"):
    for i, p in enumerate(panels, start=1):
        p["id"] = i
    return {
        "uid": uid,
        "title": title,
        "description": desc,
        "tags": ["adpulse"],
        "timezone": "browser",
        "editable": False,
        "graphTooltip": 1,  # shared crosshair across panels
        "refresh": refresh,
        "time": {"from": time_from, "to": "now"},
        "schemaVersion": 41,
        "version": 1,
        "templating": {"list": [env_variable()] if env_var else []},
        "annotations": {"list": [HEAL_ANNOTATIONS, ALERT_ANNOTATIONS]},
        "links": [
            {
                "type": "dashboards",
                "tags": ["adpulse"],
                "asDropdown": True,
                "title": "AdPulse",
            }
        ],
        "panels": panels,
    }


def pos(x, y, w, h):
    return {"x": x, "y": y, "w": w, "h": h}


E = '{env="$env"}'


# ---------------------------------------------------------------- 1. overview
def overview():
    p = [
        stat(
            "Requests / s",
            f"env:adpulse_http_requests:rate1m{E}",
            "reqps",
            pos(0, 0, 4, 4),
            [(None, CRITICAL), (0.5, GOOD)],
            "Traffic on /v1/ad over the last minute.",
            decimals=1,
        ),
        stat(
            "Error rate (5xx)",
            f"env:adpulse_http_5xx:ratio_rate1m{E}",
            "percentunit",
            pos(4, 0, 4, 4),
            [(None, GOOD), (0.01, WARNING), (0.05, CRITICAL)],
            "Alert threshold: 5% for 1m.",
            decimals=2,
        ),
        stat(
            "Latency p95",
            f"env:adpulse_http_request_duration_seconds:p95_1m{E}",
            "s",
            pos(8, 0, 4, 4),
            [(None, GOOD), (0.15, WARNING), (0.25, CRITICAL)],
            "SLO: 95% under 150ms. Alert: p95 > 250ms for 2m.",
        ),
        stat(
            "Healthy replicas",
            f"env:adpulse_api_replicas_up:count{E} or on() vector(0)",
            "none",
            pos(12, 0, 4, 4),
            [(None, CRITICAL), (2, GOOD)],
            "Replicas Prometheus can scrape. Expected: 2.",
        ),
        stat(
            "Cache hit ratio",
            f"env:adpulse_cache_hit:ratio_rate1m{E}",
            "percentunit",
            pos(16, 0, 4, 4),
            [(None, WARNING), (0.8, GOOD)],
            "Share of lookups answered by Redis.",
            decimals=1,
        ),
        stat(
            "Fallback ads / s",
            f"env:adpulse_fallback:rate1m{E}",
            "reqps",
            pos(20, 0, 4, 4),
            [(None, GOOD), (0.001, WARNING)],
            "House ads served because cache and DB both failed.",
            decimals=2,
        ),
        timeseries(
            "Requests per second ($env)",
            [target(f"env:adpulse_http_requests:rate1m{E}", "requests/s")],
            "reqps",
            pos(0, 4, 12, 8),
            min_=0,
            desc="Rate of /v1/ad requests served by the API.",
        ),
        timeseries(
            "5xx error ratio ($env)",
            [target(f"env:adpulse_http_5xx:ratio_rate1m{E}", "5xx ratio")],
            "percentunit",
            pos(12, 4, 12, 8),
            threshold_line=0.05,
            min_=0,
            desc="Dashed line: the 5% alert threshold.",
        ),
        timeseries(
            "Latency p95 and p99 ($env)",
            [
                target(f"env:adpulse_http_request_duration_seconds:p95_1m{E}", "p95", "A"),
                target(f"env:adpulse_http_request_duration_seconds:p99_1m{E}", "p99", "B"),
            ],
            "s",
            pos(0, 12, 12, 8),
            series_colors={"p95": SLOT[1], "p99": SLOT[2]},
            min_=0,
            desc="Both on one seconds axis. The p95 alert threshold is 250ms.",
        ),
        timeseries(
            "Ads served by source ($env)",
            [target(f"env_source:adpulse_ad_served:rate1m{E}", "{{source}}")],
            "reqps",
            pos(12, 12, 12, 8),
            stack=True,
            min_=0,
            series_colors={"cache": SLOT[1], "db": SLOT[2], "fallback": SLOT[3]},
            desc="Stacked: cache hits, DB lookups, and fallback (house) ads.",
        ),
        state_timeline(
            "Replica scrape status ($env)",
            [target('up{job="api", env="$env"}', "{{instance}}")],
            pos(0, 20, 24, 6),
            desc="Green = scraped OK; red = down or hung.",
            mappings=[
                {
                    "type": "value",
                    "options": {"0": {"text": "down"}, "1": {"text": "up"}},
                }
            ],
        ),
    ]
    return dashboard(
        "adpulse-overview",
        "AdPulse Overview",
        p,
        "RED metrics (rate, errors, duration), ad sources and replica health for one environment.",
    )


# ---------------------------------------------------------------- 2. infrastructure
def infrastructure():
    c = 'role!=""'
    p = [
        stat(
            "Host CPU busy",
            '1 - avg(rate(node_cpu_seconds_total{job="node", mode="idle"}[1m]))',
            "percentunit",
            pos(0, 0, 6, 4),
            [(None, GOOD), (0.7, WARNING), (0.85, CRITICAL)],
            "HostHighCPU fires above 85% for 1m.",
        ),
        stat(
            "Host memory used",
            '1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"}',
            "percentunit",
            pos(6, 0, 6, 4),
            [(None, GOOD), (0.8, WARNING), (0.9, CRITICAL)],
        ),
        stat(
            "Root disk used",
            '1 - node_filesystem_avail_bytes{job="node", mountpoint="/"}'
            ' / node_filesystem_size_bytes{job="node", mountpoint="/"}',
            "percentunit",
            pos(12, 0, 6, 4),
            [(None, GOOD), (0.8, WARNING), (0.9, CRITICAL)],
            "Docker data lives on /.",
        ),
        stat(
            "AdPulse containers memory limit total",
            'sum(max by (container) (container_spec_memory_limit_bytes{job="cadvisor", ' + c + "}))",
            "bytes",
            pos(18, 0, 6, 4),
            [(None, GOOD), (6 * 1024**3, CRITICAL)],
            "Plan cap: 6 GB in total.",
        ),
        timeseries(
            "Host CPU busy",
            [
                target(
                    '1 - avg(rate(node_cpu_seconds_total{job="node", mode="idle"}[1m]))',
                    "CPU busy",
                )
            ],
            "percentunit",
            pos(0, 4, 12, 8),
            threshold_line=0.85,
            min_=0,
            max_=1,
        ),
        timeseries(
            "Host memory used",
            [
                target(
                    '1 - node_memory_MemAvailable_bytes{job="node"} / node_memory_MemTotal_bytes{job="node"}',
                    "memory used",
                )
            ],
            "percentunit",
            pos(12, 4, 12, 8),
            min_=0,
            max_=1,
        ),
        bargauge(
            "Container memory vs limit",
            'max by (container) (container_memory_working_set_bytes{job="cadvisor", ' + c + "})"
            ' / max by (container) (container_spec_memory_limit_bytes{job="cadvisor", ' + c + "} > 0)",
            "{{container}}",
            "percentunit",
            pos(0, 12, 12, 16),
            [(None, GOOD), (0.75, WARNING), (0.9, CRITICAL)],
            "Working set / limit. ApiContainerMemoryHigh fires above 90% for 30s.",
            max_=1,
        ),
        bargauge(
            "Container CPU vs limit",
            'sum by (container) (rate(container_cpu_usage_seconds_total{job="cadvisor", ' + c + "}[1m]))"
            ' / (max by (container) (container_spec_cpu_quota{job="cadvisor", ' + c + "})"
            ' / max by (container) (container_spec_cpu_period{job="cadvisor", ' + c + "}))",
            "{{container}}",
            "percentunit",
            pos(12, 12, 12, 16),
            [(None, GOOD), (0.75, WARNING), (0.9, CRITICAL)],
            "CPU used / CPU limit. ApiContainerHighCPU fires above 90% for 1m.",
            max_=1,
        ),
        timeseries(
            "API replica memory ($env)",
            [
                target(
                    'max by (container) (container_memory_working_set_bytes{job="cadvisor", role="api", env="$env"})',
                    "{{container}}",
                )
            ],
            "bytes",
            pos(0, 28, 24, 8),
            min_=0,
            overrides=[
                {
                    "matcher": {"id": "byRegexp", "options": ".*-1$"},
                    "properties": [
                        {
                            "id": "color",
                            "value": {"mode": "fixed", "fixedColor": SLOT[1]},
                        }
                    ],
                },
                {
                    "matcher": {"id": "byRegexp", "options": ".*-2$"},
                    "properties": [
                        {
                            "id": "color",
                            "value": {"mode": "fixed", "fixedColor": SLOT[2]},
                        }
                    ],
                },
            ],
            legend=True,
            desc="Limit is 256MiB per replica; a leak shows as a steady climb.",
        ),
    ]
    return dashboard(
        "adpulse-infrastructure",
        "AdPulse Infrastructure",
        p,
        "Host CPU, memory and disk; every AdPulse container against its limits.",
    )


# ---------------------------------------------------------------- 3. database & cache
def database_cache():
    p = [
        stat(
            "PostgreSQL",
            f"pg_up{E}",
            "none",
            pos(0, 0, 4, 4),
            [(None, CRITICAL), (1, GOOD)],
            "1 = exporter can connect.",
        ),
        stat(
            "Redis",
            f"redis_up{E}",
            "none",
            pos(4, 0, 4, 4),
            [(None, CRITICAL), (1, GOOD)],
        ),
        stat(
            "Last backup age",
            f"time() - adpulse_backup_last_success_timestamp_seconds{E}",
            "s",
            pos(8, 0, 4, 4),
            [(None, GOOD), (600, WARNING), (900, CRITICAL)],
            "BackupStale fires above 900s (3 x interval).",
        ),
        stat(
            "Backup files",
            f"adpulse_backup_files{E}",
            "none",
            pos(12, 0, 4, 4),
            [(None, GOOD), (10, WARNING)],
            "Retention keeps 6.",
        ),
        stat(
            "Backup dir / quota",
            f"adpulse_backup_dir_bytes{E} / adpulse_backup_quota_bytes{E}",
            "percentunit",
            pos(16, 0, 4, 4),
            [(None, GOOD), (0.7, WARNING), (0.9, CRITICAL)],
        ),
        stat(
            "DB connections",
            'sum(pg_stat_activity_count{env="$env"})',
            "none",
            pos(20, 0, 4, 4),
            [(None, GOOD), (40, WARNING), (48, CRITICAL)],
            "max_connections = 50.",
        ),
        timeseries(
            "Backup directory: size, 1h forecast and quota ($env)",
            [
                target(f"adpulse_backup_dir_bytes{E}", "size", "A"),
                target(
                    f"predict_linear(adpulse_backup_dir_bytes{E}[10m], 3600)",
                    "forecast +1h",
                    "B",
                ),
                target(f"adpulse_backup_quota_bytes{E}", "quota", "C"),
            ],
            "bytes",
            pos(0, 4, 24, 9),
            min_=0,
            series_colors={"size": SLOT[1], "forecast +1h": SLOT[2]},
            overrides=[
                color_override(
                    "quota",
                    NEUTRAL,
                    [
                        {
                            "id": "custom.lineStyle",
                            "value": {"fill": "dash", "dash": [8, 6]},
                        }
                    ],
                ),
                {
                    "matcher": {"id": "byName", "options": "forecast +1h"},
                    "properties": [
                        {
                            "id": "custom.lineStyle",
                            "value": {"fill": "dash", "dash": [4, 4]},
                        }
                    ],
                },
            ],
            desc="predict_linear over 10m, projected 1h ahead. "
            "BackupQuotaWillFillSoon fires when the forecast crosses the quota.",
        ),
        timeseries(
            "DB connections by state ($env)",
            [
                target(
                    'sum by (state) (pg_stat_activity_count{env="$env", state=~"active|idle|idle in transaction"})',
                    "{{state}}",
                )
            ],
            "none",
            pos(0, 13, 12, 8),
            min_=0,
            stack=True,
            series_colors={
                "active": SLOT[1],
                "idle": SLOT[2],
                "idle in transaction": SLOT[3],
            },
        ),
        timeseries(
            "Longest running transaction ($env)",
            [
                target(
                    'max(pg_stat_activity_max_tx_duration{env="$env"})',
                    "max tx duration",
                )
            ],
            "s",
            pos(12, 13, 12, 8),
            min_=0,
            desc="statement_timeout is 5s; slow statements (>200ms) are logged.",
        ),
        timeseries(
            "Redis memory used vs maxmemory ($env)",
            [
                target(f"redis_memory_used_bytes{E}", "used", "A"),
                target(f"redis_memory_max_bytes{E}", "maxmemory", "B"),
            ],
            "bytes",
            pos(0, 21, 12, 8),
            min_=0,
            series_colors={"used": SLOT[1]},
            overrides=[
                color_override(
                    "maxmemory",
                    NEUTRAL,
                    [
                        {
                            "id": "custom.lineStyle",
                            "value": {"fill": "dash", "dash": [8, 6]},
                        }
                    ],
                )
            ],
        ),
        timeseries(
            "Cache hit ratio ($env)",
            [target(f"env:adpulse_cache_hit:ratio_rate1m{E}", "hit ratio")],
            "percentunit",
            pos(12, 21, 12, 8),
            min_=0,
            max_=1,
        ),
        timeseries(
            "DB errors seen by the API ($env)",
            [
                target(
                    'sum by (op) (rate(adpulse_db_errors_total{env="$env"}[1m]))',
                    "{{op}}",
                )
            ],
            "reqps",
            pos(0, 29, 24, 7),
            min_=0,
            series_colors={"select": SLOT[1], "impression": SLOT[2], "ready": SLOT[3]},
        ),
    ]
    return dashboard(
        "adpulse-db-cache",
        "AdPulse Database & Cache",
        p,
        "PostgreSQL and Redis health, backups with a trend forecast against the quota.",
    )


# ---------------------------------------------------------------- 4. SRE / SLO
def sre_slo():
    p = [
        text(
            "**SLOs for `/v1/ad`** - availability: 99.5% non-5xx (budget 0.5%); latency: 95% of requests under 150ms "
            "(budget 5%). Budget remaining is computed over the last 6h (demo window; docs/DECISIONS.md D036). "
            "Burn rate 1 = spending the budget exactly on schedule; the fast-burn alert fires at 14.4.",
            pos(0, 0, 24, 3),
        ),
        stat(
            "Availability (6h)",
            f"1 - env:slo_availability_errors:ratio_rate6h{E}",
            "percentunit",
            pos(0, 3, 6, 5),
            [(None, CRITICAL), (0.995, GOOD)],
            "Target 99.5%.",
            decimals=3,
        ),
        stat(
            "Availability budget left",
            f"env:slo_availability:error_budget_remaining6h{E}",
            "percentunit",
            pos(6, 3, 6, 5),
            [(None, CRITICAL), (0.25, WARNING), (0.5, GOOD)],
            decimals=1,
        ),
        stat(
            "Requests under 150ms (6h)",
            f"1 - env:slo_latency_errors:ratio_rate6h{E}",
            "percentunit",
            pos(12, 3, 6, 5),
            [(None, CRITICAL), (0.95, GOOD)],
            "Target 95%.",
            decimals=2,
        ),
        stat(
            "Latency budget left",
            f"env:slo_latency:error_budget_remaining6h{E}",
            "percentunit",
            pos(18, 3, 6, 5),
            [(None, CRITICAL), (0.25, WARNING), (0.5, GOOD)],
            decimals=1,
        ),
        timeseries(
            "Burn rate, 1h window ($env)",
            [
                target(f"env:slo_availability:burnrate1h{E}", "availability", "A"),
                target(f"env:slo_latency:burnrate1h{E}", "latency", "B"),
            ],
            "x",
            pos(0, 8, 24, 9),
            series_colors={"availability": SLOT[1], "latency": SLOT[2]},
            threshold_line=14.4,
            min_=0,
            desc="Multiple of the sustainable error rate. Dashed line: fast-burn threshold 14.4.",
        ),
        timeseries(
            "Error ratio, 5m window ($env)",
            [
                target(f"env:slo_availability_errors:ratio_rate5m{E}", "5xx ratio", "A"),
                target(f"env:slo_latency_errors:ratio_rate5m{E}", "slower than 150ms", "B"),
            ],
            "percentunit",
            pos(0, 17, 24, 8),
            series_colors={"5xx ratio": SLOT[1], "slower than 150ms": SLOT[2]},
            min_=0,
        ),
    ]
    return dashboard(
        "adpulse-slo",
        "AdPulse SRE / SLO",
        p,
        "Service level objectives, error budget remaining and burn rates.",
        time_from="now-6h",
    )


# ---------------------------------------------------------------- 5. incidents
def incidents():
    p = [
        text(
            "Firing alerts over time (one row per alert and env) with healer actions as annotations "
            "(tag `heal`). Raw heal log: `incidents/heal-log.jsonl`. RCAs: `docs/rca/`.",
            pos(0, 0, 24, 2),
        ),
        state_timeline(
            "Alert timeline",
            [
                target(
                    'max by (alertname, env) (ALERTS{alertstate="firing"})',
                    "{{alertname}} ({{env}})",
                )
            ],
            pos(0, 2, 24, 12),
            desc="Red = firing.",
            mappings=[
                {
                    "type": "value",
                    "options": {"1": {"text": "firing", "color": CRITICAL}},
                }
            ],
        ),
        timeseries(
            "Alerts firing",
            [target('count(ALERTS{alertstate="firing"}) or vector(0)', "firing alerts")],
            "none",
            pos(0, 14, 12, 8),
            min_=0,
            single_color=CRITICAL,
        ),
        timeseries(
            "Healer actions per minute by result",
            [
                target(
                    "sum by (result) (rate(adpulse_heal_actions_total[1m])) * 60",
                    "{{result}}",
                )
            ],
            "none",
            pos(12, 14, 12, 8),
            min_=0,
            stack=True,
            series_colors={"success": SLOT[1], "failed": SLOT[2], "dry_run": SLOT[3]},
            desc="From the healer (Phase 8).",
        ),
    ]
    return dashboard(
        "adpulse-incidents",
        "AdPulse Incidents",
        p,
        "Alert timeline and healer actions.",
        env_var=False,
        time_from="now-3h",
    )


def main() -> None:
    OUT.mkdir(parents=True, exist_ok=True)
    boards = {
        "01-overview.json": overview(),
        "02-infrastructure.json": infrastructure(),
        "03-database-cache.json": database_cache(),
        "04-sre-slo.json": sre_slo(),
        "05-incidents.json": incidents(),
    }
    for name, board in boards.items():
        (OUT / name).write_text(json.dumps(board, indent=2) + "\n")
        print(f"wrote {name}: {len(board['panels'])} panels")


if __name__ == "__main__":
    main()
