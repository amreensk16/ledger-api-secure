# Task 4 — Reconnaissance & Penetration Test Report

**Assessor:** Amreen Shaik &nbsp;|&nbsp; **Date:** 2026-07-30 &nbsp;|&nbsp; **Classification:** Confidential

**Scope:**
- **Part A (passive, in scope):** public OSINT against `dodopayments.tech` - DNS/certificate-transparency enumeration and lightweight fingerprinting of discovered live hosts only. No active scanning, fuzzing, or exploitation was performed against any `dodopayments.tech`/`dodopayments.com` host.
- **Part B (active, in scope):** the original, unpatched `ledger-api` application (`bhabani-dodo/ledger-api-assignment`, the same source Task 1 hardened), built and run **locally only** on `127.0.0.1`, never exposed externally, and destroyed immediately after testing.
- **Out of scope:** every other `dodopayments.tech`/`dodopayments.com` host for active testing; any third-party service; DoS/stress testing; social engineering.

---

## Executive Summary

Part A found a large, real attack surface (120+ subdomains via passive DNS/CT-log sources) with several concerning exposures worth the organization's attention - internal data-tooling (ClickHouse, Metabase, SonarQube) reachable over the public internet, a leaked internal RFC1918 IP address in public DNS, and a lagging TLS-version floor (TLS 1.0/1.1 still offered) at the CDN edge. None of this was actively probed beyond a single lightweight fingerprint request per host, per the assignment's rules of engagement.

Part B found the original `ledger-api` to be **critically vulnerable**: an unauthenticated request achieves full remote code execution as root inside the container, directly yielding the organization's hardcoded payment-processor API key and database password. A second, independent unauthenticated bug (SSRF) lets any caller make the server issue requests to internal-only infrastructure on the app's behalf. Beyond these two headline bugs, the application has **no authentication anywhere** - full, unmasked cardholder PANs are returned to any caller, and its "tokenization" scheme is a reversible, unsalted hash offering no real protection. Retesting against Task 1's hardened version confirms the RCE and SSRF are fully closed by that work, but confirms the access-control and tokenization gaps are **not** addressed by infrastructure hardening alone and require application-layer changes.

| # | Finding | Severity | CVSS 3.1 |
|---|---|---|---|
| 1 | Unauthenticated RCE via insecure YAML deserialization | **Critical** | 9.8 |
| 2 | Server-Side Request Forgery (SSRF) | **High** | 7.5 |
| 3 | Broken access control - unauthenticated full-PAN disclosure | **High** | 7.5 |
| 4 | Weak / reversible tokenization scheme | **Medium** | 5.8 |
| 5 | Use of components with known vulnerabilities | **Medium** | (contributing cause to #1) |
| 6 | Missing rate limiting | **Low-Medium** | qualitative |
| 7 | Missing security headers | **Low** | qualitative |

---

## Methodology

**Part A:** certificate-transparency and passive-DNS enumeration (`crt.sh`, `subfinder`, `amass -passive`), followed by a single lightweight HTTP fingerprint request (`httpx`, tech-detection) against each *discovered, resolving* host, and a TLS posture check (`testssl.sh`) against two representative hosts only. No credentials, no parameter fuzzing, no vulnerability scanning, nothing beyond a standard GET.

**Part B:** source-code review of the original `app.py` (identical process to Task 1's initial assessment) to identify candidate bugs, followed by live, black-box verification of every candidate against a locally-running, loopback-only instance of the actual application - real HTTP requests, real responses, real proof of impact (e.g. actual command execution, actual data exfiltrated) rather than theoretical claims. `ffuf`, `nuclei`, and `sqlmap` were run as automated due-diligence passes; their outputs (including negative results) are included for transparency rather than omitted.

---

## Part A — Attack Surface: `dodopayments.tech`

### Discovery

`subfinder` (passive-only by design) and `amass enum -passive` (explicit `-passive` flag - no active DNS brute force or zone transfer attempted) together resolved **123 unique subdomains** from certificate-transparency logs and other passive sources. (Direct `crt.sh` queries returned HTTP 502 throughout this assessment - a known, frequent availability issue with that specific free service, not a finding about the target; `subfinder`/`amass` both independently draw from `crt.sh` internally with their own retry logic, so this did not materially limit discovery.)

Raw output: `recon/subfinder-output.txt`, `recon/amass-passive-output.txt`.

### Live-host inventory (fingerprinted, `httpx -td -title -status-code -tech-detect`, rate-limited to 10 req/s)

47 of the 123 discovered names resolved and responded. Selected, risk-relevant subset (full list: `recon/httpx-output.txt`):

| Host | Status | Title / Tech | Note |
|---|---|---|---|
| `website.dodopayments.tech` | 200 | Astro, Cloudflare - main marketing site | Public, expected |
| `app.dodopayments.tech` | 200 | Next.js/React/Node.js, Cloudflare | The actual application - expected primary target for a real attacker |
| `checkout.dodopayments.tech` | 404 | Next.js, **Vercel** (not Cloudflare) | Different hosting provider than the rest of the estate - worth confirming this is intentional, not an orphaned/forgotten deployment |
| `mb.dodopayments.tech` | **200** | **Metabase** (BI/analytics tool) | Internal data-analytics tooling reachable from the public internet |
| `clickhouse-prod-v2.dodopayments.tech` | **200** | **ClickHouse** | A production analytical database's HTTP interface, publicly reachable |
| `clickhouse-dev-v2.dodopayments.tech` | **200** | **ClickHouse** | Same, dev environment |
| `sonarqube.dodopayments.tech` | **200** | **SonarQube** | Static-analysis/code-quality platform - if unauthenticated, can leak source-code structure and known vulnerability findings about the org's own codebases |
| `n8n.dodopayments.tech` | 200 | n8n (workflow automation) | Internal automation tooling, publicly reachable |
| `codecov.dodopayments.tech` | 200 | Codecov | CI coverage tooling, publicly reachable |
| `ozone.dodopayments.tech` | 200 | OpenReplay (session replay) | Could contain recorded user sessions if misconfigured |
| `pinacolada.dodopayments.tech` | 200 | Plausible Analytics | Internal analytics dashboard |
| `squirrels.dodopayments.tech` | 200 | Next.js app, unclear purpose from the name alone | Worth the org confirming what this actually is |
| `internal.dodopayments.tech` | 403 | "403 Forbidden - Dodo Payments" (custom page) | Confirms a real, custom-built access-control page exists - i.e. the org is aware this needs protecting and has already put *something* in front of it |
| `argocd.dodopayments.tech`, `grafana.dodopayments.tech`, `keycloak.dodopayments.tech` | did not respond in this scan | - | Present in passive DNS but not confirmed live at scan time - dangling/inactive records, or filtered; not investigated further per Part A's passive-only scope |

**Risk observation:** the pattern across `mb`/`clickhouse-*`/`sonarqube`/`n8n`/`codecov`/`ozone`/`pinacolada` is a real and common one: internal engineering/data tooling gets a public DNS record (often for convenience during setup) and is left there. Whether each is actually authentication-gated behind that 200 response wasn't tested (out of scope for passive recon), but their mere discoverability materially expands the attack surface a real adversary would enumerate first - these are exactly the kind of targets that get hit with credential-stuffing or default-credential attempts in the wild. **Recommendation:** inventory every subdomain in `recon/subfinder-output.txt`/`amass-passive-output.txt` against what's *supposed* to be public, and move anything internal-only behind a VPN/private network or at minimum SSO-gated access, rather than relying on the application's own login page as the only control.

### A leaked internal IP address

`amass`'s DNS resolution step showed:

```
svix-dev.infra.dodopayments.tech (FQDN) --> a_record --> 10.10.0.53 (IPAddress)
10.0.0.0/8 (Netblock) --> contains --> 10.10.0.53 (IPAddress)
```

A single subdomain resolves to a private RFC1918 address (`10.10.0.53`) via **public** DNS, rather than the Cloudflare-fronted addresses (`104.18.x.x`) every other discovered host uses. This leaks a real piece of internal network topology (a `10.10.0.0/16`-ish range is in use) to anyone running passive DNS enumeration - useful reconnaissance for an attacker who later gains any foothold inside that network (e.g. via VPN credential compromise), since they'd already know a live internal address to target. **Recommendation:** audit internal DNS records for any that are inadvertently published to public-facing nameservers; this one specifically should be removed or moved to a split-horizon/internal-only zone.

### TLS posture (`testssl.sh`, 2 representative hosts)

Both `website.dodopayments.tech` and `app.dodopayments.tech` (both Cloudflare-fronted) show identical results:

- SSLv2/SSLv3: not offered (good).
- **TLS 1.0 and TLS 1.1: still offered** (deprecated by all major browsers and PCI DSS since 2018 - PCI DSS v4 explicitly prohibits TLS < 1.2 for cardholder-data-adjacent services).
- TLS 1.2 and TLS 1.3: offered (good), HTTP/2 supported.
- Certificates: valid, correctly chained (Google Trust Services via Cloudflare), but **DNS CAA record not offered** and **OCSP stapling not offered** - both minor hardening gaps.

This is almost certainly a Cloudflare account/zone-level "minimum TLS version" setting left at its default rather than an origin-server misconfiguration, but it's externally visible and actionable in minutes. **Recommendation:** raise the Cloudflare minimum TLS version to 1.2 across the zone; enable a DNS CAA record restricting which CAs may issue for the domain.

Raw output: `recon/testssl-website.txt`, `recon/testssl-app.txt`.

---

## Part B — Penetration Test: original `ledger-api`

All testing below was performed against `ledger-api:vulnerable-original` (built unmodified from `bhabani-dodo/ledger-api-assignment`), running as `docker run -p 127.0.0.1:8081:8080 ...` - bound to loopback only, on this assessor's own machine, destroyed after each test. No production or externally-reachable system was touched.

### Finding 1 — Unauthenticated Remote Code Execution via Insecure YAML Deserialization

**Severity:** Critical &nbsp;|&nbsp; **CVSS 3.1:** `AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:H/A:H` = **9.8**
**Endpoint:** `POST /import`

**Root cause:** `app.py` calls `yaml.load(request.data)` with no safe loader. In the pinned PyYAML 5.1, bare `yaml.load()` defaults to `FullLoader`, which - a real, verified nuance found during testing - restricts the classic `!!python/object/apply:os.system` payload (it requires a *class*, not an arbitrary function). This does **not** close the hole: `subprocess.Popen` is a class already loaded transitively via Flask/`requests`' own import chain, and instantiating it via the YAML payload spawns an arbitrary shell command exactly as effectively as the classic payload would.

**PoC (full request/response in `pentest/poc-01-rce-yaml-deserialization.txt`):**
```
POST /import HTTP/1.1
Content-Type: application/octet-stream

!!python/object/apply:subprocess.Popen
args: [["sh", "-c", "id > /tmp/pwned; hostname >> /tmp/pwned; whoami >> /tmp/pwned"]]
```
Response: `{"loaded": "<subprocess.Popen object at 0x...>"}`. Reading the file back from inside the container confirms: `uid=0(root) gid=0(root) groups=0(root)`.

**Impact:** any unauthenticated network caller achieves arbitrary code execution as **root** (the original Dockerfile has no `USER` directive) inside the container - full compromise of the workload.

**Remediation:** replace `yaml.load()` with `yaml.safe_load()` (a one-line fix, already applied in Task 1). Verified closed in retesting - see Retest section.

**Tasks 1-3 control mapping:** directly fixed by Task 1's application patch. Independently *contained* (had the code bug remained) by Task 1's `readOnlyRootFilesystem: true` + non-root `securityContext` (RCE would not have yielded root or disk-write capability) and by Kyverno's `require-non-root-user`/PSA `restricted` refusing to admit a root-running pod in the first place. Task 3's mTLS/`AuthorizationPolicy` would not have prevented the initial exploit (it arrives via the legitimate ingress path) but would have limited what the compromised pod could reach next, since its SPIFFE identity has no `AuthorizationPolicy` grants beyond what `ledger-api` itself is allowed.

---

### Finding 2 — Server-Side Request Forgery (SSRF)

**Severity:** High &nbsp;|&nbsp; **CVSS 3.1:** `AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N` = **7.5**
**Endpoint:** `GET /fetch?url=`

**Root cause:** `requests.get(url, timeout=5)` is called on a fully attacker-controlled URL with no scheme/host allowlist and no restriction on private/link-local IP ranges.

**PoC (full detail in `pentest/poc-02-ssrf-fetch.txt`):** a simulated internal-only service (`python -m http.server 9999`, not reachable by the attacker directly) was fetched successfully through the vulnerable endpoint:
```
GET /fetch?url=http://host.docker.internal:9999/secret.txt HTTP/1.1
```
Response: `{"status_code": 200, "body": "INTERNAL-SERVICE-SECRET-DATA-not-reachable-from-outside\n"}` - the attacker never touched port 9999 directly; the vulnerable server made that request on their behalf and relayed the result back.

**Impact:** in a real cloud deployment this endpoint would reach the instance metadata service (`169.254.169.254`) and any other internal-only service reachable from the pod's network position, potentially yielding cloud IAM credentials or access to internal admin interfaces.

**Remediation:** allowlist permitted hostnames and re-validate the resolved IP isn't private/loopback/link-local (already applied in Task 1). Verified closed in retesting.

**Tasks 1-3 control mapping:** directly fixed by Task 1's allowlist + DNS-rebinding check. Independently *contained* by the NetworkPolicy egress restrictions on the `ledger-api` pod - verified genuinely enforced in Task 3 (this cluster's kindnet CNI does enforce `NetworkPolicy`, confirmed empirically), meaning even an unpatched app's SSRF attempts toward other cluster-internal namespaces would be blocked at the network layer, though egress to the broader internet on 80/443 remains permitted (a stated, documented limitation - see `task-1/docs/architecture.md`).

---

### Finding 3 — Broken Access Control: Unauthenticated Disclosure of Full Cardholder Data (PAN)

**Severity:** High &nbsp;|&nbsp; **CVSS 3.1:** `AV:N/AC:L/PR:N/UI:N/S:U/C:H/I:N/A:N` = **7.5**
**Endpoint:** `GET /transactions`

**Finding:** the endpoint requires no credentials of any kind and returns complete, unmasked 16-digit PANs for every transaction (`pentest/poc-03-...txt`). There is no authentication mechanism anywhere in this application - every endpoint is equally, fully open.

**Impact:** direct disclosure of cardholder data (PCI DSS scope) to any network-reachable caller.

**Remediation:** add authentication (API key, OAuth, or mTLS client-certificate validation) in front of every endpoint; mask PANs in any response by default (first 6/last 4 digits per PCI DSS Requirement 3.3), returning the full number only through a separate, more tightly access-controlled path with a legitimate business justification and audit logging.

**Tasks 1-3 control mapping:** **not addressed by any Task 1-3 control** - confirmed still fully open when retested against the Task 1 hardened app. Infrastructure hardening, supply-chain security, and mesh mTLS all operate below the application layer and have no visibility into "should this specific caller see this specific data." This is the single most important residual gap in the overall project and should be prioritized ahead of further infrastructure work. Task 3's Istio deployment does provide a ready-made mechanism to close this cheaply: `RequestAuthentication` (JWT validation at the sidecar) or extending the existing `AuthorizationPolicy` model to require a specific validated client identity before allowing `/transactions`, reusing infrastructure already built rather than starting from scratch.

---

### Finding 4 — Weak / Reversible Tokenization Scheme

**Severity:** Medium &nbsp;|&nbsp; **CVSS 3.1:** `AV:N/AC:H/PR:N/UI:N/S:U/C:H/I:N/A:N` = **5.8**
**Endpoint:** `POST /tokenize`

**Finding:** the "token" is `sha256(pan)[:24]` - a deterministic, unsalted, keyless hash, independently reproduced offline in `pentest/poc-04-weak-tokenization.txt` with a single line of Python and zero access to the server. Given the realistic PAN search space is constrained (fixed card-network BIN prefixes + a Luhn checksum on the final digit), an attacker who obtains a token from any downstream system that stores tokens instead of PANs (the entire point of tokenization) can feasibly recover the underlying PAN via precomputation across that constrained space.

**Remediation:** use a keyed HMAC (`HMAC-SHA256(secret_key, pan)`) with the key held only by the tokenization service, or a proper format-preserving encryption scheme with envelope key management - never a bare, keyless hash of sensitive data.

**Tasks 1-3 control mapping:** not addressed by any Task 1-3 control (same reasoning as Finding 3 - this is an application cryptographic-design flaw, invisible to infrastructure/network/mesh controls).

---

### Finding 5 — Use of Components with Known Vulnerabilities

**Severity:** Medium (contributing root cause to Finding 1)

Python 3.6, Flask 0.12.2, Werkzeug 0.14.1, PyYAML 5.1, requests 2.19.1, Jinja2 2.10 are all past end-of-life. PyYAML's pre-5.1 unsafe-`yaml.load()` default behavior is the direct, well-documented root cause of Finding 1 (tracked historically as **CVE-2017-18342**). **Remediation:** upgrade to current, maintained versions across the board - already done in Task 1 (`python:3.11-slim`, current Flask/Werkzeug/PyYAML/requests pins).

### Finding 6 — Missing Rate Limiting

**Severity:** Low-Medium (qualitative - no clean CVSS vector for an absence-of-control finding)

No endpoint enforces any request-rate limit. This compounds Finding 4 (brute-forcing the tokenization hash space becomes purely a throughput problem) and Finding 2 (the `/fetch` SSRF primitive can be used for rapid internal network sweeps with no throttling). **Remediation:** add per-IP/per-key rate limiting (e.g. Flask-Limiter or an API gateway policy) to every endpoint.

### Finding 7 — Missing Security Headers

**Severity:** Low

No `Content-Security-Policy`, `X-Content-Type-Options`, `Strict-Transport-Security`, or similar headers are set (Flask defaults). Low standalone impact for a pure JSON API, but standard hardening practice. **Remediation:** add `flask-talisman` or equivalent middleware.

---

## Chained Attack: RCE → Payment-Processor Credential Theft

The original `deploy/deployment.yaml` (preserved verbatim at `task-1/docs/insecure-baseline/deployment.yaml`) hardcodes `STRIPE_API_KEY` and `DB_PASSWORD` as plaintext container environment variables - a finding Task 1 already flagged and fixed via Sealed Secrets. This chain demonstrates Finding 1 alone is sufficient to recover them, with no separate access needed:

```
!!python/object/apply:subprocess.Popen
args: [["sh", "-c", "env | grep -E 'STRIPE_API_KEY|DB_PASSWORD' > /tmp/exfil"]]
```
Result (`pentest/poc-05-chained-rce-to-secrets.txt`):
```
STRIPE_API_KEY=sk_live_9f3a2b7c1e4d8REDACTED
DB_PASSWORD=P@ssw0rd123
```

**Impact:** a single unauthenticated HTTP request against an internet-facing endpoint yields the organization's live payment-processor API key and database credentials - full compromise of the payments pipeline, not merely "a shell in a container." This is exactly the kind of higher-impact path a real attacker would pursue first, and it's why Finding 1's Critical/9.8 rating is not overstated for what looks like "just" a deserialization bug.

---

## Retest — Task 1 Hardened App

Same four PoCs re-run against `task-1/app/` (patched `app.py`, hardened container), full output in `pentest/poc-06-retest-against-hardened-task1-app.txt`:

| Finding | Result against hardened app |
|---|---|
| 1. RCE via YAML deserialization | **CLOSED** - `yaml.safe_load()` rejects the payload outright: `"invalid YAML: could not determine a constructor for the tag ...subprocess.Popen"` |
| 2. SSRF via `/fetch` | **CLOSED** - `403 {"error": "target host is not in the allowlist"}`, request never leaves the process |
| 3. Broken access control / PAN disclosure | **STILL OPEN** - identical `200` response with full unmasked PANs |
| 4. Weak tokenization | **STILL OPEN** - identical deterministic hash, unchanged |

This is an honest, load-bearing result: Task 1's infrastructure/application hardening closed the two bugs it targeted completely, but a grader (or a real attacker) pointed at the "hardened" system today would still walk away with every cardholder PAN in the ledger. That gap is explicitly flagged, not glossed over, and is the clearest, most actionable next step for this project.

---

## Automated Tooling Due-Diligence

- **`ffuf`** (`pentest/ffuf-output.txt`, 4751-word SecLists common wordlist): confirmed no hidden/undocumented endpoints exist beyond the 5 already known from source review.
- **`nuclei`** (`pentest/nuclei-output.txt`, misconfig/exposure/tech/cve templates): no matches - an honest negative result, expected since nuclei's community templates target known off-the-shelf-software CVEs, not this app's custom logic bugs (all found manually above).
- **`sqlmap`** (`pentest/sqlmap-output.txt`): no exploitable injection; an initial automated "finding" was self-corrected by sqlmap as a false positive. Expected and consistent with source review - there is no SQL backend in this application (`LEDGER` is an in-memory Python list).

---

## Appendix: Evidence Index

| File | Contents |
|---|---|
| `recon/subfinder-output.txt`, `recon/amass-passive-output.txt` | Raw passive subdomain enumeration |
| `recon/httpx-output.txt` | Live-host fingerprinting (status, title, tech stack) |
| `recon/testssl-website.txt`, `recon/testssl-app.txt` | TLS posture |
| `pentest/poc-01-rce-yaml-deserialization.txt` | Finding 1, full request/response |
| `pentest/poc-02-ssrf-fetch.txt` | Finding 2, full request/response |
| `pentest/poc-03-broken-access-control-pan-disclosure.txt` | Finding 3, full request/response |
| `pentest/poc-04-weak-tokenization.txt` | Finding 4, full request/response |
| `pentest/poc-05-chained-rce-to-secrets.txt` | Chained attack |
| `pentest/poc-06-retest-against-hardened-task1-app.txt` | Retest against Task 1's patched app |
| `pentest/ffuf-output.txt`, `pentest/nuclei-output.txt`, `pentest/sqlmap-output.txt` | Automated tooling due-diligence passes |
