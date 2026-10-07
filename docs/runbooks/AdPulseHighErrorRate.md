# Runbook: AdPulseHighErrorRate

**Severity:** critical

## What it means
More than 5% of `/v1/ad` requests returned 5xx over 1m, for 1m.

## Impact
Users get errors instead of ads, which is lost revenue. It burns the availability SLO fast.

## How to check
```bash
Grafana → AdPulse Overview → Errors panel (which replica? since when?)
docker logs --since 5m api-<env>-1 | jq -c 'select(.status >= 500)' | tail
Was there a deploy? `cat deploy/state/<env>.json`
Staging only: `docker exec api-staging-1 curl -s -H "X-Chaos-Token: $CHAOS_TOKEN" localhost:8000/admin/chaos`
```

## How to fix manually
- Started right after a deploy: `make rollback ENV=<env>`.
- Chaos left on (staging): `chaos.py stop --env staging`, or restart the replicas.
- Otherwise: restart replicas one at a time (`make deploy` with the current tag after removing one), and look for a DB or cache cause.

## Automatic action (healer)
`restart_api` (rolling, clears in-memory faults). If it fires again within 10 min, the healer escalates (`HealerEscalated`). Inhibited while `AdPulseDatabaseDown` fires for the same env.
