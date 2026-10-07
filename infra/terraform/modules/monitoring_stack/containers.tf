# ---------------------------------------------------------------- prometheus
resource "docker_container" "prometheus" {
  name          = "prometheus"
  image         = docker_image.this["prometheus"].image_id
  user          = "65534:65534"
  restart       = "unless-stopped"
  memory        = var.limits.prometheus.memory
  memory_swap   = var.limits.prometheus.memory # no swap beyond the limit
  cpus          = var.limits.prometheus.cpus
  read_only     = true
  security_opts = local.security_opts
  command = [
    "--config.file=/etc/prometheus/prometheus.yml",
    "--storage.tsdb.path=/prometheus",
    "--storage.tsdb.retention.time=7d",
    "--web.enable-lifecycle", # POST /-/reload after editing rules
    "--web.listen-address=:9090",
  ]
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=16m"
  }
  capabilities {
    drop = ["ALL"]
  }
  mounts {
    type      = "bind"
    source    = "${local.mon}/prometheus"
    target    = "/etc/prometheus"
    read_only = true
  }
  volumes {
    volume_name    = docker_volume.data["prometheus-data"].name
    container_path = "/prometheus"
  }
  ports {
    internal = 9090
    external = 9090
    ip       = var.bind_ip
  }
  networks_advanced {
    name = docker_network.monitoring.name
  }
  dynamic "networks_advanced" {
    for_each = toset(var.env_networks)
    content {
      name = networks_advanced.value
    }
  }
  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9090/-/healthy"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }
  wait         = true
  wait_timeout = 90
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- alertmanager
resource "docker_container" "alertmanager" {
  name          = "alertmanager"
  image         = docker_image.this["alertmanager"].image_id
  user          = "65534:65534"
  restart       = "unless-stopped"
  memory        = var.limits.alertmanager.memory
  memory_swap   = var.limits.alertmanager.memory # no swap beyond the limit
  cpus          = var.limits.alertmanager.cpus
  read_only     = true
  security_opts = local.security_opts
  command = [
    "--config.file=/etc/alertmanager/alertmanager.yml",
    "--storage.path=/alertmanager",
    "--web.listen-address=:9093",
    "--cluster.listen-address=", # single instance: no gossip port
  ]
  capabilities {
    drop = ["ALL"]
  }
  mounts {
    type      = "bind"
    source    = "${local.mon}/alertmanager"
    target    = "/etc/alertmanager"
    read_only = true
  }
  volumes {
    volume_name    = docker_volume.data["alertmanager-data"].name
    container_path = "/alertmanager"
  }
  ports {
    internal = 9093
    external = 9093
    ip       = var.bind_ip
  }
  networks_advanced {
    name = docker_network.monitoring.name
  }
  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9093/-/healthy"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }
  wait         = true
  wait_timeout = 60
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- grafana
resource "docker_container" "grafana" {
  name          = "grafana"
  image         = docker_image.this["grafana"].image_id
  user          = "472:0"
  restart       = "unless-stopped"
  memory        = var.limits.grafana.memory
  memory_swap   = var.limits.grafana.memory # no swap beyond the limit
  cpus          = var.limits.grafana.cpus
  read_only     = true
  security_opts = local.security_opts
  env = [
    "GF_SECURITY_ADMIN_USER=admin",
    "GF_SECURITY_ADMIN_PASSWORD=${var.grafana_admin_password}",
    "GF_AUTH_ANONYMOUS_ENABLED=false",
    "GF_USERS_ALLOW_SIGN_UP=false",
    "GF_ANALYTICS_REPORTING_ENABLED=false",
    "GF_ANALYTICS_CHECK_FOR_UPDATES=false",
    "GF_ANALYTICS_CHECK_FOR_PLUGIN_UPDATES=false",
    "GF_PLUGINS_PREINSTALL_DISABLED=true",
    "GF_PATHS_PROVISIONING=/etc/grafana/provisioning",
  ]
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=32m"
  }
  capabilities {
    drop = ["ALL"]
  }
  mounts {
    type      = "bind"
    source    = "${local.mon}/grafana/provisioning"
    target    = "/etc/grafana/provisioning"
    read_only = true
  }
  mounts {
    type      = "bind"
    source    = "${local.mon}/grafana/dashboards"
    target    = "/etc/adpulse-dashboards"
    read_only = true
  }
  volumes {
    volume_name    = docker_volume.data["grafana-data"].name
    container_path = "/var/lib/grafana"
  }
  ports {
    internal = 3000
    external = 3000
    ip       = var.bind_ip
  }
  networks_advanced {
    name = docker_network.monitoring.name
  }
  healthcheck {
    test         = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:3000/api/health"]
    interval     = "10s"
    timeout      = "3s"
    retries      = 5
    start_period = "30s"
  }
  wait         = true
  wait_timeout = 120
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- node-exporter
# On the monitoring network instead of host networking, so port 9100 is never
# exposed on the host (docs/DECISIONS.md D023). Host CPU/memory/disk come from
# the host's /proc and / mounted read-only; network stats are the container's.
resource "docker_container" "node_exporter" {
  name        = "node-exporter"
  image       = docker_image.this["node_exporter"].image_id
  user        = "65534:65534"
  restart     = "unless-stopped"
  memory      = var.limits.node_exporter.memory
  memory_swap = var.limits.node_exporter.memory # no swap beyond the limit
  cpus        = var.limits.node_exporter.cpus
  read_only   = true
  # Docker adds label=disable itself when pid_mode = host; declared to avoid a diff.
  security_opts = concat(local.security_opts, ["label=disable"])
  pid_mode      = "host"
  command = [
    "--path.rootfs=/host",
    "--collector.textfile.directory=/textfile",
    "--collector.filesystem.mount-points-exclude=^/(dev|proc|run|sys|var/lib/docker/.+|var/snap/.+|snap/.+)($|/)",
  ]
  capabilities {
    drop = ["ALL"]
  }
  mounts {
    type      = "bind"
    source    = "/"
    target    = "/host"
    read_only = true
    bind_options {
      propagation = "rslave"
    }
  }
  volumes {
    volume_name    = docker_volume.textfile.name
    container_path = "/textfile"
    read_only      = true
  }
  networks_advanced {
    name = docker_network.monitoring.name
  }
  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9100/metrics"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- cadvisor
# Per-container CPU/memory vs limits. Mounts follow the cAdvisor docs for
# cgroup v2; see docs/DECISIONS.md D024 for what turned out to be required.
resource "docker_container" "cadvisor" {
  name          = "cadvisor"
  image         = docker_image.this["cadvisor"].image_id
  restart       = "unless-stopped"
  memory        = var.limits.cadvisor.memory
  memory_swap   = var.limits.cadvisor.memory # no swap beyond the limit
  cpus          = var.limits.cadvisor.cpus
  read_only     = true
  security_opts = local.security_opts
  command = [
    "--docker_only=true",
    "--housekeeping_interval=10s",
    "--store_container_labels=false",
    "--whitelisted_container_labels=com.adpulse.project,com.adpulse.env,com.adpulse.role",
    "--disable_metrics=advtcp,cpu_topology,cpuset,hugetlb,memory_numa,percpu,referenced_memory,resctrl,sched,tcp,udp,process",
  ]
  capabilities {
    drop = ["ALL"]
  }
  dynamic "mounts" {
    for_each = {
      "/"               = "/rootfs"
      "/var/run"        = "/var/run"
      "/sys"            = "/sys"
      "/var/lib/docker" = "/var/lib/docker"
      "/dev/disk"       = "/dev/disk"
    }
    content {
      type      = "bind"
      source    = mounts.key
      target    = mounts.value
      read_only = true
    }
  }
  devices {
    host_path      = "/dev/kmsg"
    container_path = "/dev/kmsg"
    permissions    = "r"
  }
  networks_advanced {
    name = docker_network.monitoring.name
  }
  healthcheck {
    test         = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/healthz"]
    interval     = "10s"
    timeout      = "3s"
    retries      = 3
    start_period = "5s" # the image's value; declared to avoid a diff
  }
  dynamic "labels" {
    for_each = merge(local.labels, { "com.adpulse.role" = "monitoring" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}
