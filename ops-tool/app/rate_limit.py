"""Simple in-memory rate limit: 60 requests per minute per subject."""

from __future__ import annotations

import threading
import time
from collections import defaultdict, deque
from typing import Deque

from fastapi import HTTPException, Request, status

LIMIT = 60
WINDOW_SECONDS = 60.0

_lock = threading.Lock()
_hits: dict[str, Deque[float]] = defaultdict(deque)


def _subject_key(request: Request) -> str:
    claims = getattr(request.state, "claims", None)
    if isinstance(claims, dict) and claims.get("sub"):
        return f"sub:{claims['sub']}"
    client = request.client.host if request.client else "unknown"
    return f"ip:{client}"


def check_rate_limit(request: Request, *, limit: int = LIMIT) -> None:
    """Raise 429 if the subject exceeds `limit` requests in the rolling window."""
    key = _subject_key(request)
    now = time.monotonic()
    cutoff = now - WINDOW_SECONDS

    with _lock:
        q = _hits[key]
        while q and q[0] < cutoff:
            q.popleft()
        if len(q) >= limit:
            raise HTTPException(
                status_code=status.HTTP_429_TOO_MANY_REQUESTS,
                detail=f"Rate limit exceeded ({limit} requests per minute)",
                headers={"Retry-After": "60"},
            )
        q.append(now)
