#!/usr/bin/env bash
# The three-stage zero-trust proof from task-3/README.md, runnable against
# the already-live mesh in this cluster.
set -uo pipefail

echo "=== Stage 1: STRICT mTLS - a plaintext request is refused before it reaches the app ==="
echo "(reporting and ledger-api are already both meshed in this live cluster - this reproduces"
echo " what a non-mesh caller would experience, using an ephemeral non-mesh probe pod)"
kubectl delete pod zt-plaintext-probe -n payments --ignore-not-found=true --wait=true >/dev/null 2>&1
kubectl run zt-plaintext-probe --image=curlimages/curl:8.10.1 --restart=Never -n payments \
  --annotations="sidecar.istio.io/inject=false" \
  --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"runAsGroup":10001,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"zt-plaintext-probe","image":"curlimages/curl:8.10.1","command":["sh","-c","curl -sS -o /dev/null -w \"HTTP %{http_code}\\n\" --max-time 5 http://ledger-api.payments.svc.cluster.local:8080/health; sleep 5"],"securityContext":{"runAsNonRoot":true,"runAsUser":10001,"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}'
for i in 1 2 3 4 5 6 7 8; do
  PHASE=$(kubectl get pod zt-plaintext-probe -n payments -o jsonpath='{.status.phase}' 2>/dev/null)
  [ "$PHASE" = "Succeeded" ] || [ "$PHASE" = "Failed" ] && break
  sleep 2
done
kubectl logs zt-plaintext-probe -n payments 2>&1
kubectl delete pod zt-plaintext-probe -n payments --ignore-not-found=true >/dev/null 2>&1

echo
echo "=== Stage 2: authenticated (valid mTLS) but unauthorized - Envoy RBAC denies with 403 ==="
kubectl exec -n payments deploy/reporting -c client -- curl -sS -o /dev/null -w 'HTTP %{http_code}\n' --max-time 5 \
  http://ledger-api.payments.svc.cluster.local:8080/health

echo
echo "=== Stage 3: authorized caller (Istio ingress gateway's SPIFFE identity) succeeds ==="
pkill -f "port-forward.*istio-ingressgateway" 2>/dev/null
kubectl port-forward svc/istio-ingressgateway -n istio-system 18443:443 >/dev/null 2>&1 &
PF_PID=$!
sleep 4
curl -sk --resolve ledger.local:18443:127.0.0.1 https://ledger.local:18443/health -w '\nHTTP %{http_code}\n'
kill "$PF_PID" 2>/dev/null
