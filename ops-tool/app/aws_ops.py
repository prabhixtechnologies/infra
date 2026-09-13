"""AWS read-only ops: Cost Explorer, EC2, CloudWatch CPU.

Uses the default boto3 credential chain (instance role, env AWS_*, shared config).
Never requires static keys in application config.
"""

from __future__ import annotations

import logging
import os
import re
from datetime import date, datetime, timedelta, timezone
from typing import Any

import boto3
from botocore.exceptions import BotoCoreError, ClientError
from cachetools import TTLCache

logger = logging.getLogger("ops_tool.aws")

AWS_REGION = os.environ.get("AWS_REGION", "ap-south-1")
CE_REGION = os.environ.get("AWS_CE_REGION", "us-east-1")
COST_CACHE_TTL = int(os.environ.get("AWS_COST_CACHE_TTL", "1800"))  # 30 min

_cost_cache: TTLCache[str, dict[str, Any]] = TTLCache(maxsize=32, ttl=COST_CACHE_TTL)

_RANGE_RE = re.compile(r"^(\d+)d$", re.IGNORECASE)


def _session() -> boto3.Session:
    """DefaultCredentialsProvider pattern — instance role / env / shared config."""
    return boto3.Session(region_name=AWS_REGION)


def _ce_client():
    return _session().client("ce", region_name=CE_REGION)


def _ec2_client():
    return _session().client("ec2", region_name=AWS_REGION)


def _cw_client():
    return _session().client("cloudwatch", region_name=AWS_REGION)


def _aws_error(exc: Exception) -> dict[str, Any]:
    if isinstance(exc, ClientError):
        err = exc.response.get("Error", {})
        return {
            "code": err.get("Code", "ClientError"),
            "message": err.get("Message", str(exc)),
        }
    if isinstance(exc, BotoCoreError):
        return {"code": type(exc).__name__, "message": str(exc)}
    return {"code": "Error", "message": str(exc)}


def parse_range_days(range_str: str, *, default: int = 30) -> int:
    raw = (range_str or f"{default}d").strip()
    m = _RANGE_RE.match(raw)
    if not m:
        raise ValueError("range must look like '30d'")
    days = int(m.group(1))
    if days < 1 or days > 365:
        raise ValueError("range must be between 1d and 365d")
    return days


def _cost_window(days: int) -> tuple[str, str]:
    end = date.today()
    start = end - timedelta(days=days)
    return start.isoformat(), end.isoformat()


def get_costs(*, days: int = 30) -> dict[str, Any]:
    """GetCostAndUsage: daily totals + group-by SERVICE. Cached 30 minutes."""
    cache_key = f"costs:{days}"
    cached = _cost_cache.get(cache_key)
    if cached is not None:
        return {**cached, "cached": True}

    start, end = _cost_window(days)
    ce = _ce_client()

    try:
        daily_resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="DAILY",
            Metrics=["UnblendedCost"],
        )
        by_service_resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="MONTHLY",
            Metrics=["UnblendedCost"],
            GroupBy=[{"Type": "DIMENSION", "Key": "SERVICE"}],
        )
    except (ClientError, BotoCoreError) as exc:
        logger.exception("Cost Explorer GetCostAndUsage failed")
        return {
            "ok": False,
            "error": _aws_error(exc),
            "region": CE_REGION,
            "start": start,
            "end": end,
            "days": days,
            "daily": [],
            "byService": [],
            "totalUsd": 0.0,
            "mtdUsd": 0.0,
            "cached": False,
        }

    daily: list[dict[str, Any]] = []
    total = 0.0
    for period in daily_resp.get("ResultsByTime", []):
        amount = float(
            period.get("Total", {}).get("UnblendedCost", {}).get("Amount", 0) or 0
        )
        total += amount
        daily.append(
            {
                "date": period.get("TimePeriod", {}).get("Start"),
                "amountUsd": round(amount, 4),
                "unit": period.get("Total", {}).get("UnblendedCost", {}).get("Unit", "USD"),
            }
        )

    by_service: list[dict[str, Any]] = []
    for period in by_service_resp.get("ResultsByTime", []):
        for group in period.get("Groups", []):
            keys = group.get("Keys") or ["Unknown"]
            amount = float(
                group.get("Metrics", {}).get("UnblendedCost", {}).get("Amount", 0) or 0
            )
            by_service.append(
                {
                    "service": keys[0],
                    "amountUsd": round(amount, 4),
                }
            )
    by_service.sort(key=lambda x: x["amountUsd"], reverse=True)

    # Month-to-date from daily rows in the current calendar month
    month_prefix = date.today().strftime("%Y-%m")
    mtd = sum(
        row["amountUsd"]
        for row in daily
        if isinstance(row.get("date"), str) and row["date"].startswith(month_prefix)
    )

    result: dict[str, Any] = {
        "ok": True,
        "error": None,
        "region": CE_REGION,
        "start": start,
        "end": end,
        "days": days,
        "currency": "USD",
        "daily": daily,
        "byService": by_service,
        "totalUsd": round(total, 4),
        "mtdUsd": round(mtd, 4),
        "cached": False,
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
    }
    _cost_cache[cache_key] = result
    return result


def _instance_name(tags: list[dict[str, str]] | None) -> str | None:
    if not tags:
        return None
    for tag in tags:
        if tag.get("Key") == "Name":
            return tag.get("Value")
    return None


def _cpu_average_1h(cw, instance_id: str) -> float | None:
    end = datetime.now(timezone.utc)
    start = end - timedelta(hours=1)
    try:
        resp = cw.get_metric_statistics(
            Namespace="AWS/EC2",
            MetricName="CPUUtilization",
            Dimensions=[{"Name": "InstanceId", "Value": instance_id}],
            StartTime=start,
            EndTime=end,
            Period=3600,
            Statistics=["Average"],
            Unit="Percent",
        )
    except (ClientError, BotoCoreError) as exc:
        logger.warning("CloudWatch CPU for %s failed: %s", instance_id, exc)
        return None

    datapoints = resp.get("Datapoints") or []
    if not datapoints:
        return None
    # Prefer the latest datapoint
    datapoints.sort(key=lambda d: d.get("Timestamp") or datetime.min.replace(tzinfo=timezone.utc))
    avg = datapoints[-1].get("Average")
    return round(float(avg), 2) if avg is not None else None


def list_instances() -> dict[str, Any]:
    """DescribeInstances in ap-south-1; CPU Average (1h) for running instances."""
    ec2 = _ec2_client()
    cw = _cw_client()
    instances: list[dict[str, Any]] = []

    try:
        paginator = ec2.get_paginator("describe_instances")
        for page in paginator.paginate():
            for reservation in page.get("Reservations", []):
                for inst in reservation.get("Instances", []):
                    state = (inst.get("State") or {}).get("Name", "unknown")
                    instance_id = inst.get("InstanceId", "")
                    cpu: float | None = None
                    if state == "running" and instance_id:
                        cpu = _cpu_average_1h(cw, instance_id)
                    instances.append(
                        {
                            "instanceId": instance_id,
                            "name": _instance_name(inst.get("Tags")),
                            "type": inst.get("InstanceType"),
                            "state": state,
                            "az": (inst.get("Placement") or {}).get("AvailabilityZone"),
                            "privateIp": inst.get("PrivateIpAddress"),
                            "publicIp": inst.get("PublicIpAddress"),
                            "launchTime": (
                                inst["LaunchTime"].isoformat()
                                if inst.get("LaunchTime")
                                else None
                            ),
                            "cpuAverage1h": cpu,
                        }
                    )
    except (ClientError, BotoCoreError) as exc:
        logger.exception("EC2 DescribeInstances failed")
        return {
            "ok": False,
            "error": _aws_error(exc),
            "region": AWS_REGION,
            "instances": [],
            "running": 0,
            "total": 0,
        }

    running = sum(1 for i in instances if i.get("state") == "running")
    return {
        "ok": True,
        "error": None,
        "region": AWS_REGION,
        "instances": instances,
        "running": running,
        "total": len(instances),
    }


def aws_summary(*, days: int = 30) -> dict[str, Any]:
    """Combined cost + instance snapshot for dashboards."""
    costs = get_costs(days=days)
    instances = list_instances()
    return {
        "ok": bool(costs.get("ok")) and bool(instances.get("ok")),
        "region": AWS_REGION,
        "costExplorerRegion": CE_REGION,
        "costs": {
            "totalUsd": costs.get("totalUsd", 0),
            "mtdUsd": costs.get("mtdUsd", 0),
            "days": costs.get("days", days),
            "topServices": (costs.get("byService") or [])[:5],
            "cached": costs.get("cached", False),
            "ok": costs.get("ok"),
            "error": costs.get("error"),
        },
        "instances": {
            "total": instances.get("total", 0),
            "running": instances.get("running", 0),
            "ok": instances.get("ok"),
            "error": instances.get("error"),
        },
        "fetchedAt": datetime.now(timezone.utc).isoformat(),
    }
