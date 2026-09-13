"""Probe product health endpoints."""

from __future__ import annotations

import json
import logging
import os
from datetime import datetime, timezone
from typing import Any

import httpx

logger = logging.getLogger("ops_tool.health")

DEFAULT_PRODUCT_HEALTH_URLS: dict[str, str] = {
    "identity": "https://api.prabhixtechnologies.com/healthz",
    "oneops": "https://oneops.prabhixtechnologies.com/healthz",
    "mobistack": "https://mobistack.prabhixtechnologies.com/healthz",
    "mailroom": "https://mailroom.prabhixtechnologies.com/healthz",
    "store": "https://store.prabhixtechnologies.com/healthz",
}

PROBE_TIMEOUT = float(os.environ.get("PRODUCT_HEALTH_TIMEOUT", "5"))


def load_product_urls() -> dict[str, str]:
    raw = os.environ.get("PRODUCT_HEALTH_URLS", "").strip()
    if not raw:
        return dict(DEFAULT_PRODUCT_HEALTH_URLS)
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError as exc:
        logger.error("PRODUCT_HEALTH_URLS is not valid JSON: %s", exc)
        return dict(DEFAULT_PRODUCT_HEALTH_URLS)
    if not isinstance(parsed, dict):
        logger.error("PRODUCT_HEALTH_URLS must be a JSON object")
        return dict(DEFAULT_PRODUCT_HEALTH_URLS)
    return {str(k): str(v) for k, v in parsed.items()}


async def probe_products() -> dict[str, Any]:
    urls = load_product_urls()
    products: list[dict[str, Any]] = []

    async with httpx.AsyncClient(timeout=PROBE_TIMEOUT, follow_redirects=True) as client:
        for name, url in urls.items():
            entry: dict[str, Any] = {
                "name": name,
                "url": url,
                "ok": False,
                "statusCode": None,
                "latencyMs": None,
                "error": None,
            }
            started = datetime.now(timezone.utc)
            try:
                resp = await client.get(url)
                elapsed = (datetime.now(timezone.utc) - started).total_seconds() * 1000
                entry["statusCode"] = resp.status_code
                entry["latencyMs"] = round(elapsed, 1)
                entry["ok"] = 200 <= resp.status_code < 400
                if not entry["ok"]:
                    entry["error"] = f"HTTP {resp.status_code}"
            except httpx.TimeoutException:
                entry["error"] = "timeout"
            except httpx.HTTPError as exc:
                entry["error"] = str(exc) or type(exc).__name__
            products.append(entry)

    healthy = sum(1 for p in products if p["ok"])
    return {
        "ok": healthy == len(products) and len(products) > 0,
        "checkedAt": datetime.now(timezone.utc).isoformat(),
        "healthy": healthy,
        "total": len(products),
        "products": products,
    }
