# Runbook: ErrorBudgetBurn

**Severity:** critical (Fast) / warning (Slow)

## What it means
Multi-window burn rate. Fast: 1h **and** 5m windows above 14.4× the budget. Slow: 6h **and** 30m windows above 6×. Label `slo` = `availability` (budget 0.5% 5xx) or `latency` (budget 5% slower than 150 ms).

## Impact
At 14.4×, a 30-day error budget is gone in about 2 days; at 6×, in about 5 days.

## How to check
```bash
Grafana → SRE / SLO dashboard (burn rate, budget remaining)
Correlate with AdPulseHighErrorRate, AdPulseHighLatencyP95 and recent deploys
```

## How to fix manually
- Treat the underlying cause. Consider freezing deploys until the burn stops.

## Automatic action (healer)
None (page).
