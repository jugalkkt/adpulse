# Runbook: AdPulseCacheDown

**Severity:** critical

## What it means
`redis_up == 0` for 15s.

## Impact
Every request goes to Postgres (higher latency and DB load). Still served while the DB is healthy.

## How to check
```bash
docker ps -a --filter name=redis-<env>
docker logs --tail 50 redis-<env>
```

## How to fix manually
- `docker start redis-<env>`. The cache refills itself (TTL 60s, refilled on miss).

## Automatic action (healer)
`restart_cache`.
