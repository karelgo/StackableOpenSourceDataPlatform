#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/.kube/dev-stackable-full-aks.yaml}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_RELEASE="${INGRESS_RELEASE:-ingress-nginx}"
INGRESS_CHART_VERSION="${INGRESS_CHART_VERSION:-4.15.1}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-nginx}"
BASE_DOMAIN_SUFFIX="${BASE_DOMAIN_SUFFIX:-sslip.io}"
ALLOWED_SOURCE_RANGES="${ALLOWED_SOURCE_RANGES:-}"
INGRESS_WAIT_SECONDS="${INGRESS_WAIT_SECONDS:-900}"

log() {
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"
}

fail() {
  printf 'ERROR: %s\n' "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

run() {
  log "Running: $*"
  "$@"
}

detect_public_ip() {
  curl -fsSL https://api.ipify.org
}

ensure_allowed_source_ranges() {
  if [[ -n "${ALLOWED_SOURCE_RANGES}" ]]; then
    return
  fi

  ALLOWED_SOURCE_RANGES="$(detect_public_ip)/32"
  log "Detected public IP allowlist: ${ALLOWED_SOURCE_RANGES}"
}

install_ingress_controller() {
  local -a range_args
  local -a cidrs
  local cidr idx

  range_args=()
  IFS=',' read -r -a cidrs <<< "${ALLOWED_SOURCE_RANGES}"
  for idx in "${!cidrs[@]}"; do
    cidr="${cidrs[$idx]}"
    range_args+=(--set-string "controller.service.loadBalancerSourceRanges[${idx}]=${cidr}")
  done

  run helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  run helm repo update >/dev/null

  run helm upgrade --install "${INGRESS_RELEASE}" ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NAMESPACE}" \
    --create-namespace \
    --version "${INGRESS_CHART_VERSION}" \
    "${range_args[@]}" \
    --set controller.service.externalTrafficPolicy=Local \
    --set controller.allowSnippetAnnotations=false

  run kubectl -n "${INGRESS_NAMESPACE}" rollout status deployment/"${INGRESS_RELEASE}"-controller --timeout=10m
}

wait_for_load_balancer_ip() {
  local elapsed=0

  while [[ "${elapsed}" -lt "${INGRESS_WAIT_SECONDS}" ]]; do
    INGRESS_LB_IP="$(kubectl -n "${INGRESS_NAMESPACE}" get svc "${INGRESS_RELEASE}"-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)"
    if [[ -n "${INGRESS_LB_IP}" ]]; then
      return
    fi

    sleep 10
    elapsed=$((elapsed + 10))
  done

  fail "Timed out waiting for an external IP on service ${INGRESS_RELEASE}-controller"
}

patch_cockpit_service_private() {
  if kubectl -n stackable-cockpit get service stackable-cockpit >/dev/null 2>&1; then
    run kubectl -n stackable-cockpit patch service stackable-cockpit \
      --type merge \
      -p '{"spec":{"type":"ClusterIP"}}'
  fi
}

apply_ingresses() {
  local cockpit_host airflow_host superset_host minio_host nifi_host trino_host

  cockpit_host="cockpit.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"
  airflow_host="airflow.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"
  superset_host="superset.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"
  minio_host="minio.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"
  nifi_host="nifi.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"
  trino_host="trino.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"

  cat <<EOF | run kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: cockpit-public
  namespace: stackable-cockpit
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: ${ALLOWED_SOURCE_RANGES}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - host: ${cockpit_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: stackable-cockpit
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: airflow-public
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: ${ALLOWED_SOURCE_RANGES}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - host: ${airflow_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: airflow-webserver
                port:
                  number: 8080
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: superset-public
  namespace: stackable-analytics
  annotations:
    nginx.ingress.kubernetes.io/whitelist-source-range: ${ALLOWED_SOURCE_RANGES}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - host: ${superset_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: superset-node
                port:
                  number: 8088
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: minio-console-public
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/whitelist-source-range: ${ALLOWED_SOURCE_RANGES}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - host: ${minio_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: minio-console
                port:
                  number: 9001
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: nifi-public
  namespace: stackable-streaming
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: ${ALLOWED_SOURCE_RANGES}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - host: ${nifi_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: nifi-node
                port:
                  number: 8443
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: trino-public
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: HTTPS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: ${ALLOWED_SOURCE_RANGES}
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - host: ${trino_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: trino-coordinator
                port:
                  number: 8443
EOF

  COCKPIT_URL="https://${cockpit_host}/ui/"
  AIRFLOW_URL="https://${airflow_host}/"
  SUPERSET_URL="https://${superset_host}/superset/welcome/"
  MINIO_URL="https://${minio_host}/"
  NIFI_URL="https://${nifi_host}/nifi/"
  TRINO_URL="https://${trino_host}/ui/"
}

validate_endpoint() {
  local label="$1"
  local url="$2"
  local host path code

  host="${url#https://}"
  host="${host%%/*}"
  path="/${url#https://${host}/}"
  [[ "${path}" == "/"* ]] || path="/"

  code="$(curl -skS -o /dev/null -w '%{http_code}' \
    --max-time 20 \
    --resolve "${host}:443:${INGRESS_LB_IP}" \
    "https://${host}${path}")"

  case "${code}" in
    200|302|303|308)
      log "${label} reachable (${code})"
      ;;
    *)
      fail "${label} validation failed with HTTP ${code} at ${url}"
      ;;
  esac
}

show_access_details() {
  printf '\n'
  printf 'Ingress load balancer IP: %s\n' "${INGRESS_LB_IP}"
  printf 'Allowed source ranges: %s\n' "${ALLOWED_SOURCE_RANGES}"
  printf '\n'
  printf 'URLs:\n'
  printf '  Cockpit: %s\n' "${COCKPIT_URL}"
  printf '  Airflow: %s\n' "${AIRFLOW_URL}"
  printf '  Superset: %s\n' "${SUPERSET_URL}"
  printf '  MinIO Console: %s\n' "${MINIO_URL}"
  printf '  NiFi: %s\n' "${NIFI_URL}"
  printf '  Trino UI: %s\n' "${TRINO_URL}"
  printf '\n'
  printf 'Note: HTTPS uses the ingress controller default certificate, so your browser will show a certificate warning until you add real DNS and TLS.\n'
}

main() {
  require_cmd kubectl
  require_cmd helm
  require_cmd curl

  [[ -f "${KUBECONFIG_FILE}" ]] || fail "Kubeconfig not found: ${KUBECONFIG_FILE}"
  export KUBECONFIG="${KUBECONFIG_FILE}"

  run kubectl cluster-info
  ensure_allowed_source_ranges
  install_ingress_controller
  wait_for_load_balancer_ip
  patch_cockpit_service_private
  apply_ingresses

  validate_endpoint "Cockpit" "${COCKPIT_URL}"
  validate_endpoint "Airflow" "${AIRFLOW_URL}"
  validate_endpoint "Superset" "${SUPERSET_URL}"
  validate_endpoint "MinIO Console" "${MINIO_URL}"
  validate_endpoint "NiFi" "${NIFI_URL}"
  validate_endpoint "Trino UI" "${TRINO_URL}"

  show_access_details
}

main "$@"
