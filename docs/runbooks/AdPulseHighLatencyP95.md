# Runbook: AdPulseHighLatencyP95

**Severity:** warning

## What it means
p95 latency of `/v1/ad` above 250 ms for 2 min.

## Impact
Slow ads hurt page load and auction win rate. It burns the latency SLO (95% < 150 ms).

## How to check
```bash
Grafana → AdPulse Overview → Duration; Database & Cache dashboard
Toxiproxy faults: `docker exec toxiproxy-<env> /toxiproxy-cli list` (look for toxics)
DB: `docker exec -u postgres postgres-<env> psql -c 'select state, wait_event, query from pg_stat_activity'`
Host: `docker stats --no-stream`
Healer evidence: `incidents/diagnostics/<ts>/`
```

## How to fix manually
- Network fault injected: `chaos.py stop --env <env>` (removes toxics).
- Slow queries: check `pg_stat_activity` and the slow-query log (`log_min_duration_statement=200ms`).
- CPU starvation: see HostHighCPU / ApiContainerHighCPU.

## Automatic action (healer)
`diagnose_latency` only: it snapshots evidence, but **no automatic fix**, because network or DB latency needs a human decision.
