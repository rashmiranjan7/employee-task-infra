variable "admin_cidr" {
  description = "CIDR allowed to reach SSH (22) and the Jenkins UI (8080) - restrict to your own IP, e.g. \"203.0.113.5/32\""
  type        = string
}

variable "ssh_key_name" {
  description = "Name of an existing EC2 key pair, for backup SSH access if you ever need it"
  type        = string
}

variable "instance_type" {
  type    = string
  default = "t3.small"
}

variable "ecr_repository_arns" {
  description = "ARNs of the ECR repos Jenkins needs to push to"
  type        = list(string)
}
