#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KUBECONFIG_FILE="${KUBECONFIG_FILE:-${REPO_ROOT}/.kube/dev-stackable-full-aks.yaml}"
STACKABLECTL_BIN="${STACKABLECTL_BIN:-${REPO_ROOT}/.tools/stackablectl}"

AIRFLOW_NAMESPACE="${AIRFLOW_NAMESPACE:-default}"
STORAGE_NAMESPACE="${STORAGE_NAMESPACE:-stackable-storage}"
ANALYTICS_NAMESPACE="${ANALYTICS_NAMESPACE:-stackable-analytics}"
STREAMING_NAMESPACE="${STREAMING_NAMESPACE:-stackable-streaming}"
OPERATOR_NAMESPACE="${OPERATOR_NAMESPACE:-stackable-operators}"
COCKPIT_NAMESPACE="${COCKPIT_NAMESPACE:-stackable-cockpit}"

BITNAMI_POSTGRESQL_CHART_VERSION="${BITNAMI_POSTGRESQL_CHART_VERSION:-18.5.6}"

AIRFLOW_ADMIN_PASSWORD="${AIRFLOW_ADMIN_PASSWORD:-adminadmin}"
AIRFLOW_SECRET_KEY="${AIRFLOW_SECRET_KEY:-airflowSecretKey}"
TRINO_ADMIN_PASSWORD="${TRINO_ADMIN_PASSWORD:-adminadmin}"
MINIO_ADMIN_PASSWORD="${MINIO_ADMIN_PASSWORD:-adminadmin}"
SUPERSET_ADMIN_PASSWORD="${SUPERSET_ADMIN_PASSWORD:-adminadmin}"
SUPERSET_SECRET_KEY="${SUPERSET_SECRET_KEY:-supersetSecretKey}"
NIFI_ADMIN_PASSWORD="${NIFI_ADMIN_PASSWORD:-adminadmin}"
AIRFLOW_BACKGROUND_CPU_REQUEST="${AIRFLOW_BACKGROUND_CPU_REQUEST:-250m}"
AIRFLOW_BACKGROUND_CPU_LIMIT="${AIRFLOW_BACKGROUND_CPU_LIMIT:-500m}"
AIRFLOW_BACKGROUND_MEMORY_LIMIT="${AIRFLOW_BACKGROUND_MEMORY_LIMIT:-512Mi}"
AIRFLOW_WEBSERVER_CPU_REQUEST="${AIRFLOW_WEBSERVER_CPU_REQUEST:-500m}"
AIRFLOW_WEBSERVER_CPU_LIMIT="${AIRFLOW_WEBSERVER_CPU_LIMIT:-1}"
AIRFLOW_WEBSERVER_MEMORY_LIMIT="${AIRFLOW_WEBSERVER_MEMORY_LIMIT:-1Gi}"
TRINO_CPU_REQUEST="${TRINO_CPU_REQUEST:-100m}"
TRINO_CPU_LIMIT="${TRINO_CPU_LIMIT:-500m}"
TRINO_MEMORY_LIMIT="${TRINO_MEMORY_LIMIT:-1Gi}"
TRINO_INIT_CPU_REQUEST="${TRINO_INIT_CPU_REQUEST:-100m}"
TRINO_INIT_CPU_LIMIT="${TRINO_INIT_CPU_LIMIT:-500m}"
TRINO_INIT_MEMORY_REQUEST="${TRINO_INIT_MEMORY_REQUEST:-512Mi}"
TRINO_INIT_MEMORY_LIMIT="${TRINO_INIT_MEMORY_LIMIT:-1Gi}"
TRINO_SIDECAR_CPU_REQUEST="${TRINO_SIDECAR_CPU_REQUEST:-50m}"
TRINO_SIDECAR_CPU_LIMIT="${TRINO_SIDECAR_CPU_LIMIT:-100m}"
TRINO_SIDECAR_MEMORY_REQUEST="${TRINO_SIDECAR_MEMORY_REQUEST:-32Mi}"
TRINO_SIDECAR_MEMORY_LIMIT="${TRINO_SIDECAR_MEMORY_LIMIT:-64Mi}"
SUPERSET_CPU_REQUEST="${SUPERSET_CPU_REQUEST:-100m}"
SUPERSET_CPU_LIMIT="${SUPERSET_CPU_LIMIT:-500m}"
SUPERSET_MEMORY_LIMIT="${SUPERSET_MEMORY_LIMIT:-1Gi}"
NIFI_CPU_REQUEST="${NIFI_CPU_REQUEST:-250m}"
NIFI_CPU_LIMIT="${NIFI_CPU_LIMIT:-1}"
NIFI_MEMORY_LIMIT="${NIFI_MEMORY_LIMIT:-2Gi}"
NIFI_INIT_CPU_REQUEST="${NIFI_INIT_CPU_REQUEST:-250m}"
NIFI_INIT_CPU_LIMIT="${NIFI_INIT_CPU_LIMIT:-500m}"
NIFI_INIT_MEMORY_REQUEST="${NIFI_INIT_MEMORY_REQUEST:-1Gi}"
NIFI_INIT_MEMORY_LIMIT="${NIFI_INIT_MEMORY_LIMIT:-1536Mi}"

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

ensure_namespace() {
  local namespace="$1"
  kubectl create namespace "${namespace}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
}

patch_listener_classes_internal() {
  local listener_class

  for listener_class in external-stable external-unstable; do
    run kubectl patch listenerclass "${listener_class}" \
      --type merge \
      -p '{"spec":{"serviceType":"ClusterIP"}}'
  done
}

install_airflow_stack() {
  if kubectl -n "${AIRFLOW_NAMESPACE}" get airflowcluster airflow >/dev/null 2>&1; then
    log "Airflow stack already present in namespace ${AIRFLOW_NAMESPACE}; skipping initial install"
    return
  fi

  run "${STACKABLECTL_BIN}" stack install airflow \
    --skip-release \
    --namespace "${AIRFLOW_NAMESPACE}" \
    --operator-namespace stackable-operators \
    --parameters "trinoAdminPassword=${TRINO_ADMIN_PASSWORD}" \
    --parameters "minioAdminPassword=${MINIO_ADMIN_PASSWORD}" \
    --parameters "airflowAdminPassword=${AIRFLOW_ADMIN_PASSWORD}" \
    --parameters "airflowSecretKey=${AIRFLOW_SECRET_KEY}"
}

normalize_airflow_stack_exposure() {
  if kubectl -n "${AIRFLOW_NAMESPACE}" get airflowcluster airflow >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" patch airflowcluster airflow \
      --type merge \
      -p '{"spec":{"webservers":{"roleConfig":{"listenerClass":"cluster-internal"}}}}'
  fi

  if kubectl -n "${AIRFLOW_NAMESPACE}" get trinocluster trino >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" patch trinocluster trino \
      --type merge \
      -p '{"spec":{"coordinators":{"roleConfig":{"listenerClass":"cluster-internal"}}}}'
  fi

  if kubectl -n "${AIRFLOW_NAMESPACE}" get service minio >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" patch service minio \
      --type merge \
      -p '{"spec":{"type":"ClusterIP"}}'
  fi

  if kubectl -n "${AIRFLOW_NAMESPACE}" get service minio-console >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" patch service minio-console \
      --type merge \
      -p '{"spec":{"type":"ClusterIP"}}'
  fi
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

tune_cockpit_resources() {
  if kubectl -n "${COCKPIT_NAMESPACE}" get deployment stackable-cockpit-deployment >/dev/null 2>&1; then
    run kubectl -n "${COCKPIT_NAMESPACE}" set resources deployment/stackable-cockpit-deployment \
      --containers='*' \
      --requests=cpu=100m,memory=128Mi \
      --limits=cpu=300m,memory=256Mi
  fi
}

tune_airflow_stack() {
  if kubectl -n "${AIRFLOW_NAMESPACE}" get airflowcluster airflow >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" patch airflowcluster airflow \
      --type merge \
      -p "$(cat <<EOF
{"spec":{
  "dagProcessors":{"config":{"resources":{"cpu":{"min":"${AIRFLOW_BACKGROUND_CPU_REQUEST}","max":"${AIRFLOW_BACKGROUND_CPU_LIMIT}"},"memory":{"limit":"${AIRFLOW_BACKGROUND_MEMORY_LIMIT}"}}},"roleGroups":{"default":{"replicas":0}}},
  "schedulers":{"config":{"resources":{"cpu":{"min":"${AIRFLOW_BACKGROUND_CPU_REQUEST}","max":"${AIRFLOW_BACKGROUND_CPU_LIMIT}"},"memory":{"limit":"${AIRFLOW_BACKGROUND_MEMORY_LIMIT}"}}}},
  "triggerers":{"config":{"resources":{"cpu":{"min":"${AIRFLOW_BACKGROUND_CPU_REQUEST}","max":"${AIRFLOW_BACKGROUND_CPU_LIMIT}"},"memory":{"limit":"${AIRFLOW_BACKGROUND_MEMORY_LIMIT}"}}},"roleGroups":{"default":{"replicas":0}}},
  "webservers":{"config":{"resources":{"cpu":{"min":"${AIRFLOW_WEBSERVER_CPU_REQUEST}","max":"${AIRFLOW_WEBSERVER_CPU_LIMIT}"},"memory":{"limit":"${AIRFLOW_WEBSERVER_MEMORY_LIMIT}"}}}}
}}
EOF
)"
  fi
}

tune_trino_stack() {
  if kubectl -n "${AIRFLOW_NAMESPACE}" get trinocluster trino >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" patch trinocluster trino \
      --type merge \
      -p "$(cat <<EOF
{"spec":{
  "coordinators":{
    "config":{"resources":{"cpu":{"min":"${TRINO_CPU_REQUEST}","max":"${TRINO_CPU_LIMIT}"},"memory":{"limit":"${TRINO_MEMORY_LIMIT}"}}},
    "configOverrides":{"config.properties":{"http-server.process-forwarded":"true"}},
    "podOverrides":{"spec":{
      "nodeSelector":{"agentpool":"nodepool1"},
      "initContainers":[{"name":"prepare","resources":{"requests":{"cpu":"${TRINO_INIT_CPU_REQUEST}","memory":"${TRINO_INIT_MEMORY_REQUEST}"},"limits":{"cpu":"${TRINO_INIT_CPU_LIMIT}","memory":"${TRINO_INIT_MEMORY_LIMIT}"}}}],
      "containers":[
        {"name":"trino","resources":{"requests":{"cpu":"${TRINO_CPU_REQUEST}","memory":"${TRINO_MEMORY_LIMIT}"},"limits":{"cpu":"${TRINO_CPU_LIMIT}","memory":"${TRINO_MEMORY_LIMIT}"}}},
        {"name":"password-file-updater","resources":{"requests":{"cpu":"${TRINO_SIDECAR_CPU_REQUEST}","memory":"${TRINO_SIDECAR_MEMORY_REQUEST}"},"limits":{"cpu":"${TRINO_SIDECAR_CPU_LIMIT}","memory":"${TRINO_SIDECAR_MEMORY_LIMIT}"}}}
      ]
    }}
  },
  "workers":{"config":{"resources":{"cpu":{"min":"${TRINO_CPU_REQUEST}","max":"${TRINO_CPU_LIMIT}"},"memory":{"limit":"${TRINO_MEMORY_LIMIT}"}}}}
}}
EOF
)"
  fi
}

tune_opa_stack() {
  if kubectl -n "${AIRFLOW_NAMESPACE}" get opacluster opa >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" patch opacluster opa \
      --type merge \
      -p '{"spec":{"servers":{"config":{"resources":{"cpu":{"min":"50m","max":"100m"},"memory":{"limit":"128Mi"}}},"roleGroups":{"default":{"replicas":2}}}}}'
  fi
}

downsize_minio() {
  if kubectl -n "${AIRFLOW_NAMESPACE}" get deployment minio >/dev/null 2>&1; then
    run kubectl -n "${AIRFLOW_NAMESPACE}" set resources deployment/minio \
      --containers='*' \
      --requests=cpu=200m,memory=512Mi \
      --limits=cpu=500m,memory=1Gi
  fi
}

install_superset_database() {
  run helm repo add bitnami https://charts.bitnami.com/bitnami >/dev/null
  run helm repo update >/dev/null

  run helm upgrade --install postgresql-superset bitnami/postgresql \
    --namespace "${ANALYTICS_NAMESPACE}" \
    --create-namespace \
    --version "${BITNAMI_POSTGRESQL_CHART_VERSION}" \
    --set auth.username=superset \
    --set auth.password=superset \
    --set auth.database=superset \
    --set global.security.allowInsecureImages=true \
    --set image.repository=bitnamilegacy/postgresql \
    --set volumePermissions.image.repository=bitnamilegacy/os-shell \
    --set metrics.image.repository=bitnamilegacy/postgres-exporter \
    --set primary.resources.requests.cpu=100m \
    --set primary.resources.requests.memory=256Mi \
    --set primary.resources.limits.cpu=500m \
    --set primary.resources.limits.memory=512Mi \
    --set primary.persistence.size=8Gi \
    --set commonLabels.stackable\\.tech/vendor=Stackable
}

apply_storage_stack() {
  kubectl apply -n "${STORAGE_NAMESPACE}" -f - <<'EOF'
apiVersion: zookeeper.stackable.tech/v1alpha1
kind: ZookeeperCluster
metadata:
  name: zookeeper
spec:
  image:
    productVersion: 3.9.4
  servers:
    roleGroups:
      default:
        replicas: 1
---
apiVersion: zookeeper.stackable.tech/v1alpha1
kind: ZookeeperZnode
metadata:
  name: hdfs-znode
spec:
  clusterRef:
    name: zookeeper
---
apiVersion: hdfs.stackable.tech/v1alpha1
kind: HdfsCluster
metadata:
  name: hdfs
spec:
  image:
    productVersion: 3.4.2
  clusterConfig:
    dfsReplication: 1
    listenerClass: cluster-internal
    zookeeperConfigMapName: hdfs-znode
  nameNodes:
    config:
      listenerClass: cluster-internal
      resources:
        cpu:
          min: 100m
          max: 500m
        storage:
          data:
            capacity: 5Gi
    roleGroups:
      default:
        replicas: 2
  dataNodes:
    config:
      listenerClass: cluster-internal
      resources:
        storage:
          data:
            capacity: 5Gi
    roleGroups:
      default:
        replicas: 1
  journalNodes:
    config:
      resources:
        storage:
          data:
            capacity: 5Gi
    roleGroups:
      default:
        replicas: 1
EOF
}

apply_superset() {
  kubectl apply -n "${ANALYTICS_NAMESPACE}" -f - <<EOF
apiVersion: superset.stackable.tech/v1alpha1
kind: SupersetCluster
metadata:
  name: superset
spec:
  image:
    productVersion: 6.0.0
  clusterConfig:
    credentialsSecret: superset-credentials
  nodes:
    config:
      resources:
        cpu:
          min: "${SUPERSET_CPU_REQUEST}"
          max: "${SUPERSET_CPU_LIMIT}"
        memory:
          limit: "${SUPERSET_MEMORY_LIMIT}"
    roleConfig:
      listenerClass: cluster-internal
    roleGroups:
      default:
        replicas: 1
---
apiVersion: v1
kind: Secret
metadata:
  name: superset-credentials
type: Opaque
stringData:
  adminUser.username: admin
  adminUser.firstname: Superset
  adminUser.lastname: Admin
  adminUser.email: admin@superset.com
  adminUser.password: "${SUPERSET_ADMIN_PASSWORD}"
  connections.secretKey: "${SUPERSET_SECRET_KEY}"
  connections.sqlalchemyDatabaseUri: postgresql://superset:superset@postgresql-superset.${ANALYTICS_NAMESPACE}.svc.cluster.local:5432/superset
EOF
}

apply_nifi() {
  kubectl apply -n "${STREAMING_NAMESPACE}" -f - <<EOF
apiVersion: authentication.stackable.tech/v1alpha1
kind: AuthenticationClass
metadata:
  name: streaming-nifi-admin-credentials
spec:
  provider:
    static:
      userCredentialsSecret:
        name: nifi-admin-credentials-secret
---
apiVersion: v1
kind: Secret
metadata:
  name: nifi-admin-credentials-secret
stringData:
  admin: "${NIFI_ADMIN_PASSWORD}"
---
apiVersion: nifi.stackable.tech/v1alpha1
kind: NifiCluster
metadata:
  name: nifi
spec:
  image:
    productVersion: 2.7.2
  clusterConfig:
    authentication:
      - authenticationClass: streaming-nifi-admin-credentials
    sensitiveProperties:
      keySecret: nifi-sensitive-property-key
      autoGenerate: true
  nodes:
    podOverrides:
      spec:
        nodeSelector:
          agentpool: nodepool1
        initContainers:
          - name: prepare
            resources:
              requests:
                cpu: "${NIFI_INIT_CPU_REQUEST}"
                memory: "${NIFI_INIT_MEMORY_REQUEST}"
              limits:
                cpu: "${NIFI_INIT_CPU_LIMIT}"
                memory: "${NIFI_INIT_MEMORY_LIMIT}"
    roleConfig:
      listenerClass: cluster-internal
    config:
      resources:
        cpu:
          min: "${NIFI_CPU_REQUEST}"
          max: "${NIFI_CPU_LIMIT}"
        memory:
          limit: "${NIFI_MEMORY_LIMIT}"
        storage:
          contentRepo:
            capacity: "6Gi"
          databaseRepo:
            capacity: "1Gi"
          flowfileRepo:
            capacity: "1Gi"
          provenanceRepo:
            capacity: "2Gi"
          stateRepo:
            capacity: "1Gi"
    configOverrides:
      nifi.properties:
        nifi.web.https.sni.required: "false"
        nifi.web.https.sni.host.check: "false"
    roleGroups:
      default:
        replicas: 1
EOF
}

wait_for_rollouts() {
  local namespace="$1"
  local resources
  local pods
  local pod

  resources="$(kubectl -n "${namespace}" get deployment,statefulset -o name 2>/dev/null || true)"
  if [[ -z "${resources}" ]]; then
    log "No deployments or statefulsets found in namespace ${namespace}; skipping rollout wait"
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

main() {
  require_cmd kubectl
  require_cmd helm
  require_cmd "${STACKABLECTL_BIN}"

  [[ -f "${KUBECONFIG_FILE}" ]] || fail "Kubeconfig not found: ${KUBECONFIG_FILE}"
  export KUBECONFIG="${KUBECONFIG_FILE}"

  run kubectl cluster-info

  ensure_namespace "${STORAGE_NAMESPACE}"
  ensure_namespace "${ANALYTICS_NAMESPACE}"
  ensure_namespace "${STREAMING_NAMESPACE}"

  patch_listener_classes_internal
  install_airflow_stack
  normalize_airflow_stack_exposure
  downsize_stackable_operator_deployments
  tune_cockpit_resources
  tune_airflow_stack
  tune_trino_stack
  tune_opa_stack
  downsize_minio
  install_superset_database
  apply_storage_stack
  apply_superset
  apply_nifi

  wait_for_rollouts "${AIRFLOW_NAMESPACE}"
  wait_for_rollouts "${STORAGE_NAMESPACE}"
  wait_for_rollouts "${ANALYTICS_NAMESPACE}"
  wait_for_rollouts "${STREAMING_NAMESPACE}"
  show_status

  printf '\n'
  printf 'Namespaces:\n'
  printf '  Airflow stack: %s\n' "${AIRFLOW_NAMESPACE}"
  printf '  Storage stack: %s\n' "${STORAGE_NAMESPACE}"
  printf '  Analytics stack: %s\n' "${ANALYTICS_NAMESPACE}"
  printf '  Streaming stack: %s\n' "${STREAMING_NAMESPACE}"
}

main "$@"
