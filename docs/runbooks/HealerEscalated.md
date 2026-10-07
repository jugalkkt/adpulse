# Runbook: HealerEscalated

**Severity:** critical

## What it means
The healer gave up: a playbook failed, or the alert used up its attempts (3 per 15 min).

## Impact
Automatic remediation is not working; the original problem is probably still there.

## How to check
```bash
tail -n 20 incidents/heal-log.jsonl | jq .
docker logs --tail 50 healer
Which alert? The `alert` and `env` labels on this alert.
```

## How to fix manually
- Work the original alert's runbook by hand. Fix the healer playbook if it is broken.

## Automatic action (healer)
None (this *is* the page to a human).
