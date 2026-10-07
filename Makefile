# AdPulse: single entry point for humans. Run `make help`.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ENV ?= staging
TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
SCENARIO ?=
ID ?=

# --provenance=false: BuildKit's default provenance attestation changes the
# image ID on every build, which would make Terraform recreate containers
# (e.g. restart Postgres) after every commit (docs/DECISIONS.md D029).
BUILD_FLAGS := --provenance=false

# Targets that later phases fill in; they fail loudly until then.
define todo
	@echo "make $@: not implemented yet ($(1))" >&2; exit 1
endef

.PHONY: build-healer lock-healer test-healer grafana-token dashboards check-dashboards lint-monitoring test-rules reload-monitoring migrate smoke lint-ansible check-env plan-infra plan-monitoring lint-terraform help check secrets build build-base build-api build-postgres lock lint lint-puppet lint-chef lint-app tools-puppet test test-postgres scan infra monitoring deploy rollback status \
        up down chaos chaos-stop rca aws-plan aws-up aws-bootstrap aws-deploy aws-down urls

help: ## List targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: ## Print the machine report (OS, tools, ports)
	@bash scripts/machine_report.sh

secrets: ## Create .env from .env.example (never overwrites values)
	@bash scripts/gen_secrets.sh

build: build-base build-api build-postgres build-healer ## Build all images tagged with the git SHA and dev

build-base: ## Build adpulse-base (Ubuntu + Puppet/OpenVox hardening)
	docker build $(BUILD_FLAGS) --progress=plain \
	  -f docker/base/Dockerfile -t adpulse-base:$(TAG) -t adpulse-base:dev .

build-api: build-base ## Build adpulse-api (FROM adpulse-base:<sha>) and its test image
	docker build $(BUILD_FLAGS) --progress=plain --build-arg BASE_IMAGE=adpulse-base:$(TAG) --build-arg GIT_SHA=$(TAG) \
	  -f docker/api/Dockerfile --target runtime -t adpulse-api:$(TAG) -t adpulse-api:dev .
	docker build $(BUILD_FLAGS) -q --build-arg BASE_IMAGE=adpulse-base:$(TAG) --build-arg GIT_SHA=$(TAG) \
	  -f docker/api/Dockerfile --target test -t adpulse-api-test:$(TAG) -t adpulse-api-test:dev .

build-healer: build-base ## Build adpulse-healer (FROM adpulse-base) and its test image
	docker build $(BUILD_FLAGS) --progress=plain --build-arg BASE_IMAGE=adpulse-base:$(TAG) --build-arg GIT_SHA=$(TAG) \
	  -f docker/healer/Dockerfile --target runtime -t adpulse-healer:$(TAG) -t adpulse-healer:dev .
	docker build $(BUILD_FLAGS) -q --build-arg BASE_IMAGE=adpulse-base:$(TAG) --build-arg GIT_SHA=$(TAG) \
	  -f docker/healer/Dockerfile --target test -t adpulse-healer-test:$(TAG) -t adpulse-healer-test:dev .

lock-healer: ## Re-lock healer Python dependencies with hashes
	docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp -e PIP_DEFAULT_TIMEOUT=120 -v "$(CURDIR)/healer:/w" -w /w adpulse-base:dev bash -euo pipefail -c '\
	  python3 -m venv /tmp/v && /tmp/v/bin/pip install -q pip-tools==7.6.2 && \
	  for f in requirements requirements-dev; do \
	    /tmp/v/bin/pip-compile -q --generate-hashes --allow-unsafe --strip-extras --no-header -o $$f.txt $$f.in; done'

test-healer: ## Healer unit tests + ruff (inside the healer test image)
	docker run --rm --network none --read-only --tmpfs /tmp adpulse-healer-test:$(TAG)

build-postgres: ## Build adpulse-postgres (Postgres + Chef/Cinc config + backup scripts)
	docker build $(BUILD_FLAGS) --progress=plain \
	  -f docker/postgres/Dockerfile -t adpulse-postgres:$(TAG) -t adpulse-postgres:dev .

lock: ## Re-lock Python dependencies with hashes (app/requirements*.in -> .txt)
	docker run --rm --user "$$(id -u):$$(id -g)" -e HOME=/tmp -v "$(CURDIR)/app:/w" -w /w adpulse-base:dev bash -euo pipefail -c '\
	  python3 -m venv /tmp/v && /tmp/v/bin/pip install -q pip-tools==7.6.2 && \
	  for f in requirements requirements-dev; do \
	    /tmp/v/bin/pip-compile -q --generate-hashes --allow-unsafe --strip-extras --no-header -o $$f.txt $$f.in; done'

lint: lint-puppet lint-chef lint-app lint-terraform lint-ansible lint-monitoring ## Run all linters

CINC_WORKSTATION := cincproject/workstation:26.3.0@sha256:b19f9949b1012e5a9cd93b68ee1d00b705fc66e1d47f4283471cddf293500830

lint-chef: ## cookstyle on the Chef cookbook (Cinc Workstation container)
	docker run --rm --network none -e HOME=/tmp --user "$$(id -u):$$(id -g)" \
	  -v "$(CURDIR)/config/chef:/work:ro" -w /work $(CINC_WORKSTATION) \
	  cookstyle --no-color --cache-root /tmp cookbooks && echo "cookstyle: clean"

lint-app: ## ruff check + format check (inside the test image)
	docker run --rm --network none --read-only --tmpfs /tmp adpulse-api-test:$(TAG) \
	  bash -c 'ruff check . && ruff format --check . && echo "ruff: clean"'

tools-puppet:
	@docker build -q -f docker/tools/puppet.Dockerfile -t adpulse-tools-puppet:dev docker/tools >/dev/null

lint-puppet: tools-puppet ## puppet parser/epp validate + puppet-lint
	docker run --rm --network none -v "$(CURDIR)/config/puppet:/work:ro" adpulse-tools-puppet:dev bash -euo pipefail -c '\
	  puppet parser validate manifests/site.pp modules/adpulse/manifests/*.pp && \
	  puppet epp validate modules/adpulse/templates/*.epp && \
	  puppet-lint --fail-on-warnings --relative manifests modules && \
	  echo "puppet lint: clean"'

PROM_IMAGE := prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e
AM_IMAGE := prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a

lint-monitoring: ## promtool check config/rules + amtool check-config
	docker run --rm --network none -v "$(CURDIR)/monitoring/prometheus:/etc/prometheus:ro" --entrypoint promtool $(PROM_IMAGE) check config /etc/prometheus/prometheus.yml
	docker run --rm --network none -v "$(CURDIR)/monitoring/alertmanager:/etc/alertmanager:ro" --entrypoint amtool $(AM_IMAGE) check-config /etc/alertmanager/alertmanager.yml

test-rules: ## promtool unit tests for alert rules
	docker run --rm --network none -v "$(CURDIR)/monitoring/prometheus:/etc/prometheus:ro" -w /etc/prometheus/tests --entrypoint promtool $(PROM_IMAGE) test rules alerts_test.yml

dashboards: ## Regenerate Grafana dashboard JSON from monitoring/grafana/build_dashboards.py
	python3 monitoring/grafana/build_dashboards.py

check-dashboards: ## Run every dashboard panel query against Prometheus (both envs)
	/usr/bin/python3 scripts/check_dashboards.py --env staging
	/usr/bin/python3 scripts/check_dashboards.py --env prod | tail -1

reload-monitoring: ## Hot-reload Prometheus and Alertmanager config
	@curl -fsS -X POST http://127.0.0.1:9090/-/reload && echo "prometheus reloaded"
	@curl -fsS -X POST http://127.0.0.1:9093/-/reload && echo "alertmanager reloaded"

test-postgres: ## Behavioural checks of the adpulse-postgres image (settings, auth, backups)
	bash scripts/test_postgres_image.sh adpulse-postgres:$(TAG)

test: ## Unit + integration tests (throwaway Postgres/Redis via compose)
	TAG=$(TAG) docker compose -f app/tests/compose.test.yml up -d --wait postgres redis
	rc=0; TAG=$(TAG) docker compose -f app/tests/compose.test.yml run --rm tests || rc=$$?; \
	  TAG=$(TAG) docker compose -f app/tests/compose.test.yml down -v --remove-orphans; exit $$rc
	$(MAKE) --no-print-directory test-rules
	$(MAKE) --no-print-directory test-healer

scan: ## Trivy image/config scans and gitleaks
	$(call todo,Phase 11)

check-env:
	@case "$(ENV)" in staging|prod) ;; *) echo "ENV must be staging or prod (got '$(ENV)')" >&2; exit 1;; esac

infra: check-env ## Terraform apply for ENV=staging|prod (images for TAG must be built)
	bash scripts/terraform.sh env $(ENV) apply -input=false -auto-approve -var-file=$(ENV).tfvars -var image_tag=$(TAG)

plan-infra: check-env ## Terraform plan for ENV=staging|prod
	bash scripts/terraform.sh env $(ENV) plan -input=false -var-file=$(ENV).tfvars -var image_tag=$(TAG)

HEALER_DRY_RUN ?= false

grafana-token: ## Create/refresh the healer's Grafana service-account token in .env
	bash scripts/grafana_token.sh

monitoring: ## Terraform apply for the monitoring stack (incl. healer)
	bash scripts/grafana_token.sh
	bash scripts/terraform.sh monitoring apply -input=false -auto-approve -var image_tag=$(TAG) -var healer_dry_run=$(HEALER_DRY_RUN)

plan-monitoring: ## Terraform plan for the monitoring stack
	bash scripts/terraform.sh monitoring plan -input=false -var image_tag=$(TAG) -var healer_dry_run=$(HEALER_DRY_RUN)

lint-terraform: ## terraform fmt -check and validate in every root
	terraform fmt -check -recursive infra/terraform
	@for d in infra/terraform/envs/local infra/terraform/monitoring/local; do \
	  terraform -chdir=$$d init -input=false -backend=false >/dev/null && TF_WORKSPACE=staging terraform -chdir=$$d validate -no-color || exit 1; done

ANSIBLE_PLAYBOOK := cd ansible && ANSIBLE_CONFIG=ansible.cfg ansible-playbook

deploy: check-env ## Ansible rolling deploy: ENV=staging|prod TAG=<sha>
	$(ANSIBLE_PLAYBOOK) playbooks/deploy.yml -e env=$(ENV) -e image_tag=$(TAG)

rollback: check-env ## Ansible rollback to the previous tag: ENV=staging|prod
	$(ANSIBLE_PLAYBOOK) playbooks/rollback.yml -e env=$(ENV)

migrate: check-env ## Run DB migrations only: ENV=staging|prod TAG=<sha>
	$(ANSIBLE_PLAYBOOK) playbooks/migrate.yml -e env=$(ENV) -e image_tag=$(TAG)

status: ## Containers, health, tags, firing alerts
	@docker ps --filter label=com.adpulse.project=adpulse --format 'table {{.Names}}\t{{.Status}}\t{{.Label "com.adpulse.version"}}' | sort
	@$(ANSIBLE_PLAYBOOK) playbooks/status.yml

smoke: check-env ## Smoke test ENV through nginx
	bash scripts/smoke_test.sh $(ENV)

# ansible-lint has its own pipx venv; give it the collections bundled with ansible.
ANSIBLE_COLLECTIONS := $(firstword $(wildcard $(HOME)/.local/share/pipx/venvs/ansible/lib/python3*/site-packages))

lint-ansible: ## ansible-lint
	cd ansible && ANSIBLE_COLLECTIONS_PATH="$(ANSIBLE_COLLECTIONS)" ansible-lint playbooks/

up: ## From zero to everything running (both envs + monitoring)
	$(MAKE) secrets
	$(MAKE) build
	$(MAKE) monitoring
	$(MAKE) infra ENV=staging
	$(MAKE) infra ENV=prod
	$(MAKE) monitoring
	$(MAKE) deploy ENV=staging
	$(MAKE) deploy ENV=prod
	$(MAKE) smoke ENV=staging
	$(MAKE) smoke ENV=prod
	@$(MAKE) --no-print-directory urls

down: ## Destroy local stacks (asks first; label-scoped)
	@read -r -p "Destroy local staging, prod and monitoring stacks (data volumes included)? Type yes: " a; [ "$$a" = yes ] || { echo aborted; exit 1; }
	-docker ps -aq --filter label=com.adpulse.project=adpulse --filter label=com.adpulse.role=api | xargs -r docker rm -f
	bash scripts/terraform.sh env staging destroy -input=false -auto-approve -var-file=staging.tfvars -var image_tag=$(TAG)
	bash scripts/terraform.sh env prod destroy -input=false -auto-approve -var-file=prod.tfvars -var image_tag=$(TAG)
	bash scripts/terraform.sh monitoring destroy -input=false -auto-approve -var image_tag=$(TAG)

chaos: ## Run one chaos scenario: SCENARIO=<name> ENV=staging
	$(call todo,Phase 9)

chaos-stop: ## Remove all injected faults: ENV=staging
	$(call todo,Phase 9)

rca: ## Generate an RCA from an incident directory: ID=<dir>
	$(call todo,Phase 9)

aws-plan: ## Terraform plan for AWS
	$(call todo,Phase 12)

aws-up: ## Terraform apply for AWS (asks first)
	$(call todo,Phase 12)

aws-bootstrap: ## Ansible bootstrap of the AWS host
	$(call todo,Phase 12)

aws-deploy: ## Deploy the stack to AWS
	$(call todo,Phase 12)

aws-down: ## Destroy everything on AWS (asks first)
	$(call todo,Phase 12)

urls: ## Print local URLs
	@echo "Grafana       http://127.0.0.1:3000"
	@echo "Prometheus    http://127.0.0.1:9090"
	@echo "Alertmanager  http://127.0.0.1:9093"
	@echo "staging       http://127.0.0.1:8081"
	@echo "prod          http://127.0.0.1:8080"
