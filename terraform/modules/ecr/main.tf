# One ECR repo per app (backend/frontend), account+region scoped. Every
# build gets tagged dev-<sha>-<run-number> so each image is traceable back
# to the exact commit and CI run it came from.
resource "aws_ecr_repository" "this" {
  for_each = toset(var.repository_names)

  name                 = "employee-task-${each.key}"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = {
    Name      = "employee-task-${each.key}"
    Component = each.key
  }
}

# Cost control: without this, every commit's image is retained forever.
# Untagged (dangling) images expire quickly; tagged images are capped to
# the N most recent so old builds don't accumulate indefinitely.
resource "aws_ecr_lifecycle_policy" "this" {
  for_each   = aws_ecr_repository.this
  repository = each.value.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after ${var.untagged_image_expiry_days} days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = var.untagged_image_expiry_days
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the most recent ${var.tagged_image_keep_count} tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["dev-"]
          countType     = "imageCountMoreThan"
          countNumber   = var.tagged_image_keep_count
        }
        action = { type = "expire" }
      }
    ]
  })
}
