# AdPulse: single entry point for humans. Run `make help`.
SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ENV ?= staging
TAG ?= $(shell git rev-parse --short HEAD 2>/dev/null || echo dev)
SCENARIO ?=
ID ?=

# Targets that later phases fill in; they fail loudly until then.
define todo
	@echo "make $@: not implemented yet ($(1))" >&2; exit 1
endef

.PHONY: help check secrets build lint test scan infra monitoring deploy rollback status \
        up down chaos chaos-stop rca aws-plan aws-up aws-bootstrap aws-deploy aws-down urls

help: ## List targets
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  \033[36m%-15s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

check: ## Print the machine report (OS, tools, ports)
	@bash scripts/machine_report.sh

secrets: ## Create .env from .env.example (never overwrites values)
	@bash scripts/gen_secrets.sh

build: ## Build all images tagged with the git SHA and dev
	$(call todo,Phase 2-4)

lint: ## Run all linters
	$(call todo,Phase 2+)

test: ## Unit and integration tests, healer tests, promtool rule tests
	$(call todo,Phase 3)

scan: ## Trivy image/config scans and gitleaks
	$(call todo,Phase 11)

infra: ## Terraform apply for ENV=staging|prod
	$(call todo,Phase 5)

monitoring: ## Terraform apply for the monitoring stack
	$(call todo,Phase 5)

deploy: ## Ansible rolling deploy: ENV=staging|prod TAG=<sha>
	$(call todo,Phase 6)

rollback: ## Ansible rollback to the previous tag: ENV=staging|prod
	$(call todo,Phase 6)

status: ## Containers, health, tags, firing alerts
	$(call todo,Phase 6)

up: ## From zero to everything running (both envs + monitoring)
	$(call todo,Phase 6-8)

down: ## Destroy local stacks (asks first; label-scoped)
	$(call todo,Phase 5)

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
