#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/.kube/dev-stackable-aks.yaml}"
APP_NAMESPACE="${APP_NAMESPACE:-default}"
APP_SERVICE="${APP_SERVICE:-opensearch-dashboards}"
APP_SERVICE_PORT="${APP_SERVICE_PORT:-5601}"
INGRESS_NAMESPACE="${INGRESS_NAMESPACE:-ingress-nginx}"
INGRESS_RELEASE="${INGRESS_RELEASE:-ingress-nginx}"
INGRESS_CLASS_NAME="${INGRESS_CLASS_NAME:-nginx-public}"
INGRESS_NAME="${INGRESS_NAME:-opensearch-dashboards-public}"
ALLOWED_SOURCE_RANGES="${ALLOWED_SOURCE_RANGES:-}"
PUBLIC_ENDPOINT_SCHEME="${PUBLIC_ENDPOINT_SCHEME:-http}"
VALUES_FILE_TMP=""

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

detect_allowed_source_ranges() {
  local public_ip

  if [[ -n "${ALLOWED_SOURCE_RANGES}" ]]; then
    printf '%s\n' "$(trim "${ALLOWED_SOURCE_RANGES}")"
    return
  fi

  public_ip="$(curl -4 -fsSL https://api.ipify.org)"
  [[ -n "${public_ip}" ]] || fail "Failed to detect current public IP address"
  printf '%s/32\n' "${public_ip}"
}

source_ranges_to_yaml() {
  local ranges_csv="$1"
  local old_ifs="$IFS"
  local ranges part

  IFS=',' read -r -a ranges <<< "${ranges_csv}"
  IFS="${old_ifs}"

  for part in "${ranges[@]}"; do
    part="$(trim "${part}")"
    [[ -n "${part}" ]] || continue
    printf '      - "%s"\n' "${part}"
  done
}

write_values_file() {
  local destination="$1"
  local allowed_ranges="$2"

  cat > "${destination}" <<EOF
controller:
  ingressClass: ${INGRESS_CLASS_NAME}
  ingressClassByName: true
  allowSnippetAnnotations: false
  ingressClassResource:
    name: ${INGRESS_CLASS_NAME}
    enabled: true
    default: false
    controllerValue: k8s.io/ingress-nginx
  service:
    type: LoadBalancer
    externalTrafficPolicy: Local
    annotations:
      service.beta.kubernetes.io/azure-load-balancer-health-probe-request-path: /healthz
    loadBalancerSourceRanges:
$(source_ranges_to_yaml "${allowed_ranges}")
  resources:
    requests:
      cpu: 100m
      memory: 128Mi
    limits:
      cpu: 300m
      memory: 256Mi
EOF
}

install_ingress_controller() {
  local values_file="$1"

  run helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
  run helm repo update >/dev/null
  run helm upgrade --install "${INGRESS_RELEASE}" ingress-nginx/ingress-nginx \
    --namespace "${INGRESS_NAMESPACE}" \
    --create-namespace \
    --version 4.15.1 \
    --values "${values_file}"

  run kubectl --kubeconfig "${KUBECONFIG_FILE}" -n "${INGRESS_NAMESPACE}" rollout status deployment/"${INGRESS_RELEASE}"-controller --timeout=20m
}

get_ingress_external_ip() {
  kubectl --kubeconfig "${KUBECONFIG_FILE}" -n "${INGRESS_NAMESPACE}" get service "${INGRESS_RELEASE}"-controller -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
}

wait_for_external_ip() {
  local ip=""
  local attempt

  for attempt in $(seq 1 60); do
    ip="$(get_ingress_external_ip)"
    if [[ -n "${ip}" ]]; then
      printf '%s\n' "${ip}"
      return
    fi
    sleep 10
  done

  fail "Timed out waiting for ingress controller external IP"
}

apply_dashboards_ingress() {
  local allowed_ranges="$1"

  kubectl --kubeconfig "${KUBECONFIG_FILE}" apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: ${INGRESS_NAME}
  namespace: ${APP_NAMESPACE}
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "false"
    nginx.ingress.kubernetes.io/whitelist-source-range: "${allowed_ranges}"
spec:
  ingressClassName: ${INGRESS_CLASS_NAME}
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: ${APP_SERVICE}
                port:
                  number: ${APP_SERVICE_PORT}
EOF
}

validate_endpoint() {
  local public_ip="$1"

  run curl -fsSI --max-time 20 "${PUBLIC_ENDPOINT_SCHEME}://${public_ip}/"
}

main() {
  local allowed_ranges
  local values_file
  local public_ip

  require_cmd helm
  require_cmd kubectl
  require_cmd curl

  export KUBECONFIG="${KUBECONFIG_FILE}"

  allowed_ranges="$(detect_allowed_source_ranges)"
  values_file="$(mktemp)"
  VALUES_FILE_TMP="${values_file}"
  trap 'if [[ -n "${VALUES_FILE_TMP}" ]]; then rm -f "${VALUES_FILE_TMP}"; fi' EXIT

  write_values_file "${values_file}" "${allowed_ranges}"
  install_ingress_controller "${values_file}"
  public_ip="$(wait_for_external_ip)"
  apply_dashboards_ingress "${allowed_ranges}"
  validate_endpoint "${public_ip}"

  printf '\n'
  printf 'Ingress controller namespace: %s\n' "${INGRESS_NAMESPACE}"
  printf 'Ingress name: %s\n' "${INGRESS_NAME}"
  printf 'Allowed source ranges: %s\n' "${allowed_ranges}"
  printf 'Public URL: %s://%s/\n' "${PUBLIC_ENDPOINT_SCHEME}" "${public_ip}"
}

main "$@"
