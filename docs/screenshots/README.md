# Screenshots

Saved in this folder as JPG with exactly these names (the README links them).

| File | What to capture | Where |
|---|---|---|
| `01-github-actions-cd.jpg` | The CD (staging) run graph: deploy-staging → smoke-staging, green | GitHub → Actions → CD (staging) → latest run |
| `02-github-actions-rollback.jpg` | The failed CD run for the broken release (smoke-staging red, "rolled back" annotation) | Actions → CD (staging) → run for `0e7473d` |
| `03-github-actions-promote.jpg` | A green "Promote to prod" run | Actions → Promote to prod |
| `04-grafana-overview.jpg` | AdPulse Overview during load (staging or prod) | http://127.0.0.1:3000 → AdPulse → Overview |
| `05-grafana-heal-annotation.jpg` | A panel with a healer annotation marker hovered (tooltip visible) | Overview or Incidents dashboard, time range covering a chaos run |
| `06-grafana-slo.jpg` | AdPulse SRE / SLO dashboard | Grafana |
| `07-alertmanager-firing.jpg` | Alertmanager UI with an alert firing (e.g. during a chaos run) | http://127.0.0.1:9093 |
| `08-aws-ec2-instance.jpg` | EC2 console showing the instance and its tags (Phase 12) | AWS console → EC2 → Instances |
