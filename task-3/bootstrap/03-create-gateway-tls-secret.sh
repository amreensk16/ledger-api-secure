#!/usr/bin/env bash
# Generates a local, self-signed TLS cert/key for the ledger.local gateway
# and stores it directly as a Kubernetes Secret - never written to a
# git-tracked file, same discipline as Task 1's seal-secrets.sh.
set -euo pipefail

WORKDIR=$(mktemp -d)
trap 'rm -rf "$WORKDIR"' EXIT

openssl req -x509 -newkey rsa:2048 -sha256 -days 365 -nodes \
  -keyout "$WORKDIR/tls.key" -out "$WORKDIR/tls.crt" \
  -subj "//CN=ledger.local" -addext "subjectAltName=DNS:ledger.local"

kubectl create secret tls ledger-local-tls -n istio-system \
  --cert="$WORKDIR/tls.crt" --key="$WORKDIR/tls.key" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "Created/updated Secret ledger-local-tls in istio-system"
