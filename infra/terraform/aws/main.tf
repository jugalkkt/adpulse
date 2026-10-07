# AWS production for AdPulse: one VPC, one public subnet, one EC2 host.
# Ephemeral: created and destroyed the same day (plan 12.13).

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical
  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }
  filter {
    name   = "architecture"
    values = ["x86_64"] # local images are amd64 (never t4g/arm64)
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_vpc" "this" {
  cidr_block           = "10.20.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "adpulse-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "adpulse-igw" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.this.id
  cidr_block              = "10.20.1.0/24"
  availability_zone       = var.availability_zone
  map_public_ip_on_launch = true
  tags                    = { Name = "adpulse-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "adpulse-public" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# The security group is the real network boundary (published Docker ports
# bypass ufw on the host; docs/SECURITY.md).
resource "aws_security_group" "host" {
  name        = "adpulse-host"
  description = "AdPulse host: SSH and HTTP from Jugal's IP only"
  vpc_id      = aws_vpc.this.id
  tags        = { Name = "adpulse-host" }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  security_group_id = aws_security_group.host.id
  description       = "SSH from my IP"
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  cidr_ipv4         = "${var.my_ip}/32"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  count             = var.allow_http ? 1 : 0
  security_group_id = aws_security_group.host.id
  description       = "HTTP (nginx) from my IP"
  ip_protocol       = "tcp"
  from_port         = 80
  to_port           = 80
  cidr_ipv4         = "${var.my_ip}/32"
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.host.id
  description       = "All outbound (apt, OpenVox, Cinc, Docker repos)"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_key_pair" "this" {
  key_name   = "adpulse-aws"
  public_key = file(pathexpand(var.ssh_public_key_path))
}

resource "aws_instance" "host" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.host.id]
  key_name               = aws_key_pair.this.key_name
  # No instance profile: the host needs no AWS API access.

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1 # containers cannot reach instance metadata
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = 20
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "adpulse-root" }
  }

  # Only what Ansible needs to connect; everything else is Ansible/Puppet/Chef.
  user_data = <<-EOT
    #!/bin/bash
    set -e
    apt-get update -y
    apt-get install -y python3
  EOT

  tags = { Name = "adpulse-aws-prod" }
}
