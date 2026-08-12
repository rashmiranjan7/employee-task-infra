# ─── EKS Cluster IAM Role ─────────────────────────────────────────────────────
resource "aws_iam_role" "cluster" {
  name = "${var.cluster_name}-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
  role       = aws_iam_role.cluster.name
}

# ─── EKS Cluster Security Group ────────────────────────────────────────────────
resource "aws_security_group" "cluster" {
  name        = "${var.cluster_name}-cluster-sg"
  description = "EKS control plane security group"
  vpc_id      = var.vpc_id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.cluster_name}-cluster-sg"
  }
}

resource "aws_cloudwatch_log_group" "cluster" {
  name              = "/aws/eks/${var.cluster_name}/cluster"
  retention_in_days = 7
}

# ─── Node Launch Template ───────────────────────────────────────────────────
# Managed node groups don't attach a custom security group by default — only
# the cluster's shared SG. Without this launch template, aws_security_group.node
# (the one RDS's ingress rule expects traffic to come from) is created but
# never actually attached to any instance, silently breaking DB connectivity.
resource "aws_launch_template" "node" {
  name_prefix = "${var.cluster_name}-node-"

  vpc_security_group_ids = [aws_security_group.node.id]

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.cluster_name}-node"
    }
  }

  lifecycle {
    create_before_destroy = true
  }
}

# ─── EKS Cluster ────────────────────────────────────────────────────────────────
resource "aws_eks_cluster" "this" {
  name     = var.cluster_name
  role_arn = aws_iam_role.cluster.arn
  version  = var.cluster_version

  vpc_config {
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    security_group_ids      = [aws_security_group.cluster.id]
    endpoint_private_access = true
    endpoint_public_access  = true
  }

  # No customer-managed KMS key for secrets encryption here. EKS secrets are
  # already encrypted at rest by AWS by default — adding a second,
  # project-managed key on top is one more ARN to lose track of without a
  # concrete reason to (e.g. a compliance requirement for a customer-managed
  # key specifically).
  enabled_cluster_log_types = ["api"]

  depends_on = [
    aws_iam_role_policy_attachment.cluster_policy,
    aws_cloudwatch_log_group.cluster,
  ]

  tags = {
    Name = var.cluster_name
  }
}

# ─── Node Group IAM Role ────────────────────────────────────────────────────────
resource "aws_iam_role" "node" {
  name = "${var.cluster_name}-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_worker_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_cni_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
  role       = aws_iam_role.node.name
}

resource "aws_iam_role_policy_attachment" "node_registry_policy" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
  role       = aws_iam_role.node.name
}

# NOTE: the AWS Load Balancer Controller's permissions are granted via IRSA
# now (see irsa.tf) — a role scoped to just that controller's ServiceAccount,
# not the whole node. An earlier version of this module also attached the
# same policy directly to the node role as a fallback while IRSA was being
# set up; that's been removed. Leaving both in place would mean a broken
# IRSA config (wrong policy, missing ServiceAccount annotation, etc.) fails
# SILENTLY — the controller just keeps working via the node's broader
# permissions instead of surfacing the misconfiguration. With only IRSA
# granting these permissions, a broken IRSA setup now fails loudly
# (AccessDenied in the controller's logs), which is what you want while
# learning this pattern.

# ─── Node Security Group ────────────────────────────────────────────────────────
resource "aws_security_group" "node" {
  name        = "${var.cluster_name}-node-sg"
  description = "EKS node group security group"
  vpc_id      = var.vpc_id

  ingress {
    description     = "Allow traffic from cluster control plane"
    from_port       = 0
    to_port         = 65535
    protocol        = "tcp"
    security_groups = [aws_security_group.cluster.id]
  }

  ingress {
    description = "Allow node-to-node communication"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name                                        = "${var.cluster_name}-node-sg"
    "kubernetes.io/cluster/${var.cluster_name}" = "owned"
  }
}

# ─── Cluster ← Node ingress (standalone rule to avoid an SG dependency cycle
# with the inline ingress rule inside aws_security_group.node above, which
# references aws_security_group.cluster.id) ─────────────────────────────────
resource "aws_security_group_rule" "cluster_ingress_from_nodes" {
  type                     = "ingress"
  from_port                = 443
  to_port                  = 443
  protocol                 = "tcp"
  security_group_id        = aws_security_group.cluster.id
  source_security_group_id = aws_security_group.node.id
  description               = "Allow nodes to reach the EKS API server"
}

# ─── Managed Node Group (single, on-demand) ─────────────────────────────────────
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.cluster_name}-default"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids

  instance_types = var.node_instance_types
  capacity_type  = "ON_DEMAND"

  scaling_config {
    min_size     = var.node_min_size
    max_size     = var.node_max_size
    desired_size = var.node_desired_size
  }

  launch_template {
    id      = aws_launch_template.node.id
    version = aws_launch_template.node.latest_version
  }

  depends_on = [
    aws_iam_role_policy_attachment.node_worker_policy,
    aws_iam_role_policy_attachment.node_cni_policy,
    aws_iam_role_policy_attachment.node_registry_policy,
  ]

  tags = {
    Name = "${var.cluster_name}-default"
  }

  # Nothing outside Terraform changes node count in this project today (no
  # cluster autoscaler), so this is a low-stakes safety net rather than a
  # currently-active concern — kept enabled so a future HPA-driven or
  # cluster-autoscaler-driven change to desired_size doesn't get silently
  # reverted by the next `terraform apply`.
  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# ─── EKS Add-ons ─────────────────────────────────────────────────────────────────
resource "aws_eks_addon" "vpc_cni" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "vpc-cni"
}

resource "aws_eks_addon" "coredns" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "coredns"
  depends_on   = [aws_eks_node_group.this]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name = aws_eks_cluster.this.name
  addon_name   = "kube-proxy"
}

################################################################################
# EKS OIDC Provider (Required for IRSA)
################################################################################

data "tls_certificate" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer

  client_id_list = [
    "sts.amazonaws.com"
  ]

  thumbprint_list = [
    data.tls_certificate.eks.certificates[0].sha1_fingerprint
  ]

  tags = {
    Name = "${var.cluster_name}-oidc"
  }
}
