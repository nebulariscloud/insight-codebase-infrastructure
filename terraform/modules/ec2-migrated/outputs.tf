output "instance_id" {
  description = "EC2 instance ID."
  value       = aws_instance.this.id
}

output "private_ip" {
  description = "Primary private IP."
  value       = aws_instance.this.private_ip
}

output "public_ip" {
  description = "Public IP if EIP allocated, else null."
  value       = try(aws_eip.this[0].public_ip, null)
}

output "security_group_id" {
  description = "Instance security group ID."
  value       = aws_security_group.this.id
}

output "availability_zone" {
  description = "AZ the instance landed in."
  value       = aws_instance.this.availability_zone
}
