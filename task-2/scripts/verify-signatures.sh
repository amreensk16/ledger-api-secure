#!/usr/bin/env bash
# Verifies both signatures on the current GitOps-managed image reference:
# the keyless (OIDC/Fulcio) signature Task 2 requires, and the static-key
# signature that keeps Task 1's live Kyverno policy satisfied.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/../.."

IMAGE=$(grep -oP '(?<=image: )ghcr\.io/\S+' task-1/k8s/base/deployment-ledger-api.yaml)
echo "Verifying: $IMAGE"
echo

echo "=== Keyless (OIDC/Fulcio) signature, tlog-backed ==="
cosign verify \
  --certificate-identity-regexp "^https://github.com/amreensk16/ledger-api-secure/" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "$IMAGE"

echo
echo "=== Static-key signature (task-1/cosign.pub) ==="
cosign verify --key task-1/cosign.pub --insecure-ignore-tlog=true "$IMAGE"

echo
echo "=== SLSA-style provenance attestation ==="
cosign verify-attestation --type slsaprovenance \
  --certificate-identity-regexp "^https://github.com/amreensk16/ledger-api-secure/" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "$IMAGE" 2>&1 | head -5
