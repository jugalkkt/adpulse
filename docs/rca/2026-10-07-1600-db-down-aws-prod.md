# RCA: db-down in aws-prod   (Blameless)
- **Date:** 2026-10-07 · **Env:** aws-prod · **Scenario:** `db-down` (database) · **Severity:** critical
- **Status:** Resolved
- **Injection:** docker stop postgres-<env>
- **Data:** `incidents/20261007T160012Z-db-down-aws-prod/timeline.json`

## Summary
On the AWS host, `postgres-aws-prod` was stopped. `AdPulseDatabaseDown` fired after 20.9 s and stayed firing (keep_firing_for, fast-fail exporter DNS, both from the staging RCAs). The healer's `restart_db` succeeded (12.0 s), and aws-prod recovered at 40.2 s. No request failed; API-side, 53 of 392 requests (13.5%) got house ads; p95 peaked at 0.841 s.

## Impact
- Duration (injection → recovered): **40.2s**
- User probes through nginx (1/s): 44 total, **0 failed (non-200)**, **10 fallback ads**, 10 slower than 250 ms, max latency 0.637 s
- API-side traffic in the window (loadgen + probes): 392 requests, 0 5xx (0.00%), 53 fallback ads (13.50%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T16:00:18.223Z | T+0.0s | injected |
| 2026-10-07T16:00:39.102Z | T+20.9s | alert_firing |
| 2026-10-07T16:00:45.263Z | T+27.0s | first_failed_probe |
| 2026-10-07T16:00:48.239Z | T+30.0s | heal_started |
| 2026-10-07T16:00:58.450Z | T+40.2s | recovered |
| 2026-10-07T16:00:59.229Z | T+41.0s | injection_removed |
| 2026-10-07T16:01:00.279Z | T+42.1s | heal_finished |
| 2026-10-07T16:01:28.234Z | T+70.0s | alert_resolved |

## Detection
- Expected alert: `AdPulseDatabaseDown` → **fired**, MTTD **20.9 s**.
- Other alerts seen: none
- Was it the right alert? Yes. The fixes developed locally after the first (failed) staging db-down applied unchanged in the cloud, because they live in the shared Terraform module and rules.

## Root cause
Injected fault: the database container was stopped. Cache misses (5 rps loadgen across 30 keys, 60 s TTL) needed the DB and fell back to house ads after the 0.5 s DB timeout.

## 5 Whys
1. Why house ads? Requests whose keys were not cached needed the DB, which was down.
2. Why 13.5%? A lower request rate than local prod means more keys expire between requests, so a larger share missed the cache.
3. Why did the alert stay firing? keep_firing_for 30 s.
4. Why fast detection? The exporter's DNS lookup for the stopped container fails instantly (dead upstream DNS).
5. Why 40 s? 20.9 s detection + 10 s group_wait + 12 s restart and checks.

## Resolution
- Healer: `restart_db` → **success** in 12.04 s (attempt 1, vars `{"env": "aws-prod", "alertname": "AdPulseDatabaseDown"}`).
- Expected heal: restart_db.
- **MTTR: 40.2 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** the lessons from staging (D049, D050) carried to AWS with zero extra work; healed in 40 s.
**Went badly:** 13.5% house ads; the cache only helps for keys requested within the last 60 s.
**Lucky:** low traffic.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Stale-if-error caching (same as the staging/prod db-down RCAs) | mitigate | Jugal | open |

## Evidence
Window: 16:00:18–16:01:28 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="aws-prod"}` |
| peak p95 latency (1m) | 0.841 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="aws-prod"}` |
| requests | 392 | `sum(increase(adpulse_http_requests_total{env="aws-prod", route="/v1/ad"}[70s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="aws-prod", route="/v1/ad", status=~"5.."}[70s])) or vector(0)` |
| fallback ads | 53 | `sum(increase(adpulse_fallback_total{env="aws-prod"}[70s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="aws-prod", result="error"}[70s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
FAILED - RETRYING: [localhost]: Wait for healthy | postgres-aws-prod (28 retries left).
ok: [localhost]

TASK [Wait for pg_isready] *****************************************************
ok: [localhost]

TASK [Find a running API replica] **********************************************
ok: [localhost]

TASK [Wait until the API reports ready (/readyz 200)] **************************
ok: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=7    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```
</details>
