#!/usr/bin/env bash
# update-dns.sh — points one hostname at one ALB (UPSERT), or removes a
# hostname entirely (DELETE), always using the record's actual current
# value rather than one a human has to know or paste in.
#
# This exists specifically to replace hand-typed `aws route53
# change-resource-record-sets` commands copied out of a markdown doc — that
# pattern is exactly how a stale ALB hostname ends up permanently in
# Route53: someone copies the command once, runs it again later after the
# ALB was recreated, and forgets to swap in the new hostname first. It's
# also how a DELETE ends up needing a manually-pasted "current value" that
# nobody actually re-checked. This script looks the current value up itself
# for DELETE, and takes it as a fresh argument (usually piped straight from
# `kubectl get ingress`) for UPSERT — either way, nothing here can be a
# stale copy-paste.
#
# This intentionally does NOT introduce a cluster controller (like
# external-dns) to fully automate this — see ARCHITECTURE.md for why. It's
# still a manually-triggered step; it's just no longer a hand-typed one.
#
# Usage:
#   ./update-dns.sh upsert <hostname> <alb-hostname>
#   ./update-dns.sh delete <hostname>
# Examples:
#   ./update-dns.sh upsert dev-app.yourdomain.com k8s-abc123-456789.us-east-1.elb.amazonaws.com
#   ./update-dns.sh delete dev-app.yourdomain.com

set -euo pipefail

ACTION="${1:?Usage: $0 <upsert|delete> <hostname> [alb-hostname]}"
HOSTNAME="${2:?Usage: $0 <upsert|delete> <hostname> [alb-hostname]}"
DOMAIN="yourdomain.com"

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${DOMAIN}" \
  --query "HostedZones[0].Id" \
  --output text)

if [[ -z "${ZONE_ID}" || "${ZONE_ID}" == "None" ]]; then
  echo "ERROR: no hosted zone found for ${DOMAIN}" >&2
  exit 1
fi

case "${ACTION}" in
  upsert)
    ALB_HOSTNAME="${3:?Usage: $0 upsert <hostname> <alb-hostname>}"
    echo "==> UPSERT ${HOSTNAME} -> ${ALB_HOSTNAME}"
    CHANGE_BATCH='{
      "Changes": [{
        "Action": "UPSERT",
        "ResourceRecordSet": {
          "Name": "'"${HOSTNAME}"'",
          "Type": "CNAME",
          "TTL": 60,
          "ResourceRecords": [{"Value": "'"${ALB_HOSTNAME}"'"}]
        }
      }]
    }'
    ;;

  delete)
    # Look up the record's CURRENT value ourselves — Route53's API requires
    # the exact current value to build a valid DELETE change, and asking a
    # human to know/paste that value is exactly the kind of manual step
    # that goes stale.
    CURRENT_VALUE=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "${ZONE_ID}" \
      --query "ResourceRecordSets[?Name=='${HOSTNAME}.'].ResourceRecords[0].Value" \
      --output text)

    if [[ -z "${CURRENT_VALUE}" || "${CURRENT_VALUE}" == "None" ]]; then
      echo "OK: ${HOSTNAME} has no record to delete — nothing to do."
      exit 0
    fi

    echo "==> DELETE ${HOSTNAME} (currently -> ${CURRENT_VALUE})"
    CHANGE_BATCH='{
      "Changes": [{
        "Action": "DELETE",
        "ResourceRecordSet": {
          "Name": "'"${HOSTNAME}"'",
          "Type": "CNAME",
          "TTL": 60,
          "ResourceRecords": [{"Value": "'"${CURRENT_VALUE}"'"}]
        }
      }]
    }'
    ;;

  *)
    echo "ERROR: unknown action '${ACTION}' (expected upsert or delete)" >&2
    exit 1
    ;;
esac

CHANGE_ID=$(aws route53 change-resource-record-sets \
  --hosted-zone-id "${ZONE_ID}" \
  --change-batch "${CHANGE_BATCH}" \
  --query "ChangeInfo.Id" \
  --output text)

echo "--> Waiting for the change to propagate to Route53 (not the same as global DNS propagation)..."
aws route53 wait resource-record-sets-changed --id "${CHANGE_ID}"

if [[ "${ACTION}" == "upsert" ]]; then
  RESOLVED=$(dig +short "${HOSTNAME}" CNAME || true)
  echo "OK: ${HOSTNAME} -> ${ALB_HOSTNAME} (dig currently resolves it to: ${RESOLVED:-<not yet propagated globally, this is normal — can take a few minutes>})"
else
  echo "OK: ${HOSTNAME} deleted."
fi
