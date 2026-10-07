#!/usr/bin/env bash
# Run Terraform in one root with secrets from .env (never printed).
#   scripts/terraform.sh env <staging|prod> <terraform args...>   # infra/terraform/envs/local, workspace = env
#   scripts/terraform.sh monitoring <terraform args...>           # infra/terraform/monitoring/local
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
[[ -f "$ENV_FILE" ]] || { echo "missing .env: run 'make secrets'" >&2; exit 1; }

# Read one variable from .env without sourcing the whole file into the shell.
envval() {
  local v
  v="$(grep -E "^$1=" "$ENV_FILE" | tail -n1 | cut -d= -f2-)"
  [[ -n "$v" ]] || { echo "variable $1 is empty in .env: run 'make secrets'" >&2; exit 1; }
  printf '%s' "$v"
}

kind="${1:?usage: terraform.sh env <env> ... | monitoring ...}"; shift

case "$kind" in
  env)
    env="${1:?env required}"; shift
    [[ "$env" == "staging" || "$env" == "prod" ]] || { echo "env must be staging or prod" >&2; exit 1; }
    dir="$ROOT/infra/terraform/envs/local"
    prefix="$(tr '[:lower:]-' '[:upper:]_' <<<"$env")"
    TF_VAR_db_admin_password="$(envval "${prefix}_DB_ADMIN_PASSWORD")"
    TF_VAR_db_app_password="$(envval "${prefix}_DB_APP_PASSWORD")"
    TF_VAR_db_monitor_password="$(envval "${prefix}_DB_MONITOR_PASSWORD")"
    TF_VAR_redis_password="$(envval "${prefix}_REDIS_PASSWORD")"
    export TF_VAR_db_admin_password TF_VAR_db_app_password TF_VAR_db_monitor_password TF_VAR_redis_password
    terraform -chdir="$dir" init -input=false -upgrade=false >/dev/null
    terraform -chdir="$dir" workspace select -or-create "$env" >/dev/null
    ;;
  monitoring)
    dir="$ROOT/infra/terraform/monitoring/local"
    TF_VAR_grafana_admin_password="$(envval GRAFANA_ADMIN_PASSWORD)"
    # Optional until scripts/grafana_token.sh has created it.
    TF_VAR_grafana_sa_token="$(grep -E '^GRAFANA_SA_TOKEN=' "$ENV_FILE" | tail -n1 | cut -d= -f2- || true)"
    TF_VAR_healer_uid="$(id -u)"
    mkdir -p "$ROOT/incidents"
    # Prometheus joins only env networks that already exist (DECISIONS D021).
    TF_VAR_env_networks="$(docker network ls --filter label=com.adpulse.project=adpulse --format '{{.Name}}' \
      | { grep -E '^adpulse-(staging|prod)$' || true; } | sort | /usr/bin/jq -R . | /usr/bin/jq -cs .)"
    export TF_VAR_grafana_admin_password TF_VAR_env_networks TF_VAR_grafana_sa_token TF_VAR_healer_uid
    echo "monitoring: Prometheus joins env networks $TF_VAR_env_networks"
    terraform -chdir="$dir" init -input=false -upgrade=false >/dev/null
    ;;
  *)
    echo "unknown kind: $kind" >&2; exit 1 ;;
esac

exec terraform -chdir="$dir" "$@"
