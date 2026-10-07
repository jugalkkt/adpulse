variable "region" {
  type    = string
  default = "ap-south-1" # Q7
}

variable "aws_profile" {
  type    = string
  default = "adpulse"
}

variable "availability_zone" {
  type    = string
  default = "ap-south-1a"
}

variable "instance_type" {
  description = "Q8: free-tier eligible, x86_64 (same images as local)."
  type        = string
  default     = "c7i-flex.large"
  validation {
    condition     = contains(["c7i-flex.large", "t3.small"], var.instance_type)
    error_message = "Only the Q8 candidates (x86_64, free-tier eligible) are allowed."
  }
}

variable "my_ip" {
  description = "Jugal's public IP (from https://checkip.amazonaws.com); SSH and HTTP are allowed only from this /32."
  type        = string
  validation {
    condition     = can(cidrhost("${var.my_ip}/32", 0))
    error_message = "my_ip must be a single IPv4 address."
  }
}

variable "allow_http" {
  description = "Q9: expose port 80 to my_ip/32 (false = SSH tunnel only)."
  type        = bool
  default     = true
}

variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/adpulse_aws.pub"
}
