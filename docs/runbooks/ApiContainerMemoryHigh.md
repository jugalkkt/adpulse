# Runbook: ApiContainerMemoryHigh

**Severity:** warning

## What it means
An API container's working-set memory exceeds 90% of its 256 MB limit for 30s.

## Impact
It will soon be OOM-killed (Docker restarts it, but in-flight requests fail).

## How to check
```bash
docker stats --no-stream api-<env>-<N>
Grafana → Infrastructure → container memory vs limit
Staging chaos `memory_leak` active?
```

## How to fix manually
- Restart the replica (rolling, so the others keep serving).

## Automatic action (healer)
`restart_api` on that replica.
