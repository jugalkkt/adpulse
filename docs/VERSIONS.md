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
| git | 2.51.0 | Ubuntu |
| GNU Make | 4.4.1 | Ubuntu |
| jq | 1.8.1 | Ubuntu (`/usr/bin/jq`; conda's jq 1.6 comes first on PATH, so scripts call `/usr/bin/jq`) |
| Python (system) | 3.13.7 | Ubuntu (`/usr/bin/python3`) |

Host facts: x86_64, 8 CPUs, 15 GiB RAM, cgroup v2, Docker storage driver `overlayfs`, Docker root `/var/lib/docker` on `/` (75 GB free).

## Container images

| Image | Tag | Digest | Used for |
|---|---|---|---|
| ubuntu | 24.04 | `sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55` | base image, puppet tools image |
| zricethezav/gitleaks | v8.30.0 | `sha256:691af3c7c5a48b16f187ce3446d5f194838f91238f27270ed36eef6359a574d9` | pre-commit secret scan |

_More are added from Phase 2 onwards._

## Config-management tools (inside containers only)

| Tool | Version | Where |
|---|---|---|
| OpenVox agent (Puppet) | 8.29.0-1+ubuntu24.04 (repo `openvox8`) | `docker/base/Dockerfile` (purged after apply), `docker/tools/puppet.Dockerfile` |
| puppet-lint | 5.1.1 (rubygems) | `docker/tools/puppet.Dockerfile` |

## Pre-commit hooks (`.pre-commit-config.yaml`, pinned via `pre-commit autoupdate` on 2026-10-07)

pre-commit-hooks v6.0.0, ruff-pre-commit v0.16.10, pre-commit-terraform v1.109.2, yamllint v1.38.0. gitleaks and shellcheck are local hooks (see D007).

## Python libraries

_Filled in in Phase 3 (`app/requirements.txt`)._
