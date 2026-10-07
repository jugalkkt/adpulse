# Runbook: AdPulseDatabaseDown

**Severity:** critical

## What it means
`pg_up == 0` (postgres_exporter cannot connect) for 15s.

## Impact
Cache misses fall back to house ads. Impressions are dropped. Backups fail.

## How to check
```bash
docker ps -a --filter name=postgres-<env>
docker logs --tail 50 postgres-<env>
docker exec postgres-<env> pg_isready -U postgres
```

## How to fix manually
- `docker start postgres-<env>` (or `docker restart`), wait for `pg_isready`, then `curl localhost:<port>/readyz`.
- If it won't start: check the logs for disk full or a corrupt WAL, and restore from `backups-<env>` (`pg_restore`).

## Automatic action (healer)
`restart_db`: start or restart `postgres-<env>`, wait for `pg_isready`, then check API `/readyz`.
