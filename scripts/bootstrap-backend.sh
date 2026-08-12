#!/usr/bin/env bash
# Bootstraps the S3 bucket + DynamoDB table used by Terraform remote
# state (see terraform/backend.hcl).
#
# Safe to run more than once: bucket/table creation is skipped if they
# already exist.
#
# Usage: ./bootstrap-backend.sh <aws-region>
# Example: ./bootstrap-backend.sh us-east-1

set -euo pipefail

REGION="${1:-us-east-1}"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET_NAME="employee-task-tfstate-${ACCOUNT_ID}"
TABLE_NAME="employee-task-tf-locks"

echo "Bootstrapping Terraform backend in account ${ACCOUNT_ID} / region ${REGION}"
echo "  Bucket: ${BUCKET_NAME}"
echo "  Table:  ${TABLE_NAME}"
echo

# ─── S3 bucket for state ──────────────────────────────────────────────────────
if aws s3api head-bucket --bucket "${BUCKET_NAME}" 2>/dev/null; then
  echo "Bucket ${BUCKET_NAME} already exists, skipping creation."
else
  echo "Creating S3 bucket: ${BUCKET_NAME}"
  if [ "${REGION}" == "us-east-1" ]; then
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}"
  else
    aws s3api create-bucket --bucket "${BUCKET_NAME}" --region "${REGION}" \
      --create-bucket-configuration LocationConstraint="${REGION}"
  fi

  aws s3api put-bucket-versioning --bucket "${BUCKET_NAME}" \
    --versioning-configuration Status=Enabled

  aws s3api put-bucket-encryption --bucket "${BUCKET_NAME}" \
    --server-side-encryption-configuration '{
      "Rules": [{ "ApplyServerSideEncryptionByDefault": { "SSEAlgorithm": "AES256" } }]
    }'

  aws s3api put-public-access-block --bucket "${BUCKET_NAME}" \
    --public-access-block-configuration \
    BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
fi

# ─── DynamoDB table for state locking ─────────────────────────────────────────
if aws dynamodb describe-table --table-name "${TABLE_NAME}" --region "${REGION}" &>/dev/null; then
  echo "DynamoDB table ${TABLE_NAME} already exists, skipping creation."
else
  echo "Creating DynamoDB table: ${TABLE_NAME}"
  aws dynamodb create-table \
    --table-name "${TABLE_NAME}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${REGION}"

  aws dynamodb wait table-exists --table-name "${TABLE_NAME}" --region "${REGION}"
fi

echo
echo "Backend bootstrap complete."
echo "Now update the 'bucket' value in terraform/backend.hcl to: ${BUCKET_NAME}"
