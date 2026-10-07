# Decisions (ADR-lite)

Format: **Date / Decision / Why / Alternatives**

---

### D001: Python 3 + FastAPI for the app and tools
- **Date:** 2026-10-07
- **Decision:** Write the AdPulse API, loadgen, healer, chaos and RCA tooling in Python 3 with FastAPI.
- **Why:** Jugal asked Claude to pick standard tools. Python is common in SRE tooling, FastAPI is async (good for Postgres/Redis I/O), and one language keeps the project small.
- **Alternatives:** Go (faster, single binary, but slower to build and less familiar), Node.js.

### D002: Project lives in `~/projects/adpulse`, not `~/adpulse`
- **Date:** 2026-10-07
- **Decision:** Treat every `~/adpulse` in plan.md as `~/projects/adpulse`.
- **Why:** That's where the folder already is; Jugal chose it at Q1.
- **Alternatives:** Move the folder to `~/adpulse`.

### D003: Replace all pre-existing Docker, Terraform and AWS CLI installs with the official ones
- **Date:** 2026-10-07
- **Decision:** `scripts/bootstrap.sh` purges the snap `docker` (29.8.0) and Ubuntu `docker.io` (28.2.2), which were *both* running at once, plus all their data (25 images, 7 stopped containers, the `minikube` volume). It also removes the snapcrafters Terraform snap and the Ubuntu `awscli` deb. It then installs docker-ce, Terraform and gh from the vendors' official apt repos, and AWS CLI v2 from the official zip.
- **Why:** Jugal asked for this at Q1 ("I only want this project stuff in docker"), and it frees about 13 GB on a 92%-full disk. Two Docker daemons on one machine is confusing and fragile. Official sources match the plan (R5) and get current versions.
- **Alternatives:** Keep the existing installs and add only the missing tools (less disruption, but they don't match the plan and the setup stays messy).
- **Note:** plan rule R10 forbids global Docker cleanups. This one-off purge was explicitly authorized by Jugal and runs only inside his own sudo script, after he types `yes`.

### D004: Use the `noble` (24.04 LTS) codename for the Docker and HashiCorp apt repos
- **Date:** 2026-10-07
- **Decision:** Vendor repos use suite `noble`, even though `/etc/os-release` says 24.10 (`oracular`) and the Ubuntu apt sources point at 25.10 (`questing`).
- **Why:** On 2026-10-07, Docker's `oracular` repo was frozen at 28.4.0 and `questing` at 29.7.2, while `noble` has the current 29.8.2. HashiCorp publishes no Terraform package for oracular or questing; noble has 1.16.5. The noble binaries install cleanly on this system (verified with an `apt-get -s` simulation), and Jugal's previous Docker repo line already used noble. Jugal chose this at Q1, as plan Section 3 requires.
- **Alternatives:** `questing` (outdated Docker, and Terraform would need another install method).

### D005: Pin apt signing-key fingerprints in bootstrap.sh
- **Date:** 2026-10-07
- **Decision:** The script refuses keys whose fingerprint doesn't match the pinned values:

  | Key | Fingerprint | Checked against |
  |---|---|---|
  | Docker | `9DC8 5822 9FC7 DD38 854A E2D8 8D81 803C 0EBF CD88` | the well-known Docker CE key |
  | GitHub CLI | `2C61 0620 1985 B60E 6C7A C873 23F3 D4EA 7571 6059` | listed in cli/cli `docs/install_linux.md` |
  | HashiCorp | `D55C 0D1A C78A 8D81 26CB 631C FC9C A96A CA02 6560` | weaker check: the key comes over HTTPS from `apt.releases.hashicorp.com` and validly signs its `noble` InRelease file. HashiCorp's security page is JS-rendered, so it couldn't be cross-checked. Jugal's previous keyring held HashiCorp's older key `798A EC65 … A621 E701`. |
  | AWS CLI | `FB5D B77F D5C1 18B8 0511 ADA8 A631 0ACC 4672 475C` | stored in `scripts/keys/aws-cli.asc`; matches the AWS CLI install docs, and verified a real download on 2026-10-07 |
- **Why:** This guards against a tampered key or download (supply-chain hygiene; relevant to the JD's security item).
- **Alternatives:** Trust whatever key is served (simpler, weaker).

### D006: Never rely on `python3` from PATH
- **Date:** 2026-10-07
- **Decision:** Tooling uses `/usr/bin/python3`, pipx venvs, or containers, never the first `python3` on PATH.
- **Why:** Jugal's shell activates conda `base` and another project's venv (`~/projects/shrinx/.venv`), so `python3` on PATH is 3.11 from conda, not the system 3.13.
- **Alternatives:** Ask Jugal to deactivate conda (changes his other projects' workflow).

### D007: Pre-commit hooks that avoid blocked downloads
- **Date:** 2026-10-07
- **Decision:** gitleaks runs as a local `docker_image` hook pinned to `zricethezav/gitleaks:v8.30.0@sha256:691af3c7…a574d9`. shellcheck runs as a `system` hook using the host binary that bootstrap.sh installs. The four public signing-key fingerprints in bootstrap.sh carry `# gitleaks:allow`.
- **Why:** On this network (IIIT Kottayam), `proxy.golang.org` is intercepted with the campus TLS certificate, so the upstream golang gitleaks hook cannot build. shellcheck-py's GitHub-release download got "connection reset", and IPv6 was unreachable. gitleaks' generic-api-key rule flags 40-hex-char fingerprints, but those are public by design, not secrets.
- **Alternatives:** upstream `gitleaks-docker` hook (it uses an unpinned `latest` image, which breaks R5); installing Go and gitleaks on the host (more host clutter, and still blocked).
- **Watch out:** later phases that fetch Go modules or GitHub release assets may hit the same network blocks. Prefer pinned container images.

### D008: OpenVox 8.29.0 rather than 9.0.0
- **Date:** 2026-10-07
- **Decision:** Pin `openvox-agent=8.29.0-1+ubuntu24.04` from the `openvox8` repo.
- **Why:** OpenVox 9.0.0 went GA on 2026-10-02, five days before this build. The official install docs (voxpupuli.org/openvox/install) still point to `openvox8-release`, and puppet-lint 5.1.1 targets the 8.x language. 8.29.0 is the latest release of the mature, stable line.
- **Alternatives:** 9.0.0. It's newer, but the ecosystem and docs lag, and a fresh .0 major is riskier. A good "what I'd do next" upgrade item.

### D009: Base image applies Puppet in a single layer, then purges the agent
- **Date:** 2026-10-07
- **Decision:** One `RUN` installs OpenVox, runs `puppet apply` twice, then purges the agent, its repo, `/opt/puppetlabs` and the apt lists. The Puppet code comes in through a read-only `RUN --mount=type=bind`, so it never lands in a layer.
- **Why:** A purge in a later layer would not shrink the image, and the agent's Ruby gems would show up in Trivy scans. The second apply must exit 0 (no changes), or the build fails. That is the plan's idempotency check, and the log is kept at `/etc/adpulse/puppet-idempotency.log`.
- **Alternatives:** A multi-stage build copying the filesystem out (more complex); keeping the agent (bigger image, more CVEs).

### D010: Empty setuid/setgid allow-list in the base image
- **Date:** 2026-10-07
- **Decision:** All 12 setuid/setgid binaries are stripped (su, passwd, mount, umount, newgrp, chsh, chfn, gpasswd, chage, expiry, unix_chkpwd, pam_extrausers_chkpwd).
- **Why:** Containers run as the non-root `adpulse` user with `no-new-privileges` and never log in or switch users, so none of these are needed. Stripping them removes privilege-escalation paths. The allow-list stays a class parameter in case a future image needs one.
- **Alternatives:** Keep `su` and `passwd` "just in case" (no use in a container).

### D011: `.dockerignore` is an allow-list
- **Date:** 2026-10-07
- **Decision:** `.dockerignore` excludes everything (`*`), then re-includes only the directories builds need.
- **Why:** This guarantees `.env`, Terraform state, `.git` and incident data can never be copied into an image, even by a careless `COPY . .`.
- **Alternatives:** A deny-list (easy to forget a new secret file).
