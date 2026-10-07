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
  description = "Create the healer container (Phase 8)."
  type        = bool
  default     = false
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
