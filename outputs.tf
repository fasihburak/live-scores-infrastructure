output "ec2_public_ip" {
  description = "Public IP Address of EC2"
  value       = aws_instance.app_server.public_ip
}