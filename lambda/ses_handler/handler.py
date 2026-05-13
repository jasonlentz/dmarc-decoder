"""
DMARC Decoder — SES Inbound Handler

Receives raw email via SES, extracts the DMARC aggregate report
attachment, and deposits it into the S3 raw/email/ prefix.
The parser Lambda picks it up automatically via S3 event trigger.

This Lambda is deployed but not yet wired to an SES receipt rule.
See README — "Activating Email Ingestion" for setup steps.
"""

import boto3
import email
import logging
import os
import uuid
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3        = boto3.client("s3")
S3_BUCKET = os.environ["S3_BUCKET"]

ALLOWED_EXTENSIONS   = {".xml", ".gz", ".gzip", ".zip"}
MAX_ATTACHMENT_BYTES = 10 * 1024 * 1024  # 10MB


def lambda_handler(event, context):
    """
    SES invokes this Lambda after storing the raw email in S3.
    The SES receipt rule action stores raw email, then invokes here.
    """
    for ses_record in event.get("Records", []):
        mail    = ses_record.get("ses", {}).get("mail", {})
        receipt = ses_record.get("ses", {}).get("receipt", {})

        message_id = mail.get("messageId", "")
        logger.info(f"Processing SES message: {message_id}")

        try:
            process_ses_message(message_id, receipt)
        except Exception as e:
            logger.error(f"Failed to process message {message_id}: {e}", exc_info=True)
            raise

    return {"statusCode": 200, "body": "OK"}


def process_ses_message(message_id: str, receipt: dict):
    ses_bucket = os.environ.get("SES_RAW_EMAIL_BUCKET", S3_BUCKET)
    ses_prefix = os.environ.get("SES_RAW_EMAIL_PREFIX", "ses-raw/")
    raw_email_key = f"{ses_prefix}{message_id}"

    try:
        obj       = s3.get_object(Bucket=ses_bucket, Key=raw_email_key)
        raw_email = obj["Body"].read()
    except Exception as e:
        logger.error(f"Could not fetch raw email from S3: {e}")
        raise

    msg = email.message_from_bytes(raw_email)
    attachments_saved = 0

    for part in msg.walk():
        content_disposition = part.get("Content-Disposition", "")
        content_type        = part.get_content_type()

        if "attachment" not in content_disposition and content_type not in (
            "application/zip",
            "application/gzip",
            "application/xml",
            "text/xml",
            "application/octet-stream",
        ):
            continue

        filename = part.get_filename() or f"report_{uuid.uuid4().hex}.xml"
        ext      = get_extension(filename)

        if ext not in ALLOWED_EXTENSIONS:
            logger.warning(f"Skipping unsupported attachment: {filename}")
            continue

        payload = part.get_payload(decode=True)
        if not payload:
            continue

        if len(payload) > MAX_ATTACHMENT_BYTES:
            logger.warning(f"Attachment too large ({len(payload)} bytes), skipping: {filename}")
            continue

        date_prefix = datetime.now(tz=timezone.utc).strftime("%Y/%m/%d")
        s3_key      = f"raw/email/{date_prefix}/{uuid.uuid4().hex}_{filename}"

        s3.put_object(
            Bucket      = S3_BUCKET,
            Key         = s3_key,
            Body        = payload,
            ContentType = content_type,
        )

        logger.info(f"Deposited attachment to s3://{S3_BUCKET}/{s3_key}")
        attachments_saved += 1

    if attachments_saved == 0:
        logger.warning(f"No valid DMARC attachments found in message {message_id}")


def get_extension(filename: str) -> str:
    lower = filename.lower()
    for ext in ALLOWED_EXTENSIONS:
        if lower.endswith(ext):
            return ext
    return ""
