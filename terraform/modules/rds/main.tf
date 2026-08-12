# ─── Random master password ─────────────────────────────────────────────────
resource "random_password" "master" {
  length           = 32
  special          = true
  override_special = "!#$%^&*()-_=+"
}

# ─── Security Group: only the EKS nodes can reach MySQL ────────────────────
resource "aws_security_group" "rds" {
  name        = "${var.identifier}-sg"
  description = "RDS MySQL security group - allow only from EKS nodes"
  vpc_id      = var.vpc_id

  ingress {
    description     = "MySQL from EKS nodes"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = var.allowed_security_groups
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.identifier}-sg"
  }
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.identifier}-subnet-group"
  subnet_ids = var.database_subnet_ids

  tags = {
    Name = "${var.identifier}-subnet-group"
  }
}

# ─── Parameter Group ──────────────────────────────────────────────────────────
resource "aws_db_parameter_group" "this" {
  name   = "${var.identifier}-params"
  family = "mysql8.0"

  parameter {
    name  = "character_set_server"
    value = "utf8mb4"
  }

  parameter {
    name  = "slow_query_log"
    value = "1"
  }
}

# ─── RDS Instance ─────────────────────────────────────────────────────────────────
resource "aws_db_instance" "this" {
  identifier     = var.identifier
  engine         = "mysql"
  engine_version = var.engine_version
  instance_class = var.instance_class

  allocated_storage = var.allocated_storage
  storage_type      = "gp3"
  # storage_encrypted with no kms_key_id set uses AWS's default RDS-managed
  # key (alias/aws/rds) instead of a project-managed one — one less key ARN
  # to track for the same "encrypted at rest" guarantee.
  storage_encrypted = true

  db_name  = var.database_name
  username = var.master_username
  password = random_password.master.result
  port     = 3306

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.rds.id]
  parameter_group_name   = aws_db_parameter_group.this.name

  multi_az                = var.multi_az
  backup_retention_period = 1

  skip_final_snapshot = true
  apply_immediately   = true

  auto_minor_version_upgrade = true

  tags = {
    Name = var.identifier
  }
}

# ─── Secrets Manager: store the generated credentials ──────────────────────
# So the DB password exists somewhere other than "in someone's head" or a
# plaintext .tfvars file. recovery_window_in_days = 0 means `terraform
# destroy` deletes it immediately instead of leaving a pending-deletion
# secret behind for a project you're actively tearing down and rebuilding
# while learning.
resource "aws_secretsmanager_secret" "db_credentials" {
  name                    = "${var.identifier}/db-credentials"
  description             = "RDS MySQL credentials (${var.identifier})"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "db_credentials" {
  secret_id = aws_secretsmanager_secret.db_credentials.id
  secret_string = jsonencode({
    host     = aws_db_instance.this.address
    port     = aws_db_instance.this.port
    username = var.master_username
    password = random_password.master.result
    dbname   = var.database_name
  })
}
