output "vpc_id" {
  description = "ID of the VPC the producer runs in."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs of the public subnets. Passed to the ECS service's network configuration."
  value       = aws_subnet.public[*].id
}

output "producer_security_group_id" {
  description = "ID of the producer's egress-only security group."
  value       = aws_security_group.producer.id
}
