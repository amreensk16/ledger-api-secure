# Design decisions and trade-offs

## Istio CNI plugin mode, not the default in-pod `istio-init`

**Decision:** installed Istio with `components.cni.enabled: true`, moving
iptables traffic-redirection setup into a privileged per-node DaemonSet in
`kube-system` instead of a privileged init container inside every
application pod.

**Why:** the standard `istio-init` container needs `NET_ADMIN`/`NET_RAW`
capabilities - which both the `payments` namespace's PSA `restricted` label
and Kyverno's `require-non-root-user` policy (`capabilities.drop: [ALL]`,
no exceptions) would reject outright. CNI mode was verified, not assumed,
to be sufficient: after injection, `istio-validation` and `istio-proxy` (the
current Istio release uses native Kubernetes sidecar containers -
`initContainers` with `restartPolicy: Always` - not a second regular
container) both run with `allowPrivilegeEscalation: false`,
`capabilities.drop: [ALL]`, `privileged: false`, `runAsNonRoot: true`,
non-root UID 1337, and inherit `seccompProfile: RuntimeDefault` from the
pod-level default. No Kyverno mutate backstop was needed - checked, not
guessed. Evidence: `docs/screenshots/01-sidecar-injection-psa-kyverno-pass.txt`.

## Istio Ingress Gateway supersedes ingress-nginx for ledger-api

**Decision:** once `payments` is STRICT mTLS, ingress-nginx (no sidecar,
plaintext) can't reach `ledger-api` at all. Rather than work around this,
the Istio Ingress Gateway (bonus requirement anyway) became the real,
required north-south entrypoint.

**Alternatives considered and rejected:**
- *Port-level mTLS exception* (`PeerAuthentication.spec.portLevelMtls` set
  to `PERMISSIVE` on ledger-api's port) - would technically let
  ingress-nginx keep working, but directly undercuts the assignment's
  "identity-based, not IP/port-based" requirement. Rejected as
  self-defeating.
- *Inject a sidecar into ingress-nginx itself* - would work (its outbound
  calls get wrapped in mesh mTLS transparently) and avoids needing a new
  local access path. Rejected because it reintroduces exactly the problem
  Task 2 already named and rejected once (`task-2/docs/decisions.md`'s
  Kyverno-scoping fix): imposing mesh/security requirements on a
  third-party Helm chart's pod spec that isn't authored here. It also has a
  real landmine - if the chart ever runs with `hostNetwork: true`, Istio's
  iptables-based interception silently does nothing.

`kubectl port-forward svc/istio-ingressgateway -n istio-system <port>:443`
is used for local demo access - port-forward proxies raw TCP, so it doesn't
interfere with TLS termination happening at the gateway, and it leaves
kind's existing hostPort 80/443 mapping (bound to ingress-nginx since
cluster creation) untouched.

## kindnet genuinely enforces NetworkPolicy - verified, not assumed either way

Common lore says kind's default CNI (kindnet) doesn't implement
`NetworkPolicy` at all. This was checked empirically, in both directions,
before writing a word of documentation claiming it does or doesn't:
`task-3/scripts/verify-networkpolicy-enforcement.sh` showed allow-listed
traffic (from `ingress-nginx`) succeeding while non-allow-listed traffic
(from `reporting` and from an unrelated `default`-namespace pod) genuinely
times out - real, positive enforcement, confirmed again after the mesh was
fully live (`docs/screenshots/05-networkpolicy-still-independent-layer.txt`)
to prove the two layers are both actually active, not one silently
superseding the other. This matters because asserting a control's behavior
without testing it - in either direction - is exactly the failure mode a
reviewer checks first.

## Real second backend for the canary bonus, not a label stub

**Decision:** `ledger-api-canary` is a genuine second Deployment (its own
ReplicaSet, its own Pod, 1 replica) rather than just adding a `version`
label to a subset of the existing Deployment's replicas.

**Why:** a `DestinationRule` with two subsets pointing at the *same*
underlying pods doesn't actually demonstrate a canary split - it would
just be an arbitrary, meaningless partition of identical infrastructure.
Standing up a real second Deployment (reusing the same signed, hardened
image - no new build needed) gives an authentic, independently-verifiable
split. Verified with real Envoy counters, not just "applied and assumed":
after 30 requests through the gateway, the canary pod's own
`http.inbound_0.0.0.0_8080;.rbac.allowed` stat showed 5 (~17%, consistent
with the 10% `VirtualService` weight given normal variance over a small
sample) - see `docs/screenshots/04-authz-allow-gateway-and-canary.txt`.

## Resource-driven, non-security-relevant adjustment: `ledger-api` replicas 3 → 2

This lab's single kind node has ~3.8GiB allocatable memory; adding an
Istio sidecar (plus the native `istio-validation` sidecar container) to
every pod in `payments`, then adding a canary Deployment on top, pushed
memory requests to ~97% and made the canary pod unschedulable. Reduced
`ledger-api` to 2 replicas to create headroom. This is purely a resource
constraint of running the entire multi-task assignment on one local
machine with no cloud account - not a change to any security control, and
reversible by adding more memory to the Docker Desktop VM in an environment
without this constraint.

## PCI/CDE scope tie-in, stated honestly

Istio's mTLS boundary around `payments` is a legitimate, cryptographically
enforced network segmentation control of the kind PCI DSS uses to justify
shrinking cardholder-data-environment (CDE) scope - every in-scope workload
now proves its identity on every connection, not just its IP/namespace.
But the trust root behind that boundary is istiod's own self-signed root
CA, generated locally with no external chain-of-trust or revocation
infrastructure - adequate for this lab, not what a real PCI QSA would
accept as a production mesh's root of trust. Stated plainly in
`task-3/README.md` rather than glossed over: the production-correct
version of this control plugs in an enterprise root/intermediate (e.g. via
`cert-manager`'s `istio-csr`), which is out of scope for this exercise.
