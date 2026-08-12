variable "identifier" {
  type    = string
  default = "employee-task-db"
}

variable "vpc_id" {
  type = string
}

variable "database_subnet_ids" {
  type = list(string)
}

variable "allowed_security_groups" {
  description = "Security group IDs allowed to connect on port 3306 (the EKS node SG)"
  type        = list(string)
}

variable "engine_version" {
  type    = string
  default = "8.0"
}

variable "instance_class" {
  type    = string
  default = "db.t3.micro"
}

variable "multi_az" {
  type    = bool
  default = false
}

variable "allocated_storage" {
  type    = number
  default = 20
}

variable "database_name" {
  type    = string
  default = "tasktracker"
}

variable "master_username" {
  type    = string
  default = "tasktracker_admin"
}
