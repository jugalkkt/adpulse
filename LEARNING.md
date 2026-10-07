# Learning AdPulse

This guide is for Jugal, who had used none of these tools before this project. It explains what each piece does, why it was built this way, and how to learn it using this repo as a lab. Read part 1 first; the rest can be read in any order.

Every number quoted here was measured in this repo on 2026-10-07 (see `docs/rca/SUMMARY.md` and `PROGRESS.md`).

**Contents**
1. [The big picture: what `make up` does](#1-the-big-picture-what-make-up-does)
2. [The tools, one by one](#2-the-tools-one-by-one)
3. [SRE glossary](#3-sre-glossary)
4. [Why things are built this way](#4-why-things-are-built-this-way)
5. [A 2-week self-study plan](#5-a-2-week-self-study-plan)

---

## 1. The big picture: what `make up` does

The product is tiny: an API that answers "give me an ad for a *sports* page and a *student* visitor". Everything else in the repo exists to keep that API **available**, **observable** and **repairable**. `make up` builds the whole thing from nothing. In order:

1. **`make secrets`** creates `.env` with random passwords (database, Redis, Grafana). The file is mode 600 and gitignored. Nothing secret is ever committed.
2. **`make build`** builds five Docker images, each tagged with the current git commit (for example `adpulse-api:cdee903`):
   - `adpulse-base`: Ubuntu 24.04. **Puppet** runs *inside the build* to harden it: a non-root user, no setuid binaries, locked-down file permissions. Then Puppet is uninstalled, so it never ships.
   - `adpulse-api`: the FastAPI app on top of the base image.
   - `adpulse-postgres`: PostgreSQL. **Chef** runs inside the build to write `postgresql.conf`, `pg_hba.conf` and the backup scripts. Then Chef is uninstalled too.
   - `adpulse-healer`: the self-healing service.
   - `adpulse-chaos-stress`: a stress tool, used only to break things on purpose.
3. **`make monitoring`** has **Terraform** create the monitoring stack: Prometheus, Alertmanager, Grafana, node-exporter, cAdvisor, the healer and its docker-socket-proxy.
4. **`make infra ENV=staging`** and **`ENV=prod`** have **Terraform** create each environment: a private Docker network, PostgreSQL, Redis, Toxiproxy (a "fault switch" between the API and its databases), nginx (the load balancer), a backup agent, two exporters and a load generator. Both use the *same* Terraform module with different variables; that is the point of a module.
5. **`make monitoring`** runs again so Prometheus joins the env networks that now exist (D021).
6. **`make deploy ENV=…`**: **Ansible** runs database migrations, then starts the two API replicas one at a time. Each new replica must pass `/readyz` before the old one stops, so users never see an error.
7. **`make smoke ENV=…`** makes real requests through nginx and fails if anything is wrong.

After that the system runs itself:

- `loadgen` sends steady traffic (15 requests/s to staging, 25 to prod).
- **Prometheus** scrapes metrics every 5 s and evaluates alert rules.
- When a rule fires, **Alertmanager** sends it to the **healer**, which runs an **Ansible** playbook to fix it. For example, `AdPulseDatabaseDown` triggers `restart_db.yml`.
- **Grafana** shows all of it, with a marker on the graph for every healing action.

### The two layers of healing

| Layer | Who | Handles | Example |
|---|---|---|---|
| 1 | Docker itself (`restart: unless-stopped`, health checks) | a process that **crashes** | the API is OOM-killed, so Docker restarts it in seconds |
| 2 | Prometheus → Alertmanager → healer → Ansible | everything Docker can't see | a replica **removed** entirely, the database stopped, a disk that *will* fill in 10 minutes, a noisy neighbour eating CPU, 30 % errors from a process that is technically "up" |

Layer 2 is deliberately limited. Only playbooks listed in `healer/healing.yml` can run. Each one has a cooldown and a maximum number of attempts, after which the healer **escalates** (fires `HealerEscalated`) instead of retrying forever. Some alerts, like high latency, only collect evidence, because restarting something would hide the cause.

### Where the rest fits

- **CI/CD** (GitHub Actions) runs the same `make` targets: CI checks every push, CD deploys to staging, and a "Promote" button deploys the same release to prod.
- **Chaos** (`make chaos SCENARIO=db-down ENV=staging`) breaks one thing and records exactly when it broke, when the alert fired and when it recovered. `make rca` turns that into a written root cause analysis.
- **AWS** (Phase 12) ran the same modules on one EC2 VM, which was destroyed the same day.

---

## 2. The tools, one by one

Each section covers the problem the tool solves (with an everyday analogy), its core concepts, where it lives in this repo, five commands to try, and one common mistake.

> Run the commands from the repo root (`~/projects/adpulse`) while the stack is up (`make up`). `TAG` means the current release: `TAG=$(git rev-parse --short HEAD)`.

### 2.1 Docker

**Problem.** "It works on my machine." An app needs a specific OS, libraries and config. Docker packages all of that into an **image** and runs it as an isolated **container**.
**Analogy.** An image is a frozen meal, sealed with everything in it. A container is that meal heated up and on a plate. You can heat up many plates from the same frozen meal.

**Core concepts**
- **Image**: a read-only template built from a `Dockerfile`, in **layers**.
- **Container**: a running instance of an image.
- **Tag and digest**: `redis:8.10.2-alpine` is a tag, which can move. `@sha256:3811…` is a digest, which never changes. This repo pins both.
- **Network**: containers on the same Docker network reach each other by name (`postgres-staging`).
- **Volume**: storage that outlives the container (database files).
- **Labels**: key/value tags. Every AdPulse object carries `com.adpulse.project=adpulse`, so cleanup never touches anything else.
- **Health check**: a command Docker runs to decide whether a container is *healthy*.

**In this repo:** `docker/*/Dockerfile`, `.dockerignore` (an allow-list, D011), `Makefile` (`build-*`).

**Try it**
| Command | What you should see |
|---|---|
| `docker ps --filter label=com.adpulse.project=adpulse --format '{{.Names}}\t{{.Status}}'` | about 27 containers, all `Up … (healthy)` except `loadgen-*` (no health check) |
| `docker image ls --filter label=com.adpulse.project=adpulse` | the five `adpulse-*` images, each with a commit tag and `dev` |
| `docker inspect api-staging-1 --format '{{.Config.User}} {{.HostConfig.ReadonlyRootfs}} {{.HostConfig.CapDrop}}'` | `adpulse true [ALL]`: non-root, read-only root filesystem, every Linux capability dropped |
| `docker stats --no-stream --format '{{.Name}} {{.MemUsage}}' \| sort` | each container's memory use against its limit (e.g. `… / 256MiB`) |
| `docker network inspect adpulse-staging --format '{{range .Containers}}{{.Name}} {{end}}'` | everything in staging, plus `prometheus`, which joins to scrape it |

**Common mistake.** Running `docker system prune -a` to "clean up". It deletes *every* unused image and volume on the machine, not just this project's. Always filter by label instead.

### 2.2 Terraform

**Problem.** Clicking around (or typing `docker run …`) to create infrastructure can't be reviewed, repeated or undone reliably. Terraform describes the infrastructure you *want* in code and works out how to get there.
**Analogy.** An architect's blueprint plus a builder. You change the blueprint, the builder shows exactly which walls they'll add or knock down (**plan**), and only then do they build it (**apply**).

**Core concepts**
- **Provider**: a plugin that talks to one platform. This repo uses `kreuzwerker/docker` for local Docker and `hashicorp/aws` for AWS.
- **Resource**: one thing to manage (`docker_container`, `aws_instance`).
- **Data source**: something to *look up* without managing it (`data "docker_image"`, the Ubuntu AMI).
- **State**: Terraform's record of what it created (`terraform.tfstate`). It can contain secrets, so here it is local and gitignored.
- **Plan / apply / destroy**: preview, execute, tear down. The AWS steps always applied a *saved* plan file, so what ran was exactly what was reviewed.
- **Workspace**: separate state for the same code. `envs/local` has the workspaces `staging` and `prod`.
- **Module**: reusable code with inputs. `modules/adpulse_stack` defines one whole environment and is used three times: staging, prod and aws-prod.

**In this repo:** `infra/terraform/modules/` (the building blocks), `envs/local` (staging/prod), `monitoring/local`, `aws` (VPC + EC2), `envs/aws` (the stack on the VM, over SSH).

**Try it**
| Command | What you should see |
|---|---|
| `terraform -chdir=infra/terraform/envs/local workspace list` | `default`, `prod` and `staging`, with `*` on the selected one |
| `make plan-infra ENV=staging TAG=$TAG` | `No changes. Your infrastructure matches the configuration.` |
| `terraform -chdir=infra/terraform/envs/local state list \| head` | resource addresses such as `module.stack.docker_container.postgres` |
| `docker stop redis-exporter-staging && make plan-infra ENV=staging TAG=$TAG` | Terraform notices the drift and plans to fix it. Then `make infra ENV=staging TAG=$TAG` puts it back. |
| `make lint-terraform` | `terraform fmt -check` and `validate` pass in every root |

**Common mistake.** Changing infrastructure by hand (for example `docker rm postgres-staging`) and forgetting about it. Terraform will put it back on the next apply, which is good, but the hand change was never reviewed. The other classic mistake is committing `terraform.tfstate`, which leaks secrets.

### 2.3 Puppet (OpenVox)

**Problem.** Every server must end up in the same, secure state: these users exist, SSH refuses passwords, the firewall is on. Doing that by hand on many machines drifts apart over time. Puppet *declares* the desired state and enforces it.
**Analogy.** A building inspector with a checklist. They walk through, fix anything that doesn't match ("this door must lock"), and if everything already matches, they change nothing.

**Core concepts**
- **Manifest** (`.pp`): code that declares **resources** (`user`, `file`, `package`, `exec`, `service`).
- **Class**: a named group of resources (`adpulse::base`, `adpulse::host`).
- **Module**: a directory of classes and templates.
- **Idempotency**: run it twice and the second run makes **0 changes**. The base image build fails if it doesn't (D009).
- **Ordering**: `require`, `before`, `notify`. For example, the firewall allows port 22 *before* it is enabled, so SSH is never cut off.
- **`--noop`**: report what *would* change without changing anything, which makes it a drift detector.
- **OpenVox**: the community build of Puppet. Same language, same `puppet` command.

**In this repo:** `config/puppet/modules/adpulse/manifests/base.pp` (baked into `adpulse-base`), `host.pp` (the AWS VM: users, sshd, ufw, sysctl, unattended-upgrades), templates in `templates/*.epp`.

**Try it**
| Command | What you should see |
|---|---|
| `make lint-puppet` | `puppet lint: clean` |
| `docker run --rm adpulse-base:dev cat /etc/adpulse/hardening-report.txt` | what Puppet enforced in the image |
| `docker run --rm adpulse-base:dev cat /etc/adpulse/puppet-idempotency.log` | `puppet apply #2: 0 changes (exit 0)` |
| `docker run --rm adpulse-base:dev sh -c 'command -v puppet \|\| echo purged'` | `purged`: the agent did its job and was removed |
| `docker run --rm adpulse-base:dev find / -xdev -perm /6000 -type f` | no output: no setuid/setgid binaries left (D010) |

**Common mistake.** Using `exec` for everything (`exec { 'ufw enable': … }`) without an `unless` or `onlyif` guard. It then runs on every apply, and Puppet is no longer idempotent. See how every `exec` in `host.pp` has a guard.

### 2.4 Chef (Cinc)

**Problem.** The same as Puppet, but Chef is written in Ruby and was used here for one specific node: the **database**. It owns the PostgreSQL configuration and the backup scripts.
**Analogy.** A recipe card. You follow it top to bottom, and each step says what the dish should look like ("the sauce is thick"), not just "stir for 5 minutes".

**Core concepts**
- **Resource**: `template`, `file`, `directory`, `package`.
- **Recipe** (`.rb`): resources in order.
- **Cookbook**: recipes, templates (`.erb`) and attributes.
- **Attributes**: tunable values (`default['adpulse_db']['max_connections'] = 50`).
- **`cinc-solo`** / **local mode**: run a cookbook without a Chef server, which is what this repo does.
- **Converge**: one run. "0/10 resources updated" on the second run proves idempotency.
- **Cinc**: the free community build of Chef. Same code, renamed binaries.

**In this repo:** `config/chef/cookbooks/adpulse_db/` (`recipes/default.rb` for the Postgres image, `recipes/host.rb` for the AWS VM), templates for `postgresql.conf`, `pg_hba.conf` and the backup scripts.

**Try it**
| Command | What you should see |
|---|---|
| `make lint-chef` | `cookstyle: clean` |
| `docker exec postgres-staging cat /etc/adpulse-db/cinc-idempotency.log` | the second converge: `0/10 resources updated` |
| `docker exec postgres-staging cat /etc/adpulse-db/chef-report.txt` | the values Chef rendered (shared_buffers, max_connections, …) |
| `docker exec postgres-staging psql -U postgres -tAc 'SHOW password_encryption'` | `scram-sha-256` (from a Chef attribute) |
| `docker exec backup-agent-staging ls -la /backups` | the dumps written by the Chef-templated backup script |

**Common mistake.** Putting a value straight into a template instead of an attribute. Then it can't be changed per node without editing the template.

### 2.5 Ansible

**Problem.** Some work is a **sequence of steps** across machines: "migrate the DB, then replace replica 1, wait until it's ready, then replica 2". That isn't a desired state; it's a procedure. Ansible runs procedures over SSH (or locally), with no agent to install.
**Analogy.** A checklist that a co-pilot reads out and executes, step by step, stopping if any step fails.

**Core concepts**
- **Inventory**: which hosts. Here it's `localhost`, or the EC2 VM.
- **Playbook**: an ordered list of **tasks**, each calling a **module** (`community.docker.docker_container`, `uri`, `copy`).
- **Variables**: `group_vars`, `-e image_tag=…`.
- **Handlers**: tasks that run only when notified, such as "restart Docker if `daemon.json` changed".
- **`block` / `rescue`**: try/except. The deploy rolls back automatically inside `rescue`.
- **Idempotency** again: redeploying the same tag skips every task (19 skipped in Phase 6).
- **Collections**: packs of modules (`community.docker`).

**In this repo:** `ansible/playbooks/deploy.yml`, `rollback.yml`, `migrate.yml`, `tasks/rolling_update.yml` (the zero-downtime logic), `heal/*.yml` (one playbook per fix), `aws_bootstrap.yml`.

**Try it**
| Command | What you should see |
|---|---|
| `make status` | containers, the deployed release per env, and any firing alerts |
| `make deploy ENV=staging TAG=$TAG` | the same tag again: replicas are left alone (tasks `skipped`), `failed=0` |
| `cat deploy/state/staging.json` | `current` and `previous` releases. `make rollback ENV=staging` swaps to `previous`. |
| `bash scripts/test_heal_playbooks.sh` (or `make test-heal`) | each heal playbook runs against the live staging stack and passes |
| `make lint-ansible` | ansible-lint `production` profile, 0 failures |

**Common mistake.** Using `shell:` or `command:` with no `changed_when`. Ansible then reports "changed" on every run and you can't tell whether anything really changed. ansible-lint flags this.

### 2.6 Prometheus

**Problem.** You can't fix what you can't see. Prometheus collects numbers (**metrics**) from every component every few seconds, stores them as time series, and evaluates **rules** on them.
**Analogy.** A nurse taking every patient's pulse and temperature every 5 seconds, writing it on a chart, and pressing the call button when a reading stays bad.

**Core concepts**
- **Scrape**: Prometheus *pulls* `/metrics` from **targets** (the API, exporters, cAdvisor).
- **Exporter**: a sidecar that translates a system's stats into metrics (postgres_exporter, redis_exporter, node-exporter).
- **Metric types**: counter (only goes up: requests), gauge (up and down: memory), histogram (latency buckets).
- **Labels**: `{env="prod", status="500"}`, so one query can cover every env.
- **PromQL**: the query language. `rate(adpulse_http_requests_total[1m])` gives requests per second.
- **Recording rule**: a precomputed query (`env:adpulse_api_replicas_expected:count`).
- **Alert rule**: `expr` + `for:` (it must stay true this long) + `keep_firing_for:` (don't flap off on a single good scrape, D049).
- **`predict_linear`**: trend forecasting ("at this rate, the backup volume is full in 10 minutes").
- **Service discovery**: Prometheus finds API replicas through DNS (`api-<env>`), so new replicas appear automatically.

**In this repo:** `monitoring/prometheus/prometheus.yml`, `rules/recording.yml`, `rules/alerts.yml` (14 alerts), `rules/slo.yml`, `tests/alerts_test.yml` (unit tests for alerts).

**Try it** (open http://127.0.0.1:9090)
| Query or command | What you should see |
|---|---|
| `up` | 1 for every target. Status → Targets shows them all green. |
| `sum by (env) (rate(adpulse_http_requests_total[1m]))` | about 15+ req/s for staging and about 25+ for prod (loadgen plus probes) |
| `histogram_quantile(0.95, sum by (env, le) (rate(adpulse_http_request_duration_seconds_bucket[5m])))` | p95 latency per env, normally a few milliseconds |
| `ALERTS` | empty when healthy; during `make chaos` the alert appears as `pending`, then `firing` |
| `make test-rules` | `SUCCESS`: the promtool unit tests for the alert rules |

**Common mistake.** An alert with no `for:`. It fires on a single bad scrape, and a self-healing system then acts on noise.

### 2.7 Alertmanager

**Problem.** Rules produce *alerts*; humans and robots need *notifications*: grouped, deduplicated, routed and silenceable.
**Analogy.** A hospital switchboard. Twenty beeps about the same patient become one call to the right doctor, and "don't page me during surgery" is a silence.

**Core concepts**
- **Route**: which receiver gets which alert. Here everything goes to the healer's webhook.
- **Grouping**: alerts with the same labels arrive as one notification.
- **Inhibition**: a big alert mutes the smaller ones it explains.
- **Silence**: mute matching alerts for a time window. Every deploy creates one for its env, so the healer doesn't "fix" a replica the deploy is replacing.
- **Resolved notifications**: the healer is told when an alert clears (used by `on_resolved`).

**In this repo:** `monitoring/alertmanager/alertmanager.yml`, `ansible/playbooks/tasks/silence_create.yml`.

**Try it** (open http://127.0.0.1:9093)
| Command | What you should see |
|---|---|
| the Alerts page | empty when healthy |
| `make chaos SCENARIO=replica-down ENV=staging`, then watch the page | `AdPulseApiReplicaDown` appears about 20 s after the injection, then clears when the healer restarts the replica |
| `make deploy ENV=staging TAG=$TAG`, then open Silences | a silence `deploy <tag>` for `env=staging`, expired at the end of the deploy |
| `make lint-monitoring` | `amtool check-config`: SUCCESS |
| `curl -s 127.0.0.1:9093/api/v2/status \| /usr/bin/jq .cluster.status` | `"disabled"` or `"ready"` (a single instance) |

**Common mistake.** Forgetting that a silence also hides a **real** problem. Silences here are short and expire automatically.

### 2.8 Grafana

**Problem.** Numbers in a database are hard to read. Grafana draws dashboards from Prometheus queries.
**Analogy.** The patient monitor screen above the bed.

**Core concepts**
- **Data source**: Prometheus.
- **Dashboard → panels → queries**.
- **Variables**: the `env` drop-down.
- **Annotations**: vertical markers. The healer writes one for every action.
- **Provisioning**: dashboards and data sources are loaded from files at start-up, not clicked together. They are generated by `build_dashboards.py` (D037).

**In this repo:** `monitoring/grafana/build_dashboards.py`, `dashboards/*.json`, `provisioning/`.

**Try it** (http://127.0.0.1:3000, user `admin`, password in `.env`)
| Command | What you should see |
|---|---|
| AdPulse → Overview | request rate, p95 latency, error %, ad source (cache/db/fallback) per env |
| AdPulse → SRE / SLO | availability, the latency SLO and the remaining error budget |
| run a chaos scenario, then look at Overview | a healer annotation marker; hover it for the playbook and its result |
| `make check-dashboards` | every panel query returns data in both envs |
| `make dashboards && git diff --stat` | regenerating gives an identical JSON file (no diff) |

**Common mistake.** Editing a provisioned dashboard in the UI. The change is lost on restart. Change the generator instead.

### 2.9 Toxiproxy

**Problem.** To prove the system survives a slow or broken network, you need to *create* one on demand.
**Analogy.** A water pipe with a valve you can squeeze (latency) or shut (connection down) from the outside.

**Core concepts:** a **proxy** (listen here, forward there) with **toxics** (latency, bandwidth limits, timeouts), controlled through an HTTP API. The API connects to `toxiproxy-<env>:5432` and `:6379`, never to Postgres or Redis directly.

**In this repo:** the container in `modules/adpulse_stack/containers.tf`, the proxy config, and the network scenarios in `chaos/chaos.py`.

**Try it**
| Command | What you should see |
|---|---|
| `make chaos-list` | 10 scenarios with layer, expected alert and expected healer action |
| `make chaos SCENARIO=net-latency-datapath ENV=staging` | p95 rises, `AdPulseHighLatencyP95` fires, the healer collects evidence (`diagnose_latency`), and a human removes the fault |
| `make chaos-stop ENV=staging` | `leftover faults: none` |
| `docker exec toxiproxy-staging /toxiproxy-cli list` | the `postgres` and `redis` proxies, enabled |
| `cat docs/rca/2026-10-07-1147-net-latency-datapath-staging.md` | the RCA for that run |

**Common mistake.** Leaving a toxic in place after an experiment. `chaos-stop` checks for leftovers and reports them.

### 2.10 GitHub Actions

**Problem.** Every change should be tested, scanned and deployed the same way, automatically, not "when someone remembers".
**Analogy.** A factory conveyor belt with quality checks. Nothing reaches the shop shelf (prod) without passing every station, and the last gate needs a human signature.

**Core concepts**
- **Workflow** (`.github/workflows/*.yml`) → **jobs** → **steps**.
- **Trigger**: `push`, `pull_request`, `workflow_run` (CD starts when CI succeeds), `workflow_dispatch` (a manual button).
- **Runner**: GitHub-hosted (CI) or **self-hosted** (`adpulse-laptop`, which can reach local Docker).
- **Pinning actions by commit SHA**, not `@v7`, so an action can't change under you.
- **Artifacts**: files a run keeps, such as the SBOMs.

**In this repo:** `ci.yml` (lint, test, build, security), `cd.yml` (deploy staging, smoke, automatic rollback), `promote.yml` (the manual prod gate).

**Try it**
| Command | What you should see |
|---|---|
| `gh run list -L 5` | recent CI/CD runs and their status |
| `gh run view <id> --log-failed` | only the failing step's log |
| `gh workflow run promote.yml` | promotes staging's release to prod (the runner must be running) |
| `make lint-actions` | actionlint: no findings |
| `cd ~/actions-runner && ./run.sh` | the runner prints `Listening for Jobs` |

**Common mistake.** A self-hosted runner on a **public** repo. Anyone could open a pull request that runs code on your laptop. That's why the repo is private and the runner must be removed before it goes public (see README).

### 2.11 Trivy (and gitleaks)

**Problem.** Images contain hundreds of packages, and some have known vulnerabilities (CVEs). Secrets sometimes slip into git history.
**Analogy.** An airport scanner for luggage (images) and a sniffer dog for the bags already on the plane (git history).

**Core concepts:** a **vulnerability scan** (packages vs a CVE database), **severity** (CRITICAL/HIGH/…), **fixable vs unfixed**, a **misconfiguration scan** (Dockerfiles, Terraform), and an **SBOM** (a CycloneDX list of everything inside an image). The gate here: fail on a **fixable CRITICAL**, report HIGH.

**In this repo:** `scripts/scan.sh`, `make scan`, `make sbom`, the CI `security` job, `.pre-commit-config.yaml` (gitleaks on every commit).

**Try it**
| Command | What you should see |
|---|---|
| `make scan TAG=$TAG` | 0 fixable CRITICAL in the five images, the config scan, then gitleaks `no leaks found` |
| `bash scripts/scan.sh config` | the misconfiguration scan; findings that were accepted are listed in `docs/SECURITY.md` |
| `make sbom TAG=$TAG && /usr/bin/jq '.components \| length' sbom/adpulse-api.cdx.json` | the number of packages in the API image |
| `bash scripts/scan.sh secrets` | gitleaks over the full history: `no leaks found` |
| `git commit` with a fake key in a file | the pre-commit hook blocks the commit |

**Common mistake.** Treating "0 CRITICAL" as "secure". Scanners only know *published* CVEs; configuration (non-root, capabilities, ports) matters just as much. See `docs/SECURITY.md`.

### 2.12 AWS: EC2, VPC, IAM

**Problem.** Run the same system on a real cloud machine, safely and cheaply.
**Analogy.** Renting a flat (EC2) inside a gated community (VPC), with a guard at the gate (security group) who only lets in people on a list (your IP), and keys that only work for named people (IAM).

**Core concepts**
- **Region / AZ**: ap-south-1 (Mumbai) / ap-south-1a.
- **VPC, subnet, internet gateway, route table**: your private network and its way out.
- **Security group**: a stateful firewall. Here it allows 22 and 80 from one /32 only.
- **EC2 instance, AMI, EBS volume**: the VM, its OS image and its disk.
- **Key pair**: SSH with a key, no passwords.
- **IAM user vs root**: the root account is never used for work. The CLI user `adpulse-cli` had EC2 permissions only, and its key was deleted afterwards.
- **IMDSv2**: the metadata service requires a session token, which blocks a classic SSRF credential theft.
- **Default tags**: every resource is tagged `Project=AdPulse`, so the teardown can be verified by tag.

**In this repo:** `infra/terraform/aws/`, `infra/terraform/envs/aws/`, `ansible/playbooks/aws_bootstrap.yml`, `scripts/aws_down.sh`.

**Try it** (only with a new key and an approved plan; this costs credits)
| Command | What you should see |
|---|---|
| `make aws-plan` | `Plan: 11 to add` (VPC, subnet, IGW, route table and association, SG and 2 rules, key pair, instance…) |
| `terraform -chdir=infra/terraform/aws validate` | `Success! The configuration is valid.` (free, no AWS calls) |
| `aws sts get-caller-identity --profile adpulse` | today: `InvalidClientTokenId`, because the key was deleted on purpose |
| `make aws-down` | asks `yes` twice, then lists 0 instances, volumes, IPs, SGs, VPCs and key pairs |
| `grep -n "ingress\|cidr" infra/terraform/aws/main.tf` | the only two ingress rules: `/32` on 22 and 80 |

**Common mistake.** Forgetting to tear down. A free-plan account closes when the credits run out. That's why the teardown was a mandatory step that was verified with the CLI, not just "destroy complete".

---

## 3. SRE glossary

| Term | Meaning | In AdPulse |
|---|---|---|
| **SLI** (indicator) | a measured number describing user experience | % of ad requests that are not 5xx; % served under 150 ms |
| **SLO** (objective) | the target for an SLI over a window | 99.5 % availability; 95 % of requests under 150 ms (`rules/slo.yml`) |
| **SLA** (agreement) | an SLO with a contract and penalties | none: this is internal. SLOs are set tighter than any SLA would be. |
| **Error budget** | 100 % − SLO: the failure you're allowed | 0.5 % of requests. Spend it on releases and experiments, not on outages. |
| **Burn rate** | how fast the budget is being used (1 = exactly on budget) | `ErrorBudgetBurnFast` / `Slow`: multi-window alerts (D036) |
| **MTTD** | mean time to detect: fault → alert firing | 16.0–137.3 s across the chaos runs |
| **MTTR** | mean time to recover: fault → healthy again | 34.4–353.0 s; the database is back in ~40 s |
| **RCA** | root cause analysis: what happened, why, what changes | `docs/rca/*.md`, one per incident |
| **Blameless postmortem** | an RCA that asks "why did the *system* allow this?", not "who?" | e.g. the first db-down: the alert flapped because of DNS, which became a fix, not a blame |
| **Idempotency** | running it again changes nothing if it's already right | Puppet apply #2: 0 changes; Chef converge #2: 0/10; a redeploy of the same tag skips every task |
| **Configuration drift** | a machine slowly differing from its definition | `puppet --noop` on AWS reported 0 changes; `terraform plan` shows drift |
| **Immutable infrastructure** | replace, don't modify | images are rebuilt per commit; replicas are *replaced* on deploy, never patched |
| **Rolling deploy** | replace instances one at a time | `rolling_update.yml` with the readiness gate: 0 failed requests |
| **Blue-green deploy** | run a full new copy, then switch all traffic at once | not used. Rolling needs no double capacity; the `-next` container is a tiny blue-green per replica. |
| **Graceful degradation** | partial service instead of failure | house ads (HTTP 200) when the DB is down: 0 failed probes in every db-down rerun |
| **Toil** | manual, repetitive work that scales with the system | removed by `make up`, the healer, CD and `make rca` |
| **Runbook** | step-by-step instructions for one alert | `docs/runbooks/<Alert>.md`; every alert links to one |
| **Noisy neighbour** | one workload starving others on shared hardware | the `cpu-hog` scenario; the healer's `kill_noisy_neighbor` |

---

## 4. Why things are built this way

The full reasoning is in `docs/DECISIONS.md` (D001–D067). The ideas that matter most:

- **One tool per job** (`docs/ARCHITECTURE.md`): Terraform for what lives long, Puppet and Chef for what's *inside* a machine, Ansible for procedures. Overlap creates two sources of truth.
- **Config management runs at build time, then disappears** (D009, D019). Puppet and Chef configure the images during `docker build` and are purged, so the running containers are smaller and have less to attack. On the AWS VM they run for real, because a VM is long-lived.
- **Pin everything** (R5, D013, D029): images by digest, Python packages by hash, actions by SHA. The same commit builds the same thing.
- **Reproducible image IDs** (D029): without this, Terraform would see a "new" Postgres image on every commit and restart the database.
- **Non-root, read-only, no capabilities** for every container (D027, D062, `SECURITY.md`).
- **Readiness gate in deploys** (D060): health means "the process runs"; readiness means "it can serve". Deploying on health alone could replace a good replica with one that can't reach the DB.
- **Alerts must not flap** (D049, D050): the first `db-down` run was never healed. A slow DNS failure made the exporter time out, the alert switched on and off, and Alertmanager never delivered it. The fix (`keep_firing_for` plus fast-fail DNS) took MTTR from "not healed in 600 s" to 37.5 s.
- **The healer is constrained** (D043–D047): an allow-list, cooldowns, maximum attempts, escalation, a socket proxy instead of the Docker socket, and no secrets.
- **Prod is a deliberate act** (D056): the "Promote" button deploys only the exact release staging runs.
- **The same modules everywhere** (D064): AWS used the local Terraform modules over SSH, so every local fix applied to the cloud unchanged.
- **Destroy safely** (D067): saved plans, an explicit "yes", and verification by tag afterwards.

---

## 5. A 2-week self-study plan

One to two hours a day. Each day ends with something you can *show*.

| Day | Topic | Do this in the repo | Done when |
|---|---|---|---|
| 1 | Linux and Docker basics | §2.1 commands; read `docker/api/Dockerfile` line by line | you can explain each `RUN`, `USER` and `HEALTHCHECK` |
| 2 | Docker networks, volumes, labels | `docker network inspect`, `docker volume ls --filter label=…`; restart `postgres-staging` and watch the data survive | you can draw the staging network from memory |
| 3 | Terraform core | §2.2; read `modules/adpulse_stack/containers.tf`; change nginx's memory limit in a branch, `plan`, then revert | you can read a plan and predict it |
| 4 | Terraform state and modules | `state list`, `state show`; compare `envs/local` and `envs/aws` | you can explain why one module serves three envs |
| 5 | Puppet | §2.3; read `base.pp`, then `host.pp`; add a harmless `file` resource and rebuild the base image | you see "apply #2: 0 changes" again |
| 6 | Chef | §2.4; change `max_connections` in the attributes, rebuild Postgres, `SHOW max_connections` | the new value is live |
| 7 | Review week 1 | explain `make up` (part 1) out loud in 5 minutes | no notes needed |
| 8 | Ansible | §2.5; read `deploy.yml` → `tasks/rolling_update.yml`; deploy and roll back staging | you can explain the readiness gate |
| 9 | Prometheus and PromQL | §2.6; write 5 queries of your own; read `alerts.yml` | you can explain `for` vs `keep_firing_for` |
| 10 | Alertmanager, Grafana | §2.7–2.8; regenerate the dashboards; add a panel in `build_dashboards.py` | your panel shows up in Grafana |
| 11 | Healer and chaos | read `healer/healer/engine.py` and `healing.yml`; run `replica-down`, then `db-down` | you can narrate the timeline of each |
| 12 | RCAs | `make rca ID=…` for your run; compare with `docs/rca/2026-10-07-1100-db-down-staging.md` | your RCA has a real root cause and action items |
| 13 | CI/CD and security | §2.10–2.11; break a lint rule in a PR and watch CI fail; run `make scan` | you can explain why the runner needs a private repo |
| 14 | AWS and interview prep | read `infra/terraform/aws` and `docs/SECURITY.md` §9; practise `docs/INTERVIEW_PREP.md` out loud | the 2-minute pitch without notes |

Free material that matches each week: the official *Docker "Get started"*, HashiCorp's *Terraform "Get started – Docker"* tutorial (the same provider as this repo), the *Ansible "Getting started"* docs, the *Prometheus "First steps"* guide, and Google's free **SRE Book** chapters 3–6 (risk, SLOs, toil, monitoring) and the postmortem chapter.
