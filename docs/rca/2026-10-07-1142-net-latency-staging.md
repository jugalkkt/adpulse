# RCA: net-latency in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `net-latency` (network) · **Severity:** warning
- **Status:** Resolved
- **Injection:** Toxiproxy latency toxic 300ms (jitter 100) on the redis proxy (plan's version)
- **Data:** `incidents/20261007T114212Z-net-latency-staging/timeline.json`

## Summary
The plan's network-latency scenario: +300 ms (±100) on the Redis proxy for 5 minutes. **It was not detected**: `AdPulseHighLatencyP95` never fired. The API's 200 ms Redis timeout turned every cache call into a fast error, and every request fell through to PostgreSQL. Users saw at most 236 ms (no failures), but the cache was effectively 100% broken: **4,842 cache errors out of 4,863 requests**.

## Impact
- Duration (injection → recovered): **n/a**
- User probes through nginx (1/s): 304 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.236 s
- API-side traffic in the window (loadgen + probes): 4863 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 4842
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:42:17.412Z | T+0.0s | injected |
| 2026-10-07T11:47:18.621Z | T+301.2s | injection_removed |
| 2026-10-07T11:47:21.623Z | T+304.2s | alert_resolved |

## Detection
- Expected alert: `AdPulseHighLatencyP95` → **did not fire** in this run.
- Other alerts seen: none
- Was it the right alert? No alert fired, and none of the existing alerts could. Peak p95 was 0.247 s, 3 ms under the 0.25 s threshold, because the timeout capped each request at ~205 ms. `AdPulseCacheDown` does not fire either, because `redis_up` stays 1 (Redis itself was fine; only the network path was slow). This was predicted by a pre-experiment measurement (p50 205 ms, p95 210 ms), which is why a second variant was run (see the net-latency-datapath RCA).

## Root cause
Injected fault: latency on the network path to the cache. The 200 ms fail-fast Redis timeout (D014) contained it: good for users, but it hides the fault. The only signal was `adpulse_cache_requests_total{result="error"}`, and nothing alerts on it.

## 5 Whys
1. Why no alert? p95 stayed below 250 ms.
2. Why? Each cache call timed out at 200 ms and fell back to a fast DB query, so requests took ~205 ms.
3. Why did CacheDown not fire? Redis was up; the exporter connects to Redis directly, not through Toxiproxy.
4. Why does it matter? All read load silently moved to PostgreSQL; at higher traffic that becomes the next incident.
5. Why was there no cache-error alert? Monitoring watched component health (`redis_up`) and user latency, not dependency error ratios.

## Resolution
- Healer: no heal action recorded for the expected alert.
- Expected heal: diagnose_latency (human removes the fault). The fault was removed by a human step (this tool).
- **MTTR: n/a** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** fail-fast timeouts protected users completely; the experiment's outcome was predicted and measured before running it.
**Went badly:** a fully broken cache went undetected for 5 minutes.
**Lucky:** staging traffic is light; PostgreSQL absorbed 100% of reads easily.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| New alert: cache error ratio > 50% for 1 m per env (would have fired within ~1 minute here) | detect | Jugal | open |
| Have the redis exporter (or a blackbox probe) measure latency through the same path the app uses | detect | Jugal | open |

## Evidence
Window: 11:42:17–11:47:21 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.247 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 4863 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[304s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[304s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[304s])) or vector(0)` |
| cache errors | 4842 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[304s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).
