# RCA: deploy-bad-release in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `deploy-bad-release` (process / CI) · **Severity:** warning
- **Status:** Resolved
- **Injection:** Merged a release with BROKEN_RELEASE=true baked into the API image (/readyz returns 503); CD deployed it to staging
- **Data:** `incidents/20261007T125318Z-deploy-bad-release-staging/timeline.json`

## Summary
A release with a deliberate defect (`BROKEN_RELEASE=true` baked into the image, so `/readyz` returns 503) was merged to `main` (PR #1). CI passed, and CD rolled it out to staging. The CD smoke test then failed on `/readyz`, and the pipeline rolled staging back to the previous release automatically (46 s). Staging was healthy again 150.7 s after the rollout began. **Prod was never touched** (promotion needs the manual gate). No ad request failed.

## Impact
- Duration (injection → recovered): **150.7s**
- User probes through nginx (1/s): 138 total, **0 failed (non-200)**, **0 fallback ads**, 4 slower than 250 ms, max latency 0.503 s
- API-side traffic in the window (loadgen + probes): 2383 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T12:46:47.000Z | T+-391.0s | merged_to_main |
| 2026-10-07T12:50:24.000Z | T+-174.0s | ci_passed |
| 2026-10-07T12:53:18.000Z | T+0.0s | injected |
| 2026-10-07T12:53:46.785Z | T+28.8s | first_failed_probe |
| 2026-10-07T12:54:15.000Z | T+57.0s | deploy_finished |
| 2026-10-07T12:55:01.688Z | T+103.7s | alert_firing |
| 2026-10-07T12:55:02.000Z | T+104.0s | heal_started |
| 2026-10-07T12:55:16.615Z | T+118.6s | last_failed_probe |
| 2026-10-07T12:55:48.224Z | T+150.2s | heal_finished |
| 2026-10-07T12:55:48.726Z | T+150.7s | recovered |

## Detection
- Expected alert: `staging smoke test (CD)` → **fired**, MTTD **103.7 s**.
- Other alerts seen: none
- Was it the right alert? Yes. The detector was the post-deploy smoke test, the intended safety net for release defects; Prometheus alerting played no part (no alert fired, correctly, because ads were served normally). MTTD 103.7 s breaks down as: the rolling deploy (57 s) finished before any check ran, the smoke job then started 16 s later, and the smoke test retries `/readyz` for up to 30 s before declaring failure.

## Root cause
A release that was alive (`/healthz` 200) but not ready (`/readyz` 503) passed every pre-deploy gate. Unit tests deliberately run with controlled settings, so a bad environment flag cannot show up there, like many real config defects. The rolling deploy gated each replica only on Docker health (liveness), so it replaced **both** replicas before anything checked readiness.

## 5 Whys
1. Why did a broken release reach staging? CI only proves the code works under test settings; the defect was in the image's runtime configuration.
2. Why did the deploy not stop it? The rolling update waited for Docker health (`/healthz`), which the broken release passed.
3. Why were users unaffected? The defect only affected readiness, and nginx does not use `/readyz` for routing, so `/v1/ad` kept working (0 failures). The 4 slow probes (≤0.50 s) came from the replica swaps, not the defect.
4. Why did detection take 104 s? Detection only started after the whole rollout completed (smoke test in the next job).
5. Why did prod stay safe? Prod deploys only through the manual promote gate, which also refuses any tag staging isn't running (verified: promoting `e7337dc` was refused).

## Resolution
- Healer: `make rollback ENV=staging (CD smoke-staging job)` → **success** in 46.2 s (attempt 1, vars `{"env": "staging", "rolled_back_from": "0e7473d", "to": "b4a13d3"}`).
- Expected heal: automatic rollback (make rollback ENV=staging).
- **MTTR: 150.7 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** fully automatic detection and rollback, with a post-rollback smoke PASS; prod untouched; PR builds never deploy (verified: no CD run for the branch).
**Went badly:** both staging replicas ran the bad release before anyone checked readiness; a readiness defect that also broke serving would have been a full staging outage for ~2 minutes.
**Lucky:** the defect was only a readiness flag, so traffic kept flowing.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Readiness gate per replica in the rolling deploy: `/readyz` must be 200 before the old replica is removed; otherwise fail, triggering Ansible's automatic rollback | prevent | Jugal | **done** (commit 020dffb). Verified with a broken image: deploy failed at replica 1's gate after 55 s, and both staging replicas kept the good release |
| Run the smoke test inside the deploy job (no inter-job queue delay) | detect | Jugal | open |
| Have nginx stop routing to not-ready replicas (active health checks need nginx Plus, or a sidecar) | mitigate | Jugal | open |

## Evidence
Window: 12:53:18–12:55:48 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.005 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 2383 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[150s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[150s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[150s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[150s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
PLAY RECAP: localhost ok=35 changed=7 failed=0; post-rollback smoke: /readyz 200, 20/20 /v1/ad valid, p95 4 ms, /metrics OK
```
</details>
