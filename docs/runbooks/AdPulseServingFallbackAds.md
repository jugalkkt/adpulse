# Runbook: AdPulseServingFallbackAds

**Severity:** warning

## What it means
Fallback (house) ads served at any rate > 0 for 1m.

## Impact
Users still get *an* ad (HTTP 200), but a non-paying house ad. Graceful degradation is working, but revenue is lost.

## How to check
```bash
Both cache and DB failing? `make status`, then check `pg_up` and `redis_up` in Grafana → Database & Cache
docker exec toxiproxy-<env> /toxiproxy-cli list
```

## How to fix manually
- Fix the underlying DB/cache problem (see AdPulseDatabaseDown / AdPulseCacheDown).

## Automatic action (healer)
None (symptom alert). Inhibited while `AdPulseDatabaseDown` fires for the same env.
