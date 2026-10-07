# Runbook: BackupQuotaWillFillSoon

**Severity:** warning

## What it means
`predict_linear(adpulse_backup_dir_bytes[10m], 3600)` exceeds the quota: at the current growth rate, the backup directory fills its quota within 1h. This is a **trend-based, proactive** alert that fires *before* anything breaks.

## Impact
None yet. If ignored, backups would fail once the quota (200 MB) is hit.

## How to check
```bash
docker exec backup-agent-<env> ls -la /backups
docker exec backup-agent-<env> du -sh /backups
Grafana → Database & Cache → backup forecast panel
```

## How to fix manually
- Remove junk or unexpected files, then enforce retention (keep the newest 6 `<env>-*.dump`).

## Automatic action (healer)
`cleanup_backups` enforces retention and quota (deletes non-backup files and the oldest dumps).
