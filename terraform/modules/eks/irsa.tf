################################################################################
# AWS Load Balancer Controller IRSA
################################################################################

data "aws_iam_policy_document" "alb_controller_assume_role" {
  statement {
    effect = "Allow"

    actions = [
      "sts:AssumeRoleWithWebIdentity"
    ]

    principals {
      type = "Federated"

      identifiers = [
        aws_iam_openid_connect_provider.eks.arn
      ]
    }

    condition {
      test = "StringEquals"

      variable = "${replace(
        aws_eks_cluster.this.identity[0].oidc[0].issuer,
        "https://",
        ""
      )}:sub"

      values = [
        "system:serviceaccount:kube-system:aws-load-balancer-controller"
      ]
    }

    condition {
      test = "StringEquals"

      variable = "${replace(
        aws_eks_cluster.this.identity[0].oidc[0].issuer,
        "https://",
        ""
      )}:aud"

      values = [
        "sts.amazonaws.com"
      ]
    }
  }
}

resource "aws_iam_role" "alb_controller_irsa" {
  name = "${var.cluster_name}-alb-controller-irsa"

  assume_role_policy = data.aws_iam_policy_document.alb_controller_assume_role.json

  tags = {
    Name = "${var.cluster_name}-alb-controller-irsa"
  }
}

# CRITICAL FIX: the previous version of this resource attached a
# CUSTOMER-MANAGED policy by ARN (arn:aws:iam::<account>:policy/AWSLoadBalancerControllerIAMPolicy)
# that Terraform never creates — it only exists if someone manually ran
# `aws iam create-policy` by hand first, following AWS's official docs
# outside of this project entirely. That step was never scripted or
# documented anywhere in this repo, so a fresh clone / fresh AWS account
# fails here with "NoSuchEntity: Policy ... does not exist" on
# terraform apply. This is the same official policy document (see AWS's
# aws-load-balancer-controller docs), but attached the same way the node
# role's fallback policy already is — as an inline policy built from
# alb-controller-iam-policy.json, which IS committed to this repo and
# tracked in Terraform state. Reproducible on any account, first try.
resource "aws_iam_role_policy" "alb_controller_irsa" {
  name   = "${var.cluster_name}-alb-controller-irsa-policy"
  role   = aws_iam_role.alb_controller_irsa.id
  policy = file("${path.module}/alb-controller-iam-policy.json")
}