output "public_ip" {
  value = aws_instance.host.public_ip
}

output "instance_id" {
  value = aws_instance.host.id
}

output "ami" {
  value = "${data.aws_ami.ubuntu.id} (${data.aws_ami.ubuntu.name})"
}

output "ssh_command" {
  value = "ssh -i ~/.ssh/adpulse_aws ubuntu@${aws_instance.host.public_ip}"
}
