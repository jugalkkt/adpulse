variable "env_networks" {
  description = "Existing env networks for Prometheus to join (computed by make)."
  type        = list(string)
  default     = []
}

variable "enable_healer" {
  type    = bool
  default = false
}

variable "images" {
  description = "Pinned by tag and digest (docs/VERSIONS.md)."
  type = object({
    prometheus    = string
    alertmanager  = string
    grafana       = string
    node_exporter = string
    cadvisor      = string
  })
  default = {
    prometheus    = "prom/prometheus:v3.15.0@sha256:efd719c99d83b060d9daefdcf00360461adf279f45ef5391f8d111892118753e"
    alertmanager  = "prom/alertmanager:v0.34.1@sha256:e9733bafb1bdef9b00e25a21f8f99dc26a22224bf16641ad754d1649f4c3357a"
    grafana       = "grafana/grafana:13.2.3@sha256:b28bae15e219c998fb0e0424ed724930cc61b1f61fb404d47c862f9a23f9e572"
    node_exporter = "prom/node-exporter:v1.12.1@sha256:1b4e4438faca4dd7e001dd445d161a4a2091b0fededa84093b3a8dfeae1f1be0"
    cadvisor      = "ghcr.io/google/cadvisor:v0.60.6@sha256:b8e7d1093144fd088f425ff003d75a4aa405de075db78dae3bc563730b1bd07a"
  }
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}
