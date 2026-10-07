terraform {
  required_version = ">= 1.16.0"
  required_providers {
    docker = {
      source  = "kreuzwerker/docker"
      version = "4.6.0"
    }
  }
}

# Same modules as local, driven over SSH: the provider runs
# `ssh ubuntu@host docker system dial-stdio` (plan 12.10).
provider "docker" {
  host     = "ssh://ubuntu@${var.host_ip}:22"
  ssh_opts = ["-i", pathexpand("~/.ssh/adpulse_aws"), "-o", "StrictHostKeyChecking=accept-new", "-o", "ConnectTimeout=15"]
}
