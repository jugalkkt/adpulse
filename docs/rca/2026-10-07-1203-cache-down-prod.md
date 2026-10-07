# RCA: cache-down in prod   (Blameless)
- **Date:** 2026-10-07 · **Env:** prod · **Scenario:** `cache-down` (database (cache)) · **Severity:** critical
- **Status:** Resolved
- **Injection:** docker stop redis-<env>
- **Data:** `incidents/20261007T120317Z-cache-down-prod/timeline.json`

## Summary
Game day in local **prod**: Redis stopped. `AdPulseCacheDown` fired at 16.0 s, the healer's `restart_cache` succeeded (10.9 s), and prod recovered at 34.4 s. No request failed and no house ads were served (0 API-side); all 739 cache errors fell through to PostgreSQL.

## Impact
- Duration (injection → recovered): **34.4s**
- User probes through nginx (1/s): 37 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.059 s
- API-side traffic in the window (loadgen + probes): 947 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 739
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T12:03:22.863Z | T+0.0s | injected |
| 2026-10-07T12:03:38.887Z | T+16.0s | alert_firing |
| 2026-10-07T12:03:40.928Z | T+18.1s | other alert seen: AdPulseServingFallbackAds |
| 2026-10-07T12:03:48.237Z | T+25.4s | heal_started |
| 2026-10-07T12:03:57.260Z | T+34.4s | recovered |
| 2026-10-07T12:03:57.277Z | T+34.4s | injection_removed |
| 2026-10-07T12:03:59.127Z | T+36.3s | heal_finished |
| 2026-10-07T12:04:00.283Z | T+37.4s | alert_resolved |

## Detection
- Expected alert: `AdPulseCacheDown` → **fired**, MTTD **16.0 s**.
- Other alerts seen: `AdPulseServingFallbackAds` (T+18.1s)
- Was it the right alert? Yes. The `AdPulseServingFallbackAds` seen at T+18 s, and the 0.864 s peak p95 in this window, are **carry-over from the prod db-down run that ended 50 s earlier**: both use 1 m rate windows that still contained the previous incident. This run itself produced 0 fallback ads.

## Root cause
Injected fault: the cache container was stopped. The cache → DB fall-through handled it with no user impact, as in staging, now at prod traffic (25 rps).

## 5 Whys
1. Why no user impact? Every cache error fell through to the DB, which was healthy.
2. Why fast detection (16 s)? Consistent with the fast-fail exporter DNS fix: with Redis down, an exporter scrape now takes 0.2–0.4 s (measured in staging), so `redis_up == 0` arrives on the next 5 s scrape.
3. Why a healer action at all? A stopped container is not restarted by `unless-stopped`.
4. Why the stray fallback alert? 1 m rate windows overlapped the previous experiment.
5. Why does the overlap matter? It would confuse a real on-call engineer: back-to-back incidents need spacing (or `for` long enough) to keep alerts attributable.

## Resolution
- Healer: `restart_cache` → **success** in 10.89 s (attempt 1, vars `{"env": "prod", "alertname": "AdPulseCacheDown"}`).
- Expected heal: restart_cache.
- **MTTR: 34.4 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** zero impact; quick, automatic recovery in prod.
**Went badly:** a symptom alert from the previous incident appeared during this one.
**Lucky:** PostgreSQL had just recovered from the db-down game day.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Space chaos runs by at least one rate window (60 s) after the previous alert resolves | detect | Jugal | open |

## Evidence
Window: 12:03:22–12:04:00 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="prod"}` |
| peak p95 latency (1m) | 0.864 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="prod"}` |
| requests | 947 | `sum(increase(adpulse_http_requests_total{env="prod", route="/v1/ad"}[37s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="prod", route="/v1/ad", status=~"5.."}[37s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="prod"}[37s])) or vector(0)` |
| cache errors | 739 | `sum(increase(adpulse_cache_requests_total{env="prod", result="error"}[37s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
*************
skipping: [localhost]

TASK [Restart or start | redis-prod] *******************************************
changed: [localhost]

TASK [Wait for healthy | redis-prod] *******************************************
FAILED - RETRYING: [localhost]: Wait for healthy | redis-prod (29 retries left).
FAILED - RETRYING: [localhost]: Wait for healthy | redis-prod (28 retries left).
ok: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=4    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```
</details>
