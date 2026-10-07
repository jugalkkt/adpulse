# RCA: api-hang in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `api-hang` (software) · **Severity:** critical
- **Status:** Resolved
- **Injection:** chaos endpoint hang on api-<env>-1: every route stops answering (scrape and health time out)
- **Data:** `incidents/20261007T112231Z-api-hang-staging/timeline.json`

## Summary
`api-staging-1` was made to hang (every route, including `/healthz` and `/metrics`, stopped answering). Prometheus' scrape timed out, `AdPulseApiReplicaDown` (reason=unreachable) fired at 24.3 s, and the healer restarted that exact replica by its IP (24.0 s). Recovery at 56.1 s. No request failed, but 12 of 47 probes waited up to 2.0 s. A second, redundant alert then caused a **false escalation**, now fixed.

## Impact
- Duration (injection → recovered): **56.1s**
- User probes through nginx (1/s): 47 total, **0 failed (non-200)**, **0 fallback ads**, 12 slower than 250 ms, max latency 2.011 s
- API-side traffic in the window (loadgen + probes): 950 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:22:36.308Z | T+0.0s | injected |
| 2026-10-07T11:22:40.250Z | T+3.9s | first_failed_probe |
| 2026-10-07T11:23:00.601Z | T+24.3s | alert_firing |
| 2026-10-07T11:23:10.378Z | T+34.1s | heal_started |
| 2026-10-07T11:23:32.364Z | T+56.1s | recovered |
| 2026-10-07T11:23:32.577Z | T+56.3s | injection_removed |
| 2026-10-07T11:23:34.368Z | T+58.1s | heal_finished |
| 2026-10-07T11:23:35.579Z | T+59.3s | alert_resolved |

## Detection
- Expected alert: `AdPulseApiReplicaDown` → **fired**, MTTD **24.3 s**.
- Other alerts seen: none
- Was it the right alert? Yes, and it found the right replica: the `unreachable` variant carries the scrape target's IP, which `restart_api` mapped to `api-staging-1`. But a hung replica also lowers the healthy count, so the `missing` variant fired too (different fingerprint). Its playbook ran second, found nothing to restart, failed, and the healer escalated: `HealerEscalated` fired for a problem that was already fixed.

## Root cause
Injected fault: an application hang (chaos `hang`). The Docker restart policy cannot fix a process that is alive but stuck, and Docker only marks it unhealthy, so this needed layer 2. The false escalation's root cause: `restart_api` treated 'no stopped replica found' as a failure even when all replicas were healthy again.

## 5 Whys
1. Why were requests slow? nginx sent some requests to the hung replica and waited for its 2 s `proxy_read_timeout` before retrying on the healthy one (max probe latency 2.01 s).
2. Why did the API's own p95 stay at 6 ms? Those requests never completed on the hung replica, so they never reached its metrics. Only the outside-in probe saw the user experience.
3. Why did the heal take 24 s? Most likely because `docker restart -t 10` had to wait out its 10 s grace: the hung in-flight requests keep uvicorn's graceful shutdown from finishing, so Docker kills it after the grace period. Then the playbook waits for Docker health. (Inferred from the 24 s total; the stop phase was not timed separately.)
4. Why a false escalation? Two alert variants for one fault produced two heal actions; the second found nothing to do and reported failure.
5. Why did that matter? HealerEscalated pages a human and blocked the next chaos run for 5 minutes.

## Resolution
- Healer: `restart_api` → **success** in 23.99 s (attempt 1, vars `{"env": "staging", "alertname": "AdPulseApiReplicaDown", "instance": "172.28.10.11:8000", "reason": "unreachable"}`).
- Expected heal: restart_api.
- **MTTR: 56.1 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** precise targeting by IP; 0 failed requests; the escalation path itself works.
**Went badly:** a false page. Users waited up to 2 s on 12 requests.
**Lucky:** the false escalation was caught by the chaos tool's quiet-check before the next experiment, not by a human woken at night.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| `restart_api`: nothing to restart + expected replicas healthy → success no-op | prevent | Jugal | **done** (commit e6eeba9, `make test-heal` case added) |
| Lower `proxy_read_timeout` for `/v1/ad` (e.g. 500 ms; normal p99 is single-digit ms) so a hung replica costs less | mitigate | Jugal | open |
| Measure user-facing latency at nginx (an exporter for nginx), not only inside the API | detect | Jugal | open |

## Evidence
Window: 11:22:36–11:23:35 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.006 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 950 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[59s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[59s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[59s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[59s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
*******
skipping: [localhost]

TASK [Restart or start | api-staging-1] ****************************************
changed: [localhost]

TASK [Wait for healthy | api-staging-1] ****************************************
FAILED - RETRYING: [localhost]: Wait for healthy | api-staging-1 (29 retries left).
FAILED - RETRYING: [localhost]: Wait for healthy | api-staging-1 (28 retries left).
ok: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=8    changed=1    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
```
</details>
