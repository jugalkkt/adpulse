# Runbook: AdPulseApiReplicaDown

**Severity:** critical

## What it means
`up{job="api"} == 0` for 15s (`reason=unreachable`: replica hung or crashing), or fewer healthy replicas than expected (`reason=missing`: a replica was stopped or removed).

## Impact
Capacity in that env is reduced. With 1 of 2 replicas left, users are still served (nginx retries on the healthy replica), but there is no headroom.

## How to check
```bash
make status  # which replica is missing or unhealthy
docker ps -a --filter label=com.adpulse.role=api --filter label=com.adpulse.env=<env>
docker logs --tail 50 api-<env>-<N>
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.labels.job=="api") | {instance: .labels.instance, health, lastError}'
```

## How to fix manually
- Hung or unhealthy: `docker restart api-<env>-<N>`, then wait for `healthy`.
- Stopped: `docker start api-<env>-<N>`.
- Missing entirely: `make deploy ENV=<env> TAG=$(jq -r .current deploy/state/<env>.json)` recreates it.

## Automatic action (healer)
`restart_api` restarts the named replica (or brings every replica of the env back), then waits for Docker health.
