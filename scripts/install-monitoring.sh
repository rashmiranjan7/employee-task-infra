#!/usr/bin/env bash
#
# install-monitoring.sh - installs Prometheus + Alertmanager + Grafana
# inside the cluster, reusing the same alert rules / dashboard already
# defined in employee-task-app/monitoring/ (the local Docker Compose
# stack), so there's one place these are authored, not two.
#
# Run once, any time after the app is already deployed (needs the backend
# Service to exist). Safe to re-run.
#
# Usage:
#   ./install-monitoring.sh <path-to-employee-task-app-repo>
# Example:
#   ./install-monitoring.sh ../employee-task-app
#
# Slack is optional: export SLACK_WEBHOOK_URL before running to wire up
# Alertmanager -> Slack. If unset, Alertmanager just runs with no webhook.

set -euo pipefail

APP_REPO="${1:?Usage: $0 <path-to-employee-task-app-repo>}"
NAMESPACE="monitoring"
APP_NAMESPACE="employee-task-dev"
BACKEND_SVC="employee-task-dev-backend"
MON_DIR="${APP_REPO}/monitoring"

if [[ ! -d "${MON_DIR}" ]]; then
  echo "ERROR: ${MON_DIR} not found - check the path to employee-task-app." >&2
  exit 1
fi

if ! kubectl -n "${APP_NAMESPACE}" get service "${BACKEND_SVC}" >/dev/null 2>&1; then
  echo "ERROR: Service ${BACKEND_SVC} not found in namespace ${APP_NAMESPACE}." >&2
  echo "       Deploy the app first (see SETUP.md)." >&2
  exit 1
fi
echo "OK: found backend Service ${BACKEND_SVC}.${APP_NAMESPACE}"

echo
echo "=================================================="
echo " Phase 1: Namespace + Slack webhook secret"
echo "=================================================="

kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

if [[ -n "${SLACK_WEBHOOK_URL:-}" ]]; then
  kubectl -n "${NAMESPACE}" create secret generic alertmanager-slack \
    --from-literal=slack_url="${SLACK_WEBHOOK_URL}" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "OK: alertmanager-slack secret created from \$SLACK_WEBHOOK_URL."
else
  kubectl -n "${NAMESPACE}" create secret generic alertmanager-slack \
    --from-literal=slack_url="" \
    --dry-run=client -o yaml | kubectl apply -f -
  echo "WARNING: SLACK_WEBHOOK_URL not set - Alertmanager will run with no Slack webhook."
fi

echo
echo "=================================================="
echo " Phase 2: Installing Alertmanager"
echo "=================================================="

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

# The chart expects `config` as a real YAML object, not a raw string, so
# build a small values file that nests alertmanager.yml's content under it.
ALERTMANAGER_VALUES="$(mktemp)"
{
  echo "config:"
  sed 's/^/  /' "${MON_DIR}/prometheus/alertmanager.yml"
} > "${ALERTMANAGER_VALUES}"

helm upgrade --install alertmanager prometheus-community/alertmanager \
  --namespace "${NAMESPACE}" \
  -f "${ALERTMANAGER_VALUES}" \
  --set persistence.enabled=false \
  --set extraSecretMounts[0].name=slack-secret \
  --set extraSecretMounts[0].secretName=alertmanager-slack \
  --set extraSecretMounts[0].mountPath=/etc/alertmanager/secrets \
  --wait --timeout 5m

rm -f "${ALERTMANAGER_VALUES}"

kubectl -n "${NAMESPACE}" rollout status statefulset/alertmanager --timeout=120s
echo "OK: Alertmanager is Running."

echo
echo "=================================================="
echo " Phase 3: Installing Prometheus (scraping the real backend Service)"
echo "=================================================="

PROMETHEUS_VALUES="$(mktemp)"
{
  echo "serverFiles:"
  echo "  alerting_rules.yml:"
  sed 's/^/    /' "${MON_DIR}/prometheus/alert.rules.yml"
} > "${PROMETHEUS_VALUES}"

helm upgrade --install prometheus prometheus-community/prometheus \
  --namespace "${NAMESPACE}" \
  --set alertmanager.enabled=false \
  --set server.persistentVolume.enabled=false \
  --set server.alertmanagers[0].static_configs[0].targets[0]="alertmanager.${NAMESPACE}.svc:9093" \
  -f "${PROMETHEUS_VALUES}" \
  --set-string extraScrapeConfigs="- job_name: employee-task-backend
  metrics_path: /metrics
  static_configs:
    - targets: ['${BACKEND_SVC}.${APP_NAMESPACE}.svc.cluster.local:5000']" \
  --wait --timeout 5m

rm -f "${PROMETHEUS_VALUES}"

kubectl -n "${NAMESPACE}" rollout status deployment/prometheus-server --timeout=180s
echo "OK: Prometheus is Running."

echo
echo "=================================================="
echo " Phase 4: Installing Grafana (existing dashboard + datasource)"
echo "=================================================="

helm repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

kubectl -n "${NAMESPACE}" create configmap grafana-dashboard-app-overview \
  --from-file="${MON_DIR}/grafana/dashboards/application-overview.json" \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n "${NAMESPACE}" label configmap grafana-dashboard-app-overview grafana_dashboard=1 --overwrite

helm upgrade --install grafana grafana/grafana \
  --namespace "${NAMESPACE}" \
  --set adminUser=admin \
  --set persistence.enabled=false \
  --set sidecar.dashboards.enabled=true \
  --set sidecar.dashboards.label=grafana_dashboard \
  --set datasources."datasources\.yaml".apiVersion=1 \
  --set datasources."datasources\.yaml".datasources[0].name=Prometheus \
  --set datasources."datasources\.yaml".datasources[0].type=prometheus \
  --set datasources."datasources\.yaml".datasources[0].url="http://prometheus-server.${NAMESPACE}.svc" \
  --set datasources."datasources\.yaml".datasources[0].isDefault=true \
  --wait --timeout 5m

kubectl -n "${NAMESPACE}" rollout status deployment/grafana --timeout=180s
echo "OK: Grafana is Running."
GRAFANA_PASSWORD=$(kubectl -n "${NAMESPACE}" get secret grafana -o jsonpath='{.data.admin-password}' | base64 -d)

echo
echo "=================================================="
echo " Monitoring installed successfully"
echo "=================================================="
echo
echo "No public hostname for Grafana - this project only exposes the app"
echo "and ArgoCD over the internet. To open Grafana, port-forward it:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/grafana 3000:80"
echo "  then open http://localhost:3000  (user: admin, password: ${GRAFANA_PASSWORD})"
echo
echo "Verify Prometheus is actually scraping the real backend:"
echo "  kubectl -n ${NAMESPACE} port-forward svc/prometheus-server 9090:80"
echo "  then open http://localhost:9090/targets and confirm the"
echo "  employee-task-backend job shows State: UP"
