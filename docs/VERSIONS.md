# Versions

Every tool, image and library, pinned exactly (plan rule R5). Looked up at build time, not from memory.

## Host tools (Phase 0, verified 2026-10-07)

| Tool | Version | Source |
|---|---|---|
| Docker Engine (docker-ce) | 29.8.2 | download.docker.com apt repo, suite `noble` |
| containerd.io | 2.3.6 | download.docker.com apt repo, suite `noble` |
| Docker Compose plugin | 5.6.0 | download.docker.com apt repo, suite `noble` |
| Docker Buildx plugin | 0.37.1 | download.docker.com apt repo, suite `noble` |
| Terraform | 1.16.5 | apt.releases.hashicorp.com, suite `noble` |
| AWS CLI | 2.37.10 | official zip, signature verified (key `FB5D…475C`) |
| GitHub CLI (gh) | 2.102.0 | cli.github.com apt repo, suite `stable` |
| shellcheck | 0.10.0 | Ubuntu 25.10 archive |
| Ansible (package) | 14.5.0 (ansible-core 2.21.5) | pipx, Python 3.13.7 |
| ansible-lint | 26.9.0 | pipx |
| pre-commit | 4.6.2 | pipx |
| community.docker (Ansible collection) | 5.4.0 | bundled with ansible 14.5.0 |
| requests (in the ansible pipx venv) | 2.34.2 | `pipx inject ansible requests==2.34.2` |
| git | 2.51.0 | Ubuntu |
| GNU Make | 4.4.1 | Ubuntu |
| jq | 1.8.1 | Ubuntu (`/usr/bin/jq`; conda's jq 1.6 comes first on PATH, so scripts call `/usr/bin/jq`) |
| Python (system) | 3.13.7 | Ubuntu (`/usr/bin/python3`) |

Host facts: x86_64, 8 CPUs, 15 GiB RAM, cgroup v2, Docker storage driver `overlayfs`, Docker root `/var/lib/docker` on `/` (75 GB free).

## Container images

| Image | Tag | Digest | Used for |
|---|---|---|---|
| ubuntu | 24.04 | `sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55` | base image, puppet tools image |
| postgres | 18.6-trixie | `sha256:fc973eb97c9fd04bfa1840e0f510719a584ccb3be8debfe6a4144637a9dfe8cf` | test DB (Phase 3); base of the adpulse-postgres image (Phase 4) |
| redis | 8.10.2-alpine | `sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0` | test cache; runtime cache |
| prom/prometheus | v3.15.0 | `sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e` | promtool checks (Phase 4+), Prometheus (Phase 7) |
| cincproject/workstation | 26.3.0 | `sha256:b19f9949b1012e5a9cd93b68ee1d00b705fc66e1d47f4283471cddf293500830` | cookstyle lint |
| nginxinc/nginx-unprivileged | 1.30.5-alpine (stable line) | `sha256:15c994d10d6d78658721c3bcafff14cb281fba2a4bdf9d5ba92c416a472516e3` | load balancer |
| ghcr.io/shopify/toxiproxy | 2.12.0 | `sha256:9378ed52a28bc50edc1350f936f518f31fa95f0d15917d6eb40b8e376d1a214e` | fault injection proxy |
| quay.io/prometheuscommunity/postgres-exporter | v0.20.1 | `sha256:ac5ec343104fae0e2d84a27bb8d69b38430a11910c5382cad85d478d2bab713e` | DB metrics |
| oliver006/redis_exporter | v1.93.0-alpine | `sha256:93831cd4d5d67687de67c9d5221b14312fea580af8d157583ed9d4459bf2dd70` | cache metrics |
| prom/alertmanager | v0.34.1 | `sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a` | alert routing |
| grafana/grafana | 13.2.3 | `sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572` | dashboards |
| prom/node-exporter | v1.12.1 | `sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0` | host metrics + textfile |
| ghcr.io/google/cadvisor | v0.60.6 | `sha256:b8e7d1093144fd088f425ff003d75a4aa405de075db78dae3bc563730b1bd07a` | container metrics |
| zricethezav/gitleaks | v8.30.0 | `sha256:691af3c7c5a48b16f187ce3446d5f194838f91238f27270ed36eef6359a574d9` | pre-commit secret scan |

_More are added from Phase 2 onwards._

## Terraform

| Item | Version |
|---|---|
| Terraform CLI | 1.16.5 |
| kreuzwerker/docker provider | 4.6.0 (latest on 2026-10-07; lock files committed) |

## Config-management tools (inside containers only)

| Tool | Version | Where |
|---|---|---|
| OpenVox agent (Puppet) | 8.29.0-1+ubuntu24.04 (repo `openvox8`) | `docker/base/Dockerfile` (purged after apply), `docker/tools/puppet.Dockerfile` |
| puppet-lint | 5.1.1 (rubygems) | `docker/tools/puppet.Dockerfile` |
| Cinc Client (Chef) | 19.3.14 (Debian 13 .deb, sha256 `a6094f97…aeefebd`) | `docker/postgres/Dockerfile` (purged after converge) |
| cookstyle | from Cinc Workstation 26.3.0 | `make lint-chef` |

## Pre-commit hooks (`.pre-commit-config.yaml`, pinned via `pre-commit autoupdate` on 2026-10-07)

pre-commit-hooks v6.0.0, ruff-pre-commit v0.16.10, pre-commit-terraform v1.109.2, yamllint v1.38.0. gitleaks and shellcheck are local hooks (see D007).

## Python libraries

Python 3.12.3 (from Ubuntu 24.04 in adpulse-base). Full lock with hashes: `app/requirements.txt`, `app/requirements-dev.txt` (pip-tools 7.6.2).

| Package | Version | Role |
|---|---|---|
| fastapi | 0.142.2 | web framework |
| starlette | 1.7.0 | (via fastapi) |
| uvicorn | 0.54.0 | ASGI server |
| psycopg[binary] | 3.3.6 | PostgreSQL driver |
| psycopg-pool | 3.3.3 | async connection pool |
| redis | 8.1.0 | Redis client (asyncio) |
| prometheus-client | 0.26.0 | metrics |
| pydantic / pydantic-settings | 2.13.5 / 2.15.0 | validation, env config |
| httpx | 0.28.1 | loadgen HTTP client, TestClient |
| pytest / pytest-asyncio | 9.1.1 / 1.4.0 | tests (dev) |
| ruff | 0.16.10 | lint + format (dev) |
