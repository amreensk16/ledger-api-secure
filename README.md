# ledger-api-secure

Taking [`ledger-api`](https://github.com/bhabani-dodo/ledger-api-assignment) from
intentionally-insecure to production-grade on a fully local stack: **kind** +
**Kyverno** + **Sealed Secrets** + **ingress-nginx**, no cloud account.

See `docs/architecture.md` for the architecture diagram and a deeper writeup
of two interesting problems hit along the way (a real cosign/GHCR interop
gap, and why NetworkPolicy can't fully enforce the SSRF allowlist).

## What was wrong with the original

| Issue | File | Fix |
|---|---|---|
| Hardcoded `STRIPE_API_KEY` / `DB_PASSWORD` in plaintext | `deploy/deployment.yaml` | Sealed Secrets - only ciphertext committed |
| `yaml.load(request.data)` with no `SafeLoader` - arbitrary code execution | `app/app.py` `/import` | `yaml.safe_load` |
| `/fetch?url=` - naive SSRF, fetches any attacker-supplied URL | `app/app.py` `/fetch` | Hostname allowlist (ConfigMap-driven) + post-DNS-resolution private/loopback/link-local IP check + no redirects |
| Python 3.6, Flask 0.12.2, Werkzeug 0.14.1, PyYAML 5.1 - all EOL, all CVE-laden | `app/Dockerfile`, `requirements.txt` | Bumped to `python:3.11-slim` (digest-pinned) + current pins |
| No `securityContext`, runs as root | `deploy/deployment.yaml` | Full pod+container hardening (below) |
| Default ServiceAccount, no RBAC boundary | `deploy/*.yaml` | Dedicated SAs, least-privilege Role for the neighbour, zero permissions for ledger-api |
| CI pushes `:latest` | `.github/workflows/build.yml` | SHA-tagged, cosign-signed |

## Hardening applied (Task 1 requirements)

- **Deployments, Services, ConfigMaps, Ingress** for `ledger-api` plus the
  `reporting` neighbour - `k8s/base/`.
- **securityContext**, pod- and container-level, on every container:
  `runAsNonRoot`, fixed non-root UID/GID, `readOnlyRootFilesystem: true`
  (with an `emptyDir` at `/tmp` for what little scratch space Python/Flask
  need), `capabilities.drop: [ALL]`, `allowPrivilegeEscalation: false`,
  `seccompProfile: RuntimeDefault`.
- **Resource requests/limits** and **liveness/readiness probes** on every
  container, including the `reporting` neighbour (an `exec` probe, since it
  has no HTTP endpoint).
- **Dedicated least-privilege ServiceAccounts**: `ledger-api` gets zero
  permissions and no mounted token (it never calls the k8s API - the correct
  least-privilege answer is nothing at all); `reporting` gets a namespace
  Role limited to `get/list/watch` on `pods`/`services`, explicitly excluding
  `secrets`/`configmaps`.
- **Secrets moved out of git**: Sealed Secrets. `scripts/seal-secrets.sh`
  pipes `kubectl create secret ... --dry-run=client -o yaml` straight into
  `kubeseal`; only the resulting `SealedSecret` (ciphertext) is committed at
  `k8s/base/sealedsecret-ledger-api.yaml`.
- **Kyverno guardrails** (`k8s/policies/`): reject root containers, reject
  `:latest`/missing tags, reject unsigned `ledger-api` images (cosign,
  scoped to our own image - see `docs/architecture.md` for why).

### Bonus

- **RBAC personas** (`k8s/rbac-personas/`): namespace-scoped
  developer/operator/admin Roles bound to Groups, demoed via
  `kubectl --as=... --as-group=...` impersonation (no IdP needed).
- **Pod Security Standards (`restricted`)** enforced at the namespace via
  labels on `k8s/base/namespace.yaml` - a second, independent guardrail
  layer alongside Kyverno.
- **Admission-rejection demo**: `scripts/demo-reject-insecure.sh` applies
  the *actual original* vulnerable manifest (`docs/insecure-baseline/`) and
  captures the rejection.
- **NetworkPolicies**: default-deny in `payments`, explicit per-workload
  allow rules.

## Repo layout

```
app/            hardened Flask app + Dockerfile
k8s/base/       namespace, SAs, RBAC, ConfigMap, SealedSecret, Deployments,
                Service, Ingress, NetworkPolicies (kustomize)
k8s/rbac-personas/   developer/operator/admin Roles + RoleBindings
k8s/policies/   Kyverno ClusterPolicies (kustomize)
bootstrap/      kind cluster config + controller install scripts
scripts/        seal-secrets.sh, demo-reject-insecure.sh
docs/           architecture.md, screenshots/, insecure-baseline/ fixtures
.github/workflows/build.yml   CI: build, SHA-tag, push GHCR, cosign sign
```

## Setup (from scratch)

Prereqs: Docker Desktop running, `kind`, `helm`, `kubectl`, `kubeseal`,
`cosign` on PATH.

```bash
# 1. Cluster
bash bootstrap/01-create-cluster.sh

# 2. Controllers
bash bootstrap/02-install-ingress-nginx.sh
bash bootstrap/03-install-kyverno.sh
bash bootstrap/04-install-sealed-secrets.sh

# 3. Namespace (PSA labels) + Kyverno policies
kubectl apply -f k8s/base/namespace.yaml
kubectl apply -k k8s/policies/

# 4. Secret + everything else (note: -k, not -f - there's a kustomization.yaml)
scripts/seal-secrets.sh
kubectl apply -k k8s/base/

# 5. RBAC personas
kubectl apply -f k8s/rbac-personas/
```

The `ledger-api` Deployment references `ghcr.io/amreensk16/ledger-api:d006d80`,
a public, cosign-signed image already pushed - no local build/push required
to reproduce this demo. To build and sign your own: see
`.github/workflows/build.yml` for the CI steps, or replicate them locally
with `docker build`, `docker push`, and `cosign sign --key cosign.key
--tlog-upload=false` (cosign **v2.x** - see `docs/architecture.md` for why).

## Show it working

All captured in `docs/screenshots/`:

| # | What it proves | File |
|---|---|---|
| 1 | Hardened image runs read-only, non-root; RCE payload neutralized; SSRF blocked | `01-local-docker-smoketest.txt` |
| 2 | PSA `restricted` and Kyverno `disallow-latest-tag` independently reject non-compliant pods | `02-kyverno-psa-rejection.txt` |
| 3 | RBAC boundaries: reporting SA read-only, ledger-api SA zero-permission, developer/operator/admin personas | `03-rbac-persona-demo.txt` |
| 4 | **The original vulnerable `deployment.yaml`, applied verbatim, is rejected** (PSA + Kyverno); a PSA-compliant-but-`:latest` variant is rejected by Kyverno alone | `04-reject-insecure-baseline.txt` |
| 5 | Kyverno admits the cosign-signed `ledger-api` image and rejects a genuinely unsigned one under the same image pattern | `05-signed-image-policy.txt` |
| 6 | Full stack running: pods healthy, Sealed Secret decrypted in-cluster, `ledger-api` reachable end-to-end through `ingress-nginx` | `06-full-stack-running.txt` |

Reproduce any of these directly:

```bash
scripts/demo-reject-insecure.sh
curl -H "Host: ledger.local" http://127.0.0.1/health
kubectl auth can-i get secrets --as=system:serviceaccount:payments:reporting -n payments   # no
kubectl auth can-i update deployments --as=sam --as-group=payments:operators -n payments   # yes
```

## Design decisions worth calling out

- **App code was patched, not just contained.** The `yaml.load` RCE and the
  SSRF endpoint are real, exploitable bugs; leaving them in and relying
  purely on `readOnlyRootFilesystem`/non-root/NetworkPolicy to "contain" them
  would blunt but not eliminate the risk. Both fixes are small, targeted, and
  documented inline in `app/app.py`.
- **`require-signed-images` is scoped to `ghcr.io/amreensk16/ledger-api:*`
  only.** We can't sign `curlimages/curl`, a third-party image we don't
  build - a real, explainable scope limit, not an oversight.
- **NetworkPolicy egress for `ledger-api` allows broad outbound HTTP(S)**
  (minus RFC1918/link-local ranges), because NetworkPolicy can't filter by
  hostname. The actual `/fetch` allowlist is enforced in-app. See
  `docs/architecture.md`.
- **cosign v2.4.1, not the latest v3.x, signs the image.** v3's default
  signature storage (OCI 1.1 Referrers) isn't fully supported by GHCR, and
  Kyverno's verifier can't discover it there either. v2's legacy tag-based
  storage works with both. Full writeup in `docs/architecture.md`.
