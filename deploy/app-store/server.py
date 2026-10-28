#!/usr/bin/env python3
"""Company app store: static HTML plus APK and IPA streams from S3 (or a local artifacts dir)."""

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
# (s3 key, content type, download filename). iOS is MobiStack only: the other apps have no IPA.
PACKAGES = {
    ("mobistack", "android"): (
        "mobistack/android.apk",
        "application/vnd.android.package-archive",
        "mobistack.apk",
    ),
    ("oneops", "android"): (
        "oneops/android.apk",
        "application/vnd.android.package-archive",
        "oneops.apk",
    ),
    ("mailroom", "android"): (
        "mailroom/android.apk",
        "application/vnd.android.package-archive",
        "mailroom.apk",
    ),
    ("mobistack", "ios"): (
        "mobistack/ios.ipa",
        "application/octet-stream",
        "MobiStack.ipa",
    ),
}

app = Flask(__name__, static_folder=None)
s3 = boto3.client("s3", region_name=REGION) if BUCKET else None


def _headers(content_type: str, filename: str, length: int | None = None) -> dict[str, str]:
    headers = {
        "Content-Type": content_type,
        "Content-Disposition": f'attachment; filename="{filename}"',
        "Cache-Control": "public, max-age=300",
    }
    if length is not None:
        headers["Content-Length"] = str(length)
    return headers


def _stream(key: str, content_type: str, filename: str):
    if BUCKET:
        assert s3 is not None
        try:
            if request.method == "HEAD":
                head = s3.head_object(Bucket=BUCKET, Key=key)
                return Response(status=200, headers=_headers(content_type, filename, head.get("ContentLength")))
            obj = s3.get_object(Bucket=BUCKET, Key=key)
        except ClientError as exc:
            code = exc.response.get("Error", {}).get("Code", "")
            if code in {"404", "NoSuchKey", "NotFound"}:
                abort(404)
            raise
        return Response(
            obj["Body"].iter_chunks(chunk_size=1024 * 256),
            headers=_headers(content_type, filename, obj.get("ContentLength")),
            direct_passthrough=True,
        )

    path = ARTIFACTS / key
    if not path.is_file():
        abort(404)
    if request.method == "HEAD":
        return Response(status=200, headers=_headers(content_type, filename, path.stat().st_size))
    return Response(
        path.open("rb"),
        headers=_headers(content_type, filename, path.stat().st_size),
        direct_passthrough=True,
    )


@app.get("/healthz")
def healthz():
    return {"ok": True, "bucket": BUCKET or None}


@app.route("/<product>/android.apk", methods=["GET", "HEAD"])
def android_apk(product: str):
    spec = PACKAGES.get((product, "android"))
    if not spec:
        abort(404)
    return _stream(*spec)


@app.route("/<product>/ios.ipa", methods=["GET", "HEAD"])
def ios_ipa(product: str):
    spec = PACKAGES.get((product, "ios"))
    if not spec:
        abort(404)
    return _stream(*spec)


@app.route("/", defaults={"path": ""})
@app.route("/<path:path>")
def static_pages(path: str):
    if path.endswith(".apk") or path.endswith(".ipa"):
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
