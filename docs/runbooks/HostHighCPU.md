# Runbook: HostHighCPU

**Severity:** warning

## What it means
Host CPU busy above 85% (all cores) for 1m.

## Impact
Everything slows down: latency rises, health checks may time out.

## How to check
```bash
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}' | sort -k2 -rn | head
top -o %CPU
```

## How to fix manually
- Stop the noisy process or container. Never stop the db, api, cache, monitoring or healer containers to free CPU.

## Automatic action (healer)
`kill_noisy_neighbor` stops the top CPU containers that are labelled `com.adpulse.role=chaos` **or** carry no `com.adpulse.project` label. Protected roles are never touched.
