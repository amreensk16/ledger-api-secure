#!/usr/bin/env bash
# The istio-injection=enabled label itself lives in task-1/k8s/base/namespace.yaml
# (git-managed, applied by ArgoCD) - this script just documents the sequence
# and rolls existing workloads so they pick up the sidecar.
set -euo pipefail

kubectl rollout restart deploy/ledger-api -n payments
kubectl rollout status deploy/ledger-api -n payments --timeout=120s

kubectl rollout restart deploy/reporting -n payments
kubectl rollout status deploy/reporting -n payments --timeout=120s

kubectl get pods -n payments -o wide
