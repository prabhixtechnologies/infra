"""Optional GitHub Actions status for configured repos."""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from typing import Any

import httpx

logger = logging.getLogger("ops_tool.github")

DEFAULT_REPOS = [
    "prabhixtechnologies/Mobile",
    "prabhixtechnologies/oneOps",
    "prabhixtechnologies/MobiStack",
    "prabhixtechnologies/Identity",
    "prabhixtechnologies/Mailroom",
]

GITHUB_API = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")


def _repos() -> list[str]:
    raw = os.environ.get("GITHUB_REPOS", "").strip()
    if not raw:
        return list(DEFAULT_REPOS)
    return [r.strip() for r in raw.split(",") if r.strip()]


def _token() -> str | None:
    tok = os.environ.get("GITHUB_TOKEN", "").strip()
    return tok or None


async def latest_workflow_checks() -> dict[str, Any]:
    token = _token()
    repos = _repos()

    if not token:
        return {
            "ok": True,
            "note": "GITHUB_TOKEN not set; returning empty checks",
            "checkedAt": datetime.now(timezone.utc).isoformat(),
            "checks": [],
            "repos": [],
        }

    headers = {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {token}",
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "prabhix-ops-tool",
    }
    results: list[dict[str, Any]] = []

    async with httpx.AsyncClient(timeout=15.0, headers=headers) as client:
        for full_name in repos:
            entry: dict[str, Any] = {
                "repo": full_name,
                "ok": False,
                "conclusion": None,
                "status": None,
                "workflowName": None,
                "runUrl": None,
                "runId": None,
                "updatedAt": None,
                "error": None,
            }
            url = f"{GITHUB_API}/repos/{full_name}/actions/runs"
            try:
                resp = await client.get(
                    url,
                    params={"per_page": 1, "exclude_pull_requests": "true"},
                )
                if resp.status_code == 404:
                    entry["error"] = "repo not found or no access"
                    results.append(entry)
                    continue
                resp.raise_for_status()
                data = resp.json()
                runs = data.get("workflow_runs") or []
                if not runs:
                    entry["ok"] = True
                    entry["status"] = "none"
                    entry["conclusion"] = "none"
                    entry["error"] = "no workflow runs"
                    results.append(entry)
                    continue
                run = runs[0]
                conclusion = run.get("conclusion")
                status = run.get("status")
                entry.update(
                    {
                        "ok": conclusion == "success" or (status == "completed" and conclusion == "success"),
                        "conclusion": conclusion,
                        "status": status,
                        "workflowName": run.get("name"),
                        "runUrl": run.get("html_url"),
                        "runId": run.get("id"),
                        "updatedAt": run.get("updated_at"),
                        "error": None
                        if conclusion == "success"
                        else (conclusion or status or "unknown"),
                    }
                )
                # Treat in-progress as ok=None-ish: not failed yet
                if status and status != "completed":
                    entry["ok"] = True
                    entry["error"] = None
            except httpx.HTTPError as exc:
                logger.warning("GitHub check for %s failed: %s", full_name, exc)
                entry["error"] = str(exc) or type(exc).__name__
            results.append(entry)

    failing = [r for r in results if r.get("conclusion") not in (None, "success", "none") and r.get("status") == "completed"]
    checks = [
        {
            "repo": r.get("repo"),
            "name": r.get("workflowName"),
            "status": r.get("status"),
            "conclusion": r.get("conclusion"),
            "htmlUrl": r.get("runUrl"),
        }
        for r in results
    ]
    return {
        "ok": len(failing) == 0,
        "note": None,
        "checkedAt": datetime.now(timezone.utc).isoformat(),
        "checks": checks,
        "repos": results,
    }
