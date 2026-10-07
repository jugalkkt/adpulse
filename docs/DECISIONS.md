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

### D012: Docker Compose only for test dependencies
- **Date:** 2026-10-07
- **Decision:** `app/tests/compose.test.yml` starts a throwaway Postgres (tmpfs) and Redis plus the test runner, for `make test` only. All runtime infrastructure is Terraform (Phase 5).
- **Why:** The plan requires it (Phase 3). Compose is the simplest way to get disposable, healthy-gated dependencies, and it is torn down (`down -v`) after every run, even when tests fail.
- **Alternatives:** Terraform for test deps (slow and stateful for a 3-second test run); testcontainers-python (needs the Docker socket inside the test container).

### D013: Hash-locked Python dependencies; no pip in the runtime image
- **Date:** 2026-10-07
- **Decision:** Top-level pins live in `app/requirements*.in`. `make lock` runs pip-compile inside `adpulse-base` (the same Python 3.12 as the image) to produce `requirements*.txt` with every transitive package pinned and sha256-hashed. Images install with `--require-hashes --no-deps`, then uninstall pip.
- **Why:** Exact, reproducible builds; a tampered package fails the hash check (supply chain, R5); fewer packages for Trivy to flag. The test image re-adds pip via `ensurepip`.
- **Alternatives:** Plain `==` pins (transitive deps drift); uv or poetry (another tool to learn).

### D014: Serving-path timeouts and four extra config variables
- **Date:** 2026-10-07
- **Decision:** On top of the plan's env vars, add `DB_TIMEOUT_SECONDS` (0.5), `REDIS_TIMEOUT_SECONDS` (0.2), `DB_POOL_MAX_SIZE` (5) and `IMPRESSION_QUEUE_SIZE` (1000). Every DB call is wrapped in `asyncio.wait_for`. Redis uses socket timeouts and **no retries** (redis-py 8 retries 3 times by default).
- **Why:** With both dependencies down, `/v1/ad` must still answer (fallback) well inside nginx's 2 s upstream timeout. Measured: 0.52 s with both down. Retries would multiply the latency of a dead cache.
- **Alternatives:** Library defaults (DB connects can hang for many seconds, which would turn a DB outage into 5xx at nginx instead of fallback ads).

### D015: Impressions: skip house ads; drain the queue on shutdown
- **Date:** 2026-10-07
- **Decision:** Fallback (house) ads write no impression, since they aren't billable and the DB is usually the thing that's down. On shutdown, the app waits up to 2 s for the impression queue to drain before stopping the worker, and counts anything left as dropped.
- **Why:** A flaky integration test (1 failure in 4 runs) exposed that queued impressions were lost on every shutdown, which means on every rolling deploy. After the fix: 6/6 green.
- **Alternatives:** Persisting the queue (overkill for this demo).

### D016: Chaos "hang" is a middleware gate, not a blocked event loop
- **Date:** 2026-10-07
- **Decision:** While `hang` is active, every request except `/admin/chaos*` waits in a 0.1 s polling loop. That includes `/healthz` and `/metrics`, so Docker health and Prometheus scrapes time out.
- **Why:** This produces the symptom the plan's alert needs (`up{job="api"} == 0`), while `DELETE /admin/chaos` can still end it. Restarting the replica (what the healer does) also clears it, because chaos state is in memory. Blocking the whole event loop would make the chaos API itself unreachable.
- **Alternatives:** `time.sleep` on the loop (unrecoverable without a restart).

### D017: PostgreSQL 18.6 (Debian trixie) and Redis 8.10.2 (Alpine)
- **Date:** 2026-10-07
- **Decision:** `postgres:18.6-trixie` and `redis:8.10.2-alpine`, pinned by digest. On 2026-10-07 the Docker Hub `latest` tag for each pointed to exactly these versions.
- **Why:** Current stable (R5). Postgres must be Debian-based so Cinc can run in Phase 4. Alpine Redis is small and only runs `redis-server`.
- **Alternatives:** Postgres 17 (older); Debian Redis (bigger, no benefit).

### Note: Starlette TestClient deprecation warning
Starlette 1.7 warns that `httpx` with its TestClient is deprecated in favour of `httpx2`. Tests still pass. Revisit when FastAPI's TestClient switches over (tracked as a known item, not an error).

### D018: pg_hba allows the three environment subnets, from a Chef attribute
- **Date:** 2026-10-07
- **Decision:** Attribute `node['adpulse_db']['allowed_cidrs']` = `172.28.10.0/24` (staging), `172.28.20.0/24` (prod), `172.28.30.0/24` (aws-prod). pg_hba gets one `host … scram-sha-256` line per CIDR. Chef runs at image build time, so a single image serves every environment.
- **Why:** Cinc is removed from the image (plan Phase 4), so per-container CIDRs can't be rendered at runtime. Building one image per environment would break "build once, promote everywhere". Each Postgres container is attached only to its own environment's Docker network, so in practice a container only ever sees clients from its own subnet. A client from any other subnet is rejected (tested: "no pg_hba.conf entry"). The Terraform subnets (Phase 5) must match this attribute; Phase 5 adds a validation for that.
- **Alternatives:** Per-env image builds with a build-arg CIDR (3 images per release); the `samenet` keyword (dynamic, but not a "CIDR passed as an attribute" as the plan asks).

### D019: Install Cinc from a hash-pinned .deb (via the omnitruck metadata API)
- **Date:** 2026-10-07
- **Decision:** The Dockerfile downloads `cinc_19.3.14-1_amd64.deb` (Debian 13) from packages.cinc.sh and checks the sha256 `a6094f97…aeefebd` that `omnitruck.cinc.sh/stable/cinc/metadata` reported on 2026-10-07. It runs `cinc-client --local-mode --chef-license accept-no-persist` twice (the second run must report `0/N resources updated`), then `dpkg --purge cinc`. `accept-no-persist` was passed defensively; Cinc did not prompt for a license.
- **Why:** Same artifact as omnitruck (plan option 1), but pinned and hash-verified instead of piping a script into a shell, so builds are reproducible.
- **Alternatives:** The `install.sh` script (unpinned); `COPY --from=cincproject/cinc` (an extra 58 MB image to trust).
- **Note:** The harmless log line `ERROR: shard_seed: Failed to get dmi property serial_number` appears because containers have no DMI data.

### D020: Three database roles; peer for local postgres, no trust anywhere
- **Date:** 2026-10-07
- **Decision:**
  - `postgres`: superuser, from `POSTGRES_PASSWORD`; init only, plus `docker exec` diagnostics.
  - `adpulse`: app and migrations; owns database `adpulse`; also used by pg_dump.
  - `adpulse_monitor`: `pg_monitor`, connection limit 3; used by postgres_exporter.
  - pg_hba: `local all postgres peer`, `local all all scram-sha-256`, then only the env CIDRs with scram-sha-256.
- **Why:** Least privilege: the app and the exporter never hold superuser. The plan allowed a local `trust` entry for the postgres user if init needed it. Init doesn't (the entrypoint exports `PGPASSWORD`), so the stricter `peer` is used for the healer's `docker exec psql`.
- **Alternatives:** Everything as the superuser (simpler, much riskier).

### D021: Apply order for monitoring and env stacks
- **Date:** 2026-10-07
- **Decision:** `make up` runs `monitoring → infra staging → infra prod → monitoring`. `scripts/terraform.sh monitoring` passes `env_networks` = the `adpulse-staging` / `adpulse-prod` networks that exist at that moment.
- **Why:** The plan has monitoring create the shared `adpulse-textfile` volume (which the env stacks need) and also attach Prometheus to the env networks (which the env stacks create). The two-pass apply resolves that cycle with no manual step. Once every network exists, the second pass is a no-op.
- **Alternatives:** Creating the volume outside Terraform; a third Terraform root just for shared resources.

### D022: `adpulse-textfile` is a tmpfs volume owned by uid 999
- **Date:** 2026-10-07
- **Decision:** A local-driver volume with `type=tmpfs,o=size=8m,uid=999,gid=999,mode=0755`.
- **Why:** Every env's backup-agent (uid 999) writes its `.prom` file there, and node-exporter reads it. A normal named volume takes its ownership from whichever container mounts it first, which could leave it root-owned and unwritable. The files are rewritten every 15 s, so persistence is not needed.
- **Alternatives:** One volume per env (node-exporter reads a single textfile directory); running backup-agent as root.

### D023: node-exporter on the monitoring network, not host networking
- **Date:** 2026-10-07
- **Decision:** `pid_mode=host` and the host `/` mounted read-only at `/host` (`--path.rootfs`), but attached to `adpulse-monitoring`.
- **Why:** With host networking, port 9100 would listen on every host interface (including Wi-Fi). Plan pitfall #6 explicitly allows this alternative. Trade-off: `node_network_*` metrics describe the container's interface, not the host's. CPU, memory, disk and load are the host's (MemTotal matched `/proc/meminfo` exactly).
- **Alternatives:** Host networking with Prometheus scraping via host-gateway.

### D024: cAdvisor without `privileged`
- **Date:** 2026-10-07
- **Decision:** Read-only bind mounts of `/`, `/var/run`, `/sys`, `/var/lib/docker` and `/dev/disk`, plus device `/dev/kmsg` (read), `cap_drop ALL` and `no-new-privileges`. Heavy metric groups are disabled; only the `com.adpulse.*` container labels are exported.
- **Why:** On this host (cgroup v2, Docker 29.8.2) that was enough. cAdvisor reported all containers with their labels and stayed healthy, so `privileged` (as some docs suggest) wasn't needed.
- **Alternatives:** `privileged: true` (much broader access).

### D025: Getting config into read-only containers
- **Date:** 2026-10-07
- **Decision:**
  - nginx and Redis receive their config (Redis: just the password) in an env var. A `/bin/sh -c` start command writes it to tmpfs `/tmp`, then `exec`s the server.
  - Toxiproxy (a no-shell image) gets its JSON via Terraform `upload` and is the **one container with a writable rootfs**. It runs as `nobody` with no capabilities, and the image contains only two static binaries.
- **Why:** The docker provider's `upload` copies via the container root `/`, which Docker refuses for read-only containers. That was tested: it failed even when the target path was a volume. Env + tmpfs works the same locally and over docker-over-SSH (Phase 12), where host bind-mount paths would not exist.
- **Alternatives:** Bind-mounting rendered files from the host (breaks on AWS); a writable rootfs for all three.

### D026: Fixing Terraform perpetual diffs without `ignore_changes`
- **Date:** 2026-10-07
- **Decision:** Declare the values Docker fills in on its own:
  - network `gateway = cidrhost(subnet, 1)` (it otherwise forced replacement on every plan);
  - `memory_swap = memory` (Docker defaulted it to 2× memory; this also means no container can swap past its limit);
  - `label=disable` on node-exporter (Docker adds it with `pid_mode=host`);
  - healthcheck timing fields that the image defines (loadgen's disabled check, cAdvisor's `start_period`).
- **Why:** A second `terraform plan` now shows "No changes" in staging, prod and monitoring, and real drift is still detected because nothing is ignored.
- **Alternatives:** `lifecycle { ignore_changes = [...] }`, which hides genuine drift.

### D027: Postgres and Redis run directly as their own uid
- **Date:** 2026-10-07
- **Decision:** `user = "999:999"` for Postgres and backup-agent, `999:1000` for Redis. Their entrypoints then skip the root-only `chown`/`gosu` steps.
- **Why:** With no root step, they need zero capabilities (`cap_drop ALL`, nothing added). Volume ownership comes from the images' directories on first mount.
- **Alternatives:** Root entrypoint plus CHOWN/SETUID/SETGID/DAC_OVERRIDE capabilities.

### D028: nginx hides `/metrics` and `/admin/*`
- **Date:** 2026-10-07
- **Decision:** nginx returns 404 for `/metrics` and `/admin/` in every env. Prometheus scrapes replicas directly on the env network, and chaos tooling calls replicas directly (`docker exec`).
- **Why:** The only published entry point should expose the product API, nothing internal, especially on AWS.
- **Alternatives:** Protect them with auth at nginx.

### D029: Reproducible image IDs (no provenance attestation, no SHA label on base/postgres)
- **Date:** 2026-10-07
- **Decision:** Every `docker build` uses `--provenance=false`. The `adpulse-base` and `adpulse-postgres` images carry no git-SHA label; only `adpulse-api` (the release artifact) records `GIT_SHA`.
- **Why:** BuildKit's default provenance attestation gave every build a new image ID even when every layer was cached. Combined with the SHA label, Terraform recreated Postgres and backup-agent on **every commit** (observed: "4 added, 4 destroyed" after a commit that only changed nginx config). Now two builds give the same ID, and a new commit only replaces the stateless loadgen.
- **Alternatives:** Pin Terraform to a separately versioned DB image tag (more bookkeeping); `ignore_changes = [image]` (would hide real DB image updates). Supply-chain metadata comes from a Trivy SBOM in Phase 11 instead.

### D030: Migrations are expand-only; rollback does not migrate down
- **Date:** 2026-10-07
- **Decision:** `rollback.yml` only rolls the replicas back. Migrations must be additive (expand/contract): a release never drops or renames something the previous release still uses.
- **Why:** Down-migrations are risky and rarely tested. With additive migrations, the previous release runs fine on the newer schema, which is what makes an instant rollback safe.
- **Alternatives:** Paired down-migrations.

### D031: Zero-downtime rolling update with fixed replica names
- **Date:** 2026-10-07
- **Decision:** Per replica: start `api-<env>-N-next` with the same network alias → wait for Docker health (60 s timeout) → pause 6 s → stop the old container (SIGTERM, 15 s grace, uvicorn drains) → `docker rename` next → `api-<env>-N` → pause 6 s. A replica already healthy on the target tag is skipped, so re-running a deploy is a no-op.
- **Why:** The alias makes old and new serve side by side, so capacity never drops. The pauses match nginx's `resolver valid=5s`:
  - Without the first pause, nginx might not know about the new replica yet.
  - Without the second, a smoke test right after the deploy hit a dead IP. That was observed: post-deploy p95 was 509 ms and 503 ms, which failed the 300 ms check. With it, post-deploy p95 is 4 ms.
  - Fixed names keep the healer's and chaos tool's targets stable.
- **Measured:** 0 failed requests in every run (6654, 5765 and 4613 requests during deploys, 4328 during a rollback, 2749 during a failed deploy with auto-rollback).
- **Alternatives:** Blue-green with a second alias and an nginx reload (more moving parts for the same result here).

### D032: nginx `proxy_connect_timeout 500ms` (read/send stay 2 s)
- **Date:** 2026-10-07
- **Decision:** The connect timeout is lowered from 2 s to 500 ms.
- **Why:** During a rolling update, nginx can briefly still hold the IP of a removed replica. Connects to a vanished IP hang until the timeout, then `proxy_next_upstream` retries on a live replica. Measured in the first zero-downtime run, 32 requests waited about 2 s each. After the change, the slowest request in the window was 0.505 s. On a local Docker network a real connect takes well under 1 ms.
- **Next step (not done):** Drain replicas before removal (e.g. a lower resolver TTL, or nginx-plus-style active health checks) so even those 0.5 s retries disappear.

### D033: Ansible `group_vars` live next to the playbooks
- **Date:** 2026-10-07
- **Decision:** `ansible/playbooks/group_vars/all/main.yml` (the plan's layout showed `ansible/group_vars/`).
- **Why:** Ansible only loads `group_vars` adjacent to the inventory or to the playbook. Playbook-adjacent works for both the local and the AWS inventory without duplication.
- **Alternatives:** A copy per inventory.

### D034: ansible-lint runs with the collections from the ansible pipx venv
- **Date:** 2026-10-07
- **Decision:** `make lint-ansible` sets `ANSIBLE_COLLECTIONS_PATH` to the `ansible` pipx venv's site-packages. The lint passes the strictest `production` profile with 0 skips.
- **Why:** ansible-lint is its own pipx app with only ansible-core, so `community.docker` modules were "unknown". The `requests` library was injected into the ansible venv (`pipx inject ansible requests==2.34.2`), which the community.docker modules need.

### D035: 5s scrape and evaluation intervals (demo setting)
- **Date:** 2026-10-07
- **Decision:** `scrape_interval` and `evaluation_interval` are 5s (cAdvisor 10s); `scrape_timeout` is 4s.
- **Why:** Chaos experiments must show up in seconds, and MTTD is measured. Production would use 15–30s to keep storage and CPU cost reasonable.
- **Alternatives:** 15s (MTTD would be dominated by scrape lag).

### D036: SLO windows and the "6h" error budget
- **Date:** 2026-10-07
- **Decision:** Standard multi-window burn rates (fast 1h and 5m at 14.4×, slow 6h and 30m at 6×) against a notional 30-day SLO. "Error budget remaining" on the dashboard is computed over the last 6h.
- **Why:** The lab runs for hours, not 30 days, so a 30-day budget would never move. The windows are the plan's; they need time to fill, so burn alerts only mean something after about 1h of traffic.
- **Alternatives:** Shrink every window ×30 (5m becomes 10s, which is noise at 15–25 rps).

### D037: Grafana dashboards are generated, with a validated palette
- **Date:** 2026-10-07
- **Decision:**
  - `monitoring/grafana/build_dashboards.py` writes the 5 dashboard JSON files (`make dashboards`).
  - Series colours are fixed per entity from a validated palette. The first 3 categorical slots (blue `#3987e5`, orange `#d95926`, aqua `#199e70`) passed every check of the dataviz validator in both light and dark mode, including worst-adjacent CVD ΔE 9.4.
  - Status colours appear only on thresholds. There is one y-axis per chart, legends only for 2+ series, and stat tiles for headline numbers.
  - `scripts/check_dashboards.py` (`make check-dashboards`) runs every panel query against Prometheus and fails on unexpected empty panels.
- **Why:** No click-ops (the plan's requirement); reviewable diffs; colour that stays readable for colour-blind viewers; an automated "loads with data" check.
- **Limitation:** A Grafana fixed colour can't switch with the theme, so the dark-surface steps are used. They also passed against the light surface.

### D038: DB pool `reconnect_timeout` 10s
- **Date:** 2026-10-07
- **Decision:** `DB_RECONNECT_TIMEOUT_SECONDS=10` (psycopg_pool default: 300).
- **Why:** psycopg_pool retries with unbounded doubling (1, 2, 4 … 64 s) until the timeout. Measured: after a ~100 s Postgres outage the API needed **45 s** to become ready after the DB was back. With 10s the retry chain restarts on the next waiting request. Measured after the change: a 100 s outage, then readyz 200 just **1.5 s** after Postgres was ready.
- **Alternatives:** Patch the backoff constants (private API).

### D039: Exporter connect timeouts
- **Date:** 2026-10-07
- **Decision:** `REDIS_EXPORTER_CONNECTION_TIMEOUT=2s`; `connect_timeout=2` in postgres_exporter's DSN.
- **Why:** The first real alert test showed `AdPulseCacheDown` **never fired**. With Redis stopped, an exporter scrape took 9.5s, longer than the 4s scrape timeout, so Prometheus saw the target down (TargetMissing) and never `redis_up == 0`. After the fix, down-scrapes take 0.44s (Redis) and 1.24s (Postgres), and the alerts reach the webhook 27s and 30s after the stop.

### D040: Two rules for AdPulseApiReplicaDown; stable container names
- **Date:** 2026-10-07
- **Decision:**
  - `reason=unreachable`: `up{job="api"} == 0` (hung replica).
  - `reason=missing`: healthy count below the expected 2 (stopped replica).
  - Prometheus also rebuilds cAdvisor's `container` label as `api-<env>-<com.adpulse.replica>`.
- **Why:** With DNS service discovery, a stopped container leaves DNS, so it produces no `up == 0` series at all (promtool test: a stale marker means nothing fires without the second rule). cAdvisor keeps the name a container had at start, so renamed rolling-update containers showed as `api-<env>-N-next`; alerts would then point the healer at a container that doesn't exist.

### D041: The healer scrape job arrives with the healer
- **Date:** 2026-10-07
- **Decision:** `prometheus.yml` gets the `healer` job in Phase 8, not Phase 7.
- **Why:** Scraping a service that isn't deployed would fire TargetMissing permanently.

### D042: Repo-root `ruff.toml`
- **Date:** 2026-10-07
- **Decision:** Python outside `app/` uses a root `ruff.toml` with the same style (line length 120).
- **Why:** Otherwise the pre-commit ruff hooks used defaults (line length 88) for scripts and blocked commits.

### D043: The healer reaches Docker only through docker-socket-proxy
- **Date:** 2026-10-07
- **Decision:** tecnativa/docker-socket-proxy v0.5.0 (pinned by digest) mounts the Docker socket read-only. It allows only `CONTAINERS, IMAGES, NETWORKS, EXEC, INFO, VERSION, POST`; everything else (volumes, system, build, swarm, secrets, events…) answers **403**, which was verified with `docker volume ls`. It sits on an `internal: true` network shared only with the healer, which uses `DOCKER_HOST=tcp://docker-socket-proxy:2375`.
- **Why:** Raw socket access equals root on the host. The proxy limits a compromised healer to container operations. The proxy runs as root (it must read the socket) but has no capabilities, a read-only rootfs, and no route out.
- **Residual risk:** `CONTAINERS + POST` still allows creating containers, and a container could mount host paths. Accepted for the lab and recorded in SECURITY.md (Phase 11). A stricter proxy would filter request bodies.
- **Alternatives:** Mount `/var/run/docker.sock` directly (the plan's fallback) — rejected.

### D044: The healer runs as the host uid with the adpulse group
- **Date:** 2026-10-07
- **Decision:** `user = "<host uid>:10001"`.
- **Why:** It must write `<repo>/incidents` (heal log, diagnostics) on the host, which is owned by the host user. It must also read `/opt/adpulse`, which Puppet hardened to 0750 adpulse:adpulse; the first attempt as `uid:uid` failed with "uvicorn: not found" (permission denied). Ansible temp dirs are pinned to `/tmp` because uid 1000 maps to the image's `ubuntu` user, whose home is on the read-only rootfs (second live failure).

### D045: Heal playbooks act through Ansible + the docker CLI, never with secrets
- **Date:** 2026-10-07
- **Decision:** Restarts use `docker restart` / `docker start` on the existing containers, which keep their config. `scale_api` clones a running replica's image, env and limits, so the healer never needs `.env`. A replica that is gone entirely (removed) cannot be healed: the playbook fails and the healer escalates ("a deploy is needed").
- **Why:** Least privilege: the healer holds no database or Redis passwords.

### D046: Docker label keys with dots need `.get()` in Jinja
- **Date:** 2026-10-07
- **Decision:** Read labels like `c.Labels.get('com.adpulse.replica')`, never with `map(attribute='com.adpulse.replica')`. Use `docker_host_info` with `verbose_output: true`.
- **Why:** Found by `make test-heal`. `map(attribute=…)` treats the dots as a nested path and silently returned the default, and the non-verbose container summary has no Labels or State at all. That also silently broke the Phase 6 deploy's detection of healer-scaled replicas; it is fixed in `tasks/rolling_update.yml` too.

### D047: HealerEscalated also fires for a brand-new escalation series
- **Date:** 2026-10-07
- **Decision:** `increase(x[5m]) > 0 or (x > 0 unless x offset 5m)`, plus `honor_labels: true` on the healer scrape job.
- **Why:** Three real escalations during development never fired the alert. An escalation label set first appears with value 1, and `increase()` needs a prior sample. And without `honor_labels`, the healer's `env` label was renamed to `exported_env` (the target's `env="monitoring"` won), so the alert would have named the wrong env. promtool test added. Live result: the alert fires 10 s after a failed heal, with env=staging.

### D048: Heal playbooks have their own live test (`make test-heal`)
- **Date:** 2026-10-07
- **Decision:** `scripts/test_heal_playbooks.sh` runs all 8 playbooks (11 checks) inside the running healer against staging, under an Alertmanager silence so the live healer doesn't act at the same time.
- **Why:** Two live-test attempts failed on bugs that a direct test finds in minutes, so each playbook is now proven before relying on the alert chain.

### D049: `keep_firing_for: 30s` on outage alerts
- **Date:** 2026-10-07
- **Decision:** AdPulseDatabaseDown, AdPulseCacheDown and both AdPulseApiReplicaDown rules keep firing for 30 s after their expression goes empty.
- **Why:** Real incident (RCA 2026-10-07-1100-db-down-staging): during the outage, exporter scrapes sometimes hit the 4 s timeout. The missing `pg_up` sample reset the alert to pending, so it never stayed firing for Alertmanager's 10 s `group_wait`. The healer was never notified, and staging served 94.2% house ads for 10 minutes. A promtool test with scrape gaps now guards this.
- **Alternatives:** `or up{job="postgres"} == 0` (would restart the DB when only the exporter dies).

### D050: Exporters and Toxiproxy use a dead upstream DNS (`dns = ["127.0.0.1"]`)
- **Date:** 2026-10-07
- **Decision:** These containers only ever resolve Docker names, so their upstream resolver is set to nothing. For a *stopped* container's name, Docker's embedded DNS then answers "no such host" immediately.
- **Why:** Measured on this network: resolving a stopped container's name took ~5.2 s (Docker forwards unknown names upstream). Exporter scrapes with the DB down took 3.7–9.0 s (Postgres) and 2.2–4.5 s (Redis). After the change: 1.2–2.0 s and 0.2–0.4 s. Setting `connect_timeout=1` alone did not help, because it does not bound the DNS phase.
- **Alternatives:** Static IPs for DB containers (more config to keep in sync).

### D051: Two network-latency scenarios
- **Date:** 2026-10-07
- **Decision:** `net-latency` (the plan's: +300 ms on Redis) and `net-latency-datapath` (+300 ms on Redis and Postgres). Jugal chose this after a pre-experiment measurement.
- **Why:** A 20 s measurement showed that the plan's version cannot trip the p95 alert: the 200 ms Redis timeout caps requests at ~205 ms. The run confirmed it: p95 peak 0.247 s, 4,842 cache errors, no alert. That is a valid finding (a detection gap). The second variant exercises the latency alert → `diagnose_latency` → human path.

### D052: Chaos `memory_leak` can plateau (`max_mb`)
- **Date:** 2026-10-07
- **Decision:** New query parameter `max_mb`. The mem-leak scenario uses 10 MB/s up to 190 MB (~94% of 256 MiB).
- **Why:** An uncapped leak OOM-kills the container in ~20 s. Docker's restart policy then "heals" it before ApiContainerMemoryHigh's 30 s window, so the healer is never exercised and in-flight requests fail.

### D053: Chaos tool design
- **Date:** 2026-10-07
- **Decision:**
  - The tool waits for "quiet" (no active alerts) before each run and records a 5 s baseline.
  - It probes `/v1/ad` through nginx every 1 s. A *good* probe is 200, a non-fallback ad, and under 250 ms.
  - "recovered" = scenario-specific health check + 3 consecutive good probes. Replica health means `/healthz` really answers, because Docker's health status lags.
  - It verifies the injection actually happened (cpu-hog).
  - Cleanup in `finally`, and `stop` cleans every fault type.
  - Heal events are read from the heal log after recovery, since the healer logs only when its playbook finishes.
  - Prod requires `--confirm-prod`.
- **Why:** Each rule fixes a real failure seen while running the experiments: a premature "recovered" in api-hang, a no-op cpu-hog (read-only rootfs), and missing heal events.

### D054: RCA evidence is persisted, with an exact window
- **Date:** 2026-10-07
- **Decision:** `tools/rca.py` writes `incidents/<id>/evidence.json` (PromQL plus values over exactly injection → alert resolved). `SUMMARY.md` is built only from `timeline.json`, `evidence.json` and optional `note.txt`.
- **Why:** With ±60 s padding, back-to-back runs counted each other's errors (the cache-down report first showed 25 fallback ads that belonged to the next db-down run). Persisting evidence keeps the summary reproducible after Prometheus data is gone.

### D055: Raw evidence files are never rewritten by pre-commit
- **Date:** 2026-10-07
- **Decision:** `end-of-file-fixer` and `trailing-whitespace` exclude `^incidents/`.
- **Why:** The hooks "fixed" psql output in a diagnostics file; evidence must stay byte-for-byte as captured. gitleaks still scans it.

### D056: Prod approval is a manual "Promote to prod" workflow
- **Date:** 2026-10-07
- **Decision:** `promote.yml` (workflow_dispatch). It only deploys the release staging currently runs, and only if staging's smoke test passes at that moment; prod is rolled back automatically if its own smoke test fails.
- **Why:** Q6. GitHub refused "required reviewers" for this private repo on the current plan (HTTP 422: "ensure the billing plan supports the required reviewers protection rule"). A dispatch-only workflow gives the same human gate. Verified: dispatching an older tag (`e7337dc`) was refused.
- **Alternatives:** GitHub Pro (paid); a public repo (unsafe with a self-hosted runner).

### D057: CD via `workflow_run`, on a self-hosted runner, with a clean environment
- **Date:** 2026-10-07
- **Decision:**
  - `cd.yml` triggers on `workflow_run` of CI (completed, branch main), and only runs when `conclusion == success`, `event == push`, and the head repository is this repo.
  - Runner `adpulse-laptop` (labels `self-hosted, Linux, X64, adpulse-local`, v2.338.0, sha256 verified) runs from a terminal (Q5, no sudo).
  - Its `.path` is a clean PATH (no conda or other-project venvs), and its `.env` sets `ADPULSE_HOME`, so Ansible reads `.env` and `deploy/state` from the real working copy instead of the job checkout.
  - Deploy jobs share the `deploy` concurrency group.
- **Why:** Deploys never happen for PRs or forks (verified: no CD run for the PR branch), and CI must pass first. Release history (`deploy/state`) must be shared between manual and CD deploys, or rollback would not know the previous tag.
- **Alternatives:** Dependent jobs in one workflow (would put the self-hosted runner in the PR path).

### D058: CI design
- **Date:** 2026-10-07
- **Decision:**
  - 4 parallel jobs on ubuntu-latest: lint, test, build, security.
  - Each job builds the images it needs: no artifact passing; wall time 2.4–5.3 min per job on the first run.
  - Actions are pinned by commit SHA (checkout v7.0.1, setup-python v7.0.0, setup-terraform v4.0.1).
  - Lint tools are pinned in `.github/ci-requirements.txt`.
  - The Redis service container has no password, because services cannot pass a command (CI-only, ephemeral).
  - Most steps call the same `make` targets used locally.
- **Not done:** SARIF upload to code scanning, which needs GitHub Advanced Security on a private repo. The Trivy output is in the job log instead.

### D059: Remove `gosu` from the Postgres image
- **Date:** 2026-10-07
- **Decision:** `rm -f /usr/local/bin/gosu` at build time; Postgres always runs as uid 999 (Terraform, and now the image test too).
- **Why:** Trivy found 1 fixable CRITICAL (CVE-2025-68121, Go stdlib in gosu) and 21 fixable HIGH, all in that one binary. gosu only exists to drop root privileges in the entrypoint, which AdPulse never uses. After removal: 0 CRITICAL, 0 HIGH fixable; all 14 image checks still pass.

### D060: Readiness gate in the rolling deploy
- **Date:** 2026-10-07
- **Decision:** After Docker health (liveness), each new replica must return `/readyz` 200 within 20 s before the old one is removed; otherwise the deploy fails and Ansible rolls back.
- **Why:** The deploy-bad-release incident: a release that was alive but not ready replaced both staging replicas, and only the post-deploy smoke test caught it (MTTD 103.7 s). Verified afterwards with a locally built broken image: the deploy failed at replica 1's gate after 55 s and staging kept the good release.

### D061: The test image pins `BROKEN_RELEASE=false`
- **Date:** 2026-10-07
- **Decision:** `ENV BROKEN_RELEASE=false` in the API image's test stage.
- **Why:** Unit tests must run with controlled settings, and the rollback demo needed a defect that tests cannot see (an environment flag) but a real environment can. Without the pin, CI would have blocked the demo release before it reached staging.

### D062: Every image defaults to a non-root USER
- **Date:** 2026-10-07
- **Decision:** `adpulse-base` ends with `USER adpulse`, `adpulse-postgres` with `USER postgres`, the Puppet tools image with `USER nobody` (HOME=/tmp). Derived images switch to `USER root` only for their install steps.
- **Why:** Trivy config scan DS-0002 (HIGH) in 3 Dockerfiles. Runtime users were already non-root via Terraform and Ansible, but an image's default should be safe too, so a plain `docker run` can't run as root. Verified: all tests, the Postgres image checks and puppet-lint pass; config scan 0 findings.

### D063: AWS sizing and region
- **Date:** 2026-10-07
- **Decision:** ap-south-1 (Mumbai) and c7i-flex.large (2 vCPU / 4 GiB, $0.0848/h), Ubuntu 24.04 AMI looked up from Canonical's owner ID with an x86_64 filter.
- **Why:** Q7: latency was measured as HTTPS first byte, because a transparent proxy on the campus network made TCP connect times a meaningless 3 ms for every region (Mumbai 128 ms vs Hyderabad 107 ms; Mumbai has the widest instance availability). Q8: the measured stack used ≈ 783 MiB plus OS, Docker and bootstrap, so 2 GiB would be tight, and ~$2/day is about 1.7% of the $120 credits. Prices came from AWS's public pricing data, because the least-privilege IAM user cannot call the Pricing API.

### D064: One VM; Docker over SSH with the same Terraform modules
- **Date:** 2026-10-07
- **Decision:** `infra/terraform/aws` creates the network and the VM. `infra/terraform/envs/aws` drives the VM's Docker with the **same** `adpulse_stack` and `monitoring_stack` modules over `ssh://ubuntu@host`. Images ship with `docker save | gzip` → Ansible copy → `docker load` (255 MB, 67 s), with no registry.
- **Why:** The plan's design: one definition of the stack, run locally and in the cloud. It worked on the first apply (36 resources in 61 s), so the compose fallback was not needed. All the local fixes (keep_firing_for, fast-fail exporter DNS, readiness gate) applied unchanged.
- **Notes:**
  - The provider download from GitHub release assets timed out on the campus network, so `terraform init -plugin-dir` used the identical local provider, checked against the same lock-file hashes.
  - The docker CLI's SSH transport cannot take a key flag, so a short-lived `ssh-agent` is used and `~/.ssh/config` is left untouched.

### D065: Environment-agnostic monitoring rules
- **Date:** 2026-10-07
- **Decision:** `env:adpulse_api_replicas_expected:count` = `count by (env)(up{job="postgres"}) * 0 + 2`, which means every env that has a Postgres exporter expects 2 replicas. `prometheus.aws.yml` lists only aws-prod targets; Ansible installs it as `prometheus.yml` on the VM, and promtool lints both files.
- **Why:** The hard-coded staging/prod expectation would have fired "replica missing" for two absent envs on AWS. Finding: the new rule fires for a brand-new env in the minute between Terraform creating it and the first deploy. The healer correctly escalated (`replicas=[]`). Action: silence a new env's API alerts until its first deploy.

### D066: Grafana on AWS was not used through the tunnel
- **Date:** 2026-10-07
- **Decision:** The Grafana screenshot is from the local Grafana.
- **Why:** Through the SSH tunnel (local port 13000), the browser could not load the Prometheus plugin, because Grafana's `appUrl` is `http://localhost:3000/`, making it a cross-origin request to the *local* Grafana. The fix (`GF_SERVER_ROOT_URL=http://localhost:13000/`) was not worth another apply for a screenshot. Prometheus on AWS was verified directly (9/9 targets up).
