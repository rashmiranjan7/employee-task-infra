variable "repository_names" {
  description = "Repository name suffixes, e.g. [\"backend\", \"frontend\"]"
  type        = list(string)
  default     = ["backend", "frontend"]
}

variable "untagged_image_expiry_days" {
  type    = number
  default = 3
}

variable "tagged_image_keep_count" {
  type    = number
  default = 15
}
