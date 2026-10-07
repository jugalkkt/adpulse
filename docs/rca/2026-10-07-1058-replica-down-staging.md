# RCA: replica-down in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `replica-down` (software) · **Severity:** critical
- **Status:** Resolved
- **Injection:** docker stop api-<env>-1 (manual stop: Docker's restart policy will not restart it)
- **Data:** `incidents/20261007T105809Z-replica-down-staging/timeline.json`

## Summary
One of the two staging API replicas (`api-staging-1`) was stopped. Users saw no errors: nginx retried every request that hit the dead replica on the healthy one. The healer restarted the replica 30 s after the stop, and the system was fully healthy after 42.7 s.

## Impact
- Duration (injection → recovered): **42.7s**
- User probes through nginx (1/s): 46 total, **0 failed (non-200)**, **0 fallback ads**, 2 slower than 250 ms, max latency 0.503 s
- API-side traffic in the window (loadgen + probes): 821 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T10:58:15.337Z | T+0.0s | injected |
| 2026-10-07T10:58:18.804Z | T+3.5s | first_failed_probe |
| 2026-10-07T10:58:35.951Z | T+20.6s | alert_firing |
| 2026-10-07T10:58:45.383Z | T+30.0s | heal_started |
| 2026-10-07T10:58:58.037Z | T+42.7s | recovered |
| 2026-10-07T10:58:58.060Z | T+42.7s | injection_removed |
| 2026-10-07T10:59:00.793Z | T+45.5s | heal_finished |
| 2026-10-07T10:59:07.066Z | T+51.7s | alert_resolved |

## Detection
- Expected alert: `AdPulseApiReplicaDown` → **fired**, MTTD **20.6 s**.
- Other alerts seen: none
- Was it the right alert? Yes. `AdPulseApiReplicaDown` with `reason=missing` fired, the variant written for exactly this case: a stopped container leaves Docker DNS, so there is no `up == 0` series and only the healthy-replica count reveals it.

## Root cause
Injected fault: the container was stopped by hand (`docker stop`). Docker's restart policy `unless-stopped` intentionally does not restart a container that was stopped on purpose, so layer 1 (Docker) could not help and layer 2 (the healer) had to act. Capacity dropped to one replica: an availability risk, but no user impact.

## 5 Whys
1. Why was capacity reduced? `api-staging-1` was not running.
2. Why did Docker not restart it? A manual stop is treated as intentional by the `unless-stopped` policy.
3. Why did users not notice? nginx's `proxy_next_upstream error timeout` retried on the second replica. The 2 probes slower than 250 ms (max 0.50 s) paid the 500 ms `proxy_connect_timeout` to the dead IP before the retry.
4. Why 20.6 s to detect? 5 s scrapes, plus `for: 15s`, plus evaluation alignment.
5. Why 42.7 s to recover? Alertmanager's `group_wait` (10 s) delayed the webhook until T+30 s, then the restart and the wait for Docker health took 15.4 s.

## Resolution
- Healer: `restart_api` → **success** in 15.41 s (attempt 2, vars `{"env": "staging", "alertname": "AdPulseApiReplicaDown", "reason": "missing"}`).
- Expected heal: restart_api.
- **MTTR: 42.7 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** zero failed requests; the detection variant written for stopped replicas worked first time; the healer chose the right replica without being told its name.
**Went badly:** `group_wait: 10s` is a third of the total recovery time for this alert.
**Lucky:** only one of two replicas was stopped. With both gone, nginx would have returned 502 until the healer acted.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Lower `group_wait` for critical self-healable alerts (e.g. 2 s) via a dedicated route | mitigate | Jugal | open |
| Run 3 replicas in prod so losing one keeps headroom | prevent | Jugal | open |

## Evidence
Window: 10:58:15–10:59:07 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.005 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 821 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[51s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[51s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[51s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[51s])) or vector(0)` |

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
