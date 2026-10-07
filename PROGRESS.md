# AdPulse progress log

## Current status
- **Phase 0: DONE** (2026-10-07). DoD passed.
- **Phase 1:** in progress. Next: repo files, then 🛑 Q2/Q3, then `gh auth login`.

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
- First commit done.
- **Next:** 🧑 `gh auth login` → `gh repo create adpulse --private --source . --push`.

## Open questions
- FYI for Jugal (out of project scope): the OS is half-upgraded. os-release and kernel say 24.10, apt sources say 25.10, and ~2000 packages are not upgraded.
