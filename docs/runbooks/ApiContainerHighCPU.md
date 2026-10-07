# Runbook: ApiContainerHighCPU

**Severity:** warning

## What it means
An API container uses more than 90% of its CPU limit (0.5 CPU) for 1m.

## Impact
That replica's latency rises and it may start failing health checks.

## How to check
```bash
docker stats --no-stream api-<env>-<N>
Grafana → Infrastructure → container CPU vs limit
Staging chaos `cpu_burn` active?
```

## How to fix manually
- Add capacity: start another replica, or reduce load. Restart the replica if it is stuck in a hot loop.

## Automatic action (healer)
`scale_api` adds a replica (max 4). Scale-down to 2 on resolve (SHOULD).
