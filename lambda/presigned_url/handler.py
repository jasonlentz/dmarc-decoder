"""
DMARC Decoder — Presigned URL Generator
Returns a short-lived S3 presigned URL for direct browser-to-S3 upload.
The frontend uses this URL to PUT the file directly to S3,
bypassing API Gateway size limits entirely.
"""

import boto3
import json
import logging
import os
import re
import uuid
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3        = boto3.client("s3")
S3_BUCKET = os.environ["S3_BUCKET"]

ALLOWED_CONTENT_TYPES = {
    "application/xml",
    "application/zip",
    "application/gzip",
    "application/x-gzip",
    "application/octet-stream",
    "text/xml",
}

URL_EXPIRY_SECONDS = 300  # 5 minutes


def lambda_handler(event, context):
    params       = event.get("queryStringParameters") or {}
    filename     = params.get("filename", "report.xml")
    content_type = params.get("contentType", "application/octet-stream")

    if content_type not in ALLOWED_CONTENT_TYPES:
        return response(400, {"error": f"Unsupported content type: {content_type}"})

    date_prefix = datetime.now(tz=timezone.utc).strftime("%Y/%m/%d")
    s3_key      = f"raw/web/{date_prefix}/{uuid.uuid4().hex}_{sanitize(filename)}"

    try:
        presigned_url = s3.generate_presigned_url(
            "put_object",
            Params={
                "Bucket":      S3_BUCKET,
                "Key":         s3_key,
                "ContentType": content_type,
            },
            ExpiresIn = URL_EXPIRY_SECONDS,
        )
    except Exception as e:
        logger.error(f"Failed to generate presigned URL: {e}", exc_info=True)
        return response(500, {"error": "Could not generate upload URL"})

    logger.info(f"Generated presigned URL for {s3_key}")

    return response(200, {
        "uploadUrl": presigned_url,
        "s3Key":     s3_key,
        "expiresIn": URL_EXPIRY_SECONDS,
    })


def sanitize(filename: str) -> str:
    """Strip path components and keep only safe characters."""
    name = os.path.basename(filename)
    name = re.sub(r"[^\w.\-]", "_", name)
    return name[:128]


def response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type":                "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body),
    }
