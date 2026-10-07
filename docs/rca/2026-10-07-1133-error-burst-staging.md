# RCA: error-burst in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `error-burst` (software) · **Severity:** critical
- **Status:** Resolved
- **Injection:** chaos endpoint error_rate 50% on every replica
- **Data:** `incidents/20261007T113330Z-error-burst-staging/timeline.json`

## Summary
A 50% error rate was injected into both staging replicas (chaos `error_rate`). Users saw it: **52 of 108 probes failed with HTTP 500**, and API-side 776 of 2,419 requests in the window (32.1%) were 5xx. `AdPulseHighErrorRate` fired at 74.4 s, the healer did a rolling restart of both replicas (22.7 s), which cleared the in-memory fault, and the system recovered at 105.5 s.

## Impact
- Duration (injection → recovered): **105.5s**
- User probes through nginx (1/s): 108 total, **52 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.014 s
- API-side traffic in the window (loadgen + probes): 2419 requests, 776 5xx (32.09%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:33:36.137Z | T+0.0s | injected |
| 2026-10-07T11:33:36.949Z | T+0.8s | first_failed_probe |
| 2026-10-07T11:34:50.565Z | T+74.4s | alert_firing |
| 2026-10-07T11:35:00.381Z | T+84.2s | heal_started |
| 2026-10-07T11:35:21.596Z | T+105.5s | recovered |
| 2026-10-07T11:35:21.750Z | T+105.6s | injection_removed |
| 2026-10-07T11:35:23.031Z | T+106.9s | heal_finished |
| 2026-10-07T11:36:10.797Z | T+154.7s | alert_resolved |

## Detection
- Expected alert: `AdPulseHighErrorRate` → **fired**, MTTD **74.4 s**.
- Other alerts seen: none
- Was it the right alert? Yes. It is the symptom alert that matters most here (users get errors). Its 74.4 s MTTD comes from the rule's `for: 1m` on top of a 1 m rate window. No inhibition applied (the DB was healthy), which is correct.

## Root cause
Injected fault: the application returned 500 for half of the requests. nginx's `proxy_next_upstream` deliberately does not retry on 500 (only on errors, timeouts, 502 and 503), because retrying a non-idempotent error could double side effects, so the errors reached users. The fault lived in process memory, so a restart cleared it, like a bad config reload or a poisoned in-memory cache in real life.

## 5 Whys
1. Why did users get errors? Both replicas returned 500 for ~50% of requests, and nginx passes 500s through.
2. Why ~75 s before any action? The alert needs the 1 m 5xx ratio above 5% for 1 m, then 10 s group_wait.
3. Why a rolling restart and not one replica? The alert is per env (both replicas were faulty), so `mode=rolling` restarts them one at a time and keeps serving.
4. Why did the restart fix it? The faulty state was in memory.
5. Why would this escalate next time? The rule allows one attempt per 10 min. A real bug would survive the restart and come back, and the healer would correctly hand it to a human.

## Resolution
- Healer: `restart_api` → **success** in 22.65 s (attempt 1, vars `{"env": "staging", "alertname": "AdPulseHighErrorRate", "mode": "rolling"}`).
- Expected heal: restart_api (rolling).
- **MTTR: 105.5 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** the rolling restart kept capacity while clearing the fault; MTTR under 2 minutes.
**Went badly:** about 75 s of 50% errors before anything happened. That burns the fast-burn budget: 0.532 peak 5xx ratio vs a 0.5% SLO budget.
**Lucky:** the fault was in memory; a code bug would have needed a rollback (Phase 10 demonstrates that path).

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Add a short, high-threshold error rule (e.g. > 20% for 15 s) next to the 5%/1 m one, for faster action on severe bursts | detect | Jugal | open |
| On repeat within 10 min, have the healer trigger `make rollback` instead of only escalating, if a deploy happened recently | mitigate | Jugal | open |

## Evidence
Window: 11:33:36–11:36:10 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.532 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.005 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 2419 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[154s])) or vector(0)` |
| 5xx requests | 776 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[154s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[154s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[154s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
*******
skipping: [localhost]

TASK [Restart or start | api-staging-2] ****************************************
changed: [localhost]

TASK [Wait for healthy | api-staging-2] ****************************************
FAILED - RETRYING: [localhost]: Wait for healthy | api-staging-2 (29 retries left).
FAILED - RETRYING: [localhost]: Wait for healthy | api-staging-2 (28 retries left).
ok: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=12   changed=2    unreachable=0    failed=0    skipped=6    rescued=0    ignored=0
```
</details>
