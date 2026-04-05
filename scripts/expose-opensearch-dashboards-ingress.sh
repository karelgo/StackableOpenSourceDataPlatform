#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/.kube/dev-stackable-aks.yaml}"
APP_NAMESPACE="${APP_NAMESPACE:-default}"
DASHBOARDS_SERVICE="${DASHBOARDS_SERVICE:-opensearch-dashboards}"
DASHBOARDS_SERVICE_PORT="${DASHBOARDS_SERVICE_PORT:-5601}"
JUPYTERLAB_SERVICE="${JUPYTERLAB_SERVICE:-jupyterlab}"
JUPYTERLAB_SERVICE_PORT="${JUPYTERLAB_SERVICE_PORT:-8888}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_RELEASE="${INGRESS_RELEASE:-ingress-nginx}"
INGRESS_CHART_VERSION="${INGRESS_CHART_VERSION:-4.15.1}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-nginx-public}"
CERT_MANAGER_NAMESPACE="${CERT_MANAGER_NAMESPACE:-cert-manager}"
CERT_MANAGER_RELEASE="${CERT_MANAGER_RELEASE:-cert-manager}"
CERT_MANAGER_CHART_VERSION="${CERT_MANAGER_CHART_VERSION:-v1.20.0}"
CERT_MANAGER_CLUSTER_ISSUER="${CERT_MANAGER_CLUSTER_ISSUER:-letsencrypt-prod}"
ACME_SERVER_URL="${ACME_SERVER_URL:-https://acme-v02.api.letsencrypt.org/directory}"
LETSENCRYPT_EMAIL="${LETSENCRYPT_EMAIL:-}"
BASE_DOMAIN_SUFFIX="${BASE_DOMAIN_SUFFIX:-sslip.io}"
ALLOWED_SOURCE_RANGES="${ALLOWED_SOURCE_RANGES:-}"
OPEN_ACME_SOURCE_RANGES="${OPEN_ACME_SOURCE_RANGES:-0.0.0.0/0,::/0}"
INGRESS_WAIT_SECONDS="${INGRESS_WAIT_SECONDS:-900}"
CERT_WAIT_SECONDS="${CERT_WAIT_SECONDS:-900}"
DASHBOARDS_INGRESS_NAME="${DASHBOARDS_INGRESS_NAME:-opensearch-dashboards-public}"
DASHBOARDS_TLS_SECRET_NAME="${DASHBOARDS_TLS_SECRET_NAME:-opensearch-dashboards-public-tls}"
JUPYTERLAB_INGRESS_NAME="${JUPYTERLAB_INGRESS_NAME:-jupyterlab-public}"
JUPYTERLAB_TLS_SECRET_NAME="${JUPYTERLAB_TLS_SECRET_NAME:-jupyterlab-public-tls}"
INGRESS_LB_IP=""
DASHBOARDS_URL=""
JUPYTERLAB_URL=""

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

trim() {
  printf '%s' "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

detect_public_ip() {
  curl -4 -fsSL https://api.ipify.org
}

detect_allowed_source_ranges() {
  local public_ip

  if [[ -n "${ALLOWED_SOURCE_RANGES}" ]]; then
    printf '%s\n' "$(trim "${ALLOWED_SOURCE_RANGES}")"
    return
  fi

  if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
    fail "ALLOWED_SOURCE_RANGES must be set explicitly when running in GitHub Actions"
  fi

  public_ip="$(detect_public_ip)"
  [[ -n "${public_ip}" ]] || fail "Failed to detect current public IP address"
  printf '%s/32\n' "${public_ip}"
}

detect_letsencrypt_email() {
  local candidate=""

  if [[ -n "${LETSENCRYPT_EMAIL}" ]]; then
    printf '%s\n' "${LETSENCRYPT_EMAIL}"
    return
  fi

  if command -v az >/dev/null 2>&1; then
    candidate="$(az account show --query user.name --output tsv 2>/dev/null || true)"
    if [[ "${candidate}" == *"@"* ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  fi

  if command -v git >/dev/null 2>&1; then
    candidate="$(git config user.email 2>/dev/null || true)"
    if [[ "${candidate}" == *"@"* ]]; then
      printf '%s\n' "${candidate}"
      return
    fi
  fi

  fail "LETSENCRYPT_EMAIL is required to request a trusted TLS certificate"
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

install_ingress_controller() {
  run helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx --force-update >/dev/null
  run helm repo update >/dev/null

  run helm upgrade --install "${INGRESS_RELEASE}" ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NAMESPACE}" \
    --create-namespace \
    --version "${INGRESS_CHART_VERSION}" \
    --set-string controller.ingressClass="${INGRESS_CLASS_NAME}" \
    --set controller.ingressClassByName=true \
    --set controller.ingressClassResource.enabled=true \
    --set-string controller.ingressClassResource.name="${INGRESS_CLASS_NAME}" \
    --set-string controller.ingressClassResource.controllerValue=k8s.io/ingress-nginx \
    --set controller.allowSnippetAnnotations=false \
    --set controller.service.type=LoadBalancer \
    --set controller.service.externalTrafficPolicy=Local \
    --set-string controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz \
    --set controller.resources.requests.cpu=100m \
    --set controller.resources.requests.memory=128Mi \
    --set controller.resources.limits.cpu=300m \
    --set controller.resources.limits.memory=256Mi

  run kubectl -n "${INGRESS_NAMESPACE}" rollout status deployment/"${INGRESS_RELEASE}"-controller --timeout=20m
}

install_cert_manager() {
  if kubectl -n "${CERT_MANAGER_NAMESPACE}" get deployment cert-manager >/dev/null 2>&1 \
    && kubectl -n "${CERT_MANAGER_NAMESPACE}" get deployment cert-manager-cainjector >/dev/null 2>&1 \
    && kubectl -n "${CERT_MANAGER_NAMESPACE}" get deployment cert-manager-webhook >/dev/null 2>&1; then
    log "cert-manager already exists in namespace ${CERT_MANAGER_NAMESPACE}; reusing it"
  else
    run helm upgrade --install "${CERT_MANAGER_RELEASE}" oci://quay.io/jetstack/charts/cert-manager \
      --namespace "${CERT_MANAGER_NAMESPACE}" \
      --create-namespace \
      --version "${CERT_MANAGER_CHART_VERSION}" \
      --set crds.enabled=true \
      --set prometheus.enabled=false
  fi

  run kubectl -n "${CERT_MANAGER_NAMESPACE}" rollout status deployment/cert-manager --timeout=20m
  run kubectl -n "${CERT_MANAGER_NAMESPACE}" rollout status deployment/cert-manager-cainjector --timeout=20m
  run kubectl -n "${CERT_MANAGER_NAMESPACE}" rollout status deployment/cert-manager-webhook --timeout=20m
}

ensure_service_exists() {
  local service_name="$1"

  kubectl -n "${APP_NAMESPACE}" get service "${service_name}" >/dev/null 2>&1 || fail "Service ${service_name} not found in namespace ${APP_NAMESPACE}"
}

apply_cluster_issuer() {
  local email="$1"

  cat <<EOF | run kubectl apply -f -
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: ${CERT_MANAGER_CLUSTER_ISSUER}
spec:
  acme:
    email: ${email}
    server: ${ACME_SERVER_URL}
    privateKeySecretRef:
      name: ${CERT_MANAGER_CLUSTER_ISSUER}-account-key
    solvers:
      - http01:
          ingress:
            ingressClassName: ${INGRESS_CLASS_NAME}
            serviceType: ClusterIP
            ingressTemplate:
              metadata:
                annotations:
                  nginx.ingress.kubernetes.io/ssl-redirect: "false"
                  nginx.ingress.kubernetes.io/whitelist-source-range: "${OPEN_ACME_SOURCE_RANGES}"
EOF
}

apply_https_ingresses() {
  local allowed_ranges="$1"
  local dashboards_host jupyterlab_host

  dashboards_host="dashboards.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"
  jupyterlab_host="jupyterlab.${INGRESS_LB_IP}.${BASE_DOMAIN_SUFFIX}"

  cat <<EOF | run kubectl apply -f -
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${DASHBOARDS_INGRESS_NAME}
  namespace: ${APP_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: ${CERT_MANAGER_CLUSTER_ISSUER}
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: "${allowed_ranges}"
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  tls:
    - hosts:
        - ${dashboards_host}
      secretName: ${DASHBOARDS_TLS_SECRET_NAME}
  rules:
    - host: ${dashboards_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${DASHBOARDS_SERVICE}
                port:
                  number: ${DASHBOARDS_SERVICE_PORT}
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${JUPYTERLAB_INGRESS_NAME}
  namespace: ${APP_NAMESPACE}
  annotations:
    cert-manager.io/cluster-issuer: ${CERT_MANAGER_CLUSTER_ISSUER}
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "64m"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/whitelist-source-range: "${allowed_ranges}"
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  tls:
    - hosts:
        - ${jupyterlab_host}
      secretName: ${JUPYTERLAB_TLS_SECRET_NAME}
  rules:
    - host: ${jupyterlab_host}
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${JUPYTERLAB_SERVICE}
                port:
                  number: ${JUPYTERLAB_SERVICE_PORT}
EOF

  DASHBOARDS_URL="https://${dashboards_host}/"
  JUPYTERLAB_URL="https://${jupyterlab_host}/"
}

wait_for_certificate() {
  local certificate_name="$1"
  local elapsed=0

  while [[ "${elapsed}" -lt "${CERT_WAIT_SECONDS}" ]]; do
    if kubectl -n "${APP_NAMESPACE}" get "certificate/${certificate_name}" >/dev/null 2>&1; then
      run kubectl -n "${APP_NAMESPACE}" wait --for=condition=Ready "certificate/${certificate_name}" --timeout="${CERT_WAIT_SECONDS}s"
      return
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Timed out waiting for certificate resource ${certificate_name} to be created"
}

current_source_is_allowed() {
  local allowed_ranges="$1"
  local current_ip

  current_ip="$(detect_public_ip 2>/dev/null || true)"
  if [[ -z "${current_ip}" ]]; then
    printf 'false\n'
    return
  fi

  python3 - "${current_ip}" "${allowed_ranges}" <<'PY'
import ipaddress
import sys

ip = ipaddress.ip_address(sys.argv[1])
allowed_ranges = sys.argv[2].split(",")

for item in allowed_ranges:
    item = item.strip()
    if not item:
        continue
    if ip in ipaddress.ip_network(item, strict=False):
        print("true")
        raise SystemExit(0)

print("false")
PY
}

validate_endpoint() {
  local label="$1"
  local url="$2"
  local code

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 "${url}" || true)"

  case "${code}" in
    200|302|303|307|308)
      log "${label} reachable with trusted HTTPS (${code})"
      ;;
    *)
      fail "${label} validation failed with HTTP ${code} at ${url}"
      ;;
  esac
}

show_access_details() {
  local allowed_ranges="$1"

  printf '\n'
  printf 'Ingress load balancer IP: %s\n' "${INGRESS_LB_IP}"
  printf 'Allowed source ranges: %s\n' "${allowed_ranges}"
  printf 'Dashboards URL: %s\n' "${DASHBOARDS_URL}"
  printf 'JupyterLab URL: %s\n' "${JUPYTERLAB_URL}"
  printf '\n'
  printf 'TLS issuer: %s\n' "${CERT_MANAGER_CLUSTER_ISSUER}"
  printf 'TLS CA: Let'"'"'s Encrypt\n'
}

main() {
  local allowed_ranges
  local letsencrypt_email
  local validation_allowed

  require_cmd helm
  require_cmd kubectl
  require_cmd curl
  require_cmd python3

  [[ -f "${KUBECONFIG_FILE}" ]] || fail "Kubeconfig not found: ${KUBECONFIG_FILE}"
  export KUBECONFIG="${KUBECONFIG_FILE}"

  ensure_service_exists "${DASHBOARDS_SERVICE}"
  ensure_service_exists "${JUPYTERLAB_SERVICE}"

  allowed_ranges="$(detect_allowed_source_ranges)"
  letsencrypt_email="$(detect_letsencrypt_email)"

  run kubectl cluster-info
  install_ingress_controller
  install_cert_manager
  wait_for_load_balancer_ip
  apply_cluster_issuer "${letsencrypt_email}"
  apply_https_ingresses "${allowed_ranges}"
  wait_for_certificate "${DASHBOARDS_TLS_SECRET_NAME}"
  wait_for_certificate "${JUPYTERLAB_TLS_SECRET_NAME}"

  validation_allowed="$(current_source_is_allowed "${allowed_ranges}")"
  if [[ "${validation_allowed}" == "true" ]]; then
    validate_endpoint "OpenSearch Dashboards" "${DASHBOARDS_URL}"
    validate_endpoint "JupyterLab" "${JUPYTERLAB_URL}"
  else
    log "Skipping external HTTPS curl validation because the current source IP is not in ${allowed_ranges}"
  fi

  show_access_details "${allowed_ranges}"
}

main "$@"
