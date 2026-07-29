# Insecure baseline fixtures - DO NOT deploy for real

These are demo fixtures used only to prove the admission guardrails work.
They must never be applied to a production cluster.

- `namespace.yaml`, `deployment.yaml` - byte-for-byte copies of the
  **original vulnerable manifests** from the assignment's source repo
  (hardcoded plaintext secrets, no securityContext, mutable image tag).
  Applying `deployment.yaml` to the hardened `payments` namespace is expected
  to be **rejected** by both Pod Security Admission (`restricted`) and
  Kyverno's `require-non-root-user` policy.
- `deployment-latest-tag-variant.yaml` - a variant with a fully compliant
  securityContext but a `:latest` image tag, used to prove Kyverno's
  `disallow-latest-tag` policy catches something PSA does not check at all.

See `scripts/demo-reject-insecure.sh` and `docs/screenshots/04-reject-insecure-baseline.txt`
for the captured rejection output.
