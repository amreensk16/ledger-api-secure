#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")"

if kind get clusters | grep -qx ledger-secure; then
  echo "kind cluster 'ledger-secure' already exists, skipping create"
else
  kind create cluster --name ledger-secure --config kind-config.yaml
fi

kubectl cluster-info --context kind-ledger-secure
