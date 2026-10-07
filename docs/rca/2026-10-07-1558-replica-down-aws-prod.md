# RCA: replica-down in aws-prod   (Blameless)
- **Date:** 2026-10-07 · **Env:** aws-prod · **Scenario:** `replica-down` (software) · **Severity:** critical
- **Status:** Resolved
- **Injection:** docker stop api-<env>-1 (manual stop: Docker's restart policy will not restart it)
- **Data:** `incidents/20261007T155836Z-replica-down-aws-prod/timeline.json`

## Summary
On the AWS host (aws-prod, c7i-flex.large, ap-south-1), `api-aws-prod-1` was stopped. `AdPulseApiReplicaDown` (reason=missing) fired after 28.9 s, the healer on the VM ran `restart_api` through its docker-socket-proxy (11.7 s), and the system was healthy at 52.1 s. No user impact: 0 failed of 56 probes sent over the internet from the laptop, slowest 0.12 s.

## Impact
- Duration (injection → recovered): **52.1s**
- User probes through nginx (1/s): 56 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.123 s
- API-side traffic in the window (loadgen + probes): 487 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T15:58:42.850Z | T+0.0s | injected |
| 2026-10-07T15:59:11.793Z | T+28.9s | alert_firing |
| 2026-10-07T15:59:20.442Z | T+37.6s | heal_started |
| 2026-10-07T15:59:32.102Z | T+49.3s | heal_finished |
| 2026-10-07T15:59:34.952Z | T+52.1s | recovered |
| 2026-10-07T15:59:35.731Z | T+52.9s | injection_removed |
| 2026-10-07T16:00:11.406Z | T+88.6s | alert_resolved |

## Detection
- Expected alert: `AdPulseApiReplicaDown` → **fired**, MTTD **28.9 s**.
- Other alerts seen: none
- Was it the right alert? Yes: the same rule, healer and playbook as local, deployed from the same Terraform modules and images, behaved the same in the cloud. The 8 s slower MTTD than staging's 20.6 s is within the scrape/evaluation alignment jitter (5 s intervals plus `for: 15s`).

## Root cause
Injected fault: a manually stopped replica (Docker's `unless-stopped` does not restart it). Same as staging; this run shows the cloud deployment has the same self-healing behaviour.

## 5 Whys
1. Why was capacity reduced? A replica was stopped.
2. Why no user impact? nginx retried on the other replica.
3. Why did the healer act on AWS? Alertmanager on the VM delivers to the healer on the VM (same monitoring module).
4. Why could the healer restart it? It reached the VM's Docker through the socket proxy (same least-privilege setup as local).
5. Why 52 s? 28.9 s detection + 10 s group_wait + 11.7 s restart and health wait.

## Resolution
- Healer: `restart_api` → **success** in 11.66 s (attempt 2, vars `{"env": "aws-prod", "alertname": "AdPulseApiReplicaDown", "reason": "missing"}`).
- Expected heal: restart_api.
- **MTTR: 52.1 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** identical behaviour local → cloud (one module, one set of rules); 0 failed requests.
**Went badly:** at first bring-up of aws-prod, the same rule fired before the first deploy existed (Terraform creates the env ~1 min before Ansible deploys the API). The healer correctly escalated (`replicas=[]`), but that was a false page.
**Lucky:** nothing; behaved as designed.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| On a brand-new env, silence API alerts until the first deploy (or deploy before enabling the healer) | prevent | Jugal | open |

## Evidence
Window: 15:58:42–16:00:11 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="aws-prod"}` |
| peak p95 latency (1m) | 0.005 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="aws-prod"}` |
| requests | 487 | `sum(increase(adpulse_http_requests_total{env="aws-prod", route="/v1/ad"}[88s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="aws-prod", route="/v1/ad", status=~"5.."}[88s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="aws-prod"}[88s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="aws-prod", result="error"}[88s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
*****
skipping: [localhost]

TASK [Restart or start | api-aws-prod-1] ***************************************
changed: [localhost]

TASK [Wait for healthy | api-aws-prod-1] ***************************************
FAILED - RETRYING: [localhost]: Wait for healthy | api-aws-prod-1 (29 retries left).
FAILED - RETRYING: [localhost]: Wait for healthy | api-aws-prod-1 (28 retries left).
ok: [localhost]

PLAY RECAP *********************************************************************
localhost                  : ok=8    changed=1    unreachable=0    failed=0    skipped=5    rescued=0    ignored=0
```
</details>
