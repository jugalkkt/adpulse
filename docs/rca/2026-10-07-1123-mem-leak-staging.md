# RCA: mem-leak in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `mem-leak` (hardware (container memory)) · **Severity:** warning
- **Status:** Resolved
- **Injection:** chaos endpoint memory_leak on api-<env>-1: 10 MB/s, plateau at 190 MB (~94% of the 256 MiB limit; uncapped it would OOM before the alert window)
- **Data:** `incidents/20261007T112335Z-mem-leak-staging/timeline.json`

## Summary
A memory leak was injected into `api-staging-1` (10 MB/s, plateau at 190 MB, about 94% of its 256 MiB limit). `ApiContainerMemoryHigh` fired at 62.2 s, and the healer restarted that container (14.6 s), which released the leaked memory. Recovery at 88.0 s, with no user impact.

## Impact
- Duration (injection → recovered): **88.0s**
- User probes through nginx (1/s): 91 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.013 s
- API-side traffic in the window (loadgen + probes): 1419 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:23:40.757Z | T+0.0s | injected |
| 2026-10-07T11:23:45.772Z | T+5.0s | other alert seen: HealerEscalated |
| 2026-10-07T11:24:42.973Z | T+62.2s | alert_firing |
| 2026-10-07T11:24:52.893Z | T+72.1s | heal_started |
| 2026-10-07T11:25:07.483Z | T+86.7s | heal_finished |
| 2026-10-07T11:25:08.719Z | T+88.0s | recovered |
| 2026-10-07T11:25:08.863Z | T+88.1s | injection_removed |
| 2026-10-07T11:25:11.864Z | T+91.1s | alert_resolved |

## Detection
- Expected alert: `ApiContainerMemoryHigh` → **fired**, MTTD **62.2 s**.
- Other alerts seen: `HealerEscalated` (T+5.0s)
- Was it the right alert? Yes. The alert used the stable container name rebuilt from the `com.adpulse.replica` label (`container=api-staging-1`, D040), so the healer restarted the right replica. (The `HealerEscalated` alert seen at T+5 s was the leftover false escalation from the api-hang run.)

## Root cause
Injected fault: unbounded allocation in the process (chaos `memory_leak`). Without the plateau, the container would hit its limit in about 20 s and be OOM-killed. Docker's restart policy would then 'heal' it (layer 1), but in-flight requests would fail and nothing would be recorded. The plateau models the more common real case: a leak that sits just under the limit and degrades the service.

## 5 Whys
1. Why was memory high? The process kept 190 MB of leaked buffers.
2. Why 62 s to detect? ~19 s to reach the plateau, then working set > 90% for the rule's `for: 30s`, plus cAdvisor's 10 s scrape interval.
3. Why could Docker not fix it? The container was alive and healthy, just bloated. Docker restarts only exited containers.
4. Why did a restart fix it? Leaked memory lives in the process; a new process starts clean.
5. Why no user impact? The other replica and the leaking one kept serving; the restart was a graceful SIGTERM.

## Resolution
- Healer: `restart_api` → **success** in 14.59 s (attempt 1, vars `{"env": "staging", "alertname": "ApiContainerMemoryHigh", "container": "api-staging-1"}`).
- Expected heal: restart_api.
- **MTTR: 88.0 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** the right replica was found via the stable container label; 0 failed or slow probes.
**Went badly:** a restart only treats the symptom: a real leak returns until the code is fixed, and the healer would eventually escalate (3 attempts per 15 min).
**Lucky:** the leak plateaued; a faster leak would have hit OOM before the alert's 30 s window.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Add a memory-growth trend alert (`deriv` of working set over 5 m), to page before the 90% threshold | detect | Jugal | open |
| Capture a heap profile before restarting (e.g. tracemalloc snapshot endpoint), so the code fix has evidence | mitigate | Jugal | open |

## Evidence
Window: 11:23:40–11:25:11 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.005 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 1419 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[91s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[91s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[91s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[91s])) or vector(0)` |

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
