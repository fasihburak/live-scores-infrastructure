output "ec2_public_ip" {
  description = "Public IP Address of EC2"
  value       = module.ec2_instance.public_ip
}