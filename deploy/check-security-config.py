#!/usr/bin/env python3
"""Mechanical checks for edge, mail-server and monitoring hardening.

Run in CI and locally:

    python deploy/check-security-config.py
"""
from __future__ import annotations

import json
import pathlib
import re
import sys

REPO = pathlib.Path(__file__).resolve().parent.parent
MAIL = REPO.parent / "Mailroom" / "mail-server"

errors: list[str] = []


def require(path: pathlib.Path, pattern: str, message: str) -> None:
    text = path.read_text(encoding="utf-8")
    if not re.search(pattern, text, re.MULTILINE | re.DOTALL):
        errors.append(f"{path.relative_to(REPO)}: {message}")


def forbid(path: pathlib.Path, pattern: str, message: str) -> None:
    text = path.read_text(encoding="utf-8")
    if re.search(pattern, text, re.MULTILINE | re.DOTALL):
        errors.append(f"{path.relative_to(REPO)}: {message}")


caddy = REPO / "deploy" / "Caddyfile"
require(caddy, r"handle /internal\*\s*\{[^}]*respond 404", "block /internal* on api host")
require(
    caddy,
    r"handle /api/v1/oneops/mail/inbound/\*\s*\{[^}]*respond 404",
    "block public inbound mail route on api host",
)
for host in ("mobistack.prabhixtechnologies.com", "api.mobistack.prabhixtechnologies.com"):
    block = re.search(rf"{re.escape(host)} \{{(.*?)\n\}}", caddy.read_text(encoding="utf-8"), re.DOTALL)
    if not block:
        errors.append(f"deploy/Caddyfile: missing site block for {host}")
        continue
    body = block.group(1)
    for needle in (
        "/internal*",
        "/api/v1/mobistack/admin/*",
        "/swagger-ui*",
        "respond 404",
    ):
        if needle not in body:
            errors.append(f"deploy/Caddyfile: {host} missing {needle!r}")

postfix_main = MAIL / "postfix" / "main.cf"
if postfix_main.is_file():
    require(postfix_main, r"mynetworks\s*=\s*127\.0\.0\.0/8", "mynetworks must be loopback only")
    require(postfix_main, r"milter_default_action\s*=\s*tempfail", "Rspamd failure must tempfail")
    forbid(postfix_main, r"smtpd_relay_restrictions\s*=\s*permit_mynetworks", "relay must not trust mynetworks")
else:
    errors.append("Mailroom/mail-server/postfix/main.cf not found (expected sibling checkout)")

bootstrap = MAIL / "dovecot" / "bootstrap.passwd"
if bootstrap.is_file():
    for line in bootstrap.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        errors.append(
            "Mailroom/mail-server/dovecot/bootstrap.passwd: production break-glass file must stay empty"
        )
        break

compose = REPO / "docker-compose.yml"
forbid(compose, r"GF_SECURITY_ADMIN_PASSWORD:\s*\$\{GRAFANA_ADMIN_PASSWORD:-admin\}", "remove Grafana admin default")
forbid(compose, r"--web\.enable-lifecycle", "Prometheus lifecycle API must stay disabled")

local = REPO / "docker-compose.local.yml"
text_local = local.read_text(encoding="utf-8")
if "127.0.0.1:9090:9090" not in text_local:
    errors.append("docker-compose.local.yml: bind Prometheus to loopback")
if "127.0.0.1:3001:3000" not in text_local:
    errors.append("docker-compose.local.yml: bind Grafana to loopback")

example = REPO / "docker" / "prometheus" / "secrets" / "bearer_token.example"
if example.is_file() and "changeme" in example.read_text(encoding="utf-8").lower():
    errors.append("docker/prometheus/secrets/bearer_token.example: remove known default token text")

PLAY_UPLOAD_SHA256 = "3094aa00bc187a4e1a6ea2242953998dc078b164d464725e0b7c2c4c64a060f6"
ANDROID_PACKAGES = ("app.prabhix.fixflow", "com.prabhix.operator")

assetlinks = REPO / "deploy" / "static" / "well-known" / "assetlinks.json"
if assetlinks.is_file():
    try:
        entries = json.loads(assetlinks.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        errors.append(f"deploy/static/well-known/assetlinks.json: invalid JSON ({exc})")
        entries = None
    if isinstance(entries, list):
        seen_packages: set[str] = set()
        for idx, entry in enumerate(entries):
            target = entry.get("target") if isinstance(entry, dict) else None
            if not isinstance(target, dict):
                errors.append(f"deploy/static/well-known/assetlinks.json: entry {idx} missing target")
                continue
            pkg = target.get("package_name")
            fps = target.get("sha256_cert_fingerprints")
            if pkg not in ANDROID_PACKAGES:
                errors.append(
                    f"deploy/static/well-known/assetlinks.json: unexpected package {pkg!r} at index {idx}"
                )
            if pkg:
                seen_packages.add(str(pkg))
            if not isinstance(fps, list) or PLAY_UPLOAD_SHA256 not in fps:
                errors.append(
                    f"deploy/static/well-known/assetlinks.json: {pkg or idx} missing Play upload SHA-256"
                )
        for pkg in ANDROID_PACKAGES:
            if pkg not in seen_packages:
                errors.append(f"deploy/static/well-known/assetlinks.json: missing package {pkg}")
    elif entries is not None:
        errors.append("deploy/static/well-known/assetlinks.json: root must be a JSON array")
else:
    errors.append("deploy/static/well-known/assetlinks.json: missing")

caddy_text = caddy.read_text(encoding="utf-8")
if "android_assetlinks" not in caddy_text:
    errors.append("deploy/Caddyfile: missing android_assetlinks snippet")
for host in ("oneops.prabhixtechnologies.com", "mobistack.prabhixtechnologies.com"):
    block = re.search(rf"{re.escape(host)} \{{(.*?)\n\}}", caddy_text, re.DOTALL)
    if not block:
        errors.append(f"deploy/Caddyfile: missing site block for {host}")
    elif "android_assetlinks" not in block.group(1):
        errors.append(f"deploy/Caddyfile: {host} must import android_assetlinks")

lmtp_push = MAIL / "lmtp-push" / "http-push.sh"
if lmtp_push.is_file():
    push_text = lmtp_push.read_text(encoding="utf-8")
    for hdr in ("X-Mail-Timestamp", "X-Mail-Nonce", "X-Mail-Signature", "X-Mail-Token"):
        if hdr not in push_text:
            errors.append(f"Mailroom/mail-server/lmtp-push/http-push.sh: missing {hdr}")
else:
    errors.append("Mailroom/mail-server/lmtp-push/http-push.sh not found")

if (MAIL / "postfix" / "main.cf").is_file():
    require(MAIL / "postfix" / "main.cf", r"virtual_transport\s*=\s*platform-push:", "LMTP HTTP push transport")

env_example = REPO / "deploy" / ".env.prod.example"
if env_example.is_file():
    env_text = env_example.read_text(encoding="utf-8")
    if "MAIL_LMTP_SIGNING_SECRET" not in env_text:
        errors.append("deploy/.env.prod.example: document MAIL_LMTP_SIGNING_SECRET")

verify_sign = MAIL / "lmtp-push" / "verify_sign.py"
if verify_sign.is_file():
    import subprocess

    proc = subprocess.run([sys.executable, str(verify_sign)], capture_output=True, text=True)
    if proc.returncode != 0:
        errors.append(f"Mailroom/mail-server/lmtp-push/verify_sign.py failed: {proc.stderr.strip()}")

if errors:
    for err in errors:
        print(f"ERROR: {err}", file=sys.stderr)
    sys.exit(1)

print("check-security-config: ok")
