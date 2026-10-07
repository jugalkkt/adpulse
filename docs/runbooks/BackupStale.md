# Runbook: BackupStale

**Severity:** warning

## What it means
No successful backup for more than 3 × the 300s interval.

## Impact
Recovery point objective at risk: a restore would lose more data than intended.

## How to check
```bash
docker logs --tail 20 backup-agent-<env>  # look for backup_failed
docker ps --filter name=backup-agent-<env>
Is Postgres up? (`pg_up`)
```

## How to fix manually
- Fix DB connectivity; `docker restart backup-agent-<env>`; run one backup by hand: `docker exec backup-agent-<env> adpulse-backup.sh`.

## Automatic action (healer)
None (escalate to a human).
