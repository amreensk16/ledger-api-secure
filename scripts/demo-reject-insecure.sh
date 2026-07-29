#!/usr/bin/env bash
# Applies the insecure-baseline fixtures and shows both are rejected by the
# admission guardrails. Exits 0 either way (the whole point is to observe the
# rejection messages), but prints a warning if something unexpectedly gets
# created.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== 1. Original vulnerable Deployment (hardcoded secrets, no securityContext, ledger-api:starter) ==="
kubectl apply -f docs/insecure-baseline/deployment.yaml
echo
echo "=== 2. PSA-compliant securityContext but :latest tag (isolates Kyverno's contribution) ==="
kubectl apply -f docs/insecure-baseline/deployment-latest-tag-variant.yaml
echo

for name in ledger-api ledger-api-latest-tag-variant; do
  if kubectl get deployment "$name" -n payments >/dev/null 2>&1; then
    echo "WARNING: deployment/$name was created - guardrails did not block it as expected!"
  else
    echo "OK: deployment/$name was not created (rejected as expected)"
  fi
done
