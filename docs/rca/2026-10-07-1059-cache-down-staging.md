# RCA: cache-down in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `cache-down` (database (cache)) · **Severity:** critical
- **Status:** Resolved
- **Injection:** docker stop redis-<env>
- **Data:** `incidents/20261007T105914Z-cache-down-staging/timeline.json`

## Summary
Redis in staging (`redis-staging`) was stopped. Every cache lookup failed fast (619 cache errors in the window), and the API served all requests from PostgreSQL with no errors and no fallback ads. p95 peaked at 17 ms. The healer restarted Redis 33.7 s after the stop, and recovery completed at 43.5 s.

## Impact
- Duration (injection → recovered): **43.5s**
- User probes through nginx (1/s): 46 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.027 s
- API-side traffic in the window (loadgen + probes): 733 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 619
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T10:59:19.563Z | T+0.0s | injected |
| 2026-10-07T10:59:43.593Z | T+24.0s | alert_firing |
| 2026-10-07T10:59:53.238Z | T+33.7s | heal_started |
| 2026-10-07T11:00:03.037Z | T+43.5s | recovered |
| 2026-10-07T11:00:03.056Z | T+43.5s | injection_removed |
| 2026-10-07T11:00:05.698Z | T+46.1s | heal_finished |
| 2026-10-07T11:00:06.058Z | T+46.5s | alert_resolved |

## Detection
- Expected alert: `AdPulseCacheDown` → **fired**, MTTD **24.0 s**.
- Other alerts seen: none
- Was it the right alert? Yes. `AdPulseCacheDown` fired 24 s after the stop. No symptom alerts fired, which is correct: users were not affected.

## Root cause
Injected fault: the cache container was stopped. The design contained it: Redis calls have a 200 ms socket timeout and no retries, and a cache error falls straight through to the database (without trying to refill the dead cache). The database easily carried the extra load: 733 requests in the ~60 s window, about 12 req/s across both replicas.

## 5 Whys
1. Why did lookups fail? Redis was not running.
2. Why were users unaffected? Every cache error fell through to PostgreSQL, which answered within milliseconds.
3. Why was latency still low? Cache calls failed much faster than the 200 ms timeout: p95 stayed at 17 ms and the slowest probe took 27 ms. Toxiproxy closed the connection as soon as it could not reach Redis. (The per-call failure time was not measured directly.)
4. Why did it need a healer? A stopped container is not restarted by Docker's `unless-stopped` policy.
5. Why 43.5 s to recover? 24 s detection + 10 s `group_wait` + 12.5 s restart and health wait.

## Resolution
- Healer: `restart_cache` → **success** in 12.46 s (attempt 1, vars `{"env": "staging", "alertname": "AdPulseCacheDown"}`).
- Expected heal: restart_cache.
- **MTTR: 43.5 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** graceful degradation worked exactly as designed (0 failed, 0 fallback); the healer recovered without a human.
**Went badly:** nothing user-visible. But the DB carried 100% of reads; at production traffic that load could itself become the next incident.
**Lucky:** staging traffic is low (15 req/s), so PostgreSQL had plenty of headroom.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Load-test the database at 100% cache-miss traffic to know the safe ceiling | detect | Jugal | open |
| Alert on cache error ratio, not only `redis_up` (a reachable-but-broken cache would not trip CacheDown) | detect | Jugal | open |

## Evidence
Window: 10:59:19–11:00:06 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.017 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 733 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[46s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[46s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[46s])) or vector(0)` |
| cache errors | 619 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[46s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
*******
skipping: [localhost]

TASK [Restart or start | redis-staging] ****************************************
changed: [localhost]

TASK [Wait for healthy | redis-staging] ****************************************
FAILED - RETRYING: [localhost]: Wait for healthy | redis-staging (29 retries left).
FAILED - RETRYING: [localhost]: Wait for healthy | redis-staging (28 retries left).
ok: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=4    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```
</details>
