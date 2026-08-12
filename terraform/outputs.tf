output "cluster_name" {
  value = module.eks.cluster_name
}

output "configure_kubectl" {
  value = "aws eks update-kubeconfig --name ${module.eks.cluster_name} --region ${var.aws_region}"
}

output "rds_endpoint" {
  value = module.rds.endpoint
}

output "namespace" {
  description = "The Kubernetes namespace the app runs in"
  value       = kubernetes_namespace.app.metadata[0].name
}

# Read by install-cluster-addons.sh to wire up the AWS Load Balancer
# Controller so it actually assumes this IAM role instead of the node's own
# role. Without this, the role Terraform created is never used.
output "alb_controller_irsa_role_arn" {
  description = "IRSA role ARN for the AWS Load Balancer Controller ServiceAccount"
  value       = module.eks.alb_controller_irsa_role_arn
}

output "oidc_provider_arn" {
  description = "This cluster's OIDC provider ARN"
  value       = module.eks.oidc_provider_arn
}

output "ecr_repository_urls" {
  description = "Push images here - set this (minus the /backend or /frontend part) as image.registry in the Helm chart's values.yaml"
  value       = module.ecr.repository_urls
}

output "acm_certificate_arn" {
  description = "Set this as ingress.tls.certificateArn in the Helm chart's values.yaml"
  value       = module.acm.certificate_arn
}

output "github_actions_role_arn" {
  description = "Set this as the AWS_ROLE_ARN secret in the GitHub repo"
  value       = aws_iam_role.github_actions.arn
}

output "jenkins_public_ip" {
  description = "Jenkins UI: http://<this-ip>:8080 (open only to jenkins_admin_cidr)"
  value       = module.jenkins_server.public_ip
}

output "route53_zone_id" {
  value = module.route53.zone_id
}
