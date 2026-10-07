# Containers of one environment. Common hardening on every container:
#   restart unless-stopped, memory/CPU limits, labels, no-new-privileges,
#   cap_drop ALL with no cap_add (none of these images need a capability:
#   all run as non-root users and bind ports > 1024), read-only rootfs + tmpfs.

# ---------------------------------------------------------------- postgres
resource "docker_container" "postgres" {
  name          = "postgres-${var.env}"
  image         = data.docker_image.postgres.id
  user          = "${local.postgres_uid}:${local.postgres_uid}"
  restart       = "unless-stopped"
  memory        = var.limits.postgres.memory
  memory_swap   = var.limits.postgres.memory # no swap beyond the limit
  cpus          = var.limits.postgres.cpus
  read_only     = true
  security_opts = local.security_opts
  shm_size      = 128
  env = [
    "POSTGRES_PASSWORD=${var.secrets.db_admin_password}",
    "ADPULSE_APP_PASSWORD=${var.secrets.db_app_password}",
    "ADPULSE_MONITOR_PASSWORD=${var.secrets.db_monitor_password}",
  ]
  tmpfs = {
    "/var/run/postgresql" = "rw,noexec,nosuid,size=16m,uid=${local.postgres_uid},gid=${local.postgres_uid},mode=0775"
    "/tmp"                = "rw,noexec,nosuid,size=64m,uid=${local.postgres_uid},gid=${local.postgres_uid}"
  }
  capabilities {
    drop = ["ALL"]
  }
  volumes {
    volume_name    = docker_volume.this["pgdata"].name
    container_path = "/var/lib/postgresql"
  }
  networks_advanced {
    name = docker_network.env.name
  }
  healthcheck {
    test         = ["CMD", "pg_isready", "-q", "-U", "postgres", "-d", "postgres"]
    interval     = "5s"
    timeout      = "3s"
    retries      = 5
    start_period = "30s"
  }
  wait         = true
  wait_timeout = 120
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "db" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- redis
resource "docker_container" "redis" {
  name          = "redis-${var.env}"
  image         = docker_image.registry["redis"].image_id
  user          = "${local.redis_uid}:1000"
  restart       = "unless-stopped"
  memory        = var.limits.redis.memory
  memory_swap   = var.limits.redis.memory # no swap beyond the limit
  cpus          = var.limits.redis.cpus
  read_only     = true
  security_opts = local.security_opts
  # The password goes into a config file on tmpfs at start-up, so it never
  # appears on redis-server's command line (ps). Read-only rootfs is kept.
  env        = ["REDIS_PASSWORD=${var.secrets.redis_password}"]
  entrypoint = ["/bin/sh", "-c"]
  command = [<<-EOT
    umask 077
    printf 'requirepass %s\nmaxmemory 64mb\nmaxmemory-policy allkeys-lru\nappendonly no\nprotected-mode no\ndir /data\n' "$REDIS_PASSWORD" > /tmp/redis.conf
    unset REDIS_PASSWORD
    exec redis-server /tmp/redis.conf
  EOT
  ]
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=16m,uid=${local.redis_uid},gid=1000"
  }
  capabilities {
    drop = ["ALL"]
  }
  volumes {
    volume_name    = docker_volume.this["redisdata"].name
    container_path = "/data"
  }
  networks_advanced {
    name = docker_network.env.name
  }
  healthcheck {
    # An unauthenticated PING answers NOAUTH: that proves the server is up
    # without putting the password in the healthcheck definition.
    test     = ["CMD-SHELL", "redis-cli ping 2>&1 | grep -qE 'PONG|NOAUTH'"]
    interval = "5s"
    timeout  = "2s"
    retries  = 5
  }
  wait         = true
  wait_timeout = 60
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "cache" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- toxiproxy
# The API reaches Postgres and Redis only through Toxiproxy, so chaos can
# inject network faults (Phase 9).
resource "docker_container" "toxiproxy" {
  name        = "toxiproxy-${var.env}"
  image       = docker_image.registry["toxiproxy"].image_id
  user        = "65534:65534"
  restart     = "unless-stopped"
  memory      = var.limits.toxiproxy.memory
  memory_swap = var.limits.toxiproxy.memory # no swap beyond the limit
  cpus        = var.limits.toxiproxy.cpus
  # Exception: writable rootfs. The image has no shell, so the config can only
  # be delivered by upload, and the provider uploads via the container root.
  # Mitigations: runs as nobody, no capabilities, image = 2 static binaries.
  # (docs/DECISIONS.md D025)
  read_only     = false
  security_opts = local.security_opts
  command       = ["-host=0.0.0.0", "-config=/config/toxiproxy.json"]
  capabilities {
    drop = ["ALL"]
  }
  upload {
    file        = "/config/toxiproxy.json"
    permissions = "0444"
    content = jsonencode([
      { name = "postgres", listen = "0.0.0.0:15432", upstream = "postgres-${var.env}:5432", enabled = true },
      { name = "redis", listen = "0.0.0.0:16379", upstream = "redis-${var.env}:6379", enabled = true },
    ])
  }
  networks_advanced {
    name = docker_network.env.name
  }
  healthcheck {
    test     = ["CMD", "/toxiproxy-cli", "list"]
    interval = "5s"
    timeout  = "2s"
    retries  = 5
  }
  wait         = true
  wait_timeout = 60
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "proxy" })
    content {
      label = labels.key
      value = labels.value
    }
  }
  depends_on = [docker_container.postgres, docker_container.redis]
}

# ---------------------------------------------------------------- nginx
resource "docker_container" "nginx" {
  name          = "nginx-${var.env}"
  image         = docker_image.registry["nginx"].image_id
  restart       = "unless-stopped"
  memory        = var.limits.nginx.memory
  memory_swap   = var.limits.nginx.memory # no swap beyond the limit
  cpus          = var.limits.nginx.cpus
  read_only     = true
  security_opts = local.security_opts
  # Config rendered by Terraform, passed in env, written to tmpfs at start-up
  # (keeps the read-only rootfs; docs/DECISIONS.md D025).
  env        = ["NGINX_CONF=${templatefile("${path.module}/../../../../config/nginx/nginx.conf.tftpl", { env = var.env })}"]
  entrypoint = ["/bin/sh", "-c"]
  command    = ["printf '%s' \"$NGINX_CONF\" > /tmp/nginx.conf && exec nginx -c /tmp/nginx.conf -g 'daemon off;'"]
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=32m,uid=101,gid=101"
  }
  capabilities {
    drop = ["ALL"]
  }
  ports {
    internal = 8080
    external = var.nginx_host_port
    ip       = var.nginx_host_ip
  }
  networks_advanced {
    name = docker_network.env.name
  }
  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:8080/nginx-health"]
    interval = "5s"
    timeout  = "2s"
    retries  = 3
  }
  wait         = true
  wait_timeout = 60
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "lb" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- backup agent
resource "docker_container" "backup_agent" {
  name          = "backup-agent-${var.env}"
  image         = data.docker_image.postgres.id
  user          = "${local.postgres_uid}:${local.postgres_uid}"
  restart       = "unless-stopped"
  memory        = var.limits.backup.memory
  memory_swap   = var.limits.backup.memory # no swap beyond the limit
  cpus          = var.limits.backup.cpus
  read_only     = true
  security_opts = local.security_opts
  entrypoint    = ["/usr/local/bin/adpulse-backup-loop.sh"]
  env = [
    "ADPULSE_ENV=${var.env}",
    "BACKUP_INTERVAL_SECONDS=${var.backup_interval_seconds}",
    "PGHOST=postgres-${var.env}",
    "PGUSER=adpulse",
    "PGDATABASE=adpulse",
    "PGPASSWORD=${var.secrets.db_app_password}",
  ]
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=16m,uid=${local.postgres_uid},gid=${local.postgres_uid}"
  }
  capabilities {
    drop = ["ALL"]
  }
  volumes {
    volume_name    = docker_volume.this["backups"].name
    container_path = "/backups"
  }
  volumes {
    volume_name    = var.textfile_volume
    container_path = "/textfile"
  }
  networks_advanced {
    name = docker_network.env.name
  }
  healthcheck {
    # Healthy while the metrics file keeps being refreshed (every 15s).
    test     = ["CMD-SHELL", "test $(( $(date +%s) - $(stat -c %Y /textfile/backup_${var.env}.prom) )) -lt 60"]
    interval = "15s"
    timeout  = "3s"
    retries  = 3
  }
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "backup" })
    content {
      label = labels.key
      value = labels.value
    }
  }
  depends_on = [docker_container.postgres]
}

# ---------------------------------------------------------------- exporters
resource "docker_container" "postgres_exporter" {
  name          = "postgres-exporter-${var.env}"
  image         = docker_image.registry["postgres_exporter"].image_id
  restart       = "unless-stopped"
  memory        = var.limits.postgres_exporter.memory
  memory_swap   = var.limits.postgres_exporter.memory # no swap beyond the limit
  cpus          = var.limits.postgres_exporter.cpus
  read_only     = true
  security_opts = local.security_opts
  # Talks to Postgres directly (not via Toxiproxy): DB metrics should describe
  # the database, not injected network faults.
  env = [
    # connect_timeout keeps a scrape with the DB down well under the 4s scrape timeout.
    "DATA_SOURCE_URI=postgres-${var.env}:5432/adpulse?sslmode=disable&connect_timeout=2",
    "DATA_SOURCE_USER=adpulse_monitor",
    "DATA_SOURCE_PASS=${var.secrets.db_monitor_password}",
  ]
  capabilities {
    drop = ["ALL"]
  }
  networks_advanced {
    name = docker_network.env.name
  }
  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9187/metrics"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "exporter" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

resource "docker_container" "redis_exporter" {
  name          = "redis-exporter-${var.env}"
  image         = docker_image.registry["redis_exporter"].image_id
  restart       = "unless-stopped"
  memory        = var.limits.redis_exporter.memory
  memory_swap   = var.limits.redis_exporter.memory # no swap beyond the limit
  cpus          = var.limits.redis_exporter.cpus
  read_only     = true
  security_opts = local.security_opts
  env = [
    "REDIS_ADDR=redis://redis-${var.env}:6379",
    "REDIS_PASSWORD=${var.secrets.redis_password}",
    # Default 15s: with Redis down a scrape took 9.5s > Prometheus' 4s timeout,
    # so redis_up==0 was never seen and AdPulseCacheDown could not fire.
    "REDIS_EXPORTER_CONNECTION_TIMEOUT=2s",
  ]
  capabilities {
    drop = ["ALL"]
  }
  networks_advanced {
    name = docker_network.env.name
  }
  healthcheck {
    test     = ["CMD", "wget", "-q", "-O", "/dev/null", "http://127.0.0.1:9121/health"]
    interval = "10s"
    timeout  = "3s"
    retries  = 3
  }
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "exporter" })
    content {
      label = labels.key
      value = labels.value
    }
  }
}

# ---------------------------------------------------------------- loadgen
resource "docker_container" "loadgen" {
  name          = "loadgen-${var.env}"
  image         = data.docker_image.api.id
  restart       = "unless-stopped"
  memory        = var.limits.loadgen.memory
  memory_swap   = var.limits.loadgen.memory # no swap beyond the limit
  cpus          = var.limits.loadgen.cpus
  read_only     = true
  security_opts = local.security_opts
  entrypoint    = ["python", "-m", "loadgen.loadgen"]
  env = [
    "APP_ENV=${var.env}",
    "LOADGEN_TARGET=http://nginx-${var.env}:8080",
    "LOADGEN_RPS=${var.loadgen_rps}",
  ]
  tmpfs = {
    "/tmp" = "rw,noexec,nosuid,size=16m"
  }
  capabilities {
    drop = ["ALL"]
  }
  networks_advanced {
    name = docker_network.env.name
  }
  # The API image's HEALTHCHECK probes :8000, which loadgen doesn't serve, so
  # it is disabled. Docker keeps the image's timing fields even for NONE; they
  # are repeated here (from docker/api/Dockerfile) to avoid a perpetual diff.
  healthcheck {
    test         = ["NONE"]
    interval     = "5s"
    timeout      = "2s"
    start_period = "10s"
    retries      = 3
  }
  dynamic "labels" {
    for_each = merge(local.base_labels, { "com.adpulse.role" = "loadgen" })
    content {
      label = labels.key
      value = labels.value
    }
  }
  depends_on = [docker_container.nginx]
}
