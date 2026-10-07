# aws-prod: one AdPulse environment + monitoring + healer on the EC2 host.

module "stack" {
  source = "../../modules/adpulse_stack"

  env             = "aws-prod"
  subnet          = "172.28.30.0/24"
  nginx_host_port = 80
  nginx_host_ip   = "0.0.0.0" # the AWS security group limits port 80 to Jugal's /32
  loadgen_rps     = 5
  chaos_enabled   = false
  textfile_volume = module.monitoring.textfile_volume
  images = {
    postgres          = "adpulse-postgres:${var.image_tag}"
    api               = "adpulse-api:${var.image_tag}"
    redis             = var.registry_images["redis"]
    nginx             = var.registry_images["nginx"]
    toxiproxy         = var.registry_images["toxiproxy"]
    postgres_exporter = var.registry_images["postgres_exporter"]
    redis_exporter    = var.registry_images["redis_exporter"]
  }
  secrets = {
    db_admin_password   = var.db_admin_password
    db_app_password     = var.db_app_password
    db_monitor_password = var.db_monitor_password
    redis_password      = var.redis_password
  }
}

module "monitoring" {
  source = "../../modules/monitoring_stack"

  repo_root              = "/opt/adpulse-repo" # staged by aws_bootstrap.yml
  env_networks           = [module.stack.network]
  bind_ip                = "127.0.0.1" # UIs only through an SSH tunnel
  grafana_admin_password = var.grafana_admin_password
  enable_healer          = true
  healer_image           = "adpulse-healer:${var.image_tag}"
  healer_uid             = 1000 # ubuntu, owner of /opt/adpulse-repo/incidents
  grafana_sa_token       = ""   # no heal annotations on AWS (token setup needs the tunnel)
  images = {
    prometheus    = var.registry_images["prometheus"]
    alertmanager  = var.registry_images["alertmanager"]
    grafana       = var.registry_images["grafana"]
    node_exporter = var.registry_images["node_exporter"]
    cadvisor      = var.registry_images["cadvisor"]
  }
}
