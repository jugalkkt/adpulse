variable "subnet" {
  type = string
}

variable "nginx_host_port" {
  type = number
}

variable "loadgen_rps" {
  type = number
}

variable "chaos_enabled" {
  type = bool
}

variable "image_tag" {
  description = "Tag of the locally built adpulse-postgres and adpulse-api images (git short SHA)."
  type        = string
}

variable "registry_images" {
  description = "Third-party images, pinned by tag and digest (docs/VERSIONS.md)."
  type = object({
    redis             = string
    nginx             = string
    toxiproxy         = string
    postgres_exporter = string
    redis_exporter    = string
  })
  default = {
    redis             = "redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0"
    nginx             = "nginxinc/nginx-unprivileged:1.30.5-alpine@sha256:15c994d10d6d78658721c3bcafff14cb281fba2a4bdf9d5ba92c416a472516e3"
    toxiproxy         = "ghcr.io/shopify/toxiproxy:2.12.0@sha256:9378ed52a28bc50edc1350f936f518f31fa95f0d15917d6eb40b8e376d1a214e"
    postgres_exporter = "quay.io/prometheuscommunity/postgres-exporter:v0.20.1@sha256:ac5ec343104fae0e2d84a27bb8d69b38430a11910c5382cad85d478d2bab713e"
    redis_exporter    = "oliver006/redis_exporter:v1.93.0-alpine@sha256:93831cd4d5d67687de67c9d5221b14312fea580af8d157583ed9d4459bf2dd70"
  }
}

# Secrets: set by scripts/terraform.sh from .env (TF_VAR_*). Never in tfvars.
variable "db_admin_password" {
  type      = string
  sensitive = true
}

variable "db_app_password" {
  type      = string
  sensitive = true
}

variable "db_monitor_password" {
  type      = string
  sensitive = true
}

variable "redis_password" {
  type      = string
  sensitive = true
}
