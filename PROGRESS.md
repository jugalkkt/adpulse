# AdPulse progress log

## Current status
- **Phase 0: DONE** (2026-10-07). DoD passed.
- **Phase 1: DONE** (2026-10-07). DoD passed. Repo: https://github.com/jugalkkt/adpulse (private).
- **Phase 2: DONE** (2026-10-07). DoD passed.
- **Phase 3: DONE** (2026-10-07). DoD passed.
- **Phase 4:** next (Postgres image with Chef/Cinc + backup agent).

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

## Open questions
- FYI for Jugal (out of project scope): the OS is half-upgraded. os-release and kernel say 24.10, apt sources say 25.10, and ~2000 packages are not upgraded.
