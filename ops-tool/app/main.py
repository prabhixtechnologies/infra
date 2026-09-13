"""Ops Tool FastAPI entrypoint."""

from __future__ import annotations

import logging
import os
from typing import Any

from fastapi import Depends, FastAPI, HTTPException, Query, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse

from app import __version__
from app.audit import AuditMiddleware
from app.auth import require_platform_admin
from app.aws_ops import aws_summary, get_costs, list_instances, parse_range_days
from app.github_ops import latest_workflow_checks
from app.health import probe_products
from app.rate_limit import check_rate_limit

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s %(message)s",
)
logger = logging.getLogger("ops_tool")

app = FastAPI(
    title="Prabhix Ops Tool",
    version=__version__,
    description="Read-only platform ops API for AWS cost/instances, product health, and CI checks.",
)

_cors_origins = [
    o.strip()
    for o in os.environ.get(
        "CORS_ORIGINS",
        "https://admin.prabhixtechnologies.com,http://localhost:3000,http://localhost:5173,http://127.0.0.1:3000,http://127.0.0.1:5173",
    ).split(",")
    if o.strip()
]

app.add_middleware(
    CORSMiddleware,
    allow_origins=_cors_origins,
    allow_credentials=True,
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type", "Accept"],
)
app.add_middleware(AuditMiddleware)


async def _authed(request: Request, claims: dict[str, Any] = Depends(require_platform_admin)) -> dict[str, Any]:
    """Attach claims for audit + enforce rate limit."""
    request.state.claims = claims
    check_rate_limit(request)
    return claims


@app.get("/healthz", tags=["public"])
async def healthz() -> dict[str, Any]:
    """Liveness probe — no auth."""
    return {"ok": True, "service": "ops-tool", "version": __version__}


@app.get("/v1/aws/summary", tags=["aws"])
async def v1_aws_summary(
    range: str = Query("30d", description="Lookback window, e.g. 30d"),
    _claims: dict[str, Any] = Depends(_authed),
) -> dict[str, Any]:
    try:
        days = parse_range_days(range)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return aws_summary(days=days)


@app.get("/v1/aws/costs", tags=["aws"])
async def v1_aws_costs(
    range: str = Query("30d", description="Lookback window, e.g. 30d"),
    _claims: dict[str, Any] = Depends(_authed),
) -> dict[str, Any]:
    try:
        days = parse_range_days(range)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    return get_costs(days=days)


@app.get("/v1/aws/instances", tags=["aws"])
async def v1_aws_instances(_claims: dict[str, Any] = Depends(_authed)) -> dict[str, Any]:
    return list_instances()


@app.get("/v1/health/products", tags=["health"])
async def v1_health_products(_claims: dict[str, Any] = Depends(_authed)) -> dict[str, Any]:
    return await probe_products()


@app.get("/v1/github/checks", tags=["github"])
async def v1_github_checks(_claims: dict[str, Any] = Depends(_authed)) -> dict[str, Any]:
    return await latest_workflow_checks()


def _parse_money(value: float | None, label: str) -> float:
    if value is None:
        return 0.0
    try:
        return float(value)
    except (TypeError, ValueError) as exc:
        raise HTTPException(status_code=400, detail=f"Invalid {label}") from exc


@app.get("/v1/pnl", tags=["pnl"])
async def v1_pnl(
    mobiCaptured: float | None = Query(None, description="MobiStack captured revenue (INR or USD as provided)"),
    oneopsCaptured: float | None = Query(None, description="oneOps captured revenue"),
    awsMtd: float | None = Query(None, description="Override AWS month-to-date cost; else from Cost Explorer"),
    _claims: dict[str, Any] = Depends(_authed),
) -> dict[str, Any]:
    """Simple P&L strip: captured revenue vs AWS MTD cost."""
    mobi = _parse_money(mobiCaptured, "mobiCaptured")
    oneops = _parse_money(oneopsCaptured, "oneopsCaptured")
    revenue = mobi + oneops

    aws_source = "query"
    if awsMtd is not None:
        aws_cost = _parse_money(awsMtd, "awsMtd")
    else:
        costs = get_costs(days=30)
        if not costs.get("ok"):
            return JSONResponse(
                status_code=502,
                content={
                    "ok": False,
                    "error": costs.get("error") or {"message": "Unable to load AWS costs"},
                    "revenue": {
                        "mobiCaptured": mobi,
                        "oneopsCaptured": oneops,
                        "total": round(revenue, 2),
                    },
                    "awsMtd": None,
                },
            )
        aws_cost = float(costs.get("mtdUsd") or 0)
        aws_source = "cost_explorer"

    contribution = revenue - aws_cost
    return {
        "ok": True,
        "revenue": {
            "mobiCaptured": round(mobi, 2),
            "oneopsCaptured": round(oneops, 2),
            "total": round(revenue, 2),
        },
        "awsMtd": round(aws_cost, 4),
        "awsMtdSource": aws_source,
        "contribution": round(contribution, 4),
        "note": "Units are as supplied by the caller for revenue; AWS costs are USD.",
    }
