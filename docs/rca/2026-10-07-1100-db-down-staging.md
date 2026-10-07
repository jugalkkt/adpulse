# RCA: db-down in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `db-down` (database) · **Severity:** critical
- **Status:** Resolved
- **Injection:** docker stop postgres-<env>
- **Data:** `incidents/20261007T110006Z-db-down-staging/timeline.json`

## Summary
PostgreSQL in staging was stopped. `AdPulseDatabaseDown` went to firing 22 s later, but it **flapped** between firing and pending for the whole outage, so Alertmanager never delivered it and the healer never acted. Staging served house (fallback) ads to **94.2% of requests (9,078 of 9,637)** for ten minutes, until the chaos tool's 600 s safety limit restored the database. No requests failed (HTTP 200 throughout), but the revenue impact was total.

## Impact
- Duration (injection → recovered): **n/a**
- User probes through nginx (1/s): 603 total, **0 failed (non-200)**, **593 fallback ads**, 594 slower than 250 ms, max latency 0.760 s
- API-side traffic in the window (loadgen + probes): 9637 requests, 0 5xx (0.00%), 9078 fallback ads (94.20%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:00:11.438Z | T+0.0s | injected |
| 2026-10-07T11:00:19.183Z | T+7.7s | first_failed_probe |
| 2026-10-07T11:00:33.469Z | T+22.0s | alert_firing |
| 2026-10-07T11:01:20.615Z | T+69.2s | other alert seen: AdPulseServingFallbackAds |
| 2026-10-07T11:02:30.833Z | T+139.4s | other alert seen: AdPulseHighLatencyP95 |
| 2026-10-07T11:10:12.025Z | T+600.6s | injection_removed |
| 2026-10-07T11:10:15.030Z | T+603.6s | alert_resolved |

## Detection
- Expected alert: `AdPulseDatabaseDown` → **fired**, MTTD **22.0 s**.
- Other alerts seen: `AdPulseServingFallbackAds` (T+69.2s), `AdPulseHighLatencyP95` (T+139.4s)
- Was it the right alert? The right alert fired, but it **could not stay firing**. During the outage the postgres_exporter scrape took 3–4 s (and sometimes hit the 4 s scrape timeout), because Docker's embedded DNS spent ~5.2 s failing to resolve the stopped container's name. Each timed-out scrape left `pg_up` empty for one evaluation, which reset the alert to pending. It reached firing four times in the first 3 minutes, but never stayed for the 10 s `group_wait`. A side effect: the inhibition of `AdPulseServingFallbackAds` only works while the source alert fires, so that symptom alert fired at T+69 s. `AdPulseHighLatencyP95` fired at T+139 s, and the healer ran `diagnose_latency` (evidence: `incidents/diagnostics/20261007T110241Z-staging/`).

## Root cause
Detection depended on an exporter scrape that became slower than the scrape timeout during exactly the failure it was meant to detect. When a container stops, its name leaves Docker DNS, and Docker forwards the lookup upstream, where a negative answer took ~5.2 s on this network (measured). The exporter's `connect_timeout` did not bound the DNS phase. Nothing in the alert rule tolerated a missing sample.

## 5 Whys
1. Why were users served house ads for 10 minutes? The database was down and nothing restarted it.
2. Why did the healer not restart it? Alertmanager never sent `AdPulseDatabaseDown`: the alert never stayed firing for the 10 s `group_wait`.
3. Why did it not stay firing? Every few evaluations the `pg_up` sample was missing, which resets an alert to pending.
4. Why was the sample missing? The exporter scrape took 3–4 s and sometimes exceeded Prometheus' 4 s scrape timeout.
5. Why was the scrape that slow? Resolving the stopped container's name took ~5.2 s: Docker's embedded DNS forwarded it to the upstream resolver, which answers negatives slowly on this network.

## Resolution
- Healer: no heal action recorded for the expected alert.
- Expected heal: restart_db.
- **MTTR: n/a** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** no request failed; the API degraded to fallback ads within its 0.5 s DB timeout instead of hanging; the healer still collected latency diagnostics; the chaos tool's hard limit ended the outage.
**Went badly:** self-healing failed silently. Detection 'worked' (it fired at 22 s), yet nothing was paged, because a flapping alert looks fine at a glance. The cache hid the outage for only about one TTL (60 s).
**Lucky:** this was staging, and the same chaos run had a 10-minute safety limit.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| `keep_firing_for: 30s` on DatabaseDown, CacheDown and ApiReplicaDown, plus a promtool test with scrape gaps | prevent | Jugal | **done** (commit d93d3dd) |
| Exporters and Toxiproxy use a dead upstream DNS (`dns = 127.0.0.1`), so the name of a stopped container fails instantly; measured scrape with the DB down: 1.2–2.0 s (was 3.7–9.0 s) | prevent | Jugal | **done** (commit e361a59) |
| Lower exporter connect timeouts to 1 s | mitigate | Jugal | **done** |
| Serve stale cache entries when the DB is down (stale-if-error) instead of house ads after the 60 s TTL | mitigate | Jugal | open |
| Re-run db-down after the fixes and record it | detect | Jugal | done: see the next db-down RCA |

## Evidence
Window: 11:00:11–11:10:15 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.975 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 9637 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[603s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[603s])) or vector(0)` |
| fallback ads | 9078 | `sum(increase(adpulse_fallback_total{env="staging"}[603s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[603s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).
