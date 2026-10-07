# Monitoring: Prometheus, Alertmanager, Grafana, node-exporter, cAdvisor
# (and the healer from Phase 8). Config directories are bind-mounted
# read-only from the repo so Prometheus/Alertmanager can hot-reload.

terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

locals {
  labels        = { "com.adpulse.project" = "adpulse", "com.adpulse.env" = var.env_label }
  security_opts = ["no-new-privileges:true"]
  mon           = "${var.repo_root}/monitoring"
}

resource "docker_image" "this" {
  for_each     = var.images
  name         = each.value
  keep_locally = true
}

resource "docker_network" "monitoring" {
  name   = "adpulse-monitoring"
  driver = "bridge"
  ipam_config {
    subnet  = "172.28.1.0/24"
    gateway = "172.28.1.1" # explicit, avoids a perpetual replace diff
  }
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "network" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# Shared node-exporter textfile directory. tmpfs owned by uid 999 (postgres
# in the adpulse-postgres image), so every env's backup-agent can write its
# .prom file whichever container mounts it first. Contents are regenerated
# every 15s, so nothing needs to persist (docs/DECISIONS.md D022).
resource "docker_volume" "textfile" {
  name   = "adpulse-textfile"
  driver = "local"
  driver_opts = {
    type   = "tmpfs"
    device = "tmpfs"
    o      = "size=8m,uid=999,gid=999,mode=0755"
  }
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_volume" "data" {
  for_each = toset(["prometheus-data", "alertmanager-data", "grafana-data"])
  name     = each.key
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
