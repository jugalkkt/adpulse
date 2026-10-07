# AdPulse

A small ad-serving API wrapped in reliability machinery: Terraform, Puppet (OpenVox), Chef (Cinc), Ansible, Prometheus/Grafana/Alertmanager, a self-healing service, chaos experiments with RCAs, and a staging→prod CI/CD pipeline.

> Work in progress. See `PROGRESS.md` for status. The full README is written in the final phase.

```
make help
```

## CI/CD

- **CI** (`.github/workflows/ci.yml`, GitHub-hosted runners, every push and PR): lint, tests (Postgres/Redis service containers), image builds, security scans (Trivy, gitleaks).
- **CD** (`.github/workflows/cd.yml`, the laptop's self-hosted runner): after CI succeeds on a **push to `main`**, build, roll out to **staging**, run the smoke test, and roll back automatically if it fails.
- **Promote** (`.github/workflows/promote.yml`): the manual approval gate. *Actions → Promote to prod → Run workflow* deploys the release staging currently runs, then smoke-tests prod and rolls back automatically if that fails.

### Self-hosted runner: security notice
A self-hosted runner executes workflow code on this laptop, with access to Docker (root-equivalent) and the `.env` secrets.
- The repository **must stay private** while the runner is registered.
- Deploy jobs never run for pull requests: CD only runs for a successful CI run of a push to `main` in this repository, and promote only on manual dispatch.
- **Before making the repo public, remove the runner:**
  ```bash
  cd ~/actions-runner
  ./config.sh remove --token "$(gh api -X POST repos/jugalkkt/adpulse/actions/runners/remove-token --jq .token)"
  ```
