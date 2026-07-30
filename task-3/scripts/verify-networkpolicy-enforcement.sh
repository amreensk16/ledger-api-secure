#!/usr/bin/env bash
# Verifies whether the existing NetworkPolicies (task-1/k8s/base/) are
# actually enforced by this cluster's CNI, or merely syntactically valid.
# kind's default CNI (kindnet) does not implement the NetworkPolicy API at
# all - this must be checked empirically before any doc claims the
# NetworkPolicy layer "catches" anything.
set -uo pipefail

echo "== CNI in use =="
kubectl get pods -n kube-system -o wide | grep -i "kindnet\|calico\|cilium\|weave" || echo "(no match - inspect kube-system manually)"

echo
echo "== Test 1: reporting -> ledger-api =="
echo "reporting's NetworkPolicy has no egress rule permitting this, and"
echo "ledger-api's NetworkPolicy only allows ingress from ingress-nginx - if"
echo "this succeeds, NetworkPolicy is NOT being enforced."
kubectl exec -n payments deploy/reporting -- curl -sS -o /dev/null -w 'HTTP %{http_code} (connect: %{exitcode})\n' --max-time 3 \
  http://ledger-api.payments.svc.cluster.local:8080/health || echo "curl failed/timed out (would indicate enforcement)"

echo
echo "== Test 2: unrelated pod in default namespace -> ledger-api =="
echo "default-deny-all + no matching allow rule should block this - if it"
echo "succeeds, NetworkPolicy is NOT being enforced."
kubectl run netpol-probe --rm -i --image=curlimages/curl:8.10.1 --restart=Never -n default --command -- \
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 3 http://ledger-api.payments.svc.cluster.local:8080/health \
  || echo "curl failed/timed out (would indicate enforcement)"
