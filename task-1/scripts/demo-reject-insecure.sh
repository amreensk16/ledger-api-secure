#!/usr/bin/env bash
# Applies the insecure-baseline fixtures and shows both are rejected by the
# admission guardrails. Exits 0 either way (the whole point is to observe the
# rejection messages).
#
# Note: docs/insecure-baseline/deployment.yaml is named "ledger-api" - the
# same name as the real, legitimately-deployed workload. Once that real
# deployment exists (it does, from here on: Task 1's own apply, or Task 2's
# ArgoCD sync), applying this fixture is a PATCH attempt against it, not a
# fresh create - so "does deployment/ledger-api exist" is always true and
# useless as a check. What actually matters is whether the malicious patch
# took effect, checked below via the live pod spec's securityContext/image
# rather than mere existence.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== 1. Original vulnerable Deployment (hardcoded secrets, no securityContext, ledger-api:starter) ==="
kubectl apply -f docs/insecure-baseline/deployment.yaml
echo
echo "=== 2. PSA-compliant securityContext but :latest tag (isolates Kyverno's contribution) ==="
kubectl apply -f docs/insecure-baseline/deployment-latest-tag-variant.yaml
echo

RUN_AS_NON_ROOT=$(kubectl get deployment ledger-api -n payments -o jsonpath='{.spec.template.spec.containers[0].securityContext.runAsNonRoot}' 2>/dev/null || true)
if [ "$RUN_AS_NON_ROOT" = "true" ]; then
  echo "OK: deployment/ledger-api still has its hardened securityContext (malicious patch rejected as expected)"
else
  echo "WARNING: deployment/ledger-api's securityContext looks changed - guardrails did not block the patch as expected!"
fi

if kubectl get deployment ledger-api-latest-tag-variant -n payments >/dev/null 2>&1; then
  echo "WARNING: deployment/ledger-api-latest-tag-variant was created - guardrails did not block it as expected!"
else
  echo "OK: deployment/ledger-api-latest-tag-variant was not created (rejected as expected)"
fi
