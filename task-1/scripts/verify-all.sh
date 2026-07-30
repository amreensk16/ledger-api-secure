#!/usr/bin/env bash
# Full smoke-test sequence: assumes bootstrap/*.sh have already been run and
# k8s/base + k8s/policies + k8s/rbac-personas are already applied.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

echo "=== Pods ==="
kubectl get pods -n payments -o wide

echo
echo "=== Ingress reachability ==="
curl -s -H "Host: ledger.local" http://127.0.0.1/health; echo

echo
echo "=== Sealed Secret decrypted, no plaintext in git ==="
kubectl get secret ledger-api-secrets -n payments
git log --oneline -- k8s/base/sealedsecret-ledger-api.yaml

echo
echo "=== Admission guardrails reject the original insecure manifest ==="
bash scripts/demo-reject-insecure.sh

echo
echo "=== RBAC boundaries ==="
kubectl auth can-i list pods    --as=system:serviceaccount:payments:reporting -n payments
kubectl auth can-i get secrets  --as=system:serviceaccount:payments:reporting -n payments
kubectl auth can-i get pods     --as=system:serviceaccount:payments:ledger-api -n payments
kubectl auth can-i update deployments --as=jane --as-group=payments:developers -n payments
kubectl auth can-i update deployments --as=sam  --as-group=payments:operators  -n payments
kubectl auth can-i get secrets         --as=alex --as-group=payments:admins    -n payments
