variable "environment" {
  description = "Environment name. Suffixes the VPC, subnets, route table and security group."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR for the VPC. Deliberately not 10.0.0.0/16 -- this account is shared with other projects, and an overlapping range is the thing that makes a future peering or VPN impossible."
  type        = string
  default     = "10.42.0.0/16"
}

variable "public_subnet_count" {
  description = "How many AZs to spread public subnets across. Two is the minimum that survives an AZ failure; subnets are free, so there is no reason to run one."
  type        = number
  default     = 2
}
