# ─── Find the account's default VPC + a public subnet in it ─────────────────
# Jenkins is one shared server used by both environments' pipelines, not
# part of either environment's dedicated VPC — putting it in the default
# VPC avoids standing up (and paying for) a whole extra VPC/NAT Gateway just
# to host one EC2 instance.
data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }
}

# ─── Security Group ─────────────────────────────────────────────────────────
resource "aws_security_group" "jenkins" {
  name        = "employee-task-jenkins-sg"
  description = "Jenkins server - SSH for admin access, 8080 for the UI"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "SSH (backup admin access) - restrict this to your own IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  ingress {
    description = "Jenkins UI"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.admin_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "employee-task-jenkins-sg"
  }
}

# ─── IAM: just enough to push images to ECR, nothing else ──────────────────
resource "aws_iam_role" "jenkins" {
  name = "employee-task-jenkins-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "jenkins_ecr" {
  name = "employee-task-jenkins-ecr-push"
  role = aws_iam_role.jenkins.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ECRAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "ECRPush"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:PutImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:BatchGetImage",
        ]
        Resource = var.ecr_repository_arns
      }
    ]
  })
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "employee-task-jenkins-profile"
  role = aws_iam_role.jenkins.name
}

# ─── EC2 instance ────────────────────────────────────────────────────────────
# user-data.sh runs automatically on first boot and installs Jenkins,
# Docker, kubectl, Helm, Trivy, and Node - everything the Jenkinsfile
# needs. No separate setup step after `terraform apply`.
resource "aws_instance" "jenkins" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnets.default_public.ids[0]
  vpc_security_group_ids = [aws_security_group.jenkins.id]
  iam_instance_profile   = aws_iam_instance_profile.jenkins.name
  key_name               = var.ssh_key_name
  user_data              = file("${path.module}/user-data.sh")

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = {
    Name = "employee-task-jenkins"
  }
}
