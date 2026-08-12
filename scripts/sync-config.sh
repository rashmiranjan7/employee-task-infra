#!/usr/bin/env bash
# sync-config.sh - copies the ECR registry, ACM cert ARN, and hostname
# from terraform output straight into the Helm chart's values.yaml in
# employee-task-app, instead of typing them in by hand.
#
# Run once, after `terraform apply` succeeds.
#
# Requires: terraform, yq, jq, git.
#
# Usage:
#   ./sync-config.sh <path-to-employee-task-app>
# Example:
#   ./sync-config.sh ../employee-task-app

set -euo pipefail

APP_PATH="${1:?Usage: $0 <path-to-employee-task-app>}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="${REPO_ROOT}/terraform"
AWS_REGION="us-east-1"
APP_DOMAIN="yourdomain.com"   # same value as domain_name in terraform.tfvars

echo "==> Reading terraform output"
cd "${TF_DIR}"
ECR_URLS_JSON="$(terraform output -json ecr_repository_urls)"
ACM_CERT_ARN="$(terraform output -raw acm_certificate_arn)"
GITHUB_ROLE_ARN="$(terraform output -raw github_actions_role_arn)"

# Both repo URLs share the same registry prefix (everything before the
# first "/") - take it from either one.
ECR_REGISTRY="$(echo "${ECR_URLS_JSON}" | jq -r 'to_entries[0].value | split("/")[0]')"

# ─── Update the Helm chart's values.yaml ────────────────────────────────────
VALUES_FILE="${APP_PATH}/helm/employee-task/values.yaml"
echo "==> Updating ${VALUES_FILE}"
cd "${APP_PATH}"
yq -i ".image.registry = \"${ECR_REGISTRY}\"" "helm/employee-task/values.yaml"
yq -i ".ingress.host = \"${APP_DOMAIN}\"" "helm/employee-task/values.yaml"
yq -i ".ingress.tls.certificateArn = \"${ACM_CERT_ARN}\"" "helm/employee-task/values.yaml"
git add "helm/employee-task/values.yaml"

if git diff --cached --quiet; then
  echo "    (no changes - already up to date)"
else
  git commit -m "chore: sync registry + cert ARN + hostname from terraform output [skip ci]"
  git push origin HEAD
  echo "    committed and pushed"
fi

# ─── Print what to paste into GitHub Settings ──────────────────────────────
echo ""
echo "==> Now set these in employee-task-app's GitHub Settings -> Secrets"
echo "    and variables -> Actions:"
echo ""
echo "    Secret    AWS_ROLE_ARN     ${GITHUB_ROLE_ARN}"
echo "    Variable  AWS_REGION       ${AWS_REGION}"
echo "    Variable  ECR_REGISTRY     ${ECR_REGISTRY}"
echo ""
echo "    Plus one more that doesn't come from terraform output:"
echo "    Secret    SLACK_WEBHOOK_URL  optional - from a Slack incoming webhook"
