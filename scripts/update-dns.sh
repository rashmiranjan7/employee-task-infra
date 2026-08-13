#!/usr/bin/env bash
# update-dns.sh — points one hostname at one ALB (UPSERT), or removes a
# hostname entirely (DELETE), always using the record's actual current
# value rather than one a human has to know or paste in.
#
# Handles both cases: a subdomain (argocd.rashmidevops.xyz) gets a plain
# CNAME; the apex/root domain (rashmidevops.xyz itself) can't take a
# CNAME per DNS rules, so it gets Route53's Alias A record instead.
#
# Usage:
#   ./update-dns.sh upsert <hostname> <alb-hostname>
#   ./update-dns.sh delete <hostname>
# Examples:
#   ./update-dns.sh upsert argocd.rashmidevops.xyz k8s-abc123-456789.us-east-1.elb.amazonaws.com
#   ./update-dns.sh upsert rashmidevops.xyz k8s-abc123-456789.us-east-1.elb.amazonaws.com
#   ./update-dns.sh delete argocd.rashmidevops.xyz

set -euo pipefail

ACTION="${1:?Usage: $0 <upsert|delete> <hostname> [alb-hostname]}"
HOSTNAME="${2:?Usage: $0 <upsert|delete> <hostname> [alb-hostname]}"
DOMAIN="rashmidevops.xyz"

ZONE_ID=$(aws route53 list-hosted-zones-by-name \
  --dns-name "${DOMAIN}" \
  --query "HostedZones[0].Id" \
  --output text)

if [[ -z "${ZONE_ID}" || "${ZONE_ID}" == "None" ]]; then
  echo "ERROR: no hosted zone found for ${DOMAIN}" >&2
  exit 1
fi

# DNS doesn't allow a CNAME at the apex/root of a domain (rashmidevops.xyz
# itself) - only on subdomains (argocd.rashmidevops.xyz). Route53's
# equivalent for the apex is an Alias A record, which needs the ALB's own
# "canonical hosted zone ID" (a fixed value per AWS region/service, not
# something we choose) rather than a TTL/value pair.
IS_APEX="false"
if [[ "${HOSTNAME}" == "${DOMAIN}" ]]; then
  IS_APEX="true"
fi

case "${ACTION}" in
  upsert)
    ALB_HOSTNAME="${3:?Usage: $0 upsert <hostname> <alb-hostname>}"
    echo "==> UPSERT ${HOSTNAME} -> ${ALB_HOSTNAME}"

    if [[ "${IS_APEX}" == "true" ]]; then
      ALB_ZONE_ID=$(aws elbv2 describe-load-balancers \
        --query "LoadBalancers[?DNSName=='${ALB_HOSTNAME}'].CanonicalHostedZoneId" \
        --output text)
      if [[ -z "${ALB_ZONE_ID}" || "${ALB_ZONE_ID}" == "None" ]]; then
        echo "ERROR: could not find an ALB with DNSName '${ALB_HOSTNAME}' to read its CanonicalHostedZoneId from." >&2
        exit 1
      fi
      CHANGE_BATCH='{
        "Changes": [{
          "Action": "UPSERT",
          "ResourceRecordSet": {
            "Name": "'"${HOSTNAME}"'",
            "Type": "A",
            "AliasTarget": {
              "HostedZoneId": "'"${ALB_ZONE_ID}"'",
              "DNSName": "'"${ALB_HOSTNAME}"'",
              "EvaluateTargetHealth": true
            }
          }
        }]
      }'
    else
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
    fi
    ;;

  delete)
    # Look up the record's CURRENT type/value ourselves - Route53's API
    # requires an exact match to build a valid DELETE change, and asking a
    # human to know/paste that (including whether it's a CNAME or an Alias
    # A record) is exactly the kind of manual step that goes stale.
    RECORD_JSON=$(aws route53 list-resource-record-sets \
      --hosted-zone-id "${ZONE_ID}" \
      --query "ResourceRecordSets[?Name=='${HOSTNAME}.']" \
      --output json)

    if [[ "${RECORD_JSON}" == "[]" ]]; then
      echo "OK: ${HOSTNAME} has no record to delete — nothing to do."
      exit 0
    fi

    RECORD_TYPE=$(echo "${RECORD_JSON}" | jq -r '.[0].Type')

    if [[ "${RECORD_TYPE}" == "A" ]]; then
      ALIAS_ZONE_ID=$(echo "${RECORD_JSON}" | jq -r '.[0].AliasTarget.HostedZoneId')
      ALIAS_DNS=$(echo "${RECORD_JSON}" | jq -r '.[0].AliasTarget.DNSName')
      echo "==> DELETE ${HOSTNAME} (currently an Alias A record -> ${ALIAS_DNS})"
      CHANGE_BATCH='{
        "Changes": [{
          "Action": "DELETE",
          "ResourceRecordSet": {
            "Name": "'"${HOSTNAME}"'",
            "Type": "A",
            "AliasTarget": {
              "HostedZoneId": "'"${ALIAS_ZONE_ID}"'",
              "DNSName": "'"${ALIAS_DNS}"'",
              "EvaluateTargetHealth": true
            }
          }
        }]
      }'
    else
      CURRENT_VALUE=$(echo "${RECORD_JSON}" | jq -r '.[0].ResourceRecords[0].Value')
      echo "==> DELETE ${HOSTNAME} (currently a CNAME -> ${CURRENT_VALUE})"
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
    fi
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
  RESOLVED=$(dig +short "${HOSTNAME}" || true)
  echo "OK: ${HOSTNAME} -> ${ALB_HOSTNAME} (dig currently resolves it to: ${RESOLVED:-<not yet propagated globally, this is normal — can take a few minutes>})"
else
  echo "OK: ${HOSTNAME} deleted."
fi