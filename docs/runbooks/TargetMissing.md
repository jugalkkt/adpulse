# Runbook: TargetMissing

**Severity:** warning

## What it means
A non-API scrape target (exporter, node, cAdvisor, Alertmanager, Prometheus, healer) has been down for 1m.

## Impact
Monitoring is blind for that component, so alerts that depend on it cannot fire.

## How to check
```bash
curl -s localhost:9090/api/v1/targets | jq '.data.activeTargets[] | select(.health!="up") | {job: .labels.job, instance: .labels.instance, lastError}'
docker ps -a --filter label=com.adpulse.project=adpulse | grep -v Up
```

## How to fix manually
- Restart the container (`docker start <name>`), or re-apply Terraform: `make infra ENV=<env>` / `make monitoring`.

## Automatic action (healer)
None.
