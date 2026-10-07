# RCA: disk-quota in staging   (Blameless)
- **Date:** 2026-10-07 · **Env:** staging · **Scenario:** `disk-quota` (trend / capacity) · **Severity:** warning
- **Status:** Resolved
- **Injection:** write 20 MB junk files every 15s into backups-<env> (stops once the healer has acted)
- **Data:** `incidents/20261007T113610Z-disk-quota-staging/timeline.json`

## Summary
Junk files (20 MB every 15 s) were written into the staging backup directory. The trend alert `BackupQuotaWillFillSoon` fired at 137.3 s, the healer's `cleanup_backups` removed the junk in 2.8 s, and the directory went back to 12 MB. The remediation was done at T+150 s. The tool's MTTR (353 s) is dominated by the 10-minute forecast window slowly 'forgetting' the spike. No user impact.

## Impact
- Duration (injection → recovered): **353.0s**
- User probes through nginx (1/s): 356 total, **0 failed (non-200)**, **0 fallback ads**, 0 slower than 250 ms, max latency 0.048 s
- API-side traffic in the window (loadgen + probes): 5698 requests, 0 5xx (0.00%), 0 fallback ads (0.00%), cache errors 0
- Note: requests nginx failed itself (e.g. 502 while no replica answered) are not counted API-side; the probes see them.

## Timeline (UTC)
| Time | Offset | Event |
|---|---|---|
| 2026-10-07T11:36:16.056Z | T+0.0s | injected |
| 2026-10-07T11:38:33.360Z | T+137.3s | alert_firing |
| 2026-10-07T11:38:43.238Z | T+147.2s | heal_started |
| 2026-10-07T11:38:46.008Z | T+150.0s | heal_finished |
| 2026-10-07T11:38:46.750Z | T+150.7s | injection_stopped |
| 2026-10-07T11:42:09.049Z | T+353.0s | recovered |
| 2026-10-07T11:42:09.154Z | T+353.1s | injection_removed |
| 2026-10-07T11:42:12.156Z | T+356.1s | alert_resolved |

## Detection
- Expected alert: `BackupQuotaWillFillSoon` → **fired**, MTTD **137.3 s**.
- Other alerts seen: none
- Was it the right alert? Yes, and it was proactive, **but only just**. Measured: the 1 h forecast (`predict_linear(...[10m], 3600)`) crossed the 209.7 MB quota at T+75 s, when the directory held only 112 MB (53% of quota). The rule's `for: 1m` then consumed most of that lead: at firing (T+137 s) the directory held 192 MB, and the 15 s sample around the heal shows 212 MB, so the quota was exceeded by ~2 MB for a few seconds before cleanup.

## Root cause
Injected fault: unexpected files filling the backup volume (in real life: a stuck job, an un-rotated dump, or a dev copying data). Retention only manages real `<env>-*.dump` files, so junk grows unchecked until cleanup removes non-backup files and enforces the quota.

## 5 Whys
1. Why did the directory grow? Files that are not backups were being written into it.
2. Why did retention not stop it? Retention only deletes old real dumps.
3. Why did the alert fire so close to the quota? The forecast crossed at T+75 s, but `for: 1m` delayed firing by 60 s, and the growth was fast (1.33 MB/s).
4. Why did the alert clear only at T+353 s? `predict_linear` over 10 m still saw the steep climb in its window after the cleanup, so the forecast stayed above the quota for minutes.
5. Why does that matter? The 'recovered' time overstates the outage; the real repair took 2.8 s at T+150 s.

## Resolution
- Healer: `cleanup_backups` → **success** in 2.77 s (attempt 1, vars `{"env": "staging", "alertname": "BackupQuotaWillFillSoon"}`).
- Expected heal: cleanup_backups.
- **MTTR: 353.0 s** (injection → system healthy and 3 consecutive good probes).

## What went well / What went badly / Where we got lucky
**Went well:** the trend crossed the quota at T+75 s (directory at 112 MB), about a minute before a plain 90%-of-quota threshold would have (189 MB was reached between the T+120 s and T+135 s samples); cleanup was surgical (only junk removed, real dumps kept).
**Went badly:** `for: 1m` wasted most of the forecast's lead time; MTTR as measured is misleading for trend alerts.
**Lucky:** the injection stopped at the first heal, while a real runaway writer would keep refilling the disk.

## Action items
| Action | Type | Owner | Status |
|---|---|---|---|
| Shorten `for` on BackupQuotaWillFillSoon to 15 s (the forecast already smooths noise) | detect | Jugal | open |
| Report trend-alert recovery as 'remediated at' (heal finished) alongside alert-clear time | detect | Jugal | open |
| Alert on the writer: unknown files in the backup dir (`adpulse_backup_files` > retention + 1) | detect | Jugal | open |

## Evidence
Window: 11:36:16–11:42:12 UTC (injection → alert resolved).

| Value | Result | PromQL |
|---|---|---|
| peak 5xx ratio (1m) | 0.000 | `max over window of env:adpulse_http_5xx:ratio_rate1m{env="staging"}` |
| peak p95 latency (1m) | 0.005 s | `max over window of env:adpulse_http_request_duration_seconds:p95_1m{env="staging"}` |
| requests | 5698 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad"}[356s])) or vector(0)` |
| 5xx requests | 0 | `sum(increase(adpulse_http_requests_total{env="staging", route="/v1/ad", status=~"5.."}[356s])) or vector(0)` |
| fallback ads | 0 | `sum(increase(adpulse_fallback_total{env="staging"}[356s])) or vector(0)` |
| cache errors | 0 | `sum(increase(adpulse_cache_requests_total{env="staging", result="error"}[356s])) or vector(0)` |

Grafana: *AdPulse Overview* (Error rate, Latency p95 and p99, Ads served by source, Replica scrape status), *AdPulse Incidents* (Alert timeline, heal annotations), plus the panel matching the layer (*Infrastructure* or *Database & Cache*).

<details><summary>Healer playbook output (tail)</summary>

```
Heal | clean up backups] *************************************************

TASK [Enforce retention and quota inside backup-agent-staging] *****************
changed: [localhost]

TASK [Result] ******************************************************************
ok: [localhost] =>
    msg: '{"junk_removed":10,"retention_removed":0,"quota_removed":0,"bytes_before":212420899,"bytes_after":12420899}'

PLAY RECAP *********************************************************************
localhost                  : ok=2    changed=1    unreachable=0    failed=0    skipped=0    rescued=0    ignored=0
```
</details>
