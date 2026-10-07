variable "host_ip" {
  description = "Public IP of the EC2 host (output of infra/terraform/aws)."
  type        = string
}

variable "image_tag" {
  description = "Tag of the adpulse images shipped with make aws-push-images."
  type        = string
}

variable "registry_images" {
  description = "Same pins as envs/local and monitoring/local (docs/VERSIONS.md)."
  type        = map(string)
  default = {
    redis             = "redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0"
    nginx             = "nginxinc/nginx-unprivileged:1.30.5-alpine@sha256:15c994d10d6d78658721c3bcafff14cb281fba2a4bdf9d5ba92c416a472516e3"
    toxiproxy         = "ghcr.io/shopify/toxiproxy:2.12.0@sha256:9378ed52a28bc50edc1350f936f518f31fa95f0d15917d6eb40b8e376d1a214e"
    postgres_exporter = "quay.io/prometheuscommunity/postgres-exporter:v0.20.1@sha256:ac5ec343104fae0e2d84a27bb8d69b38430a11910c5382cad85d478d2bab713e"
    redis_exporter    = "oliver006/redis_exporter:v1.93.0-alpine@sha256:93831cd4d5d67687de67c9d5221b14312fea580af8d157583ed9d4459bf2dd70"
    prometheus        = "prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"
    alertmanager      = "prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a"
    grafana           = "grafana/grafana:13.2.3@sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572"
    node_exporter     = "prom/node-exporter:v1.12.1@sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0"
    cadvisor          = "ghcr.io/google/cadvisor:v0.60.6@sha256:b8e7d1093144fd088f425ff003d75a4aa405de075db78dae3bc563730b1bd07a"
  }
}

# Secrets: from .env via scripts/terraform.sh (TF_VAR_*), never in files.
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

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}
