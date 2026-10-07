# AdPulse security

Every control lists **where** it is implemented and **how it was verified** (dates are 2026-10-07 unless noted). Accepted risks are listed at the end, with the reason each is acceptable for this lab.

## 1. Secrets

| Control | Where | Verified |
|---|---|---|
| Secrets live only in `.env` (mode 600, gitignored); `.env.example` holds names only | `scripts/gen_secrets.sh`, `.gitignore` | `stat -c %a .env` → 600; `git ls-files \| grep -c '^.env$'` → 0; `git check-ignore .env` → ignored |
| Secrets reach Terraform as `TF_VAR_*` env vars, never on the command line or in tfvars | `scripts/terraform.sh` | code review; `sensitive = true` on every secret variable |
| Ansible reads secrets from `.env` with `no_log: true` | `ansible/playbooks/tasks/load_secrets.yml`, `replica.yml`, `scale_api.yml` | ansible-lint (production profile) clean; deploy logs show no values |
| Redis password is not on the command line (written to a tmpfs config at start-up) | `adpulse_stack/containers.tf` (redis) | `redis-cli ping` without auth → `NOAUTH Authentication required` |
| The healer holds no DB/Redis passwords (restarts and clones existing containers) | `ansible/playbooks/heal/*` (D045) | code review; healer env contains only `GRAFANA_SA_TOKEN` |
| Grafana service-account token created by script, written to `.env`, never printed | `scripts/grafana_token.sh` | token works (heal annotations visible); not in any log or commit |
| Terraform state (contains secrets) stays local and gitignored | `.gitignore` (`*.tfstate*`, `.terraform/`) | `git ls-files \| grep -cE 'tfstate\|/\.terraform/'` → 0 |
| No secrets in git history | gitleaks (pre-commit on every commit; CI on full history) | `make scan` → `scripts/scan.sh secrets`: no leaks (see §7) |
| No secrets in images | Trivy secret scanner; `.dockerignore` allow-list keeps `.env`/state out of build contexts (D011) | `make scan` (§7) |
| Public signing-key fingerprints allow-listed for gitleaks (they are not secrets) | `scripts/bootstrap.sh` (`# gitleaks:allow`) | gitleaks clean |
| AWS keys only in `~/.aws`, typed by Jugal, deleted after Phase 12 | Phase 12 | _Phase 12_ |

**Incident (2026-10-07, Phase 5):** a `bash -x` debug run of `scripts/terraform.sh` printed `GRAFANA_ADMIN_PASSWORD` in Claude's tool output. The value was rotated in `.env` within minutes, **before any Grafana container existed**, so the leaked value was never used. Rule adopted: never trace (`bash -x`) scripts that read secrets.

## 2. Containers

Audit of all 27 running AdPulse containers (`docker inspect`, 2026-10-07):

| Control | Where | Verified |
|---|---|---|
| Non-root users | api/loadgen `adpulse` (10001), postgres/backup 999, redis 999, nginx 101, grafana 472, exporters/prometheus/alertmanager/node-exporter/toxiproxy `nobody`/59000, healer = host uid + group 10001 | audit: 25 of 27 non-root; the two root exceptions are in §8 |
| `no-new-privileges` | every container (Terraform, Ansible) | audit: 27/27 |
| `cap_drop ALL`, **no** `cap_add` | every container | audit: 27/27 drop ALL, 0 add (none needs a capability: no privileged ports, no root entrypoints, D027) |
| Read-only root filesystem + tmpfs | every container except Toxiproxy (D025) | audit: 26/27 `ReadonlyRootfs=true` |
| Memory and CPU limits; `memory_swap = memory` | Section 5.4 values in Terraform and Ansible | audit: all limited; total 5,056 MB (cap 6 GB) |
| Healthchecks | every service (loadgen has none by design) | audit: 25/27 with a check, plus loadgen with an explicit `NONE` |
| Images pinned by digest | 11 registry images in Terraform; `FROM ubuntu:24.04@sha256…`, `postgres:18.6-trixie@sha256…` | grep of `*.tf` and Dockerfiles: all pinned |
| Puppet-hardened base (no setuid/setgid, umask 027, no world-writable files, nologin user) | `config/puppet`, `docker/base` | `hardening-report.txt`; `find / -perm /6000` → 0 in the image |
| Config-management agents never ship (OpenVox, Cinc purged after use) | `docker/base`, `docker/postgres` | image checks: no `/opt/puppetlabs`, `/opt/cinc` |
| Unused privileged helper removed (`gosu`) | `docker/postgres/Dockerfile` (D059) | Trivy: CRITICAL CVE-2025-68121 and 21 HIGH gone |
| pip removed from runtime images; dependencies hash-locked | `docker/api`, `docker/healer` (D013) | `pip install --require-hashes`; no pip in the runtime venv |

## 3. Network

| Control | Where | Verified |
|---|---|---|
| Only nginx and the monitoring UIs are published, bound to 127.0.0.1 | Terraform `ports { ip = "127.0.0.1" }` | published ports: 127.0.0.1:{3000, 8080, 8081, 9090, 9093} only |
| DB and Redis never published | Terraform (no `ports`) | not in the published list |
| One Docker network per environment; monitoring separate; healer↔proxy network is `internal` | `adpulse_stack`, `monitoring_stack`, `healer.tf` | `pg_isready -h postgres-staging` from `adpulse-monitoring` → no response |
| PostgreSQL: scram-sha-256 only, from the env subnets only; no `trust` | Chef `pg_hba.conf.erb` (D018, D020) | `make test-postgres`: wrong password rejected, foreign subnet rejected ("no pg_hba.conf entry"), no trust lines |
| Redis `requirepass` | Terraform redis config | `NOAUTH` without the password |
| nginx exposes only the product API (`/metrics`, `/admin/*` → 404) | `config/nginx/nginx.conf.tftpl` (D028) | curl: 404 for both |
| Chaos endpoints only in staging, behind a token (constant-time compare); 404 elsewhere | app (`CHAOS_ENABLED`), Ansible env | unit tests (404 when disabled, 403 bad token) |

## 4. Configuration management hardening

- **Puppet (OpenVox) `adpulse::base`** (base image): see `/etc/adpulse/hardening-report.txt`. Idempotency proven: the second apply changed 0 resources.
- **Chef (Cinc) `adpulse_db`** (DB node): scram-sha-256, CIDR-restricted pg_hba, statement timeout, roles with least privilege (app owns its DB, exporter has `pg_monitor`). Idempotency proven: second converge updated 0/10 resources.
- **AWS host (`adpulse::host`)**: _Phase 12_.

## 5. Supply chain

| Control | Where | Verified |
|---|---|---|
| Trivy image scan: **fail on CRITICAL with a fix**, report HIGH | `scripts/scan.sh images`, CI `security` job | §7 |
| Trivy config scan (Dockerfiles, Terraform) | `scripts/scan.sh config` | §7 |
| hadolint on every Dockerfile | `make lint-docker`, CI | 0 warnings/errors |
| Pinned Python dependencies with hashes | `app/requirements*.txt`, `healer/requirements*.txt` | `--require-hashes` installs |
| Pinned tool versions and GitHub Actions by commit SHA | `docs/VERSIONS.md`, workflows | actionlint clean |
| Verified downloads: apt keys by fingerprint, AWS CLI by signature, runner and Cinc by sha256 | `scripts/bootstrap.sh`, Dockerfiles (D005, D019) | build/bootstrap logs |
| SBOM (CycloneDX) per image | `make sbom` (`sbom/*.cdx.json`, gitignored); CI artifact | §7 |

## 6. Healer and automation

| Control | Where | Verified |
|---|---|---|
| Least-privilege Docker access via docker-socket-proxy (containers, images, networks, exec, info, POST only) | `healer.tf` (D043) | `docker volume ls` from the healer → **403** |
| Playbook allow-list: only playbooks named in `healing.yml`, name regex, file must exist | `healer/healer/engine.py` | unit test `test_rules_reject_unknown_or_malicious_playbooks` |
| Guardrails: cooldown, max attempts per window, escalation, per-env lock, dry-run | engine | 14 unit tests; live tests (Phase 8/9) |
| Noisy-neighbour killer only touches `role=chaos` or unlabelled containers; protected roles never | `heal/kill_noisy_neighbor.yml` | `make test-heal`: only the test hog stopped; cpu-hog RCA: only the stressor stopped |
| Deploys silence API alerts so the healer cannot fight a rollout | `deploy.yml` | silence created and expired per deploy |

## 7. Scan results

_Filled in from `make scan` and `make sbom` below._

## 8. CI/CD

| Control | Where | Verified |
|---|---|---|
| Deploy jobs never run for pull requests or forks | `cd.yml` `if:` (event == push, head repo == this repo); `promote.yml` dispatch-only | PR #1: CI ran, **no CD run** |
| Repo private while the self-hosted runner is registered; removal documented | README | `gh api repos/... --jq .private` → true |
| Least `permissions:` (`contents: read`) in every workflow | `.github/workflows/*` | actionlint |
| Prod gate: only the release staging runs, only if staging smoke passes now | `promote.yml` (D056) | dispatching `e7337dc` was refused |
| Automatic rollback on failed smoke test (staging and prod); readiness gate per replica | `cd.yml`, `promote.yml`, `tasks/replica.yml` (D060) | deploy-bad-release RCA; broken-image test |

## 9. AWS

_Phase 12: root MFA, IAM user (not root), SSH key only, no password auth, SG restricted to Jugal's IP /32, IMDSv2 required, EBS encrypted, ufw, unattended-upgrades, default tags, zero-spend budget, same-day teardown, access key deleted._

## 10. Accepted risks

| Risk | Why accepted (lab) | What production would do |
|---|---|---|
| Terraform state is local (contains secrets) | single operator; state gitignored and on an encrypted laptop disk | remote state (S3 + encryption + lockfile) |
| docker-socket-proxy allows `CONTAINERS + POST` (a compromised healer could create a container with host mounts) | needed to restart and scale; far smaller than raw-socket access; internal network only | stricter proxy that filters request bodies, or an orchestrator API with RBAC |
| Socket proxy and cAdvisor run as root | the proxy must read the root-owned socket; cAdvisor reads host cgroups. Both have no capabilities and a read-only rootfs | rootless Docker; node-level agents managed by the platform |
| Toxiproxy has a writable root filesystem | no-shell image, config only via upload (D025); runs as nobody, no capabilities | bake config into a derived image |
| node-exporter uses `pid: host` and reads `/` read-only | needed for host metrics | same (standard pattern) |
| Healer runs as the host uid (to write `incidents/`) | read-only rootfs, no capabilities, proxy-only Docker access | write evidence to a log pipeline, not a bind mount |
| Secrets visible in `docker inspect` (container env) | `docker inspect` already requires root-equivalent access | Docker/K8s secrets or a vault |
| Self-hosted runner on the laptop executes workflow code with Docker access | repo private; deploys only from `main` pushes and manual dispatch; runner removable (README) | ephemeral runners in an isolated network |
| Chaos endpoints compiled into the app (disabled outside staging) | token-protected, constant-time compare, 404 when disabled | separate chaos tooling (service-mesh fault injection) |
| CI Redis service has no password | ephemeral CI container on GitHub's runner | — |
| 5 s scrape/evaluation intervals | faster MTTD for demos (D035) | 15–30 s |
| Lab-only defaults: HTTP (no TLS) on 127.0.0.1 | local only; AWS exposes port 80 to one /32 | TLS everywhere, WAF |
