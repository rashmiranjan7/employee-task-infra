#!/usr/bin/env bash
#
# install-cluster-addons.sh - installs everything the EKS cluster needs
# before the app can be deployed: the AWS Load Balancer Controller (with
# IRSA) and ArgoCD, plus an Ingress so the ArgoCD UI is reachable over
# HTTPS.
#
# Run once, right after `terraform apply` succeeds. Safe to re-run.
#
# Usage:
#   ./install-cluster-addons.sh

set -euo pipefail

CLUSTER_NAME="employee-task-dev"
AWS_REGION="us-east-1"
APP_DOMAIN="yourdomain.com"   # same value as domain_name in terraform.tfvars
ARGOCD_HOSTNAME="argocd.${APP_DOMAIN}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"

echo "=================================================="
echo " Phase 1: Configuring kubectl"
echo "=================================================="

aws eks update-kubeconfig \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}"

VPC_ID=$(aws eks describe-cluster \
  --name "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --query "cluster.resourcesVpcConfig.vpcId" \
  --output text)

echo "VPC ID: ${VPC_ID}"

kubectl get nodes
echo "OK: kubectl is talking to ${CLUSTER_NAME} and at least one node is visible above."

echo
echo "=================================================="
echo " Phase 2: Installing the AWS Load Balancer Controller (with IRSA)"
echo "=================================================="

# Without this role annotated onto the ServiceAccount, the controller pod
# has no AWS permissions to create a load balancer at all. If this comes
# back empty, check that `terraform apply` actually finished.
ALB_IRSA_ROLE_ARN=$(terraform -chdir="${TF_DIR}" output -raw alb_controller_irsa_role_arn)

if [[ -z "${ALB_IRSA_ROLE_ARN}" ]]; then
  echo "ERROR: alb_controller_irsa_role_arn is empty. Run 'terraform apply' in" >&2
  echo "       ${TF_DIR} first." >&2
  exit 1
fi

echo "IRSA role for aws-load-balancer-controller: ${ALB_IRSA_ROLE_ARN}"

helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --set replicaCount=1 \
  --set serviceAccount.create=true \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${ALB_IRSA_ROLE_ARN}" \
  --wait

kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=120s
ANNOTATED_ROLE=$(kubectl -n kube-system get serviceaccount aws-load-balancer-controller \
  -o jsonpath='{.metadata.annotations.eks\.amazonaws\.com/role-arn}')
if [[ "${ANNOTATED_ROLE}" != "${ALB_IRSA_ROLE_ARN}" ]]; then
  echo "ERROR: ServiceAccount annotation is '${ANNOTATED_ROLE}', expected '${ALB_IRSA_ROLE_ARN}'." >&2
  exit 1
fi
echo "OK: aws-load-balancer-controller is Running and its ServiceAccount is annotated with the IRSA role."

echo
echo "=================================================="
echo " Phase 3: Installing ArgoCD"
echo "=================================================="

helm repo add argo https://argoproj.github.io/argo-helm >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl create namespace argocd --dry-run=client -o yaml | kubectl apply -f -

helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set crds.install=true \
  --set configs.params."server\.insecure"=true \
  --wait \
  --timeout 10m

kubectl -n argocd rollout status deployment/argocd-server --timeout=300s
echo "OK: argocd-server is Running."

echo
echo "=================================================="
echo " Phase 4: Exposing ArgoCD's UI (Ingress)"
echo "=================================================="

ACM_CERT_ARN=$(terraform -chdir="${TF_DIR}" output -raw acm_certificate_arn)

if [[ -z "${ACM_CERT_ARN}" ]]; then
  echo "ERROR: acm_certificate_arn is empty. Run 'terraform apply' first, and" >&2
  echo "       confirm the certificate finished validating:" >&2
  echo "       aws acm describe-certificate --certificate-arn <arn> --query 'Certificate.Status'" >&2
  exit 1
fi

echo "ACM certificate: ${ACM_CERT_ARN}"
echo "ArgoCD hostname: ${ARGOCD_HOSTNAME}"

sed \
  -e "s|__ACM_CERTIFICATE_ARN__|${ACM_CERT_ARN}|" \
  -e "s|__ARGOCD_HOSTNAME__|${ARGOCD_HOSTNAME}|" \
  "${REPO_ROOT}/k8s/argocd/ingress.yaml.tpl" \
  | kubectl apply -f -

echo "--> Waiting for the ALB to be provisioned (this can take 2-3 minutes)..."
for i in $(seq 1 30); do
  ALB_HOSTNAME=$(kubectl -n argocd get ingress argocd-server -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  if [[ -n "${ALB_HOSTNAME}" ]]; then
    break
  fi
  sleep 10
done

if [[ -z "${ALB_HOSTNAME}" ]]; then
  echo "ERROR: the ArgoCD Ingress has no ADDRESS after 5 minutes." >&2
  echo "       Check the controller's logs for the real reason:" >&2
  echo "       kubectl -n kube-system logs -l app.kubernetes.io/name=aws-load-balancer-controller --tail=50" >&2
  exit 1
fi
echo "OK: ALB provisioned - ${ALB_HOSTNAME}"

echo
echo "=================================================="
echo " Phase 5: Point DNS at the ArgoCD ALB"
echo "=================================================="
"${REPO_ROOT}/scripts/update-dns.sh" upsert "${ARGOCD_HOSTNAME}" "${ALB_HOSTNAME}"

echo
echo "=================================================="
echo " Cluster add-ons installed successfully"
echo "=================================================="
echo
echo "ArgoCD UI:      https://${ARGOCD_HOSTNAME}"
echo "ArgoCD admin password:"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d
echo
echo
echo "Next: apply apps/dev-application.yaml from employee-task-gitops (see SETUP.md)."
