"""Log every authenticated request to stdout as JSON."""

from __future__ import annotations

import json
import logging
import sys
import time
from typing import Callable

from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

logger = logging.getLogger("ops_tool.audit")


class AuditMiddleware(BaseHTTPMiddleware):
    """Emit one JSON audit line per authenticated request (stdout)."""

    async def dispatch(self, request: Request, call_next: Callable) -> Response:
        started = time.perf_counter()
        response: Response | None = None
        try:
            response = await call_next(request)
            return response
        finally:
            claims = getattr(request.state, "claims", None)
            # Only audit routes that resolved an authenticated subject
            if isinstance(claims, dict) and claims.get("sub"):
                elapsed_ms = round((time.perf_counter() - started) * 1000, 2)
                record = {
                    "event": "ops_tool.audit",
                    "sub": claims.get("sub"),
                    "path": request.url.path,
                    "method": request.method,
                    "status": response.status_code if response is not None else 500,
                    "elapsed_ms": elapsed_ms,
                }
                line = json.dumps(record, separators=(",", ":"), default=str)
                # Prefer stdout for log shippers; also mirror to logger
                print(line, file=sys.stdout, flush=True)
                logger.info(line)
