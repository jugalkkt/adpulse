# RCA: net-latency-datapath in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `net-latency-datapath` (network) · **Severity:** warning
- **Status:** Resolved
- **Injection:** Toxiproxy latency toxic 300ms (jitter 100) on BOTH the redis and postgres proxies
- **Data:** `incidents/20261007T114721Z-net-latency-datapath-staging/timeline.json`

## Summary
+300 ms (±100) on **both** the Redis and Postgres proxies. Cache calls timed out, DB queries often exceeded the 0.5 s DB timeout, and the API served house ads to **74.5% of requests (2,742 of 3,683)**, with p95 up to 2.4 s. `AdPulseHighLatencyP95` fired at 134.2 s, the healer ran `diagnose_latency` (evidence only, 27.2 s), and the 'human' step (the chaos tool) removed the toxics at 172.1 s. Recovered at 175.4 s.

## Impact
- Duration (injection → recovered): **175.4s**
- User probes through nginx (1/s): 152 total, **0 failed (non-200)**, **145 fallback ads**, 145 slower than 250 ms, max latency 1.805 s
- API-side traffic in the window (loadgen + probes): 3683 requests, 0 5xx (0.00%), 2742 fallback ads (74.45%), cache errors 2728
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:47:27.010Z | T+0.0s | injected |
| 2026-10-07T11:47:27.754Z | T+0.7s | first_failed_probe |
| 2026-10-07T11:48:36.117Z | T+69.1s | other alert seen: AdPulseServingFallbackAds |
| 2026-10-07T11:49:41.222Z | T+134.2s | alert_firing |
| 2026-10-07T11:49:50.378Z | T+143.4s | heal_started |
| 2026-10-07T11:50:17.538Z | T+170.5s | heal_finished |
| 2026-10-07T11:50:19.128Z | T+172.1s | injection_removed |
| 2026-10-07T11:50:22.418Z | T+175.4s | recovered |
| 2026-10-07T11:51:21.857Z | T+234.8s | alert_resolved |

## Detection
- Expected alert: `AdPulseHighLatencyP95` → **fired**, MTTD **134.2 s**.
- Other alerts seen: `AdPulseServingFallbackAds` (T+69.1s)
- Was it the right alert? Yes. The latency alert fired as designed, after its 2 m `for`. `AdPulseServingFallbackAds` also fired (T+69 s), which is correct because the DB was not down, so no inhibition. Both MTTD and MTTR are dominated by design choices: the 2 m `for`, and a human in the loop for network faults.

## Root cause
Injected fault: latency on the whole data path (both dependencies). No automatic fix exists for a slow network; the healer gathered evidence (`incidents/diagnostics/20261007T114952Z-staging/`: toxics list, docker stats, pg_stat_activity, Redis INFO, p95 series) so a human could see the toxics and act.

## 5 Whys
1. Why were users served house ads? Cache calls timed out (200 ms) and DB calls often exceeded their 0.5 s timeout.
2. Why p95 2.4 s? Requests waited for the cache timeout, the DB pool wait and the DB timeout in sequence, and nginx may retry on its 2 s read timeout.
3. Why 134 s to detect? The p95 rule uses a 1 m window plus `for: 2m`.
4. Why no automatic fix? Network latency has many causes; restarting things does not help and could hurt, so the design hands it to a human.
5. Why 41 s from alert to human action? The healer's diagnostics took 27 s, then the 'human' acted immediately.

## Resolution
- Healer: `diagnose_latency` → **success** in 27.16 s (attempt 1, vars `{"env": "staging", "alertname": "AdPulseHighLatencyP95"}`).
- Expected heal: diagnose_latency (human removes the fault). The fault was removed by a human step (this tool).
- **MTTR: 175.4 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** no request failed (graceful degradation); the evidence bundle showed the injected toxics directly, so diagnosis took seconds.
**Went badly:** 74.5% house ads (revenue loss) and over 2 minutes before any alert. ServingFallbackAds (for: 1m) fired before the latency alert.
**Lucky:** a human was 'on call' immediately.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Treat AdPulseServingFallbackAds > 20% as critical (it detected this 65 s earlier than the latency alert) | detect | Jugal | open |
| Shorter `for` (30 s) on the latency alert when p95 > 1 s (a severity tier) | detect | Jugal | open |
| Stale-if-error caching to keep serving real ads when the data path is slow | mitigate | Jugal | open |

## Evidence
Window: 11:47:27–11:51:21 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 2.377 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 3683 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[234s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[234s])) or vector(0)` |
| fallback ads | 2742 | `sum(increase(adpulse_fallback_total{env="staging"}[234s])) or vector(0)` |
| cache errors | 2728 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[234s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
*******************
ok: [localhost]

TASK [Write p95 series] ********************************************************
changed: [localhost]

TASK [Report] ******************************************************************
ok: [localhost] =>
    msg: Diagnostics written to /data/diagnostics/20261007T114952Z-staging (no automatic
        fix for latency; see docs/runbooks/AdPulseHighLatencyP95.md)

PLAY RECAP *********************************************************************
localhost                  : ok=7    changed=3    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```
</details>
