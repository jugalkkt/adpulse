# Healer (Phase 8) and the docker-socket-proxy it uses. The healer never gets
# the Docker socket itself: it reaches a proxy on an internal-only network
# that allows just the API sections the heal playbooks need.

resource "docker_network" "healer_docker" {
  count    = var.enable_healer ? 1 : 0
  name     = "adpulse-healer-docker"
  driver   = "bridge"
  internal = true # no route out; only healer <-> proxy
  ipam_config {
    subnet  = "172.28.2.0/24"
    gateway = "172.28.2.1"
  }
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "network" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_image" "socket_proxy" {
  count        = var.enable_healer ? 1 : 0
  name         = var.socket_proxy_image
  keep_locally = true
}

resource "docker_container" "socket_proxy" {
  count       = var.enable_healer ? 1 : 0
  name        = "docker-socket-proxy"
  image       = docker_image.socket_proxy[0].image_id
  restart     = "unless-stopped"
  memory      = 64
  memory_swap = 64
  cpus        = "0.1"
  read_only   = true
  # Runs as root only to read the root-owned socket; no capabilities at all.
  security_opts = local.security_opts
  env = [
    "CONTAINERS=1", # list/inspect/start/stop/restart/stats/create
    "IMAGES=1",     # inspect image of a template replica (scale_api)
    "NETWORKS=1",   # attach new replicas to the env network
    "EXEC=1",       # pg_isready, readyz, backup cleanup, diagnostics
    "INFO=1",
    "VERSION=1",
    "POST=1", # write operations, limited to the sections above
    "EVENTS=0",
    "VOLUMES=0",
    "SYSTEM=0",
    "BUILD=0",
    "COMMIT=0",
    "SECRETS=0",
    "SWARM=0",
    "AUTH=0",
    "LOG_LEVEL=warning",
  ]
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=8m"
    "/run" = "rw,noexec,nosuid,size=8m"
  }
  capabilities {
    drop = ["ALL"]
  }
  mounts {
    type      = "bind"
    source    = "/var/run/docker.sock"
    target    = "/var/run/docker.sock"
    read_only = true
  }
  networks_advanced {
    name = docker_network.healer_docker[0].name
  }
  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:2375/_ping"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "healer" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

data "docker_image" "healer" {
  count = var.enable_healer ? 1 : 0
  name  = var.healer_image
}

resource "docker_container" "healer" {
  count         = var.enable_healer ? 1 : 0
  name          = "healer"
  image         = data.docker_image.healer[0].id
  user          = "${var.healer_uid}:${var.healer_uid}"
  restart       = "unless-stopped"
  memory        = var.limits.healer.memory
  memory_swap   = var.limits.healer.memory
  cpus          = var.limits.healer.cpus
  read_only     = true
  security_opts = local.security_opts
  env = [
    "HEALER_DRY_RUN=${var.healer_dry_run}",
    "DOCKER_HOST=tcp://docker-socket-proxy:2375",
    "GRAFANA_URL=http://grafana:3000",
    "GRAFANA_SA_TOKEN=${var.grafana_sa_token}",
    "PROMETHEUS_URL=http://prometheus:9090",
  ]
  tmpfs = {
    "/tmp" = "rw,nosuid,size=64m,uid=${var.healer_uid},gid=${var.healer_uid}"
  }
  capabilities {
    drop = ["ALL"]
  }
  # Heal log and diagnostics land in <repo>/incidents on the host.
  mounts {
    type   = "bind"
    source = "${var.repo_root}/incidents"
    target = "/data"
  }
  networks_advanced {
    name = docker_network.monitoring.name
  }
  networks_advanced {
    name = docker_network.healer_docker[0].name
  }
  wait         = true
  wait_timeout = 60
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "healer" })
    content {
      label = labels.key
      value = labels.value
    }
  }
  depends_on = [docker_container.socket_proxy]
}
