#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx >/dev/null
helm repo update ingress-nginx >/dev/null

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --namespace ingress-nginx --create-namespace \
  -f values/ingress-nginx-values.yaml \
  --wait --timeout 5m

kubectl -n ingress-nginx rollout status deploy/ingress-nginx-controller --timeout=120s
