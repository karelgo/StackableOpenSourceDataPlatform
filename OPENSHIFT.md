# Stackable On OpenShift

This repo now includes an OpenShift path for the same full Stackable platform that the AKS scripts deploy.

## What Works

As of April 7, 2026, Stackable `26.3` is published in the Red Hat Certified Operator Catalog for OpenShift `4.18`, `4.19`, and `4.20`.

The new scripts in this repo install:

- the full Stackable operator release into `stackable-operators`
- Stackable Cockpit into `stackable-cockpit`
- the trimmed demo workloads used by this repo:
  - Airflow + Trino + OPA + MinIO
  - HDFS
  - Superset + PostgreSQL
  - NiFi

## Files

- `scripts/deploy-stackable-full-openshift.sh`: installs the full Stackable operator release plus Cockpit on an existing OpenShift cluster
- `scripts/deploy-stackable-full-workloads-openshift.sh`: deploys the trimmed demo workloads on top of that base platform

## Important OpenShift Constraint

This does **not** work on Red Hat Developer Sandbox.

Why:

- Developer Sandbox is a shared multi-tenant cluster, not your own cluster
- Red Hat documents that running pods are deleted after 12 hours
- Stackable's `secret` and `listener` operators need elevated SCC permissions on OpenShift
- the free sandbox does not give you the level of cluster administration needed for that

For Stackable on OpenShift, you need an OpenShift cluster where you can grant SCC access to service accounts in `stackable-operators`.

## Best Trial Option

The hosted Red Hat option that can work for a full Stackable deployment is the **OpenShift Dedicated trial**:

- trial length: 60 days
- requires your own AWS or GCP account through Customer Cloud Subscription (CCS)
- you are still responsible for the cloud infrastructure cost
- CCS clusters can grant `cluster-admin`, which is what you need for the SCC step

If you only need to explore OpenShift itself, Developer Sandbox is fine. If you want the full Stackable platform, it is the wrong target.

## Prerequisites

- an existing OpenShift cluster
- `oc` logged into that cluster
- a user that can grant SCCs, or a true `cluster-admin`
- `kubectl`
- `helm`
- `curl`
- `python3`

The scripts optionally respect `KUBECONFIG_FILE`, otherwise they use your current `oc login` context.

## Deploy The Base Platform

```bash
chmod +x ./scripts/deploy-stackable-full-openshift.sh
./scripts/deploy-stackable-full-openshift.sh
```

What this does:

- installs Stackable `26.3`
- grants the `privileged` SCC to:
  - `secret-operator-serviceaccount`
  - `listener-operator-serviceaccount`
- installs Cockpit
- waits for operator deployments and daemonsets to become ready

Access Cockpit:

```bash
oc -n stackable-cockpit port-forward service/stackable-cockpit 8080:80
```

## Deploy The Workloads

```bash
chmod +x ./scripts/deploy-stackable-full-workloads-openshift.sh
./scripts/deploy-stackable-full-workloads-openshift.sh
```

This uses the same trimmed workload profile as the AKS path and keeps user-facing services internal so you can expose them later with OpenShift Routes, an ingress controller, or `oc port-forward`.

Useful access commands:

```bash
oc -n default port-forward service/airflow-webserver 8081:8080
oc -n stackable-analytics port-forward service/superset-node 8088:8088
oc -n stackable-streaming port-forward service/nifi-node 8443:8443
oc -n default port-forward service/trino-coordinator 8444:8443
```

## Trial Signup Notes

I cannot create the Red Hat trial account for you from this environment because signup requires your Red Hat identity and, for the viable hosted trial, your own AWS or GCP account.

The practical path is:

1. Create or sign in to your Red Hat account.
2. Start an OpenShift Dedicated trial in OpenShift Cluster Manager.
3. Choose the free-trial, Customer Cloud Subscription option.
4. Use your own AWS or GCP account for the cluster infrastructure.
5. After the cluster is ready, log in with `oc` and run the scripts above.
