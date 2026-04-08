#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-45m}"
STACKABLECTL_BIN="${STACKABLECTL_BIN:-${REPO_ROOT}/.tools/stackablectl}"
STACKABLECTL_DOWNLOAD_BASE_URL="${STACKABLECTL_DOWNLOAD_BASE_URL:-https://github.com/stackabletech/stackable-cockpit/releases/latest/download}"

STACKABLE_RELEASE="${STACKABLE_RELEASE:-26.3}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-stackable-operators}"
LISTENER_CLASS_PRESET="${LISTENER_CLASS_PRESET:-ephemeral-nodes}"

COCKPIT_NAMESPACE="${COCKPIT_NAMESPACE:-stackable-cockpit}"
COCKPIT_RELEASE_NAME="${COCKPIT_RELEASE_NAME:-stackable-cockpit}"
# Pin Cockpit to an immutable build; the mutable 0.0.0-dev tag currently serves
# duplicate Content-Type headers for static assets and renders a blank page.
COCKPIT_CHART_VERSION="${COCKPIT_CHART_VERSION:-0.0.0-pr338}"
COCKPIT_SERVICE_NAME="${COCKPIT_SERVICE_NAME:-stackable-cockpit}"
COCKPIT_ADMIN_USERNAME="${COCKPIT_ADMIN_USERNAME:-admin}"
COCKPIT_ADMIN_PASSWORD="${COCKPIT_ADMIN_PASSWORD:-}"
COCKPIT_HTPASSWD_FILE="${COCKPIT_HTPASSWD_FILE:-}"
COCKPIT_DEFAULT_ADMIN_PASSWORD="${COCKPIT_DEFAULT_ADMIN_PASSWORD:-adminadmin}"
COCKPIT_PASSWORD_WAS_DEFAULTED="false"
TEMP_HTPASSWD_FILE=""
OPENSHIFT_VERSION=""

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

detect_stackablectl_asset() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "${os}:${arch}" in
    Darwin:arm64)
      printf 'stackablectl-aarch64-apple-darwin\n'
      ;;
    Darwin:x86_64)
      printf 'stackablectl-x86_64-apple-darwin\n'
      ;;
    Linux:arm64|Linux:aarch64)
      printf 'stackablectl-aarch64-unknown-linux-gnu\n'
      ;;
    Linux:x86_64|Linux:amd64)
      printf 'stackablectl-x86_64-unknown-linux-gnu\n'
      ;;
    *)
      fail "Unsupported platform for automatic stackablectl download: ${os}/${arch}"
      ;;
  esac
}

install_stackablectl() {
  local asset
  asset="$(detect_stackablectl_asset)"

  mkdir -p "$(dirname "${STACKABLECTL_BIN}")"

  log "Downloading stackablectl to ${STACKABLECTL_BIN}"
  run curl -fsSL -o "${STACKABLECTL_BIN}" "${STACKABLECTL_DOWNLOAD_BASE_URL}/${asset}"
  run chmod +x "${STACKABLECTL_BIN}"
  run "${STACKABLECTL_BIN}" --version
}

configure_kubeconfig() {
  if [[ -n "${KUBECONFIG_FILE}" ]]; then
    export KUBECONFIG="${KUBECONFIG_FILE}"
    log "Using kubeconfig from ${KUBECONFIG_FILE}"
  fi
}

ensure_openshift_login() {
  oc whoami >/dev/null 2>&1 || fail "OpenShift CLI is not logged in. Run: oc login <api-url>"
}

detect_openshift_version() {
  OPENSHIFT_VERSION="$(oc get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || true)"
  if [[ -z "${OPENSHIFT_VERSION}" ]]; then
    log "Could not determine the OpenShift version from clusterversion/version"
    return
  fi

  log "Detected OpenShift ${OPENSHIFT_VERSION}"
  case "${OPENSHIFT_VERSION}" in
    4.18.*|4.19.*|4.20.*)
      ;;
    *)
      log "WARNING: Stackable 26.3 is certified for OpenShift 4.18, 4.19, and 4.20"
      ;;
  esac
}

show_cluster_details() {
  run oc whoami
  oc whoami --show-console >/dev/null 2>&1 && run oc whoami --show-console || true
  run kubectl cluster-info
  run oc get nodes -o wide
}

ensure_namespace() {
  local namespace="$1"
  log "Ensuring namespace ${namespace} exists"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
}

wait_for_serviceaccount() {
  local namespace name elapsed
  namespace="$1"
  name="$2"
  elapsed=0

  while [[ "${elapsed}" -lt 300 ]]; do
    if kubectl -n "${namespace}" get serviceaccount "${name}" >/dev/null 2>&1; then
      return
    fi

    sleep 5
    elapsed=$((elapsed + 5))
  done

  fail "Timed out waiting for serviceaccount ${namespace}/${name}"
}

normalize_htpasswd_file() {
  local source_file destination_file
  source_file="$1"
  destination_file="$2"

  python3 - "$source_file" "$destination_file" <<'PY'
import sys

source_path, destination_path = sys.argv[1], sys.argv[2]
with open(source_path, "r", encoding="utf-8") as source:
    lines = [line.rstrip("\r\n") for line in source if line.strip()]

with open(destination_path, "w", encoding="utf-8", newline="") as destination:
    destination.write("\n".join(lines))
PY
}

ensure_cockpit_admin_password() {
  if [[ -n "${COCKPIT_HTPASSWD_FILE}" || -n "${COCKPIT_ADMIN_PASSWORD}" ]]; then
    return
  fi

  COCKPIT_ADMIN_PASSWORD="${COCKPIT_DEFAULT_ADMIN_PASSWORD}"
  COCKPIT_PASSWORD_WAS_DEFAULTED="true"
  log "No Cockpit admin password supplied; using the default demo credential"
}

write_htpasswd_entry() {
  local destination_file hash
  destination_file="$1"

  if command -v htpasswd >/dev/null 2>&1; then
    htpasswd -nbB "${COCKPIT_ADMIN_USERNAME}" "${COCKPIT_ADMIN_PASSWORD}" > "${destination_file}"
    return
  fi

  if command -v openssl >/dev/null 2>&1; then
    hash="$(printf '%s' "${COCKPIT_ADMIN_PASSWORD}" | openssl passwd -apr1 -stdin)"
    printf '%s:%s\n' "${COCKPIT_ADMIN_USERNAME}" "${hash}" > "${destination_file}"
    return
  fi

  fail "Set COCKPIT_HTPASSWD_FILE or install htpasswd/openssl so the Cockpit password file can be generated"
}

create_temp_htpasswd_file() {
  local destination raw_destination
  destination="$(mktemp)"
  raw_destination="$(mktemp)"

  if [[ -n "${COCKPIT_HTPASSWD_FILE}" ]]; then
    [[ -f "${COCKPIT_HTPASSWD_FILE}" ]] || fail "COCKPIT_HTPASSWD_FILE does not exist: ${COCKPIT_HTPASSWD_FILE}"
    cp "${COCKPIT_HTPASSWD_FILE}" "${raw_destination}"
    normalize_htpasswd_file "${raw_destination}" "${destination}"
    rm -f "${raw_destination}"
    printf '%s\n' "${destination}"
    return
  fi

  [[ -n "${COCKPIT_ADMIN_PASSWORD}" ]] || fail "Set COCKPIT_ADMIN_PASSWORD or COCKPIT_HTPASSWD_FILE before running this script"

  write_htpasswd_entry "${raw_destination}"
  normalize_htpasswd_file "${raw_destination}" "${destination}"
  rm -f "${raw_destination}"
  printf '%s\n' "${destination}"
}

install_stackable_release() {
  run "${STACKABLECTL_BIN}" \
    release install "${STACKABLE_RELEASE}" \
    --operator-namespace "${OPERATOR_NAMESPACE}" \
    --listener-class-preset "${LISTENER_CLASS_PRESET}"
}

grant_required_sccs() {
  local serviceaccount

  for serviceaccount in secret-operator-serviceaccount listener-operator-serviceaccount; do
    wait_for_serviceaccount "${OPERATOR_NAMESPACE}" "${serviceaccount}"

    if ! oc adm policy add-scc-to-user privileged -z "${serviceaccount}" -n "${OPERATOR_NAMESPACE}" >/dev/null; then
      fail "Failed to grant the privileged SCC to ${OPERATOR_NAMESPACE}/${serviceaccount}. This deployment needs a cluster-admin capable OpenShift cluster and will not work on Developer Sandbox."
    fi
  done
}

install_cockpit() {
  local htpasswd_file
  htpasswd_file="$1"

  if kubectl get clusterrole "${COCKPIT_RELEASE_NAME}-clusterrole" >/dev/null 2>&1; then
    # Helm's server-side apply conflicts with the manual RBAC patch on reruns.
    # Drop the ClusterRole and let the chart recreate it before patching it again.
    run kubectl delete clusterrole "${COCKPIT_RELEASE_NAME}-clusterrole"
  fi

  run helm repo add stackable-dev https://repo.stackable.tech/repository/helm-dev/ --force-update >/dev/null
  run helm repo update >/dev/null

  run helm upgrade --install "${COCKPIT_RELEASE_NAME}" stackable-dev/stackable-cockpit \
    --namespace "${COCKPIT_NAMESPACE}" \
    --create-namespace \
    --version "${COCKPIT_CHART_VERSION}" \
    --set-file htpasswd="${htpasswd_file}" \
    --set service.type=ClusterIP \
    --set resources.requests.cpu=100m \
    --set resources.requests.memory=128Mi \
    --set resources.limits.cpu=300m \
    --set resources.limits.memory=256Mi
}

patch_cockpit_rbac() {
  local clusterrole_name api_groups patch_ops patch_json
  clusterrole_name="${COCKPIT_RELEASE_NAME}-clusterrole"

  if ! kubectl get clusterrole "${clusterrole_name}" >/dev/null 2>&1; then
    log "Cockpit ClusterRole ${clusterrole_name} not found; skipping RBAC patch"
    return
  fi

  api_groups="$(kubectl get clusterrole "${clusterrole_name}" -o jsonpath='{range .rules[*].apiGroups[*]}{.}{"\n"}{end}')"
  patch_ops=()

  # Current cockpit chart RBAC omits these API groups, but cockpit uses both
  # when listing stacklets and resolving listener-backed endpoints.
  if ! grep -qx 'listeners.stackable.tech' <<<"${api_groups}"; then
    patch_ops+=('{"op":"add","path":"/rules/1/apiGroups/-","value":"listeners.stackable.tech"}')
  fi
  if ! grep -qx 'opensearch.stackable.tech' <<<"${api_groups}"; then
    patch_ops+=('{"op":"add","path":"/rules/1/apiGroups/-","value":"opensearch.stackable.tech"}')
  fi

  if [[ "${#patch_ops[@]}" -eq 0 ]]; then
    log "Cockpit ClusterRole ${clusterrole_name} already has the required API groups"
    return
  fi

  patch_json="[$(IFS=,; printf '%s' "${patch_ops[*]}")]"
  run kubectl patch clusterrole "${clusterrole_name}" --type json --patch "${patch_json}"
}

wait_for_namespace_deployments() {
  local namespace
  namespace="$1"

  if [[ -z "$(kubectl -n "${namespace}" get deployments -o name 2>/dev/null)" ]]; then
    log "No deployments found in namespace ${namespace}; skipping wait"
    return
  fi

  run kubectl -n "${namespace}" wait deployment --all --for=condition=Available --timeout="${DEPLOY_TIMEOUT}"
}

wait_for_namespace_daemonsets() {
  local namespace daemonsets daemonset
  namespace="$1"
  daemonsets="$(kubectl -n "${namespace}" get daemonsets -o name 2>/dev/null || true)"

  while IFS= read -r daemonset; do
    [[ -n "${daemonset}" ]] || continue
    run kubectl -n "${namespace}" rollout status "${daemonset}" --timeout="${DEPLOY_TIMEOUT}"
  done <<< "${daemonsets}"
}

show_access_details() {
  printf '\n'
  printf 'OpenShift cluster: %s\n' "$(oc whoami --show-server)"
  if [[ -n "${OPENSHIFT_VERSION}" ]]; then
    printf 'OpenShift version: %s\n' "${OPENSHIFT_VERSION}"
  fi
  printf 'Operator namespace: %s\n' "${OPERATOR_NAMESPACE}"
  printf 'Cockpit namespace: %s\n' "${COCKPIT_NAMESPACE}"
  printf 'Cockpit username: %s\n' "${COCKPIT_ADMIN_USERNAME}"
  if [[ "${COCKPIT_PASSWORD_WAS_DEFAULTED}" == "true" ]]; then
    printf 'Cockpit password: %s (default demo credential)\n' "${COCKPIT_ADMIN_PASSWORD}"
  else
    printf 'Cockpit password: supplied via secret or htpasswd file\n'
  fi
  printf '\n'
  printf 'Access commands:\n'
  printf '  oc -n %q port-forward service/%q 8080:80\n' \
    "${COCKPIT_NAMESPACE}" "${COCKPIT_SERVICE_NAME}"
  printf '\n'
  printf 'Validation commands:\n'
  printf '  kubectl -n %q get deployments\n' "${OPERATOR_NAMESPACE}"
  printf '  kubectl -n %q get daemonsets\n' "${OPERATOR_NAMESPACE}"
  printf '  kubectl -n %q get pods,svc\n' "${COCKPIT_NAMESPACE}"
  printf '\n'
  printf 'Next step:\n'
  printf '  %q\n' "${SCRIPT_DIR}/deploy-stackable-full-workloads-openshift.sh"
  printf '\n'
}

main() {
  local htpasswd_file

  require_cmd oc
  require_cmd kubectl
  require_cmd helm
  require_cmd curl
  require_cmd python3

  configure_kubeconfig
  ensure_openshift_login
  detect_openshift_version
  show_cluster_details
  ensure_namespace "${OPERATOR_NAMESPACE}"
  ensure_namespace "${COCKPIT_NAMESPACE}"

  install_stackablectl
  install_stackable_release
  grant_required_sccs

  ensure_cockpit_admin_password
  htpasswd_file="$(create_temp_htpasswd_file)"
  TEMP_HTPASSWD_FILE="${htpasswd_file}"
  trap 'if [[ -n "${TEMP_HTPASSWD_FILE}" && -f "${TEMP_HTPASSWD_FILE}" ]]; then rm -f "${TEMP_HTPASSWD_FILE}"; fi' EXIT
  install_cockpit "${htpasswd_file}"
  patch_cockpit_rbac

  wait_for_namespace_deployments "${OPERATOR_NAMESPACE}"
  wait_for_namespace_daemonsets "${OPERATOR_NAMESPACE}"
  wait_for_namespace_deployments "${COCKPIT_NAMESPACE}"

  run kubectl -n "${OPERATOR_NAMESPACE}" get deployments,daemonsets
  run kubectl -n "${COCKPIT_NAMESPACE}" get pods,svc
  show_access_details
}

main "$@"
