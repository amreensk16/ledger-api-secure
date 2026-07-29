# Architecture

```mermaid
flowchart TB
    subgraph Host["Windows host"]
        Browser["curl / browser<br/>Host: ledger.local"]
    end

    subgraph Kind["kind cluster: ledger-secure"]
        subgraph IngressNS["ingress-nginx namespace"]
            Ingress["ingress-nginx controller<br/>(hostPort 80/443)"]
        end

        subgraph KyvernoNS["kyverno namespace"]
            Kyverno["Kyverno admission controller<br/>require-non-root-user<br/>disallow-latest-tag<br/>require-signed-images"]
        end

        subgraph KubeSystem["kube-system namespace"]
            SS["sealed-secrets-controller"]
        end

        subgraph Payments["payments namespace (PSA: restricted)"]
            IngressObj["Ingress: ledger-api<br/>host ledger.local"]
            Svc["Service: ledger-api :8080"]
            LA1["Pod: ledger-api (x3)<br/>SA: ledger-api (no RBAC, no token)"]
            Rep["Pod: reporting (curl, sleep)<br/>SA: reporting (read-only pods/services)"]
            CM["ConfigMap: ledger-api-config"]
            SealedSecret["SealedSecret: ledger-api-secrets<br/>(ciphertext, safe to commit)"]
            Secret["Secret: ledger-api-secrets<br/>(decrypted in-cluster only)"]
            NetPol["NetworkPolicies:<br/>default-deny-all + per-workload allow"]
        end
    end

    GHCR["ghcr.io/amreensk16/ledger-api<br/>cosign-signed, public"]

    Browser -->|HTTP, Host header| Ingress
    Ingress -->|allowed by NetworkPolicy| Svc
    Svc --> LA1
    LA1 -. reads .-> CM
    LA1 -. reads .-> Secret
    SS -->|decrypts| SealedSecret
    SS -.creates.-> Secret
    Kyverno -.admission webhook, validates every Pod/Deployment.-> Payments
    Kyverno -.verifies signature against cosign.pub.-> GHCR
    LA1 -. imagePullPolicy: IfNotPresent .-> GHCR
```

## Request path

1. A client sends `Host: ledger.local` to the kind node's mapped hostPort 80/443 (`bootstrap/kind-config.yaml` maps these on the control-plane node; `ingress-nginx` is scheduled there via the `ingress-ready=true` node label).
2. `ingress-nginx` routes to the `ledger-api` Service on port 8080, only allowed in because `networkpolicy-ledger-api.yaml` explicitly permits ingress from the `ingress-nginx` namespace and denies everything else by default (`networkpolicy-default-deny.yaml`).
3. The Service load-balances across 3 `ledger-api` pods, each running as a hardened, non-root, read-only-rootfs container with a dedicated ServiceAccount that has no RBAC and no mounted token at all.
4. App configuration comes from a plain `ConfigMap`; app secrets come from a `Secret` that the Sealed Secrets controller decrypts in-cluster from the committed `SealedSecret` ciphertext - the plaintext secret values never touch git.

## Admission-time guardrails

Every object creation in `payments` passes through two independent layers before it is ever scheduled:

1. **Pod Security Admission**, via namespace labels (`pod-security.kubernetes.io/enforce: restricted`), a built-in Kubernetes feature - no controller to install. Rejects anything missing `runAsNonRoot`, `seccompProfile`, `capabilities.drop: [ALL]`, or `allowPrivilegeEscalation: false`, on Pods **and** on Pod templates inside Deployments/ReplicaSets/etc.
2. **Kyverno ClusterPolicies** (`k8s/policies/`), a validating/mutating admission webhook:
   - `require-non-root-user` - re-checks the same hardening fields (belt-and-suspenders with PSA, and portable to clusters that don't use PSA).
   - `disallow-latest-tag` - rejects any container with a missing tag or an explicit `:latest` tag. Kyverno "autogens" this rule onto Deployments/ReplicaSets/etc automatically, so a bad Deployment is rejected outright, not just its resulting Pods.
   - `require-signed-images` - verifies a cosign signature against `cosign.pub` for any image matching `ghcr.io/amreensk16/ledger-api:*`. Scoped deliberately: we can't sign `curlimages/curl`, a third-party image we don't build.

See `docs/screenshots/02-kyverno-psa-rejection.txt` and `docs/screenshots/04-reject-insecure-baseline.txt` for captured rejections of the original insecure manifest and of variants isolating each guardrail.

## Known environment limitation: cosign signature storage vs GHCR

cosign 3.x defaults to storing signatures via the OCI 1.1 Referrers API. GHCR's registry does not implement the `GET /v2/<name>/referrers/<digest>` endpoint (confirmed directly against the API: it returns `MANIFEST_UNKNOWN`), so tools that only speak that API - including Kyverno's built-in verifier, even with `cosignOCI11: true` - cannot find a signature stored that way, even though `cosign verify` itself succeeds (it additionally implements a client-side fallback-tag discovery mechanism that Kyverno's verifier does not replicate).

The fix used here: sign with cosign **v2.4.1**, which defaults to the older, universally-supported `sha256-<digest>.sig` tag convention. Kyverno finds that tag with its default settings (`cosignOCI11: false`). This is documented in `.github/workflows/build.yml` and pinned there for the same reason.

## Why NetworkPolicy can't fully enforce the `/fetch` SSRF allowlist

`NetworkPolicy` filters by IP/CIDR and namespace/pod selectors, not by hostname - so it cannot itself restrict egress to `example.com`/`httpbin.org` by name. `networkpolicy-ledger-api.yaml` provides the layer NetworkPolicy *can* provide (deny-by-default, explicit allow for DNS and standard web ports, explicit exclusion of RFC1918/link-local ranges so ledger-api can't reach other cluster-internal services or the node/metadata endpoints over the "internet" egress rule). The hostname-level allowlist itself is enforced in `app/app.py` (`_is_allowed_target`), which also re-resolves DNS and rejects private/loopback/link-local results - closing the DNS-rebinding gap that a hostname-string allowlist alone would leave open.
