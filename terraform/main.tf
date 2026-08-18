# Employee Task - infra for the dev environment.
# This project only runs ONE environment (dev). Everything AWS needs -
# network, EKS cluster, database, container registry, HTTPS cert, DNS,
# the CI IAM role, and the Jenkins server - is created by this one
# terraform apply. No separate "global" step, no prod.
#
# Usage:
#   terraform init -backend-config=backend.hcl
#   terraform apply -var-file=terraform.tfvars

terraform {
  required_version = ">= 1.6.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.31"
    }

    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.25"
    }

    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }

    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }

  backend "s3" {
    # config comes from: terraform init -backend-config=backend.hcl
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "employee-task"
      Environment = "dev"
      ManagedBy   = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

locals {
  cluster_name = "employee-task-dev"
  namespace    = "employee-task-dev"
}

# ─── Networking ─────────────────────────────────────────────────────────────
module "vpc" {
  source = "./modules/vpc"

  cluster_name       = local.cluster_name
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  public_subnets     = var.public_subnets
  private_subnets    = var.private_subnets
  database_subnets   = var.database_subnets
}

# ─── EKS ──────────────────────────────────────────────────────────────────────
module "eks" {
  source = "./modules/eks"

  cluster_name        = local.cluster_name
  cluster_version     = var.cluster_version
  vpc_id              = module.vpc.vpc_id
  vpc_cidr            = var.vpc_cidr
  private_subnet_ids  = module.vpc.private_subnet_ids
  public_subnet_ids   = module.vpc.public_subnet_ids
  node_instance_types = var.node_instance_types
  node_min_size       = var.node_min_size
  node_max_size       = var.node_max_size
  node_desired_size   = var.node_desired_size
}

# ─── RDS ──────────────────────────────────────────────────────────────────────
module "rds" {
  source = "./modules/rds"

  identifier              = "employee-task-dev-db"
  vpc_id                  = module.vpc.vpc_id
  database_subnet_ids     = module.vpc.database_subnet_ids
  allowed_security_groups = [module.eks.node_security_group_id]
  instance_class          = var.rds_instance_class
  multi_az                = false
}

# ─── ECR (one repo each for backend/frontend images) ────────────────────────
module "ecr" {
  source = "./modules/ecr"
}

# ─── DNS + HTTPS cert for the one hostname the app uses ─────────────────────
module "route53" {
  source = "./modules/route53"

  domain_name = var.domain_name
}

module "acm" {
  source = "./modules/acm"

  domain_name = var.domain_name
  # A wildcard here means one certificate covers the app's own hostname
  # (rashmidevops.xyz, from domain_name above) AND any one-level
  # subdomain - argocd.rashmidevops.xyz today, anything else later -
  # without needing another Terraform change each time.
  subject_alternative_names = ["*.${var.domain_name}"]
  route53_zone_id            = module.route53.zone_id
}

# ─── GitHub Actions OIDC role: lets the workflow push to ECR ────────────────
# without a long-lived AWS access key stored as a GitHub secret. GitHub
# hands the workflow a short-lived token; AWS trusts it came from GitHub
# via this provider, and only lets it assume the one role below.
resource "aws_iam_openid_connect_provider" "github_actions" {
  url = "https://token.actions.githubusercontent.com"

  client_id_list = [
    "sts.amazonaws.com"
  ]

  # thumbprint_list is optional here - AWS provider v5.x validates GitHub's
  # certificate chain itself for well-known OIDC providers.
}

resource "aws_iam_role" "github_actions" {
  name = "employee-task-github-actions"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRoleWithWebIdentity"
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github_actions.arn }
      Condition = {
        StringEquals = {
          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"
        }
        # Only this one GitHub repo can assume this role.
        # Only this one GitHub repo can assume this role. Matches BOTH
        # subject formats GitHub can send: the classic name-based one
        # (repo:OWNER/REPO:*) and, since GitHub started using it for all
        # repos created after July 15 2026, the newer immutable-ID one
        # (repo:OWNER@id/REPO@id:*) - the "@*" wildcard matches whatever
        # numeric owner/repo ID GitHub embeds, so this doesn't need to be
        # updated if the repo is ever renamed or the ID changes.
        # https://github.blog/changelog/2026-04-23-immutable-subject-claims-for-github-actions-oidc-tokens/
        StringLike = {
          "token.actions.githubusercontent.com:sub" = [
            "repo:${var.github_repo_subject}:*",
            "repo:${split("/", var.github_repo_subject)[0]}@*/${split("/", var.github_repo_subject)[1]}@*:*",
          ]
        }
      }
    }]
  })
}

resource "aws_iam_role_policy" "github_actions_ecr" {
  name = "employee-task-github-actions-ecr"
  role = aws_iam_role.github_actions.id

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
        Resource = values(module.ecr.repository_arns)
      }
    ]
  })
}

# ─── Jenkins server ─────────────────────────────────────────────────────────
# Terraform creates the EC2 instance AND installs Jenkins + Docker + kubectl
# + Helm + Trivy on it (via user_data - see modules/jenkins-server/user-data.sh).
# One apply, one server, nothing to run by hand afterwards.
module "jenkins_server" {
  source = "./modules/jenkins-server"

  admin_cidr          = var.jenkins_admin_cidr
  ssh_key_name        = var.jenkins_ssh_key_name
  ecr_repository_arns = values(module.ecr.repository_arns)
}

# ─── Kubernetes auth (uses the EKS cluster this same apply just created) ────
provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

  exec {
    api_version = "client.authentication.k8s.io/v1"
    command     = "aws"
    args = [
      "eks",
      "get-token",
      "--cluster-name",
      module.eks.cluster_name
    ]
  }
}

# ─── App secrets ────────────────────────────────────────────────────────────
# Terraform already knows the RDS password (it just created it) and
# generates the JWT secrets itself, so it writes them straight into a
# Kubernetes Secret. The Helm chart just reads this Secret by name - it
# never contains a secret value itself, so nothing sensitive is in Git.
resource "random_password" "jwt_secret" {
  length  = 48
  special = false
}

resource "random_password" "jwt_refresh_secret" {
  length  = 48
  special = false
}

resource "kubernetes_namespace" "app" {
  metadata {
    name = local.namespace
  }

  depends_on = [module.eks]
}

resource "kubernetes_secret" "app" {
  metadata {
    name      = "employee-task-secrets"
    namespace = kubernetes_namespace.app.metadata[0].name
  }

  data = {
    DB_HOST            = module.rds.endpoint
    DB_PORT            = tostring(module.rds.port)
    DB_NAME            = module.rds.database_name
    DB_USER            = module.rds.master_username
    DB_PASSWORD        = module.rds.master_password
    JWT_SECRET         = random_password.jwt_secret.result
    JWT_REFRESH_SECRET = random_password.jwt_refresh_secret.result
  }

  type = "Opaque"
}
