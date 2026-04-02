#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-4910a5a6-aec6-405d-9294-c7f2845512a4}"
RESOURCE_GROUP="${RESOURCE_GROUP:-dev-stackable-rg}"
LOCATION="${LOCATION:-westeurope}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-dev-stackable-aks}"
AKS_NAMESPACE="${AKS_NAMESPACE:-default}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-1}"
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D8s_v5}"
AKS_NODE_OSDISK_SIZE="${AKS_NODE_OSDISK_SIZE:-128}"
ENABLE_PUBLIC_NODEPORTS="${ENABLE_PUBLIC_NODEPORTS:-false}"
LISTENER_CLASS_PRESET="${LISTENER_CLASS_PRESET:-ephemeral-nodes}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-45m}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/.kube/${AKS_CLUSTER_NAME}.yaml}"
STACKABLECTL_BIN="${STACKABLECTL_BIN:-${REPO_ROOT}/.tools/stackablectl}"
STACKABLECTL_DOWNLOAD_BASE_URL="${STACKABLECTL_DOWNLOAD_BASE_URL:-https://github.com/stackabletech/stackable-cockpit/releases/latest/download}"
NODEPORT_RULE_NAME="${NODEPORT_RULE_NAME:-allow-stackable-nodeports}"
NODEPORT_RULE_PRIORITY="${NODEPORT_RULE_PRIORITY:-350}"
OLLAMA_CPU_REQUEST="${OLLAMA_CPU_REQUEST:-4}"
OLLAMA_CPU_LIMIT="${OLLAMA_CPU_LIMIT:-8}"
OLLAMA_MEMORY_REQUEST="${OLLAMA_MEMORY_REQUEST:-10Gi}"
OLLAMA_MEMORY_LIMIT="${OLLAMA_MEMORY_LIMIT:-16Gi}"

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

to_lower() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

ensure_bool() {
  case "$(to_lower "$1")" in
    true|false) ;;
    *)
      fail "Expected true or false, got: $1"
      ;;
  esac
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

  local -a args=(
    az aks create
    --resource-group "${RESOURCE_GROUP}"
    --name "${AKS_CLUSTER_NAME}"
    --location "${LOCATION}"
    --node-count "${AKS_NODE_COUNT}"
    --node-vm-size "${AKS_NODE_VM_SIZE}"
    --node-osdisk-size "${AKS_NODE_OSDISK_SIZE}"
    --load-balancer-sku standard
    --vm-set-type VirtualMachineScaleSets
    --enable-managed-identity
    --generate-ssh-keys
    --only-show-errors
    --output none
  )

  if [[ "$(to_lower "${ENABLE_PUBLIC_NODEPORTS}")" == "true" ]]; then
    args+=(
      --enable-node-public-ip
      --network-plugin azure
      --network-policy none
    )
  fi

  run "${args[@]}"
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
  log "Ensuring namespace ${AKS_NAMESPACE} exists"
  kubectl create namespace "${AKS_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
  run kubectl config set-context --current --namespace="${AKS_NAMESPACE}"
}

ensure_public_node_ips_if_requested() {
  local enable_node_public_ip

  if [[ "$(to_lower "${ENABLE_PUBLIC_NODEPORTS}")" != "true" ]]; then
    return
  fi

  enable_node_public_ip="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" --query 'agentPoolProfiles[0].enableNodePublicIp' --output tsv)"
  if [[ "${enable_node_public_ip}" != "true" ]]; then
    fail "ENABLE_PUBLIC_NODEPORTS=true was requested, but AKS cluster ${AKS_CLUSTER_NAME} does not have node public IPs enabled. Recreate the cluster or use port-forward access."
  fi
}

ensure_nodeport_rule() {
  local node_resource_group
  local nsg_name

  node_resource_group="$(az aks show --resource-group "${RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" --query nodeResourceGroup --output tsv)"
  [[ -n "${node_resource_group}" ]] || fail "Unable to determine the AKS node resource group"

  nsg_name="$(az network nsg list --resource-group "${node_resource_group}" --query "[0].name" --output tsv)"
  [[ -n "${nsg_name}" ]] || fail "Unable to determine the AKS network security group in ${node_resource_group}"

  if az network nsg rule show --resource-group "${node_resource_group}" --nsg-name "${nsg_name}" --name "${NODEPORT_RULE_NAME}" --output none >/dev/null 2>&1; then
    log "NSG rule ${NODEPORT_RULE_NAME} already exists on ${nsg_name}"
    return
  fi

  log "Creating inbound NSG rule ${NODEPORT_RULE_NAME} on ${nsg_name} for Kubernetes NodePort TCP traffic"
  run az network nsg rule create \
    --resource-group "${node_resource_group}" \
    --nsg-name "${nsg_name}" \
    --name "${NODEPORT_RULE_NAME}" \
    --priority "${NODEPORT_RULE_PRIORITY}" \
    --direction Inbound \
    --access Allow \
    --protocol Tcp \
    --source-address-prefixes Internet \
    --source-port-ranges '*' \
    --destination-address-prefixes '*' \
    --destination-port-ranges 30000-32767 \
    --description "Allow Kubernetes NodePort access for Stackable demo services" \
    --output none \
    --only-show-errors
}

find_first_resource_name() {
  local kind pattern
  kind="$1"
  pattern="$2"

  kubectl -n "${AKS_NAMESPACE}" get "${kind}" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null | awk -v pattern="${pattern}" '$0 ~ pattern { print; exit }'
}

wait_for_rollout_match() {
  local kind pattern name
  kind="$1"
  pattern="$2"
  name="$(find_first_resource_name "${kind}" "${pattern}")"

  if [[ -z "${name}" ]]; then
    log "No ${kind} matching '${pattern}' found in namespace ${AKS_NAMESPACE}; skipping rollout wait"
    return
  fi

  run kubectl -n "${AKS_NAMESPACE}" rollout status "${kind}/${name}" --timeout="${DEPLOY_TIMEOUT}"
}

wait_for_job_match() {
  local pattern name
  pattern="$1"
  name="$(find_first_resource_name job "${pattern}")"

  if [[ -z "${name}" ]]; then
    log "No Job matching '${pattern}' found in namespace ${AKS_NAMESPACE}; skipping job wait"
    return
  fi

  run kubectl -n "${AKS_NAMESPACE}" wait --for=condition=complete "job/${name}" --timeout="${DEPLOY_TIMEOUT}"
}

deploy_rag_demo() {
  run "${STACKABLECTL_BIN}" \
    demo install \
    -n "${AKS_NAMESPACE}" \
    opensearch-rag \
    --listener-class-preset "${LISTENER_CLASS_PRESET}"
}

patch_ollama_resources() {
  if ! kubectl -n "${AKS_NAMESPACE}" get deployment ollama >/dev/null 2>&1; then
    log "Deployment ollama does not exist in namespace ${AKS_NAMESPACE}; skipping resource patch"
    return
  fi

  log "Patching ollama resources to request ${OLLAMA_CPU_REQUEST} CPU / ${OLLAMA_MEMORY_REQUEST} memory and limit ${OLLAMA_CPU_LIMIT} CPU / ${OLLAMA_MEMORY_LIMIT} memory"
  kubectl -n "${AKS_NAMESPACE}" patch deployment ollama --type merge -p "{
    \"spec\": {
      \"template\": {
        \"spec\": {
          \"containers\": [
            {
              \"name\": \"ollama\",
              \"resources\": {
                \"requests\": {
                  \"cpu\": \"${OLLAMA_CPU_REQUEST}\",
                  \"memory\": \"${OLLAMA_MEMORY_REQUEST}\"
                },
                \"limits\": {
                  \"cpu\": \"${OLLAMA_CPU_LIMIT}\",
                  \"memory\": \"${OLLAMA_MEMORY_LIMIT}\"
                }
              }
            }
          ]
        }
      }
    }
  }" >/dev/null
}

wait_for_demo() {
  wait_for_rollout_match deployment 'ollama'
  wait_for_rollout_match deployment 'jupyterlab'
  wait_for_rollout_match statefulset 'opensearch'
  wait_for_rollout_match deployment 'opensearch-dashboards'
  wait_for_job_match 'load-embeddings-from-git'
}

show_access_details() {
  local external_ips

  log "Stackable status"
  run "${STACKABLECTL_BIN}" stacklet list -n "${AKS_NAMESPACE}" || true
  run kubectl -n "${AKS_NAMESPACE}" get pods,svc,job

  printf '\n'
  printf 'KUBECONFIG=%s\n' "${KUBECONFIG_FILE}"
  printf 'Namespace: %s\n' "${AKS_NAMESPACE}"
  printf 'JupyterLab token: adminadmin\n'
  printf 'OpenSearch Dashboards username: admin\n'
  printf 'OpenSearch Dashboards password: adminadmin\n'
  printf '\n'
  printf 'Port-forward commands:\n'
  printf '  kubectl --kubeconfig %q -n %q port-forward service/jupyterlab 8888:8888\n' "${KUBECONFIG_FILE}" "${AKS_NAMESPACE}"
  printf '  kubectl --kubeconfig %q -n %q port-forward service/opensearch-dashboards 5601:5601\n' "${KUBECONFIG_FILE}" "${AKS_NAMESPACE}"
  printf '\n'

  if [[ "$(to_lower "${ENABLE_PUBLIC_NODEPORTS}")" == "true" ]]; then
    external_ips="$(kubectl get nodes -o jsonpath='{range .items[*]}{range .status.addresses[?(@.type=="ExternalIP")]}{.address}{"\n"}{end}{end}')"
    if [[ -n "${external_ips}" ]]; then
      printf 'Node public IPs:\n%s\n\n' "${external_ips}"
    fi
    printf 'Public NodePort access was enabled. Only TCP NodePort range 30000-32767 was opened on the AKS NSG.\n'
  else
    printf 'Public NodePort access was not enabled. Use the port-forwards above for browser access.\n'
  fi
}

main() {
  ensure_bool "${ENABLE_PUBLIC_NODEPORTS}"

  require_cmd az
  require_cmd kubectl
  require_cmd curl

  ensure_azure_login
  select_subscription
  register_azure_providers
  ensure_resource_group
  ensure_aks_cluster
  ensure_kubeconfig
  ensure_public_node_ips_if_requested
  ensure_namespace

  if [[ "$(to_lower "${ENABLE_PUBLIC_NODEPORTS}")" == "true" ]]; then
    ensure_nodeport_rule
  fi

  install_stackablectl
  deploy_rag_demo
  patch_ollama_resources
  wait_for_demo
  show_access_details
}

main "$@"
