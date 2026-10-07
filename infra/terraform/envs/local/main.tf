# Local environments. The Terraform workspace IS the env: staging or prod.
#   make infra ENV=staging   (selects/creates the workspace, uses staging.tfvars)

locals {
  env = terraform.workspace
}

resource "terraform_data" "workspace_guard" {
  lifecycle {
    precondition {
      condition     = contains(["staging", "prod"], terraform.workspace)
      error_message = "Workspace is '${terraform.workspace}'. Use 'make infra ENV=staging' or 'ENV=prod'; the default workspace is not an environment."
    }
  }
}

module "stack" {
  source = "../../modules/adpulse_stack"

  env             = local.env
  subnet          = var.subnet
  nginx_host_port = var.nginx_host_port
  loadgen_rps     = var.loadgen_rps
  chaos_enabled   = var.chaos_enabled
  images = merge(var.registry_images, {
    postgres = "adpulse-postgres:${var.image_tag}"
    api      = "adpulse-api:${var.image_tag}"
  })
  secrets = {
    db_admin_password   = var.db_admin_password
    db_app_password     = var.db_app_password
    db_monitor_password = var.db_monitor_password
    redis_password      = var.redis_password
  }

  depends_on = [terraform_data.workspace_guard]
}
