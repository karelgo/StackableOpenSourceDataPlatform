# Stackable On AKS

This workspace contains scripts that provision Azure Kubernetes Service clusters in subscription `4910a5a6-aec6-405d-9294-c7f2845512a4`, create or reuse the resource group `dev-stackable-rg`, and deploy Stackable workloads.

The current upstream `opensearch-rag` demo manifests expect deployment into the Kubernetes `default` namespace, so the script defaults to that namespace.

## Files

- `scripts/deploy-stackable-rag-aks.sh`: end-to-end AKS and demo deployment script
- `scripts/deploy-stackable-full-aks.sh`: end-to-end AKS and full platform deployment script for the current full Stackable release plus Cockpit
- `scripts/deploy-stackable-full-workloads.sh`: deploys a resource-trimmed set of actual Stackable workloads on `dev-stackable-full-aks`
- `scripts/expose-opensearch-dashboards-ingress.sh`: exposes the RAG JupyterLab and Dashboards UIs through trusted HTTPS on a single ingress IP
- `scripts/expose-stackable-full-platform-ingress.sh`: exposes the full-platform UIs through a single IP-restricted ingress
- `.github/workflows/deploy-stackable-full-platform.yml`: GitHub Actions workflow for the full platform
- `.github/workflows/deploy-stackable-rag.yml`: GitHub Actions workflow for the RAG demo
- `AUTONOMOUS_AGENT_PROMPT.md`: the prompt you asked me to preserve alongside the deployment assets

## Defaults

- Azure subscription: `4910a5a6-aec6-405d-9294-c7f2845512a4`
- Resource group: `dev-stackable-rg`
- Location: `swedencentral`
- AKS cluster: `dev-stackable-aks`
- Namespace: `default`
- Node size: `Standard_D8s_v3`
- Node count: `1`
- Listener preset: `ephemeral-nodes`
- Trusted HTTPS ingress: enabled
- Base domain suffix: `sslip.io`

The script writes a dedicated kubeconfig to `.kube/dev-stackable-aks.yaml` in this repo so it does not have to overwrite your default kubeconfig.

## Prerequisites

- `az` logged into the `freshminds.nl` tenant
- `kubectl`
- `helm`
- `curl`
- `python3`

## Run

```bash
chmod +x ./scripts/deploy-stackable-rag-aks.sh
./scripts/deploy-stackable-rag-aks.sh
```

## Default HTTPS ingress

By default the RAG deployment now creates a public `ingress-nginx` load balancer, installs `cert-manager`, and issues trusted Let's Encrypt certificates for two `sslip.io` hostnames:

- OpenSearch Dashboards
- JupyterLab

The ingress is application-restricted to your current public IP by default when you run the script locally.

If you run the script from GitHub Actions or any other remote environment, set `ALLOWED_SOURCE_RANGES` explicitly so the ingress is not locked to the runner's egress IP:

```bash
ALLOWED_SOURCE_RANGES=84.104.63.18/32 \
LETSENCRYPT_EMAIL=you@example.com \
./scripts/deploy-stackable-rag-aks.sh
```

If the script cannot infer an email address for Let's Encrypt registration, set `LETSENCRYPT_EMAIL` explicitly.

To disable public HTTPS ingress and keep the deployment private:

```bash
ENABLE_PUBLIC_HTTPS_INGRESS=false ./scripts/deploy-stackable-rag-aks.sh
```

## Optional public NodePort access

You can still use public NodePort access if you want direct node exposure instead of ingress:

If you want direct external access from the internet, run:

```bash
ENABLE_PUBLIC_NODEPORTS=true ./scripts/deploy-stackable-rag-aks.sh
```

In that mode the script:

- enables public IPs on AKS nodes during cluster creation
- opens only TCP NodePort traffic (`30000-32767`) on the AKS-created NSG

That is intentionally narrower than Stackable's generic AKS doc recommendation of allowing all inbound traffic.

## Reapply or repair the HTTPS ingress

If you need to re-run the HTTPS exposure step without redeploying the whole RAG stack, run:

```bash
./scripts/expose-opensearch-dashboards-ingress.sh
```

You can override the allowlist or Let's Encrypt registration email if needed:

```bash
ALLOWED_SOURCE_RANGES=84.104.63.18/32,203.0.113.10/32 \
LETSENCRYPT_EMAIL=you@example.com \
./scripts/expose-opensearch-dashboards-ingress.sh
```

This path exposes only `80/443` on a dedicated ingress load balancer and uses trusted certificates rather than the ingress controller's default self-signed certificate.

## Common overrides

```bash
LOCATION=swedencentral \
AKS_NODE_VM_SIZE=Standard_D8s_v3 \
AKS_NODE_COUNT=1 \
AKS_NAMESPACE=default \
OLLAMA_CPU_REQUEST=3 \
OLLAMA_CPU_LIMIT=6 \
ALLOWED_SOURCE_RANGES=84.104.63.18/32 \
./scripts/deploy-stackable-rag-aks.sh
```

## Cleanup

```bash
az group delete --name dev-stackable-rg --yes --no-wait
```

## Full Platform Deployment

The full platform script provisions a separate AKS cluster named `dev-stackable-full-aks`, installs the current Stackable release bundle `26.3` with all operators, and installs Stackable Cockpit.

The release bundle currently includes: `airflow`, `commons`, `druid`, `hbase`, `hdfs`, `hive`, `kafka`, `listener`, `nifi`, `opa`, `opensearch`, `secret`, `spark-k8s`, `superset`, `trino`, and `zookeeper`.

Defaults:

- Resource group: `dev-stackable-rg`
- AKS cluster: `dev-stackable-full-aks`
- Location: `swedencentral`
- AKS pricing tier: `Standard` (paid control plane)
- Node count: `2`
- Node size: `Standard_D4s_v3`
- Auxiliary nodepool: `d2pool` with `1 x Standard_D2s_v3`
- Operator namespace: `stackable-operators`
- Cockpit namespace: `stackable-cockpit`

Cockpit authentication:

- Set `COCKPIT_ADMIN_PASSWORD` to generate a bcrypt htpasswd file automatically
- Or set `COCKPIT_HTPASSWD_FILE` to point at an existing bcrypt htpasswd file

Example:

```bash
COCKPIT_ADMIN_PASSWORD='change-me-now' \
./scripts/deploy-stackable-full-aks.sh
```

After deployment, access Cockpit with:

```bash
kubectl --kubeconfig /Users/karelgoense/Documents/programming/sandbox/StackableDataplatform/.kube/dev-stackable-full-aks.yaml \
  -n stackable-cockpit port-forward service/stackable-cockpit 8080:80
```

## Full Platform Workloads

The full platform base cluster only installs operators plus Cockpit. To deploy actual workloads on top of it, run:

```bash
./scripts/deploy-stackable-full-workloads.sh
```

The script deploys:

- the Stackable `airflow` stack with reduced Airflow, Trino, OPA, and MinIO resource requests
- a small HDFS stack in `stackable-storage`
- Superset plus PostgreSQL in `stackable-analytics`
- NiFi in `stackable-streaming`

This script is tuned for the current quota-constrained AKS shape in this subscription: `2 x Standard_D4s_v3` plus `1 x Standard_D2s_v3`. In `swedencentral`, the current subscription quota is fully allocated at `10 / 10` regional vCPUs, so increasing worker-node capacity requires a quota increase or a different region.

Default UI credentials created by the workload script:

- Airflow: `admin` / `adminadmin`
- Superset: `admin` / `adminadmin`
- NiFi: `admin` / `adminadmin`
- Trino: `admin` / `adminadmin`
- MinIO: `admin` / `adminadmin`

## Public Ingress For The Full Platform

To expose the user-facing UIs through a single Azure load balancer restricted to your current public IP by default, run:

```bash
./scripts/expose-stackable-full-platform-ingress.sh
```

This script installs `ingress-nginx`, patches Cockpit back to `ClusterIP`, and creates public ingress routes for:

- Cockpit
- Airflow
- Superset
- MinIO Console
- NiFi
- Trino UI

If you need a different allowlist, override it explicitly:

```bash
ALLOWED_SOURCE_RANGES=84.104.63.18/32 \
./scripts/expose-stackable-full-platform-ingress.sh
```

The generated URLs use `sslip.io` hostnames derived from the ingress public IP. HTTPS works, but until you add real DNS and certificates the browser will warn because the ingress uses its default certificate.

## GitHub Actions

Two manual GitHub Actions workflows are included:

- `.github/workflows/deploy-stackable-full-platform.yml`
- `.github/workflows/deploy-stackable-rag.yml`

They are intentionally `workflow_dispatch` only, because they create billable Azure resources.

Azure authentication:

- Preferred: configure OIDC and set `AZURE_CLIENT_ID`, `AZURE_TENANT_ID`, and optionally `AZURE_SUBSCRIPTION_ID`
- Fallback: set `AZURE_CREDENTIALS` as the JSON payload expected by `azure/login`, for example:

```json
{
  "clientId": "00000000-0000-0000-0000-000000000000",
  "clientSecret": "replace-me",
  "subscriptionId": "4910a5a6-aec6-405d-9294-c7f2845512a4",
  "tenantId": "00000000-0000-0000-0000-000000000000"
}
```

Full platform workflow secrets:

- Optional: `STACKABLE_COCKPIT_ADMIN_PASSWORD`
- If omitted, Cockpit falls back to the demo credential `admin` / `adminadmin`
- Optional overrides: `STACKABLE_AIRFLOW_ADMIN_PASSWORD`, `STACKABLE_AIRFLOW_SECRET_KEY`, `STACKABLE_TRINO_ADMIN_PASSWORD`, `STACKABLE_MINIO_ADMIN_PASSWORD`, `STACKABLE_SUPERSET_ADMIN_PASSWORD`, `STACKABLE_SUPERSET_SECRET_KEY`, `STACKABLE_NIFI_ADMIN_PASSWORD`

RAG workflow:

- No extra secrets are required beyond Azure authentication if public HTTPS ingress stays disabled
- If you enable public HTTPS ingress from GitHub Actions, also set `LETSENCRYPT_EMAIL`

Ingress note:

- The RAG workflow only enables public HTTPS ingress when you explicitly pass `allowed_source_ranges` as a workflow input
- This is deliberate: auto-detecting the public IP inside GitHub Actions would capture the GitHub runner egress IP, not your own client IP
