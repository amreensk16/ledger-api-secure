#!/usr/bin/env bash
# Generates k8s/base/sealedsecret-ledger-api.yaml. Plaintext secret material
# is piped directly from kubectl into kubeseal and never touches disk.
#
# Override with real values via env vars if you have them:
#   STRIPE_API_KEY=sk_live_xxx DB_PASSWORD=xxx scripts/seal-secrets.sh
# Defaults below are obviously-fake demo values for portfolio/assignment use.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

STRIPE_API_KEY="${STRIPE_API_KEY:-sk_test_demo_0000000000000000000000}"
DB_PASSWORD="${DB_PASSWORD:-demo-not-a-real-password}"

kubectl create secret generic ledger-api-secrets -n payments \
  --from-literal=STRIPE_API_KEY="$STRIPE_API_KEY" \
  --from-literal=DB_PASSWORD="$DB_PASSWORD" \
  --dry-run=client -o yaml | \
kubeseal \
  --controller-name=sealed-secrets-controller \
  --controller-namespace=kube-system \
  --format=yaml > k8s/base/sealedsecret-ledger-api.yaml

echo "Wrote k8s/base/sealedsecret-ledger-api.yaml (ciphertext only, safe to commit)"
