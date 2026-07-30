#!/usr/bin/env bash
# Demonstrates ArgoCD drift detection + self-heal: a manual kubectl edit that
# bypasses git is detected as drift and automatically reverted, without any
# human running a sync command.
set -uo pipefail

echo "=== 1. Baseline: ArgoCD reports Synced/Healthy, 3 replicas ==="
kubectl -n argocd get application ledger-api -o wide
kubectl get deploy ledger-api -n payments

echo
echo "=== 2. Manual, out-of-band drift: scale to 5 replicas via kubectl (bypasses git) ==="
kubectl scale deployment ledger-api -n payments --replicas=5
sleep 3
kubectl get deploy ledger-api -n payments

echo
echo "=== 3. ArgoCD detects drift (OutOfSync) ==="
for i in 1 2 3 4 5 6; do
  SYNC=$(kubectl -n argocd get application ledger-api -o jsonpath='{.status.sync.status}')
  echo "check $i: sync=$SYNC"
  if [ "$SYNC" = "OutOfSync" ]; then break; fi
  sleep 5
done
kubectl -n argocd get application ledger-api -o wide

echo
echo "=== 4. Self-heal: ArgoCD reverts to the git-declared state (3 replicas) without manual sync ==="
for i in 1 2 3 4 5 6 7 8 9 10; do
  REPLICAS=$(kubectl get deploy ledger-api -n payments -o jsonpath='{.spec.replicas}')
  SYNC=$(kubectl -n argocd get application ledger-api -o jsonpath='{.status.sync.status}')
  echo "check $i: replicas=$REPLICAS sync=$SYNC"
  if [ "$REPLICAS" = "3" ] && [ "$SYNC" = "Synced" ]; then break; fi
  sleep 5
done
kubectl -n argocd get application ledger-api -o wide
kubectl get deploy ledger-api -n payments
