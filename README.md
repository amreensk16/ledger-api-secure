# ledger-api-secure

A four-part cloud-native security assessment built entirely on free, local
tooling: a `kind` Kubernetes cluster + GitHub Actions, no cloud account.

| Task | What it covers | Status |
|---|---|---|
| [`task-1/`](task-1/) | Deploy & harden `ledger-api`: securityContext, RBAC, Sealed Secrets, Kyverno admission policies, PSA `restricted` | ✅ complete |
| [`task-2/`](task-2/) | Secure CI/CD & software supply chain: SAST/SCA/secrets/image scanning gates, keyless cosign + SLSA provenance, GitOps with ArgoCD | ✅ complete |
| [`task-3/`](task-3/) | Istio service mesh: mTLS STRICT, identity-based `AuthorizationPolicy`, defense-in-depth with NetworkPolicy | ✅ complete |
| [`task-4/`](task-4/) | Recon (OSINT) + authorized penetration test, delivered as a standalone report | ✅ complete |

Each task folder has its own README with the approach, design decisions,
setup steps, and a "show it working" evidence section - read those for the
full detail. This top-level README is just the index.

## Shared context across tasks

- Everything runs on the same local `kind` cluster (`ledger-secure`) created
  for Task 1 - Task 2's GitOps and Task 3's mesh both build on top of the
  `payments` namespace and workloads defined in `task-1/k8s/base/`.
- The container image lives at `ghcr.io/amreensk16/ledger-api`. Task 1's
  workflow (`.github/workflows/task-1-build.yml`, now manual-dispatch only)
  established static cosign key-pair signing, which the live Kyverno
  `require-signed-images` policy trusts. Task 2's pipeline
  (`.github/workflows/task-2-pipeline.yml`) is the real, automatic delivery
  path: it scans, builds, signs the image **twice** (keyless for a modern
  supply-chain story + the same static key so Task 1's policy keeps working),
  attaches SLSA-style provenance, and hands off to ArgoCD via a GitOps
  image-tag bump - see `task-2/README.md` for the full reasoning.
- Task 1's `require-non-root-user`/`disallow-latest-tag` Kyverno policies
  are scoped to the `payments` namespace (not cluster-wide) precisely so
  Task 2's ArgoCD install - and Task 3's Istio install - aren't blocked by
  guardrails meant for ledger-api's own workloads.
- Task 3 brought both `ledger-api` and `reporting` into an Istio mesh with
  STRICT mTLS - this genuinely broke ingress-nginx's plaintext path to
  `ledger-api` (a non-mesh caller has no identity to present), so the Istio
  Ingress Gateway now replaces it as the access path. `task-1/scripts/verify-all.sh`'s
  ingress-nginx health check is expected to fail from here on - see
  `task-3/README.md`'s "Known, intentional regression" section.
- Task 4's passive recon (Part A) targeted `dodopayments.tech` using only
  public data sources, per the assignment's rules of engagement. Active
  testing (Part B) targeted only the explicitly authorized local vulnerable
  app (the same `bhabani-dodo/ledger-api-assignment` source Task 1 hardened,
  run unmodified and locally, never any `dodopayments.tech`/`.com` host) -
  see `task-4/report.md` for the full findings, including a confirmed
  unauthenticated-RCE-to-payment-credential-theft chain and a retest proving
  which findings Task 1's hardening actually closed vs. which remain open
  application-layer gaps.
