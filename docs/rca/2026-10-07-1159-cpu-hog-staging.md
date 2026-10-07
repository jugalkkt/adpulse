# RCA: cpu-hog in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `cpu-hog` (hardware (host)) · **Severity:** warning
- **Status:** Resolved
- **Injection:** adpulse-chaos-stress (stress-ng, workers = nproc, role=chaos), hard limit 180s
- **Data:** `incidents/20261007T115935Z-cpu-hog-staging/timeline.json`

## Summary
A CPU stressor (stress-ng, 8 workers, labelled `role=chaos`) saturated the host. `HostHighCPU` fired at 106.3 s, and the healer's `kill_noisy_neighbor` stopped exactly that container (measured at 644.8% CPU) in 14.6 s, touching nothing else (27 AdPulse containers kept running). Recovered at 137.6 s, with no user impact (slowest probe 55 ms).

## Impact
- Duration (injection → recovered): **137.6s**
- User probes through nginx (1/s): 140 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.055 s
- API-side traffic in the window (loadgen + probes): 2334 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:59:46.725Z | T+0.0s | injected |
| 2026-10-07T12:01:33.040Z | T+106.3s | alert_firing |
| 2026-10-07T12:01:42.894Z | T+116.2s | heal_started |
| 2026-10-07T12:01:57.524Z | T+130.8s | heal_finished |
| 2026-10-07T12:02:04.333Z | T+137.6s | recovered |
| 2026-10-07T12:02:04.349Z | T+137.6s | injection_removed |
| 2026-10-07T12:02:13.414Z | T+146.7s | alert_resolved |

## Detection
- Expected alert: `HostHighCPU` → **fired**, MTTD **106.3 s**.
- Other alerts seen: none
- Was it the right alert? Yes. MTTD is long by design: a 1 m CPU rate window plus `for: 1m`. A first attempt at this run was **invalid**: the stressor exited at once on its read-only root filesystem, CPU stayed at 16–20%, and the tool reported 'not detected'. The tool now verifies the injection (container running and using ≥ 100% CPU) and fails loudly otherwise (commit 9583a07; raw data kept in `incidents/raw/`).

## Root cause
Injected fault: a noisy neighbour on shared hardware. The API kept serving because every AdPulse container has CPU limits, and the API's work per request is tiny. The healer's label rules (only `role=chaos` or unlabelled containers) made it safe to act automatically on a shared host.

## 5 Whys
1. Why was the CPU saturated? A container ran 8 busy workers.
2. Why were users unaffected? CPU limits and shares kept the API responsive (max 55 ms).
3. Why 106 s to detect? 1 m rate window + 1 m `for` + 5 s evaluation.
4. Why was it safe to kill automatically? Strict label allow-list; protected roles are never candidates.
5. Why did the first run not test anything? The chaos tool trusted `docker run` and never checked the stressor actually ran.

## Resolution
- Healer: `kill_noisy_neighbor` → **success** in 14.63 s (attempt 1, vars `{"env": "host", "alertname": "HostHighCPU"}`).
- Expected heal: kill_noisy_neighbor.
- **MTTR: 137.6 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** precise, safe remediation; zero user impact.
**Went badly:** a chaos experiment silently injected nothing on the first try, a reminder to verify injections, not just commands.
**Lucky:** the real stressor had a 180 s hard limit even if healing failed.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Every chaos scenario verifies its injection (done for cpu-hog; extend to all) | detect | Jugal | partly done |
| Lower `for` on HostHighCPU to 30 s for > 95% busy | detect | Jugal | open |

## Evidence
Window: 11:59:46–12:02:13 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.009 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 2334 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[146s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[146s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[146s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[146s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
project: adpulse
        role: cache

TASK [Pick containers to stop] *************************************************
ok: [localhost]

TASK [Fail when no eligible noisy neighbour was found (a human must look)] *****
skipping: [localhost]

TASK [Stop the noisy neighbours] ***********************************************
changed: [localhost] => (item=adpulse-chaos-stress (644.83% CPU, role=chaos))

PLAY RECAP *********************************************************************
localhost                  : ok=6    changed=1    unreachable=0    failed=0    skipped=1    rescued=0    ignored=0
```
</details>
