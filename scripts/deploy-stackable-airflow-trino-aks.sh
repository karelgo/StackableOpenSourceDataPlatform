#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

SUBSCRIPTION_ID="${SUBSCRIPTION_ID:-4910a5a6-aec6-405d-9294-c7f2845512a4}"
RESOURCE_GROUP="${RESOURCE_GROUP:-dev-stackable-rg}"
LOCATION="${LOCATION:-swedencentral}"
AKS_CLUSTER_NAME="${AKS_CLUSTER_NAME:-dev-stackable-airflow-trino-aks}"
AKS_NAMESPACE="${AKS_NAMESPACE:-default}"
AKS_NODE_COUNT="${AKS_NODE_COUNT:-1}"
AKS_NODE_VM_SIZE="${AKS_NODE_VM_SIZE:-Standard_D4s_v3}"
AKS_NODE_OSDISK_SIZE="${AKS_NODE_OSDISK_SIZE:-128}"
DEPLOY_TIMEOUT="${DEPLOY_TIMEOUT:-45m}"
KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/.kube/${AKS_CLUSTER_NAME}.yaml}"
STACKABLECTL_BIN="${STACKABLECTL_BIN:-${REPO_ROOT}/.tools/stackablectl}"
STACKABLECTL_DOWNLOAD_BASE_URL="${STACKABLECTL_DOWNLOAD_BASE_URL:-https://github.com/stackabletech/stackable-cockpit/releases/latest/download}"

STACKABLE_RELEASE="${STACKABLE_RELEASE:-26.3}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-stackable-operators}"
LISTENER_CLASS_PRESET="${LISTENER_CLASS_PRESET:-ephemeral-nodes}"
TRINO_STACK_NAME="${TRINO_STACK_NAME:-trino-iceberg}"

BITNAMI_POSTGRESQL_CHART_VERSION="${BITNAMI_POSTGRESQL_CHART_VERSION:-18.5.6}"

AIRFLOW_PRODUCT_VERSION="${AIRFLOW_PRODUCT_VERSION:-3.1.6}"
AIRFLOW_CREDENTIALS_SECRET_NAME="${AIRFLOW_CREDENTIALS_SECRET_NAME:-airflow-credentials}"
AIRFLOW_ADMIN_USERNAME="${AIRFLOW_ADMIN_USERNAME:-admin}"
AIRFLOW_ADMIN_PASSWORD="${AIRFLOW_ADMIN_PASSWORD:-adminadmin}"
AIRFLOW_ADMIN_FIRST_NAME="${AIRFLOW_ADMIN_FIRST_NAME:-Airflow}"
AIRFLOW_ADMIN_LAST_NAME="${AIRFLOW_ADMIN_LAST_NAME:-Admin}"
AIRFLOW_ADMIN_EMAIL="${AIRFLOW_ADMIN_EMAIL:-admin@airflow.local}"
AIRFLOW_POSTGRESQL_RELEASE_NAME="${AIRFLOW_POSTGRESQL_RELEASE_NAME:-airflow-postgresql}"
AIRFLOW_POSTGRESQL_USERNAME="${AIRFLOW_POSTGRESQL_USERNAME:-airflow}"
AIRFLOW_POSTGRESQL_PASSWORD="${AIRFLOW_POSTGRESQL_PASSWORD:-airflow}"
AIRFLOW_POSTGRESQL_DATABASE="${AIRFLOW_POSTGRESQL_DATABASE:-airflow}"

TRINO_ADMIN_USERNAME="${TRINO_ADMIN_USERNAME:-admin}"
TRINO_ADMIN_PASSWORD="${TRINO_ADMIN_PASSWORD:-adminadmin}"
MINIO_ADMIN_USERNAME="${MINIO_ADMIN_USERNAME:-admin}"
MINIO_ADMIN_PASSWORD="${MINIO_ADMIN_PASSWORD:-adminadmin}"

AIRFLOW_WEBSERVER_CPU_REQUEST="${AIRFLOW_WEBSERVER_CPU_REQUEST:-100m}"
AIRFLOW_WEBSERVER_CPU_LIMIT="${AIRFLOW_WEBSERVER_CPU_LIMIT:-500m}"
AIRFLOW_WEBSERVER_MEMORY_LIMIT="${AIRFLOW_WEBSERVER_MEMORY_LIMIT:-512Mi}"
AIRFLOW_SCHEDULER_CPU_REQUEST="${AIRFLOW_SCHEDULER_CPU_REQUEST:-250m}"
AIRFLOW_SCHEDULER_CPU_LIMIT="${AIRFLOW_SCHEDULER_CPU_LIMIT:-750m}"
AIRFLOW_SCHEDULER_MEMORY_LIMIT="${AIRFLOW_SCHEDULER_MEMORY_LIMIT:-1Gi}"
AIRFLOW_EXECUTOR_CPU_REQUEST="${AIRFLOW_EXECUTOR_CPU_REQUEST:-100m}"
AIRFLOW_EXECUTOR_CPU_LIMIT="${AIRFLOW_EXECUTOR_CPU_LIMIT:-500m}"
AIRFLOW_EXECUTOR_MEMORY_LIMIT="${AIRFLOW_EXECUTOR_MEMORY_LIMIT:-512Mi}"
TRINO_CPU_REQUEST="${TRINO_CPU_REQUEST:-50m}"
TRINO_CPU_LIMIT="${TRINO_CPU_LIMIT:-500m}"
TRINO_MEMORY_LIMIT="${TRINO_MEMORY_LIMIT:-1Gi}"
TRINO_INIT_CPU_REQUEST="${TRINO_INIT_CPU_REQUEST:-50m}"
TRINO_INIT_CPU_LIMIT="${TRINO_INIT_CPU_LIMIT:-500m}"
TRINO_INIT_MEMORY_REQUEST="${TRINO_INIT_MEMORY_REQUEST:-512Mi}"
TRINO_INIT_MEMORY_LIMIT="${TRINO_INIT_MEMORY_LIMIT:-1Gi}"
TRINO_SIDECAR_CPU_REQUEST="${TRINO_SIDECAR_CPU_REQUEST:-20m}"
TRINO_SIDECAR_CPU_LIMIT="${TRINO_SIDECAR_CPU_LIMIT:-100m}"
TRINO_SIDECAR_MEMORY_REQUEST="${TRINO_SIDECAR_MEMORY_REQUEST:-32Mi}"
TRINO_SIDECAR_MEMORY_LIMIT="${TRINO_SIDECAR_MEMORY_LIMIT:-64Mi}"
OPA_CPU_REQUEST="${OPA_CPU_REQUEST:-25m}"
OPA_CPU_LIMIT="${OPA_CPU_LIMIT:-100m}"
OPA_MEMORY_LIMIT="${OPA_MEMORY_LIMIT:-128Mi}"
HIVE_METASTORE_CPU_REQUEST="${HIVE_METASTORE_CPU_REQUEST:-100m}"
HIVE_METASTORE_CPU_LIMIT="${HIVE_METASTORE_CPU_LIMIT:-500m}"
HIVE_METASTORE_MEMORY_LIMIT="${HIVE_METASTORE_MEMORY_LIMIT:-512Mi}"
MINIO_CPU_REQUEST="${MINIO_CPU_REQUEST:-100m}"
MINIO_CPU_LIMIT="${MINIO_CPU_LIMIT:-500m}"
MINIO_MEMORY_REQUEST="${MINIO_MEMORY_REQUEST:-256Mi}"
MINIO_MEMORY_LIMIT="${MINIO_MEMORY_LIMIT:-1Gi}"
POSTGRES_CPU_REQUEST="${POSTGRES_CPU_REQUEST:-100m}"
POSTGRES_CPU_LIMIT="${POSTGRES_CPU_LIMIT:-500m}"
POSTGRES_MEMORY_REQUEST="${POSTGRES_MEMORY_REQUEST:-256Mi}"
POSTGRES_MEMORY_LIMIT="${POSTGRES_MEMORY_LIMIT:-512Mi}"
STACKABLE_SECRET_CSI_CPU_REQUEST="${STACKABLE_SECRET_CSI_CPU_REQUEST:-40m}"
STACKABLE_SECRET_CSI_CPU_LIMIT="${STACKABLE_SECRET_CSI_CPU_LIMIT:-100m}"
STACKABLE_SECRET_CSI_MEMORY_REQUEST="${STACKABLE_SECRET_CSI_MEMORY_REQUEST:-64Mi}"
STACKABLE_SECRET_CSI_MEMORY_LIMIT="${STACKABLE_SECRET_CSI_MEMORY_LIMIT:-128Mi}"

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
  local namespace="$1"

  log "Ensuring namespace ${namespace} exists"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f -
}

install_stackable_release() {
  run "${STACKABLECTL_BIN}" \
    release install "${STACKABLE_RELEASE}" \
    --operator-namespace "${OPERATOR_NAMESPACE}" \
    --listener-class-preset "${LISTENER_CLASS_PRESET}" \
    --include commons \
    --include listener \
    --include secret \
    --include airflow \
    --include trino \
    --include hive \
    --include opa
}

patch_listener_classes_internal() {
  local listener_class

  for listener_class in external-stable external-unstable; do
    if kubectl get listenerclass "${listener_class}" >/dev/null 2>&1; then
      run kubectl patch listenerclass "${listener_class}" \
        --type merge \
        -p '{"spec":{"serviceType":"ClusterIP"}}'
    fi
  done
}

install_trino_stack() {
  if kubectl -n "${AKS_NAMESPACE}" get trinocluster trino >/dev/null 2>&1; then
    log "Trino stack already present in namespace ${AKS_NAMESPACE}; skipping initial install"
    return
  fi

  run "${STACKABLECTL_BIN}" stack install "${TRINO_STACK_NAME}" \
    --skip-release \
    --release "${STACKABLE_RELEASE}" \
    --operator-namespace "${OPERATOR_NAMESPACE}" \
    --namespace "${AKS_NAMESPACE}" \
    --parameters "trinoAdminPassword=${TRINO_ADMIN_PASSWORD}" \
    --parameters "minioAdminPassword=${MINIO_ADMIN_PASSWORD}"
}

install_airflow_postgresql() {
  run helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
  run helm repo update >/dev/null

  run helm upgrade --install "${AIRFLOW_POSTGRESQL_RELEASE_NAME}" bitnami/postgresql \
    --namespace "${AKS_NAMESPACE}" \
    --create-namespace \
    --version "${BITNAMI_POSTGRESQL_CHART_VERSION}" \
    --set auth.username="${AIRFLOW_POSTGRESQL_USERNAME}" \
    --set auth.password="${AIRFLOW_POSTGRESQL_PASSWORD}" \
    --set auth.database="${AIRFLOW_POSTGRESQL_DATABASE}" \
    --set global.security.allowInsecureImages=true \
    --set image.repository=bitnamilegacy/postgresql \
    --set volumePermissions.image.repository=bitnamilegacy/os-shell \
    --set metrics.image.repository=bitnamilegacy/postgres-exporter \
    --set primary.resources.requests.cpu="${POSTGRES_CPU_REQUEST}" \
    --set primary.resources.requests.memory="${POSTGRES_MEMORY_REQUEST}" \
    --set primary.resources.limits.cpu="${POSTGRES_CPU_LIMIT}" \
    --set primary.resources.limits.memory="${POSTGRES_MEMORY_LIMIT}" \
    --set primary.persistence.size=8Gi \
    --wait
}

apply_airflow_credentials() {
  kubectl apply -n "${AKS_NAMESPACE}" -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: ${AIRFLOW_CREDENTIALS_SECRET_NAME}
type: Opaque
stringData:
  adminUser.username: ${AIRFLOW_ADMIN_USERNAME}
  adminUser.firstname: ${AIRFLOW_ADMIN_FIRST_NAME}
  adminUser.lastname: ${AIRFLOW_ADMIN_LAST_NAME}
  adminUser.email: ${AIRFLOW_ADMIN_EMAIL}
  adminUser.password: ${AIRFLOW_ADMIN_PASSWORD}
  connections.sqlalchemyDatabaseUri: postgresql+psycopg2://${AIRFLOW_POSTGRESQL_USERNAME}:${AIRFLOW_POSTGRESQL_PASSWORD}@${AIRFLOW_POSTGRESQL_RELEASE_NAME}.${AKS_NAMESPACE}.svc.cluster.local:5432/${AIRFLOW_POSTGRESQL_DATABASE}
EOF
}

apply_airflow_cluster() {
  kubectl apply -n "${AKS_NAMESPACE}" -f - <<EOF
apiVersion: airflow.stackable.tech/v1alpha1
kind: AirflowCluster
metadata:
  name: airflow
spec:
  image:
    productVersion: ${AIRFLOW_PRODUCT_VERSION}
    pullPolicy: IfNotPresent
  clusterConfig:
    loadExamples: true
    exposeConfig: false
    credentialsSecret: ${AIRFLOW_CREDENTIALS_SECRET_NAME}
  webservers:
    roleConfig:
      listenerClass: cluster-internal
    config:
      resources:
        cpu:
          min: "${AIRFLOW_WEBSERVER_CPU_REQUEST}"
          max: "${AIRFLOW_WEBSERVER_CPU_LIMIT}"
        memory:
          limit: "${AIRFLOW_WEBSERVER_MEMORY_LIMIT}"
    roleGroups:
      default:
        replicas: 1
  schedulers:
    config:
      resources:
        cpu:
          min: "${AIRFLOW_SCHEDULER_CPU_REQUEST}"
          max: "${AIRFLOW_SCHEDULER_CPU_LIMIT}"
        memory:
          limit: "${AIRFLOW_SCHEDULER_MEMORY_LIMIT}"
    roleGroups:
      default:
        replicas: 1
  kubernetesExecutors:
    config:
      resources:
        cpu:
          min: "${AIRFLOW_EXECUTOR_CPU_REQUEST}"
          max: "${AIRFLOW_EXECUTOR_CPU_LIMIT}"
        memory:
          limit: "${AIRFLOW_EXECUTOR_MEMORY_LIMIT}"
EOF
}

downsize_stackable_operator_deployments() {
  local deployment

  while IFS= read -r deployment; do
    [[ -n "${deployment}" ]] || continue
    run kubectl -n "${OPERATOR_NAMESPACE}" set resources "${deployment}" \
      --containers='*' \
      --requests=cpu=50m,memory=64Mi \
      --limits=cpu=200m,memory=256Mi
  done < <(kubectl -n "${OPERATOR_NAMESPACE}" get deployment -o name 2>/dev/null || true)
}

downsize_stackable_secret_csi_daemonset() {
  if kubectl -n "${OPERATOR_NAMESPACE}" get daemonset secret-operator-csi-node-driver >/dev/null 2>&1; then
    run kubectl -n "${OPERATOR_NAMESPACE}" set resources daemonset/secret-operator-csi-node-driver \
      --containers='*' \
      --requests="cpu=${STACKABLE_SECRET_CSI_CPU_REQUEST},memory=${STACKABLE_SECRET_CSI_MEMORY_REQUEST}" \
      --limits="cpu=${STACKABLE_SECRET_CSI_CPU_LIMIT},memory=${STACKABLE_SECRET_CSI_MEMORY_LIMIT}"
  fi
}

normalize_stack_exposure() {
  if kubectl -n "${AKS_NAMESPACE}" get trinocluster trino >/dev/null 2>&1; then
    run kubectl -n "${AKS_NAMESPACE}" patch trinocluster trino \
      --type merge \
      -p '{"spec":{"coordinators":{"roleConfig":{"listenerClass":"cluster-internal"}}}}'
  fi

  if kubectl -n "${AKS_NAMESPACE}" get service minio >/dev/null 2>&1; then
    run kubectl -n "${AKS_NAMESPACE}" patch service minio \
      --type merge \
      -p '{"spec":{"type":"ClusterIP"}}'
  fi

  if kubectl -n "${AKS_NAMESPACE}" get service minio-console >/dev/null 2>&1; then
    run kubectl -n "${AKS_NAMESPACE}" patch service minio-console \
      --type merge \
      -p '{"spec":{"type":"ClusterIP"}}'
  fi
}

tune_trino_stack() {
  if kubectl -n "${AKS_NAMESPACE}" get trinocluster trino >/dev/null 2>&1; then
    run kubectl -n "${AKS_NAMESPACE}" patch trinocluster trino \
      --type merge \
      -p "$(cat <<EOF
{"spec":{
  "coordinators":{
    "config":{"resources":{"cpu":{"min":"${TRINO_CPU_REQUEST}","max":"${TRINO_CPU_LIMIT}"},"memory":{"limit":"${TRINO_MEMORY_LIMIT}"}}},
    "configOverrides":{"config.properties":{"http-server.process-forwarded":"true"}},
    "podOverrides":{"spec":{
      "initContainers":[{"name":"prepare","resources":{"requests":{"cpu":"${TRINO_INIT_CPU_REQUEST}","memory":"${TRINO_INIT_MEMORY_REQUEST}"},"limits":{"cpu":"${TRINO_INIT_CPU_LIMIT}","memory":"${TRINO_INIT_MEMORY_LIMIT}"}}}],
      "containers":[
        {"name":"trino","resources":{"requests":{"cpu":"${TRINO_CPU_REQUEST}","memory":"${TRINO_MEMORY_LIMIT}"},"limits":{"cpu":"${TRINO_CPU_LIMIT}","memory":"${TRINO_MEMORY_LIMIT}"}}},
        {"name":"password-file-updater","resources":{"requests":{"cpu":"${TRINO_SIDECAR_CPU_REQUEST}","memory":"${TRINO_SIDECAR_MEMORY_REQUEST}"},"limits":{"cpu":"${TRINO_SIDECAR_CPU_LIMIT}","memory":"${TRINO_SIDECAR_MEMORY_LIMIT}"}}}
      ]
    }}
  },
  "workers":{
    "config":{"resources":{"cpu":{"min":"${TRINO_CPU_REQUEST}","max":"${TRINO_CPU_LIMIT}"},"memory":{"limit":"${TRINO_MEMORY_LIMIT}"}}},
    "podOverrides":{"spec":{
      "initContainers":[{"name":"prepare","resources":{"requests":{"cpu":"${TRINO_INIT_CPU_REQUEST}","memory":"${TRINO_INIT_MEMORY_REQUEST}"},"limits":{"cpu":"${TRINO_INIT_CPU_LIMIT}","memory":"${TRINO_INIT_MEMORY_LIMIT}"}}}],
      "containers":[
        {"name":"trino","resources":{"requests":{"cpu":"${TRINO_CPU_REQUEST}","memory":"${TRINO_MEMORY_LIMIT}"},"limits":{"cpu":"${TRINO_CPU_LIMIT}","memory":"${TRINO_MEMORY_LIMIT}"}}}
      ]
    }}
  }
}}
EOF
)"

    kubectl -n "${AKS_NAMESPACE}" patch trinocluster trino \
      --type json \
      -p '[{"op":"remove","path":"/spec/coordinators/podOverrides/spec/nodeSelector/kubernetes.io~1hostname"}]' \
      >/dev/null 2>&1 || true
  fi
}

tune_opa_stack() {
  if kubectl -n "${AKS_NAMESPACE}" get opacluster opa >/dev/null 2>&1; then
    run kubectl -n "${AKS_NAMESPACE}" patch opacluster opa \
      --type merge \
      -p "$(cat <<EOF
{"spec":{"servers":{"config":{"resources":{"cpu":{"min":"${OPA_CPU_REQUEST}","max":"${OPA_CPU_LIMIT}"},"memory":{"limit":"${OPA_MEMORY_LIMIT}"}}},"roleGroups":{"default":{"replicas":1}}}}}
EOF
)"
  fi
}

tune_hive_stack() {
  if kubectl -n "${AKS_NAMESPACE}" get hivecluster hive-iceberg >/dev/null 2>&1; then
    run kubectl -n "${AKS_NAMESPACE}" patch hivecluster hive-iceberg \
      --type merge \
      -p "$(cat <<EOF
{"spec":{"metastore":{"config":{"resources":{"cpu":{"min":"${HIVE_METASTORE_CPU_REQUEST}","max":"${HIVE_METASTORE_CPU_LIMIT}"},"memory":{"limit":"${HIVE_METASTORE_MEMORY_LIMIT}"}}}}}
EOF
)"
  fi
}

downsize_minio() {
  if kubectl -n "${AKS_NAMESPACE}" get deployment minio >/dev/null 2>&1; then
    run kubectl -n "${AKS_NAMESPACE}" set resources deployment/minio \
      --containers='*' \
      --requests="cpu=${MINIO_CPU_REQUEST},memory=${MINIO_MEMORY_REQUEST}" \
      --limits="cpu=${MINIO_CPU_LIMIT},memory=${MINIO_MEMORY_LIMIT}"
  fi
}

wait_for_rollouts() {
  local namespace="$1"
  local resources
  local pods
  local pod

  resources="$(kubectl -n "${namespace}" get deployment,statefulset,daemonset -o name 2>/dev/null || true)"
  if [[ -z "${resources}" ]]; then
    log "No deployments, statefulsets, or daemonsets found in namespace ${namespace}; skipping rollout wait"
    return
  fi

  while IFS= read -r resource; do
    [[ -n "${resource}" ]] || continue
    run kubectl -n "${namespace}" rollout status "${resource}" --timeout=30m
  done <<< "${resources}"

  pods="$(kubectl -n "${namespace}" get pods --field-selector=status.phase!=Succeeded -o name 2>/dev/null || true)"
  while IFS= read -r pod; do
    [[ -n "${pod}" ]] || continue
    run kubectl -n "${namespace}" wait --for=condition=Ready "${pod}" --timeout=20m
  done <<< "${pods}"
}

show_status() {
  run kubectl get pods -A
  run kubectl get svc -A
}

show_access_details() {
  printf '\n'
  printf 'KUBECONFIG=%s\n' "${KUBECONFIG_FILE}"
  printf 'AKS cluster: %s\n' "${AKS_CLUSTER_NAME}"
  printf 'Namespace: %s\n' "${AKS_NAMESPACE}"
  printf 'Operator namespace: %s\n' "${OPERATOR_NAMESPACE}"
  printf 'Stackable release: %s\n' "${STACKABLE_RELEASE}"
  printf '\n'
  printf 'Credentials:\n'
  printf '  Airflow: %s / %s\n' "${AIRFLOW_ADMIN_USERNAME}" "${AIRFLOW_ADMIN_PASSWORD}"
  printf '  Trino: %s / %s\n' "${TRINO_ADMIN_USERNAME}" "${TRINO_ADMIN_PASSWORD}"
  printf '  MinIO: %s / %s\n' "${MINIO_ADMIN_USERNAME}" "${MINIO_ADMIN_PASSWORD}"
  printf '\n'
  printf 'Access commands:\n'
  printf '  kubectl --kubeconfig %q -n %q port-forward service/airflow-webserver 8080:8080\n' \
    "${KUBECONFIG_FILE}" "${AKS_NAMESPACE}"
  printf '  kubectl --kubeconfig %q -n %q port-forward service/trino-coordinator 8443:8443\n' \
    "${KUBECONFIG_FILE}" "${AKS_NAMESPACE}"
  printf '  kubectl --kubeconfig %q -n %q port-forward service/minio-console 9001:9001\n' \
    "${KUBECONFIG_FILE}" "${AKS_NAMESPACE}"
  printf '\n'
  printf 'Validation commands:\n'
  printf '  kubectl --kubeconfig %q -n %q get airflowcluster,trinocluster,hivecluster,opacluster\n' \
    "${KUBECONFIG_FILE}" "${AKS_NAMESPACE}"
  printf '  kubectl --kubeconfig %q -n %q get pods,svc,statefulset\n' \
    "${KUBECONFIG_FILE}" "${AKS_NAMESPACE}"
  printf '\n'
}

main() {
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
  ensure_kubeconfig
  ensure_namespace "${AKS_NAMESPACE}"
  ensure_namespace "${OPERATOR_NAMESPACE}"

  if [[ ! -x "${STACKABLECTL_BIN}" ]]; then
    install_stackablectl
  fi

  require_cmd "${STACKABLECTL_BIN}"

  install_stackable_release
  downsize_stackable_operator_deployments
  downsize_stackable_secret_csi_daemonset
  wait_for_rollouts "${OPERATOR_NAMESPACE}"
  patch_listener_classes_internal

  install_trino_stack
  install_airflow_postgresql
  apply_airflow_credentials
  apply_airflow_cluster

  normalize_stack_exposure
  tune_trino_stack
  tune_opa_stack
  tune_hive_stack
  downsize_minio

  wait_for_rollouts "${AKS_NAMESPACE}"
  show_status
  show_access_details
}

main "$@"
