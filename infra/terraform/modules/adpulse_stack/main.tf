# One AdPulse environment: network, volumes and every long-lived container
# except the API replicas (Ansible owns those, Phase 6).

terraform {
  required_providers {
    docker = {
      source = "kreuzwerker/docker"
    }
  }
}

locals {
  network = "adpulse-${var.env}"
  base_labels = {
    "com.adpulse.project" = "adpulse"
    "com.adpulse.env"     = var.env
  }
  # Every container: drop all capabilities, no privilege escalation (docs/SECURITY.md).
  security_opts = ["no-new-privileges:true"]

  postgres_uid = 999 # postgres user in the official image
  redis_uid    = 999 # redis user in redis:alpine (gid 1000)
}

# ---------------------------------------------------------------- images
data "docker_image" "postgres" {
  name = var.images.postgres
}

data "docker_image" "api" {
  name = var.images.api
}

resource "docker_image" "registry" {
  for_each = {
    redis             = var.images.redis
    nginx             = var.images.nginx
    toxiproxy         = var.images.toxiproxy
    postgres_exporter = var.images.postgres_exporter
    redis_exporter    = var.images.redis_exporter
  }
  name         = each.value
  keep_locally = true
}

# ---------------------------------------------------------------- network
resource "docker_network" "env" {
  name   = local.network
  driver = "bridge"
  ipam_config {
    subnet = var.subnet
    # Explicit gateway: Docker computes it otherwise, and the provider then
    # sees a diff on every plan that forces network replacement.
    gateway = cidrhost(var.subnet, 1)
  }
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "network" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- volumes
resource "docker_volume" "this" {
  for_each = {
    pgdata    = "db"
    redisdata = "cache"
    backups   = "backup"
  }
  name = "${each.key}-${var.env}"
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = each.value })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
