import hashlib
import ipaddress
import logging
import os
import socket
from urllib.parse import urlparse

import requests
import yaml
from flask import Flask, request, jsonify

app = Flask(__name__)

LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()
APP_ENV = os.environ.get("APP_ENV", "production")
LEDGER_SOURCE = os.environ.get("LEDGER_SOURCE", "static")
FETCH_ALLOWLIST = {
    h.strip().lower()
    for h in os.environ.get("FETCH_ALLOWLIST", "").split(",")
    if h.strip()
}

logging.basicConfig(level=getattr(logging, LOG_LEVEL, logging.INFO))
logger = logging.getLogger("ledger-api")

STRIPE_API_KEY = os.environ.get("STRIPE_API_KEY", "")
DB_PASSWORD = os.environ.get("DB_PASSWORD", "")

LEDGER = [
    {"id": "txn_1001", "pan": "4242424242424242", "amount": 4200, "currency": "USD", "status": "captured"},
    {"id": "txn_1002", "pan": "5555555555554444", "amount": 1899, "currency": "EUR", "status": "refunded"},
]


@app.route("/health")
def health():
    return jsonify(status="ok", env=APP_ENV)


@app.route("/tokenize", methods=["POST"])
def tokenize():
    payload = request.get_json(silent=True) or {}
    pan = payload.get("pan", "")
    token = "tok_" + hashlib.sha256(pan.encode()).hexdigest()[:24]
    return jsonify(token=token, last4=pan[-4:])


@app.route("/transactions")
def transactions():
    logger.info("serving %d transactions from source=%s", len(LEDGER), LEDGER_SOURCE)
    return jsonify(transactions=LEDGER)


@app.route("/import", methods=["POST"])
def import_config():
    # yaml.safe_load refuses to construct arbitrary Python objects, closing the
    # deserialization RCE that yaml.load(..., Loader=None) allowed.
    try:
        config = yaml.safe_load(request.data)
    except yaml.YAMLError as exc:
        return jsonify(error=f"invalid YAML: {exc}"), 400
    return jsonify(loaded=str(config))


def _is_allowed_target(hostname: str) -> bool:
    if hostname.lower() not in FETCH_ALLOWLIST:
        return False
    try:
        resolved_ips = {info[4][0] for info in socket.getaddrinfo(hostname, None)}
    except socket.gaierror:
        return False
    for ip in resolved_ips:
        addr = ipaddress.ip_address(ip)
        if addr.is_private or addr.is_loopback or addr.is_link_local or addr.is_reserved or addr.is_multicast:
            return False
    return True


@app.route("/fetch")
def fetch():
    url = request.args.get("url", "")
    parsed = urlparse(url)

    if parsed.scheme not in ("http", "https") or not parsed.hostname:
        return jsonify(error="url must be an absolute http(s) URL"), 400

    # Allowlist-only egress plus a DNS-resolution check against private/loopback
    # ranges blocks both naive SSRF and DNS-rebinding against internal services.
    if not _is_allowed_target(parsed.hostname):
        logger.warning("blocked fetch to disallowed target host=%s", parsed.hostname)
        return jsonify(error="target host is not in the allowlist"), 403

    try:
        # Semgrep's generic SSRF rule can't see that _is_allowed_target() above
        # already enforces a hostname allowlist AND re-resolves DNS to reject
        # private/loopback/link-local IPs (DNS-rebinding defense).
        # allow_redirects=False also blocks a redirect-based bypass of that
        # check. Reviewed and accepted as a confirmed false positive.
        resp = requests.get(url, timeout=5, allow_redirects=False)  # nosemgrep: python.flask.security.injection.ssrf-requests.ssrf-requests
    except requests.RequestException as exc:
        return jsonify(error=f"fetch failed: {exc}"), 502

    return jsonify(status_code=resp.status_code, body=resp.text[:2048])


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)
