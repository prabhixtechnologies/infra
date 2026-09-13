"""Bearer JWT validation via JWKS, then platform-admin check via oneOps /auth/me.

Identity access tokens do not carry platform_admin. Staff authority lives in the
oneOps user row and is exposed on GET /api/v1/auth/me (platformAdmin).
"""

from __future__ import annotations

import logging
import os
import time
from typing import Any

import httpx
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from jwt import PyJWKClient

logger = logging.getLogger("ops_tool.auth")

IDENTITY_ISSUER = os.environ.get(
    "IDENTITY_ISSUER", "https://api.prabhixtechnologies.com"
).rstrip("/")
IDENTITY_AUDIENCE = os.environ.get("IDENTITY_AUDIENCE", "").strip() or None
JWKS_URI_OVERRIDE = os.environ.get("IDENTITY_JWKS_URI", "").strip() or None
PLATFORM_ME_URL = os.environ.get(
    "PLATFORM_ME_URL", "https://api.prabhixtechnologies.com/api/v1/auth/me"
).strip()

_bearer = HTTPBearer(auto_error=True)
_jwks_client: PyJWKClient | None = None
_jwks_client_uri: str | None = None
_jwks_uri: str | None = None
_jwks_uri_fetched_at: float = 0.0
_JWKS_URI_TTL_SECONDS = 3600.0

# Short-lived cache: sub -> (expires_monotonic, is_admin)
_admin_cache: dict[str, tuple[float, bool]] = {}
_ADMIN_CACHE_TTL = 60.0

ADMIN_CLAIMS = ("padm", "platform_admin", "platformAdmin")


def _truthy(value: Any) -> bool:
    if value is True:
        return True
    if isinstance(value, (int, float)) and value == 1:
        return True
    if isinstance(value, str) and value.strip().lower() in {"true", "1", "yes"}:
        return True
    return False


def is_platform_admin_claim(claims: dict[str, Any]) -> bool:
    return any(_truthy(claims.get(name)) for name in ADMIN_CLAIMS)


def _resolve_jwks_uri() -> str:
    global _jwks_uri, _jwks_uri_fetched_at

    if JWKS_URI_OVERRIDE:
        return JWKS_URI_OVERRIDE

    now = time.monotonic()
    if _jwks_uri and (now - _jwks_uri_fetched_at) < _JWKS_URI_TTL_SECONDS:
        return _jwks_uri

    discovery_url = f"{IDENTITY_ISSUER}/.well-known/openid-configuration"
    try:
        with httpx.Client(timeout=10.0) as client:
            resp = client.get(discovery_url)
            resp.raise_for_status()
            data = resp.json()
    except Exception as exc:
        logger.warning("OIDC discovery failed (%s); falling back to /.well-known/jwks.json", exc)
        _jwks_uri = f"{IDENTITY_ISSUER}/.well-known/jwks.json"
        _jwks_uri_fetched_at = now
        return _jwks_uri

    uri = data.get("jwks_uri")
    if not uri:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Identity discovery missing jwks_uri",
        )
    _jwks_uri = str(uri)
    _jwks_uri_fetched_at = now
    return _jwks_uri


def _get_jwks_client() -> PyJWKClient:
    global _jwks_client, _jwks_client_uri
    uri = _resolve_jwks_uri()
    if _jwks_client is None or _jwks_client_uri != uri:
        _jwks_client = PyJWKClient(uri, cache_keys=True, lifespan=3600)
        _jwks_client_uri = uri
    return _jwks_client


def decode_jwt(token: str) -> dict[str, Any]:
    """Validate RS256 JWT against issuer JWKS. Does not check platform admin."""
    try:
        client = _get_jwks_client()
        signing_key = client.get_signing_key_from_jwt(token)
    except HTTPException:
        raise
    except Exception as exc:
        logger.info("JWKS / signing key error: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Unable to validate token signature",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    options = {
        "require": ["exp", "sub"],
        "verify_aud": IDENTITY_AUDIENCE is not None,
    }
    try:
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256"],
            issuer=IDENTITY_ISSUER,
            audience=IDENTITY_AUDIENCE,
            options=options,
        )
    except jwt.ExpiredSignatureError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token expired",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except jwt.InvalidIssuerError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Invalid token issuer",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc
    except jwt.InvalidTokenError as exc:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=f"Invalid token: {exc}",
            headers={"WWW-Authenticate": "Bearer"},
        ) from exc

    if not isinstance(claims, dict) or not claims.get("sub"):
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token missing subject",
            headers={"WWW-Authenticate": "Bearer"},
        )
    return claims


def _check_platform_me(token: str) -> bool:
    try:
        with httpx.Client(timeout=10.0) as client:
            resp = client.get(
                PLATFORM_ME_URL,
                headers={"Authorization": f"Bearer {token}", "Accept": "application/json"},
            )
    except Exception as exc:
        logger.warning("PLATFORM_ME_URL check failed: %s", exc)
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="Unable to verify platform admin with oneOps",
        ) from exc

    if resp.status_code == 401:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail="Token rejected by platform",
            headers={"WWW-Authenticate": "Bearer"},
        )
    if resp.status_code >= 400:
        logger.info("auth/me returned %s", resp.status_code)
        return False
    try:
        data = resp.json()
    except Exception:
        return False
    return _truthy(data.get("platformAdmin")) or _truthy(data.get("platform_admin"))


def ensure_platform_admin(token: str, claims: dict[str, Any]) -> dict[str, Any]:
    if is_platform_admin_claim(claims):
        claims["_adminSource"] = "jwt"
        return claims

    sub = str(claims["sub"])
    now = time.monotonic()
    cached = _admin_cache.get(sub)
    if cached and cached[0] > now:
        if cached[1]:
            claims["_adminSource"] = "cache"
            return claims
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Platform admin required",
        )

    ok = _check_platform_me(token)
    _admin_cache[sub] = (now + _ADMIN_CACHE_TTL, ok)
    if not ok:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail="Platform admin required (oneOps auth/me.platformAdmin)",
        )
    claims["_adminSource"] = "auth_me"
    return claims


async def require_platform_admin(
    credentials: HTTPAuthorizationCredentials = Depends(_bearer),
) -> dict[str, Any]:
    """FastAPI dependency: authenticated platform admin claims."""
    token = credentials.credentials
    claims = decode_jwt(token)
    return ensure_platform_admin(token, claims)
