variable "env" {
  description = "Environment name."
  type        = string
  validation {
    condition     = contains(["staging", "prod", "aws-prod"], var.env)
    error_message = "env must be staging, prod or aws-prod. In envs/local the env IS the Terraform workspace: run 'make infra ENV=staging' or 'ENV=prod' (the 'default' workspace is not an environment)."
  }
}

variable "subnet" {
  description = "Subnet of the env's Docker network. Must be in the Chef pg_hba allow-list (docs/DECISIONS.md D018)."
  type        = string
  validation {
    condition     = contains(["172.28.10.0/24", "172.28.20.0/24", "172.28.30.0/24"], var.subnet)
    error_message = "subnet must be one of the CIDRs in config/chef/cookbooks/adpulse_db/attributes/default.rb (allowed_cidrs)."
  }
}

variable "nginx_host_port" {
  description = "Host port that publishes nginx."
  type        = number
}

variable "nginx_host_ip" {
  description = "Host IP that nginx binds to (127.0.0.1 locally; 0.0.0.0 on AWS, where the security group is the boundary)."
  type        = string
  default     = "127.0.0.1"
}

variable "images" {
  description = "Image references. Registry images are pinned by tag@digest; local images by tag."
  type = object({
    postgres          = string # local: adpulse-postgres:<sha>
    api               = string # local: adpulse-api:<sha> (used by loadgen)
    redis             = string
    nginx             = string
    toxiproxy         = string
    postgres_exporter = string
    redis_exporter    = string
  })
}

variable "secrets" {
  description = "Per-env secrets from .env (via scripts/terraform.sh)."
  type = object({
    db_admin_password   = string
    db_app_password     = string
    db_monitor_password = string
    redis_password      = string
  })
  sensitive = true
}

variable "textfile_volume" {
  description = "Name of the shared node-exporter textfile volume (created by the monitoring stack)."
  type        = string
  default     = "adpulse-textfile"
}

variable "loadgen_rps" {
  description = "Requests per second sent by loadgen."
  type        = number
}

variable "chaos_enabled" {
  description = "Whether the API's chaos endpoints are enabled in this env (consumed by the Ansible deploy via output)."
  type        = bool
  default     = false
}

variable "backup_interval_seconds" {
  description = "Seconds between database backups."
  type        = number
  default     = 300
}

variable "limits" {
  description = "Memory (MB) and CPU limits per container (plan Section 5.4)."
  type = map(object({
    memory = number
    cpus   = string
  }))
  default = {
    nginx             = { memory = 64, cpus = "0.25" }
    postgres          = { memory = 512, cpus = "1.0" }
    redis             = { memory = 128, cpus = "0.25" }
    toxiproxy         = { memory = 64, cpus = "0.25" }
    backup            = { memory = 128, cpus = "0.25" }
    postgres_exporter = { memory = 64, cpus = "0.1" }
    redis_exporter    = { memory = 64, cpus = "0.1" }
    loadgen           = { memory = 128, cpus = "0.25" }
  }
}
