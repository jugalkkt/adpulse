variable "env_label" {
  description = "Value of com.adpulse.env on monitoring resources."
  type        = string
  default     = "monitoring"
}

variable "repo_root" {
  description = "Absolute path of the repo on the Docker host (config dirs are bind-mounted read-only from it)."
  type        = string
}

variable "env_networks" {
  description = "Env networks Prometheus joins (only ones that already exist; see docs/DECISIONS.md D021)."
  type        = list(string)
  default     = []
}

variable "bind_ip" {
  description = "Host IP the monitoring UIs bind to."
  type        = string
  default     = "127.0.0.1"
}

variable "images" {
  type = object({
    prometheus    = string
    alertmanager  = string
    grafana       = string
    node_exporter = string
    cadvisor      = string
  })
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

variable "enable_healer" {
  description = "Create the healer and its docker-socket-proxy (Phase 8)."
  type        = bool
  default     = false
}

variable "healer_image" {
  description = "Locally built healer image (adpulse-healer:<sha>)."
  type        = string
  default     = ""
}

variable "socket_proxy_image" {
  type    = string
  default = "tecnativa/docker-socket-proxy:v0.5.0@sha256:1f5038b54f06c3e18422902cf00ba21803d1c97805aae032e5e6673d532d3459"
}

variable "healer_dry_run" {
  description = "Log intended heal actions without running them."
  type        = bool
  default     = false
}

variable "healer_uid" {
  description = "uid the healer runs as; must be able to write <repo>/incidents on the host (the host user's uid)."
  type        = number
  default     = 1000
}

variable "grafana_sa_token" {
  description = "Grafana service-account token for heal annotations (scripts/grafana_token.sh)."
  type        = string
  default     = ""
  sensitive   = true
}

variable "limits" {
  type = map(object({
    memory = number
    cpus   = string
  }))
  default = {
    prometheus    = { memory = 768, cpus = "1.0" }
    alertmanager  = { memory = 64, cpus = "0.1" }
    grafana       = { memory = 256, cpus = "0.5" }
    node_exporter = { memory = 64, cpus = "0.1" }
    cadvisor      = { memory = 256, cpus = "0.25" }
    healer        = { memory = 256, cpus = "0.5" }
  }
}
