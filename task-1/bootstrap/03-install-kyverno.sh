#!/usr/bin/env bash
set -euo pipefail

helm repo add kyverno https://kyverno.github.io/kyverno/ >/dev/null
helm repo update kyverno >/dev/null

helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --wait --timeout 5m

kubectl -n kyverno rollout status deploy/kyverno-admission-controller --timeout=120s
