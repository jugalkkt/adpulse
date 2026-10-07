# Local monitoring stack, shared by staging and prod.
#   make monitoring   (passes env_networks = the env networks that exist now)

module "monitoring" {
  source = "../../modules/monitoring_stack"

  repo_root              = abspath("${path.root}/../../../..")
  env_networks           = var.env_networks
  images                 = var.images
  grafana_admin_password = var.grafana_admin_password
  enable_healer          = var.enable_healer
  healer_image           = "adpulse-healer:${var.image_tag}"
  healer_dry_run         = var.healer_dry_run
  healer_uid             = var.healer_uid
  grafana_sa_token       = var.grafana_sa_token
}
