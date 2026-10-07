# AdPulse progress log

## Current status
- **Phase 0: DONE** (2026-10-07). DoD passed.
- **Phase 1: DONE** (2026-10-07). DoD passed. Repo: https://github.com/jugalkkt/adpulse (private).
- **Phase 2: DONE** (2026-10-07). DoD passed.
- **Phase 3: DONE** (2026-10-07). DoD passed.
- **Phase 4: DONE** (2026-10-07). DoD passed.
- **Phase 5: DONE** (2026-10-07). DoD passed. Local staging, prod and monitoring stacks are **running**.
- **Phase 6: DONE** (2026-10-07). DoD passed. Both envs run release `0b5f3a9` with 2 healthy replicas each.
- **Phase 7: DONE** (2026-10-07). DoD passed. Both envs on release `7a6904c`.
- **Phase 8: DONE** (2026-10-07). DoD passed. The healer is live (dry-run off).
- **Phase 9:** next (chaos, MTTD/MTTR, RCAs). The laptop must stay awake and on Ethernet.

## Phase 0: Preflight

### 0.1 Machine report (2026-10-07), `scripts/machine_report.sh`
- OS: `/etc/os-release` says Ubuntu 24.10 (oracular), an interim release that is now EOL (archive moved to old-releases.ubuntu.com). Kernel 6.11.0-29.
  - Apt sources list both `oracular` and `questing` (25.10) suites, and installed packages are mostly 25.10 versions (python3 3.13.7, git 2.51). This looks like a mixed or partial upgrade. **We do not touch system apt config (R10).**
- Arch x86_64, 8 CPUs, 15 GiB RAM (about 7.8 GiB available at report time), 8.2 GiB swap.
- Disk: `/home` 223G, **19G free (92% used)**. That is under the 20 GB threshold. Docker images: 9.5 GB, 7 GB of which are not used by any container (other projects; not ours to prune).
- Already installed:
  - Docker Engine 28.2.2 from Ubuntu's `docker.io` package (the plan asks for Docker's official `docker-ce`). Compose v5.5.1 and Buildx 0.37.1 come from Docker's official repo (noble). The service is active, and **docker works without sudo** (user is in the `docker` group).
  - Terraform 1.16.5 (snap, snapcrafters, classic). HashiCorp apt repo is configured for oracular.
  - AWS CLI 2.17.3 (Ubuntu `awscli` deb, not the official zip).
  - git 2.51.0, make 4.3, jq 1.8.1, pipx 1.6.0, python3-venv.
- Missing: `gh`, `ansible`, `shellcheck`.
- Vendor repos: Docker has both `oracular` and `noble`; HashiCorp has both `oracular` and `noble`; GitHub CLI uses `stable` (no codename).
- PATH note: a conda `base` env and another project's venv (`~/projects/shrinx/.venv`) come before `/usr/bin` in PATH. AdPulse tooling will call `/usr/bin/python3` explicitly.
- Ports 3000/8080/8081/9090/9093: all free.
- Project folder is `~/projects/adpulse`, not `~/adpulse` as the plan says.
- Pre-existing `.gitignore` contains `.env` and `plan.md` (so plan.md would not be committed). To confirm in Phase 1.

### Q1 answers (2026-10-07)
- Folder: stay in `~/projects/adpulse` (D002).
- Discovery: **two Docker daemons were running** (snap docker 29.8.0, which owns the socket and data, plus apt docker.io 28.2.2).
- Jugal: delete ALL existing Docker data (25 images, 7 stopped containers, `minikube` volume) and reinstall from official sources (D003).
- Vendor repo codename: `noble` (D004).

### 0.2 `scripts/bootstrap.sh` written and checked
- `bash -n` passes.
- Non-root `apt-get update` with the proposed repo files: exit 0.
- `apt-get -s install` simulation: removes only awscli, docker.io, containerd and runc. Installs docker-ce 29.8.2, containerd.io 2.3.6, compose 5.6.0, terraform 1.16.5, gh 2.102.0 and shellcheck 0.10.0. Small upgrades to make, pipx and unzip.
- AWS CLI zip signature verified with the pinned key (`scripts/keys/aws-cli.asc`).

### 0.4 pipx tools (done, no sudo)
- ansible 14.5.0 (core 2.21.5), ansible-lint 26.9.0, pre-commit 4.6.2, all on /usr/bin/python3.13.
- `~/.local/bin` is already on PATH.
- Tool quirk: in Claude's Bash tool, run `ansible*` with `</dev/null >file 2>&1`. Otherwise it errors "requires blocking IO".

### 0.3 bootstrap run by Jugal, and Phase 0 DoD (2026-10-07)
- `docker run --rm hello-world` works **without sudo** ("Hello from Docker!").
- Client/server 29.8.2, Docker root `/var/lib/docker` on `/` (75 GB free), cgroup v2.
- compose 5.6.0, buildx 0.37.1, terraform 1.16.5, aws-cli 2.37.10, gh 2.102.0, shellcheck 0.10.0, ansible core 2.21.5, ansible-lint 26.9.0: all print versions.
- No leftovers: no docker/terraform snaps, no docker.io/awscli debs, `snap.docker.dockerd` inactive, no snap snapshots.
- `shellcheck scripts/*.sh`: clean. Versions are recorded in `docs/VERSIONS.md`.
- Disk: Docker data lives on `/` (75 GB free), not `/home` (19 GB free), so the Q1 disk concern is resolved.

## Phase 1: Repo, Git, GitHub

### Steps 1–4 (2026-10-07)
- `git init -b main`.
- Created `.gitignore` (plan list, plus `plan.md`: kept local per Jugal), `.editorconfig`, README stub, `.env.example` (13 vars: per-env DB admin/app and Redis passwords, CHAOS_TOKEN, GRAFANA_ADMIN_PASSWORD, plus empty GRAFANA_SA_TOKEN and ALERT_WEBHOOK_URL).
- `scripts/gen_secrets.sh`: verified twice. Run 1: generated=11, empty-added=2. Run 2: kept=13. `.env` is mode 600 and not tracked.
- Makefile: all Section 8 targets. `help`, `check`, `secrets` and `urls` work; the others exit 1 with "not implemented yet (Phase N)".
- `.pre-commit-config.yaml` + `.yamllint.yml`; `pre-commit install`. `pre-commit run --all-files`: all hooks pass.
- Network workaround for the gitleaks and shellcheck hooks: D007.
- Global git identity already set: user.name `jugalkkt`, email `jugalkakkat@gmail.com`. Q3 still asks Jugal to confirm.
- `gh`: not logged in yet.
- Q2: GitHub user `jugalkkt`, repo **private**. Q3: commits as `jugalkkt <jugalkakkat@gmail.com>` (set in repo-local git config). `plan.md` stays local (gitignored).
- First commit `a3c9d33`.
- `gh auth login` done by Jugal. gh chose the **SSH** git protocol; Jugal's existing key `~/.ssh/id_ed25519` ("myKey" on GitHub) authenticates, so the remote is `git@github.com:jugalkkt/adpulse.git`.
- `gh repo create adpulse --private --source . --remote origin --push`.

### Phase 1 DoD (2026-10-07)
- `git log`: `a3c9d33 chore: bootstrap repo, ...`; `origin/main` is at a3c9d33.
- `gh repo view`: jugalkkt/adpulse, PRIVATE, default branch main.
- `.env` is mode 600; `git ls-files | grep -c '^.env$'` prints 0.
- `pre-commit run --all-files`: all hooks pass.

## Phase 2: Base image with Puppet (OpenVox)

### Built (2026-10-07)
- `config/puppet/`:
  - `site.pp` includes `adpulse::base`.
  - `adpulse::base`: user/group, directories, packages, umask, filesystem hardening via the `adpulse-fs-hardening` check/fix script, hardening report.
  - `adpulse::host`: stub (TODO Phase 12).
  - No external modules (no stdlib), so no Forge downloads.
- `docker/base/Dockerfile`: `ubuntu:24.04` pinned by digest, OpenVox 8.29.0, two applies in one layer, then the agent is purged (D009).
- `docker/tools/puppet.Dockerfile` (puppet-lint 5.1.1); `.dockerignore` allow-list (D011).
- Make targets: `build-base`, `lint-puppet`, `tools-puppet`; `build` and `lint` call them.
- Versions: OpenVox 8 rather than 9 (D008). Empty setuid allow-list (D010).

### Phase 2 DoD (2026-10-07)
- `make build-base`: exit 0 on the first try. Image `adpulse-base:b033731` and `:dev`, 201 MB, labelled `com.adpulse.project=adpulse`.
- `docker run --rm adpulse-base:dev id adpulse` → `uid=10001(adpulse) gid=10001(adpulse)`.
- `hardening-report.txt` prints 7 controls.
- `make lint-puppet` → "puppet lint: clean". Sanity probe: a deliberately bad .pp file gives 1 error and 4 warnings, exit 1, so the linter really runs.
- **Idempotency:**
  - Apply #1 changed 26 resources (created user/group/dirs, installed tzdata/python3/python3-venv, set the umask, and stripped setuid/setgid from 12 binaries).
  - Apply #2: "Applied catalog in 1.31 seconds" with no change notices, exit 0. The log is in the image at `/etc/adpulse/puppet-idempotency.log`.
- In the image: 0 setuid/setgid files, `fs-hardening check` OK, no OpenVox packages or `/opt/puppetlabs`, 0 apt list files. Python 3.12.3.

## Phase 3: AdPulse API

### Built (2026-10-07)
- `app/adpulse/`: config, logging_setup (JSON), metrics (all 10 from Section 9), db (psycopg pool, timeouts), cache (redis, no retries), selection (cache → db → fallback, weighted by bid_cpm, injectable RNG), chaos (5 modes, auto-expire), main (app factory, middleware, endpoints, impression queue), migrate (advisory lock, schema_migrations).
- `app/migrations/`: 001_init, 002_seed (10 advertisers, 60 ads; every category has `all`-segment ads).
- `app/loadgen/loadgen.py`.
- `docker/api/Dockerfile`: `runtime` and `test` targets, FROM `adpulse-base:<sha>`.
- `app/tests/compose.test.yml`.
- Make targets: `build-api`, `lint-app`, `test`, `lock`.
- Decisions D012–D017.

### Phase 3 DoD (2026-10-07)
- `make lint-app`: "All checks passed", 20 files already formatted.
- `make test`: **33 passed** (30 unit + 3 integration on real postgres 18.6 / redis 8.10.2), green 6 runs in a row.
  - Unit coverage: weighted selection (75%±2% share for 3:1 bids over 20k draws, determinism), cache hit/miss/error, fallback when both fail (and miss + DB fail), param validation (4 cases → 422), chaos expiry (fake clock), chaos 404 when disabled / 403 on bad token, memory_leak alloc + free, readyz/broken release, metrics, request-id, async impressions + queue-full drop.
  - Integration coverage: migrations idempotent (60 ads, 10 advertisers), db → cache path, impressions written, all 30 category×segment combos served.
  - Bug found and fixed: queued impressions were lost on shutdown (D015).
- Images: `adpulse-api:0e1eb19`/`:dev` 266 MB; `adpulse-api-test` 340 MB.
- Read-only run (`--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges`, no DB/Redis):
  - Docker health `healthy` after 6 s; `/healthz` 200; `/readyz` 503 with details.
  - `/v1/ad` 200 `source=fallback` in 0.52 s; chaos route 404; runs as `adpulse`; rootfs write denied; JSON logs only.
- Loadgen entrypoint: 10 requests per 2 s window at 5 rps.

## Phase 4: Database image with Chef (Cinc) + backup agent

### Built (2026-10-07)
- Cookbook `config/chef/cookbooks/adpulse_db`:
  - Attributes from the plan, plus `allowed_cidrs` (D018).
  - `recipes/default.rb` renders `/etc/adpulse-db/{postgresql.conf,pg_hba.conf,chef-report.txt}`, the initdb roles script (D020), `/backups` + `/textfile` (owned by postgres), and `adpulse-backup{,-metrics,-loop}.sh`.
  - `recipes/host.rb` stub.
- `docker/postgres/Dockerfile`: postgres 18.6-trixie (digest), Cinc 19.3.14 via hash-pinned deb (D019), converge twice, Cinc purged.
- `scripts/test_postgres_image.sh` → `make test-postgres`. Also `make build-postgres` and `make lint-chef`.
- `.env.example`: added `<ENV>_DB_MONITOR_PASSWORD` (`make secrets` added 3, kept the rest).

### Phase 4 DoD (2026-10-07)
- `make build-postgres`: exit 0. Converge #1: 10/10 resources updated. **Converge #2: 0/10 resources updated** (log in the image at `/etc/adpulse-db/cinc-idempotency.log`). Our layer is 3.9 MB (the base image is 644 MB); no `/opt/cinc`, cinc or curl packages left.
  - First build failed only because my check grepped for "Cinc Client finished"; Cinc 19 prints "Infra Phase complete". Fixed the regex.
- `make lint-chef`: cookstyle "4 files inspected, no offenses detected".
- `make test-postgres`: 14/14 PASS:
  - `SHOW shared_buffers` = 128MB; max_connections 50; scram-sha-256; statement_timeout 5s.
  - Correct password connects; monitor role reads pg_stat_activity; **wrong password rejected** ("password authentication failed"); a non-allowed subnet is rejected ("no pg_hba.conf entry"); no trust lines.
  - Backup loop: `pgtest-20261007T071516Z.dump` (pg_restore --list OK, 0.099 s). The `.prom` file passes `promtool check metrics` (Prometheus v3.15.0) and has all 5 metrics.
  - No leftover test containers, networks or volumes.

## Phase 5: Local infrastructure with Terraform

### Built (2026-10-07)
- `infra/terraform/modules/adpulse_stack`: network with a fixed subnet and explicit gateway; volumes pgdata/redisdata/backups; containers postgres, redis, toxiproxy, nginx, backup-agent, postgres-exporter, redis-exporter, loadgen.
  - Every container has limits (Section 5.4), labels, no-new-privileges, cap_drop ALL (no cap_add anywhere) and a read-only rootfs (toxiproxy excepted, D025).
- `modules/monitoring_stack`: adpulse-monitoring network, tmpfs textfile volume (D022), prometheus, alertmanager, grafana, node-exporter (D023), cadvisor (D024). The healer variable exists but is not used yet (Phase 8).
- Roots: `envs/local` (workspace = env, `staging.tfvars`/`prod.tfvars`, guard) and `monitoring/local`.
- `config/nginx/nginx.conf.tftpl`: resolver 127.0.0.11 valid=5s with a variable `proxy_pass`, X-Request-ID, 2s timeouts, next_upstream, JSON logs, `/metrics` and `/admin` blocked (D028).
- `scripts/terraform.sh` loads secrets from .env as TF_VAR_* and computes `env_networks` for monitoring (D021).
- Make targets: `infra`, `plan-infra`, `monitoring`, `plan-monitoring`, `lint-terraform`, `down`.
- Bootstrap configs: `monitoring/prometheus/prometheus.yml` (self-scrape), `alertmanager.yml` (null receiver), Grafana datasource and dashboard provider.

### Problems hit and fixed
1. **Secret exposure (my mistake):** a `bash -x` debug run of scripts/terraform.sh printed GRAFANA_ADMIN_PASSWORD in Claude's tool output. It was **rotated immediately** in .env (still mode 600) before any Grafana container existed, so the leaked value was never used. Lesson: never use `bash -x` on scripts that read secrets. To be recorded in SECURITY.md (Phase 11).
2. An empty `grep` under pipefail broke `scripts/terraform.sh monitoring` when no env networks existed yet → `|| true`.
3. The provider's `upload` fails on read-only containers, even for volume paths → D025.
4. Perpetual diffs (network gateway → forced replacement, memory_swap, label=disable, healthcheck timings) → D026, no ignore_changes.

### Phase 5 DoD (2026-10-07)
- `make lint-terraform`: fmt -check OK, validate "Success" in both roots.
- Applied monitoring (15 resources), staging, prod (18 resources each), then monitoring again (Prometheus joined both env networks).
- `docker ps --filter label=com.adpulse.env=<env>`: all 8 staging and 8 prod containers Up, every one with a healthcheck **healthy** (loadgen has none by design). All 5 monitoring containers healthy.
- **Idempotency:** a second `terraform plan` shows "No changes" for staging, prod and monitoring.
- Default workspace: plan refused with the message "env must be staging, prod or aws-prod. In envs/local the env IS the Terraform workspace: run 'make infra ENV=staging' ...", exit 1.
- Published ports: only 127.0.0.1:{3000,8080,8081,9090,9093}; DB and Redis are not published.
- nginx (both envs): /nginx-health 200, /metrics 404, /admin 404, /v1/ad 502 (expected: no API replicas until Phase 6), X-Request-ID echoed and logged as JSON.
- Toxiproxy: proxies postgres :15432 → postgres-staging:5432 and redis :16379 → redis-staging:6379 enabled.
- Backups running; node-exporter exposes `adpulse_backup_*{env="staging"|"prod"}` from the textfile volume.
- Memory limits: 3712 MB across 21 containers; plus 4 API replicas × 256 MB (Phase 6) = **4736 MB, under the 6144 MB cap**.

## Phase 6: Ansible releases, rollback, zero-downtime

### Built (2026-10-07)
- `ansible/ansible.cfg` (yaml result format, no retry files) and `inventories/local/hosts.yml`.
- Variables live in `playbooks/group_vars/all/main.yml` (D033).
- Playbooks: `deploy.yml` (silence → migrate → rolling update → state → expire silence; rescue = auto-rollback + fail), `rollback.yml`, `migrate.yml`, `status.yml`.
- Task files: load_secrets (from .env, no_log), replica (D031), rolling_update, migrate (one-shot container, always removed), silence_create/expire, read/write_state.
- `scripts/smoke_test.sh`, `scripts/check_zero_downtime.sh`.
- Make targets: `deploy`, `rollback`, `migrate`, `status`, `smoke`, `lint-ansible`, and the full **`make up`**.
- Also fixed along the way: reproducible image IDs (D029) and nginx connect timeout (D032).

### Phase 6 DoD (2026-10-07)
- `make deploy ENV=staging` and `ENV=prod`: first deploy applied migrations 001_init and 002_seed in each env. Current release `0b5f3a9` in both.
- `make smoke`: PASS in both envs (/readyz 200, 20/20 valid, p95 2–59 ms, /metrics on a replica).
- **Zero downtime:** deploy during the request loop → 0 failed requests in every run:
  - f5bded1→da5499b: 6654/6654 OK (32 requests waited ~2 s before failover → D032)
  - →1d25438: 5765/5765 OK, max latency 0.505 s
  - →0b5f3a9: 4613/4613 OK, smoke right after the deploy p95 4 ms
- `make rollback ENV=staging` (1d25438 → da5499b) under load: 4328/4328 OK. State swapped, smoke PASS.
- Auto-rollback: a deliberately broken image (`crashtest`) failed at migration → rescue rolled back to da5499b, the play failed with a clear message, 2749/2749 requests OK, no leftover containers (after the fix).
- Idempotent redeploy of the same tag: both replicas untouched (19 tasks skipped).
- `make lint-ansible`: Passed, 0 failures, 0 warnings, profile **production**.
- `make up` on the running system: exit 0 in 34 s, both smoke tests PASS. (The from-scratch `make up` test is part of final acceptance.)

## Phase 7: Monitoring, alerting, dashboards, SLOs

### Q4 (2026-10-07)
No chat webhook. Alerts go to the healer, the Alertmanager UI and Grafana.

### Built
- `monitoring/prometheus/prometheus.yml`: 5s intervals (D035); jobs api (DNS SD, env relabel), postgres, redis, node (textfile env relabel), cadvisor (AdPulse containers only, env/role/container relabel, D040), alertmanager, prometheus. The healer job comes in Phase 8 (D041).
- `rules/recording.yml` (10 rules), `rules/alerts.yml` (14 rules; every Section 10 alert, severity/env/summary/description/runbook), `rules/slo.yml` (16 rules: availability 99.5%, latency 95%<150ms, fast/slow burn, D036).
- `alertmanager.yml`: group by [alertname, env], 10s/30s/15m, healer webhook with send_resolved; DatabaseDown inhibits HighErrorRate and ServingFallbackAds.
- `docs/runbooks/*.md`: 14 runbooks, all linked from the rules.
- `monitoring/prometheus/tests/alerts_test.yml`: 4 promtool unit tests (DB down timing, error rate, stopped replica, backup forecast).
- Grafana: 5 provisioned dashboards generated by `monitoring/grafana/build_dashboards.py` (D037); `scripts/check_dashboards.py`.
- Make targets: `lint-monitoring`, `test-rules` (now part of `make test`), `reload-monitoring`, `dashboards`, `check-dashboards`.

### Problems found by testing, and fixed
- **AdPulseCacheDown could not fire:** a Redis-exporter scrape took 9.5s with Redis down, more than the 4s timeout (D039).
- **DB recovery took 45s** after a long outage (pool backoff) → 1.5s (D038).
- cAdvisor showed `-next` names after rolling updates (D040).
- 5xx ratio was "no data" instead of 0 with no errors → `or … * 0`.
- loadgen logged every request through httpx at INFO → WARNING.
- Dashboard bugs found by the checker: "Healthy replicas" returned 2 series (`or on() vector(0)`); "DB connections by state" had 6 states (3 would get cycled colours), now filtered to 3.

### Phase 7 DoD (2026-10-07)
- `curl localhost:9090/api/v1/targets`: **12/12 up** (4 API replicas via DNS SD, 2+2 exporters, node, cadvisor, alertmanager, prometheus).
- `make lint-monitoring`: promtool config SUCCESS, 14+10+16 rules SUCCESS; amtool check-config SUCCESS.
- `make test-rules`: SUCCESS (4 tests).
- All 5 dashboards provisioned in folder "AdPulse" (anonymous access → 401). `make check-dashboards`: every panel returns data in staging and prod, except the 2 expected-empty ones (alert timeline when nothing fired; healer actions before Phase 8).
- **Alert delivery** (temporary echo receiver at http://healer:9100, since removed):
  - `amtool alert add` → webhook after ~11s.
  - Real alerts: stop redis-staging → AdPulseCacheDown at the webhook after **27s**, resolved sent after the restart.
  - Stop postgres-staging → AdPulseDatabaseDown after **30s**. The API kept serving HTTP 200 fallback ads. AdPulseServingFallbackAds was **suppressed by the inhibition rule**.
- After the tests: 0 firing alerts.

## Phase 8: Self-healing healer

### Built (2026-10-07)
- `healer/`: engine.py (decisions), app.py (webhook, runner, heal log, Grafana annotations, metrics), healing.yml (alert → playbook allow-list), 14 unit tests. Dependencies hash-locked (`make lock-healer`; needed the Ethernet connection, D-notes in PROGRESS).
- `ansible/playbooks/heal/`: restart_api (container / instance IP / missing / rolling), restart_db (+pg_isready +API readyz), restart_cache, scale_api (clone, max 4), scale_down_api (on resolve), kill_noisy_neighbor (only role=chaos or unlabelled, protected roles never), cleanup_backups (junk, retention, quota), diagnose_latency (evidence only).
- `docker/healer/Dockerfile` (FROM adpulse-base, docker-ce-cli 29.8.2, community.docker 5.4.0, non-root).
- Terraform: socket proxy + healer + internal network (D043, D044). `scripts/grafana_token.sh` (service account adpulse-healer, token only in .env).
- Prometheus healer job (honor_labels). HealerEscalated rule fixed (D047). Make: build-healer, lock-healer, test-healer, test-heal, grafana-token.

### Problems hit and fixed
1. Lock: pip-compile hashing timed out three times at ~350 KB/s (campus Wi-Fi). Asked Jugal (R9); he switched to Ethernet (4.3 MB/s), and the lock finished in 150 s.
2. The healer couldn't run as uid:uid because /opt/adpulse is 0750 (D044).
3. Live test #1: escalated, because Ansible's temp dir was under /home/ubuntu on the read-only rootfs (D044). Escalation itself worked as designed.
4. Live test #2: escalated, because the non-verbose docker_host_info had no State (D046).
5. `make test-heal` found 2 more bugs: dotted label keys (also in the Phase 6 deploy) and the diagnostics timestamp re-evaluated per use.
6. HealerEscalated never fired, and the env label clashed (D047).
Raw logs of the failed attempts are kept in `incidents/raw/` (gitignored).

### Phase 8 DoD (2026-10-07)
- `make test-healer`: **14 passed**, ruff clean (mapping, allow-list rejection, label→vars, resolved/on_resolved, dedupe, cooldown, max attempts + escalate once, window expiry, error-rate re-fire escalation, failed playbook → escalate, dry-run, per-env lock, webhook dry-run).
- **Dry run** (HEALER_DRY_RUN=true): sample payload → decisions restart_db / restart_api / BackupStale ignored; the heal log shows `result: dry_run` with the correct extra_vars.
- `make test-heal`: **11/11 PASS** (all 8 playbooks against staging).
- **Live, dry-run off:** `docker stop api-staging-1` at T+0 → AdPulseApiReplicaDown (reason=missing) active at **T+31s** → healer `restart_api` succeeded in **14.4s** → api-staging-1 healthy at **T+52s** → alert resolved at **T+60s** → Grafana annotation "healer: restart_api for AdPulseApiReplicaDown (staging) -> success in 14.4s".
- Escalation: a webhook for a non-existent replica IP → playbook failed → escalated → **HealerEscalated firing 10s later** (alert=AdPulseApiReplicaDown, env=staging).
- Socket proxy: the healer can list/restart containers and is denied volumes (403).
- `make test-rules`: SUCCESS (5 tests). `make lint-ansible`: production profile, 0 failures.

## Open questions
- FYI for Jugal (out of project scope): the OS is half-upgraded. os-release and kernel say 24.10, apt sources say 25.10, and ~2000 packages are not upgraded.
