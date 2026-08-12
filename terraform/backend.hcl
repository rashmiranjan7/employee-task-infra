# Fill in your own S3 bucket name (must already exist - see
# scripts/bootstrap-backend.sh) and run:
#   terraform init -backend-config=backend.hcl

bucket         = "employee-task-tfstate-897074277336"
key            = "dev/terraform.tfstate"
region         = "us-east-1"
dynamodb_table = "employee-task-tf-locks"
encrypt        = true
