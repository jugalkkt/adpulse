# RCA: db-down in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `db-down` (database) · **Severity:** critical
- **Status:** Resolved
- **Injection:** docker stop postgres-<env>
- **Data:** `incidents/20261007T112050Z-db-down-staging/timeline.json`

## Summary
Re-run of db-down after the fixes from the first db-down incident (keep_firing_for, fast-fail exporter DNS). PostgreSQL was stopped. `AdPulseDatabaseDown` fired after 18.0 s and stayed firing, the healer ran `restart_db` (14.8 s), and the system was healthy again at 37.5 s. This time the self-healing chain worked end to end.

## Impact
- Duration (injection → recovered): **37.5s**
- User probes through nginx (1/s): 40 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.011 s
- API-side traffic in the window (loadgen + probes): 639 requests, 0 5xx (0.00%), 25 fallback ads (3.94%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:20:55.499Z | T+0.0s | injected |
| 2026-10-07T11:21:13.547Z | T+18.0s | alert_firing |
| 2026-10-07T11:21:15.629Z | T+20.1s | other alert seen: AdPulseServingFallbackAds |
| 2026-10-07T11:21:23.236Z | T+27.7s | heal_started |
| 2026-10-07T11:21:33.038Z | T+37.5s | recovered |
| 2026-10-07T11:21:33.059Z | T+37.6s | injection_removed |
| 2026-10-07T11:21:36.060Z | T+40.6s | alert_resolved |
| 2026-10-07T11:21:38.076Z | T+42.6s | heal_finished |

## Detection
- Expected alert: `AdPulseDatabaseDown` → **fired**, MTTD **18.0 s**.
- Other alerts seen: `AdPulseServingFallbackAds` (T+20.1s)
- Was it the right alert? Yes. It fired 4 s faster than in the first run and, crucially, did not flap. `AdPulseServingFallbackAds` also appeared in Alertmanager at T+20.1 s. The chaos tool records suppressed alerts as well, and the inhibition rule (DatabaseDown → ServingFallbackAds) applies while DatabaseDown fires. Recording each alert's state (active vs suppressed) is an open tooling improvement.

## Root cause
Injected fault: the database container was stopped. With the earlier detection bug fixed, this is the expected path: DB unreachable → `pg_up == 0` → alert → `restart_db` → `pg_isready` → API `/readyz` 200 → the DB pool reconnects within seconds (pool `reconnect_timeout` 10 s, D038).

## 5 Whys
1. Why did some users get house ads? Requests whose category/segment was not in the 60 s cache needed the DB, which was down: 25 of 639 API requests (3.9%). The 1/s probe's key stayed cached, so the probe saw no fallback.
2. Why did p95 reach 0.908 s? Those cache-miss requests waited for the 0.5 s DB timeout (pool wait plus query) before falling back.
3. Why was the outage short? The alert stayed firing (keep_firing_for) and reached the healer within one group_wait.
4. Why did the first run fail? See RCA 2026-10-07-1100-db-down-staging: slow DNS made scrapes time out, so the alert flapped.
5. Why 37.5 s? 18 s detection + 10 s group_wait + 14.8 s restart, readiness and API checks (partly overlapping).

## Resolution
- Healer: `restart_db` → **success** in 14.84 s (attempt 1, vars `{"env": "staging", "alertname": "AdPulseDatabaseDown"}`).
- Expected heal: restart_db.
- **MTTR: 37.5 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** the fixes from the previous RCA were verified within an hour (MTTR 600+ s with no heal → 37.5 s); 0 failed requests.
**Went badly:** 3.9% house ads during a 37 s outage. The cache only covers recently requested keys.
**Lucky:** the outage was shorter than the 60 s cache TTL, so most keys stayed cached throughout.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Serve stale cache entries on DB error (stale-if-error), or pre-warm all 30 category×segment keys | mitigate | Jugal | open |
| Record alert state (active/suppressed) in chaos timelines | detect | Jugal | open |

## Evidence
Window: 11:20:55–11:21:36 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.908 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 639 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[40s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[40s])) or vector(0)` |
| fallback ads | 25 | `sum(increase(adpulse_fallback_total{env="staging"}[40s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[40s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
.
FAILED - RETRYING: [localhost]: Wait for healthy | postgres-staging (28 retries left).
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
