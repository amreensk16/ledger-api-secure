# Dodo Payments security assessment — ledger-api-secure

A four-part cloud-native security assessment built entirely on free, local
tooling: a `kind` Kubernetes cluster + GitHub Actions, no cloud account.

| Task | What it covers | Status |
|---|---|---|
| [`task-1/`](task-1/) | Deploy & harden `ledger-api`: securityContext, RBAC, Sealed Secrets, Kyverno admission policies, PSA `restricted` | ✅ complete |
| `task-2/` | Secure CI/CD & software supply chain: SAST/SCA/secrets/image scanning gates, keyless cosign + SLSA provenance, GitOps with ArgoCD | 🚧 in progress |
| `task-3/` | Istio service mesh: mTLS STRICT, identity-based `AuthorizationPolicy`, defense-in-depth with NetworkPolicy | ⏳ not started |
| `task-4/` | Recon (OSINT) + authorized penetration test, delivered as a standalone report | ⏳ not started |

Each task folder has its own README with the approach, design decisions,
setup steps, and a "show it working" evidence section - read those for the
full detail. This top-level README is just the index.

## Shared context across tasks

- Everything runs on the same local `kind` cluster (`ledger-secure`) created
  for Task 1 - Task 2's GitOps and Task 3's mesh both build on top of the
  `payments` namespace and workloads defined in `task-1/k8s/base/`.
- The container image lives at `ghcr.io/amreensk16/ledger-api` - Task 1's
  workflow (`.github/workflows/task-1-build.yml`) builds/signs it with a
  static cosign key pair; Task 2 replaces that with keyless (OIDC/Fulcio)
  signing plus SLSA provenance, as a strictly more rigorous supply-chain
  story for the same image.
- Task 4's passive recon (Part A) targets `dodopayments.tech` using only
  public data sources, per the assignment's rules of engagement. Active
  testing (Part B) targets only the explicitly authorized local vulnerable
  app named in the assignment materials - never any `dodopayments.tech` or
  `dodopayments.com` host.
