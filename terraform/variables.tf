variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "domain_name" {
  description = "The one hostname the app is reachable on, e.g. app.example.com. Must already be a domain you can point DNS at."
  type        = string
}

variable "github_repo_subject" {
  description = "rashmiranjan7/employee-task-app - scopes the OIDC role to only this repo"
  type        = string
}

variable "jenkins_admin_cidr" {
  description = "Your own IP in CIDR form, e.g. 203.0.113.5/32 - the only address allowed to reach Jenkins"
  type        = string
}

variable "jenkins_ssh_key_name" {
  description = "Name of an existing EC2 key pair (for emergency SSH access - Jenkins itself installs on boot without it)"
  type        = string
}

# ─── Networking ─────────────────────────────────────────────────────────────
variable "vpc_cidr" {
  type = string
}

variable "availability_zones" {
  type = list(string)
}

variable "public_subnets" {
  type = list(string)
}

variable "private_subnets" {
  type = list(string)
}

variable "database_subnets" {
  type = list(string)
}

# ─── EKS ──────────────────────────────────────────────────────────────────────
variable "cluster_version" {
  type    = string
  default = "1.30"
}

variable "node_instance_types" {
  type    = list(string)
  default = ["t3.medium"]
}

variable "node_min_size" {
  type    = number
  default = 1
}

variable "node_max_size" {
  type    = number
  default = 2
}

variable "node_desired_size" {
  type    = number
  default = 1
}

# ─── RDS ──────────────────────────────────────────────────────────────────────
variable "rds_instance_class" {
  type    = string
  default = "db.t4g.micro"
}
