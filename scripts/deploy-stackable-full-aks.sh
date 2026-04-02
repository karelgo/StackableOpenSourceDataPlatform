#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-4910a5a6-aec6-405d-9294-c7f2845512a4}"
RESOURCE_GROUP="${RESOURCE_GROUP:-dev-stackable-rg}"
LOCATION="${LOCATION:-swedencentral}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-dev-stackable-full-aks}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-2}"
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4s_v3}"
AKS_NODE_OSDISK_SIZE="${AKS_NODE_OSDISK_SIZE:-128}"
AKS_AUX_NODEPOOL_ENABLED="${AKS_AUX_NODEPOOL_ENABLED:-true}"
AKS_AUX_NODEPOOL_NAME="${AKS_AUX_NODEPOOL_NAME:-d2pool}"
AKS_AUX_NODEPOOL_COUNT="${AKS_AUX_NODEPOOL_COUNT:-1}"
AKS_AUX_NODEPOOL_VM_SIZE="${AKS_AUX_NODEPOOL_VM_SIZE:-Standard_D2s_v3}"
AKS_AUX_NODEPOOL_OSDISK_SIZE="${AKS_AUX_NODEPOOL_OSDISK_SIZE:-128}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-45m}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/.kube/${AKS_CLUSTER_NAME}.yaml}"
STACKABLECTL_BIN="${STACKABLECTL_BIN:-${REPO_ROOT}/.tools/stackablectl}"
STACKABLECTL_DOWNLOAD_BASE_URL="${STACKABLECTL_DOWNLOAD_BASE_URL:-https://github.com/stackabletech/stackable-cockpit/releases/latest/download}"

STACKABLE_RELEASE="${STACKABLE_RELEASE:-26.3}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-stackable-operators}"
LISTENER_CLASS_PRESET="${LISTENER_CLASS_PRESET:-ephemeral-nodes}"

COCKPIT_NAMESPACE="${COCKPIT_NAMESPACE:-stackable-cockpit}"
COCKPIT_RELEASE_NAME="${COCKPIT_RELEASE_NAME:-stackable-cockpit}"
COCKPIT_CHART_VERSION="${COCKPIT_CHART_VERSION:-0.0.0-dev}"
COCKPIT_SERVICE_NAME="${COCKPIT_SERVICE_NAME:-stackable-cockpit}"
COCKPIT_ADMIN_USERNAME="${COCKPIT_ADMIN_USERNAME:-admin}"
COCKPIT_ADMIN_PASSWORD="${COCKPIT_ADMIN_PASSWORD:-}"
COCKPIT_HTPASSWD_FILE="${COCKPIT_HTPASSWD_FILE:-}"
TEMP_HTPASSWD_FILE=""

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

ensure_azure_login() {
  az account show --output none >/dev/null 2>&1 || fail "Azure CLI is not logged in. Run: az login"
}

select_subscription() {
  local active_subscription

  run az account set --subscription "${SUBSCRIPTION_ID}"
  active_subscription="$(az account show --query id --output tsv)"
  [[ "${active_subscription}" == "${SUBSCRIPTION_ID}" ]] || fail "Active subscription is ${active_subscription}, expected ${SUBSCRIPTION_ID}"

  log "Using subscription ${SUBSCRIPTION_ID} ($(az account show --query name --output tsv)) as $(az account show --query user.name --output tsv)"
}

register_azure_providers() {
  local provider state
  for provider in Microsoft.ContainerService Microsoft.Compute Microsoft.Network; do
    state="$(az provider show --namespace "${provider}" --query registrationState --output tsv 2>/dev/null || true)"
    if [[ "${state}" == "Registered" ]]; then
      log "Azure provider ${provider} is already registered"
      continue
    fi

    log "Registering Azure provider ${provider}"
    run az provider register --namespace "${provider}" --wait --only-show-errors
  done
}

ensure_resource_group() {
  local existing_location

  existing_location="$(az group show --name "${RESOURCE_GROUP}" --query location --output tsv 2>/dev/null || true)"
  if [[ -n "${existing_location}" ]]; then
    log "Resource group ${RESOURCE_GROUP} already exists in ${existing_location}; reusing it"
    return
  fi

  run az group create \
    --name "${RESOURCE_GROUP}" \
    --location "${LOCATION}" \
    --output none \
    --only-show-errors
}

cluster_exists() {
  az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${AKS_CLUSTER_NAME}" \
    --output none \
    --only-show-errors >/dev/null 2>&1
}

ensure_aks_cluster() {
  if cluster_exists; then
    log "AKS cluster ${AKS_CLUSTER_NAME} already exists in ${RESOURCE_GROUP}; reusing it"
    return
  fi

  run az aks create \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${AKS_CLUSTER_NAME}" \
    --location "${LOCATION}" \
    --node-count "${AKS_NODE_COUNT}" \
    --node-vm-size "${AKS_NODE_VM_SIZE}" \
    --node-osdisk-size "${AKS_NODE_OSDISK_SIZE}" \
    --load-balancer-sku standard \
    --vm-set-type VirtualMachineScaleSets \
    --enable-managed-identity \
    --generate-ssh-keys \
    --only-show-errors \
    --output none
}

ensure_aks_cluster_running() {
  local power_state

  power_state="$(az aks show \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${AKS_CLUSTER_NAME}" \
    --query powerState.code \
    --output tsv \
    --only-show-errors 2>/dev/null || true)"

  if [[ "${power_state}" == "Stopped" ]]; then
    run az aks start \
      --resource-group "${RESOURCE_GROUP}" \
      --name "${AKS_CLUSTER_NAME}" \
      --only-show-errors \
      --output none
  fi
}

aux_nodepool_exists() {
  az aks nodepool show \
    --resource-group "${RESOURCE_GROUP}" \
    --cluster-name "${AKS_CLUSTER_NAME}" \
    --name "${AKS_AUX_NODEPOOL_NAME}" \
    --output none \
    --only-show-errors >/dev/null 2>&1
}

ensure_aux_nodepool() {
  if [[ "${AKS_AUX_NODEPOOL_ENABLED}" != "true" ]]; then
    log "Auxiliary nodepool creation disabled"
    return
  fi

  if aux_nodepool_exists; then
    log "AKS auxiliary nodepool ${AKS_AUX_NODEPOOL_NAME} already exists; reusing it"
    return
  fi

  run az aks nodepool add \
    --resource-group "${RESOURCE_GROUP}" \
    --cluster-name "${AKS_CLUSTER_NAME}" \
    --name "${AKS_AUX_NODEPOOL_NAME}" \
    --mode User \
    --node-count "${AKS_AUX_NODEPOOL_COUNT}" \
    --node-vm-size "${AKS_AUX_NODEPOOL_VM_SIZE}" \
    --node-osdisk-size "${AKS_AUX_NODEPOOL_OSDISK_SIZE}" \
    --only-show-errors \
    --output none
}

ensure_kubeconfig() {
  mkdir -p "$(dirname "${KUBECONFIG_FILE}")"

  run az aks get-credentials \
    --resource-group "${RESOURCE_GROUP}" \
    --name "${AKS_CLUSTER_NAME}" \
    --admin \
    --file "${KUBECONFIG_FILE}" \
    --overwrite-existing \
    --only-show-errors

  export KUBECONFIG="${KUBECONFIG_FILE}"

  run kubectl cluster-info
  run kubectl get nodes -o wide
}

ensure_namespace() {
  local namespace
  namespace="$1"

  log "Ensuring namespace ${namespace} exists"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
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

create_temp_htpasswd_file() {
  local destination
  local raw_destination
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
  require_cmd htpasswd

  htpasswd -nbB "${COCKPIT_ADMIN_USERNAME}" "${COCKPIT_ADMIN_PASSWORD}" > "${raw_destination}"
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

install_cockpit() {
  local htpasswd_file
  htpasswd_file="$1"

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

wait_for_namespace_deployments() {
  local namespace
  namespace="$1"

  if [[ -z "$(kubectl -n "${namespace}" get deployments -o name 2>/dev/null)" ]]; then
    log "No deployments found in namespace ${namespace}; skipping wait"
    return
  fi

  run kubectl -n "${namespace}" wait deployment --all --for=condition=Available --timeout="${DEPLOY_TIMEOUT}"
}

show_access_details() {
  printf '\n'
  printf 'KUBECONFIG=%s\n' "${KUBECONFIG_FILE}"
  printf 'AKS cluster: %s\n' "${AKS_CLUSTER_NAME}"
  printf 'Operator namespace: %s\n' "${OPERATOR_NAMESPACE}"
  printf 'Cockpit namespace: %s\n' "${COCKPIT_NAMESPACE}"
  printf 'Cockpit username: %s\n' "${COCKPIT_ADMIN_USERNAME}"
  printf '\n'
  printf 'Access commands:\n'
  printf '  kubectl --kubeconfig %q -n %q port-forward service/%q 8080:80\n' \
    "${KUBECONFIG_FILE}" "${COCKPIT_NAMESPACE}" "${COCKPIT_SERVICE_NAME}"
  printf '\n'
  printf 'Validation commands:\n'
  printf '  kubectl --kubeconfig %q -n %q get deployments\n' "${KUBECONFIG_FILE}" "${OPERATOR_NAMESPACE}"
  printf '  kubectl --kubeconfig %q -n %q get pods,svc\n' "${KUBECONFIG_FILE}" "${COCKPIT_NAMESPACE}"
  printf '\n'
}

main() {
  local htpasswd_file

  require_cmd az
  require_cmd kubectl
  require_cmd helm
  require_cmd curl

  ensure_azure_login
  select_subscription
  register_azure_providers
  ensure_resource_group
  ensure_aks_cluster
  ensure_aks_cluster_running
  ensure_aux_nodepool
  ensure_kubeconfig
  ensure_namespace "${OPERATOR_NAMESPACE}"
  ensure_namespace "${COCKPIT_NAMESPACE}"

  install_stackablectl
  install_stackable_release

  htpasswd_file="$(create_temp_htpasswd_file)"
  TEMP_HTPASSWD_FILE="${htpasswd_file}"
  trap 'if [[ -n "${TEMP_HTPASSWD_FILE}" && -f "${TEMP_HTPASSWD_FILE}" ]]; then rm -f "${TEMP_HTPASSWD_FILE}"; fi' EXIT
  install_cockpit "${htpasswd_file}"

  wait_for_namespace_deployments "${OPERATOR_NAMESPACE}"
  wait_for_namespace_deployments "${COCKPIT_NAMESPACE}"

  run kubectl -n "${OPERATOR_NAMESPACE}" get deployments
  run kubectl -n "${COCKPIT_NAMESPACE}" get pods,svc
  show_access_details
}

main "$@"
