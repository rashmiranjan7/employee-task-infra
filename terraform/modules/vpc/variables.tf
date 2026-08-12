variable "cluster_name" {
  description = "Name prefix used for every resource this module creates (e.g. employee-task)"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
}

variable "availability_zones" {
  description = "AZs to spread subnets across, e.g. [\"us-east-1a\", \"us-east-1b\"]"
  type        = list(string)
}

variable "public_subnets" {
  description = "CIDR blocks for public subnets, one per AZ"
  type        = list(string)
}

variable "private_subnets" {
  description = "CIDR blocks for private (EKS node) subnets, one per AZ"
  type        = list(string)
}

variable "database_subnets" {
  description = "CIDR blocks for database (RDS) subnets, one per AZ"
  type        = list(string)
}
