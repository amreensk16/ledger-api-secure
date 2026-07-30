#!/usr/bin/env bash
set -euo pipefail

helm repo add sealed-secrets https://bitnami.github.io/sealed-secrets >/dev/null
helm repo update sealed-secrets >/dev/null

helm upgrade --install sealed-secrets sealed-secrets/sealed-secrets \
  --namespace kube-system \
  --set fullnameOverride=sealed-secrets-controller \
  --wait --timeout 5m

kubectl -n kube-system rollout status deploy/sealed-secrets-controller --timeout=120s
