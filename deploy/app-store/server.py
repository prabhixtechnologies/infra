#!/usr/bin/env python3
"""Company app store: static HTML plus APK streams from S3 (or a local artifacts dir)."""

from __future__ import annotations

import os
from pathlib import Path

import boto3
from botocore.exceptions import ClientError
from flask import Flask, Response, abort, request, send_from_directory

WWW = Path(os.environ.get("STORE_WWW", "/srv/www"))
ARTIFACTS = Path(os.environ.get("STORE_ARTIFACTS", "/artifacts"))
BUCKET = os.environ.get("APK_S3_BUCKET", "").strip()
REGION = os.environ.get("APK_S3_REGION", os.environ.get("AWS_REGION", "ap-south-1")).strip()
APPS = {
    "mobistack": "mobistack/android.apk",
    "oneops": "oneops/android.apk",
    "mailroom": "mailroom/android.apk",
}

app = Flask(__name__, static_folder=None)
s3 = boto3.client("s3", region_name=REGION) if BUCKET else None


def _disposition(product: str) -> str:
    return f'attachment; filename="{product}.apk"'


def _apk_headers(product: str, length: int | None = None) -> dict[str, str]:
    headers = {
        "Content-Type": "application/vnd.android.package-archive",
        "Content-Disposition": _disposition(product),
        "Cache-Control": "public, max-age=300",
    }
    if length is not None:
        headers["Content-Length"] = str(length)
    return headers


@app.get("/healthz")
def healthz():
    return {"ok": True, "bucket": BUCKET or None}


@app.route("/<product>/android.apk", methods=["GET", "HEAD"])
def android_apk(product: str):
    key = APPS.get(product)
    if not key:
        abort(404)

    if BUCKET:
        assert s3 is not None
        try:
            if request.method == "HEAD":
                head = s3.head_object(Bucket=BUCKET, Key=key)
                return Response(status=200, headers=_apk_headers(product, head.get("ContentLength")))
            obj = s3.get_object(Bucket=BUCKET, Key=key)
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code in {"404", "NoSuchKey", "NotFound"}:
                abort(404)
            raise
        return Response(
            obj["Body"].iter_chunks(chunk_size=1024 * 256),
            headers=_apk_headers(product, obj.get("ContentLength")),
            direct_passthrough=True,
        )

    path = ARTIFACTS / key
    if not path.is_file():
        abort(404)
    if request.method == "HEAD":
        return Response(status=200, headers=_apk_headers(product, path.stat().st_size))
    return Response(
        path.open("rb"),
        headers=_apk_headers(product, path.stat().st_size),
        direct_passthrough=True,
    )


@app.route("/", defaults={"path": ""})
@app.route("/<path:path>")
def static_pages(path: str):
    if path.endswith(".apk"):
        abort(404)
    if path:
        candidate = WWW / path
        if candidate.is_file():
            return send_from_directory(WWW, path)
        index = candidate / "index.html"
        if index.is_file():
            return send_from_directory(WWW, f"{path.rstrip('/')}/index.html")
        abort(404)
    return send_from_directory(WWW, "index.html")


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", "80")))
