"""
DMARC Decoder — Parser Lambda
Triggered by S3 ObjectCreated events on the raw/ prefix.
Handles XML, ZIP, and GZIP compressed DMARC aggregate reports.
Writes structured records to Aurora via the Data API.
"""

import boto3
import gzip
import io
import json
import logging
import os
import urllib.parse
import zipfile
import xml.etree.ElementTree as ET
from datetime import datetime, timezone

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3      = boto3.client("s3")
rds     = boto3.client("rds-data", region_name=os.environ["AWS_REGION"])

CLUSTER_ARN = os.environ["AURORA_CLUSTER_ARN"]
SECRET_ARN  = os.environ["AURORA_SECRET_ARN"]
DB_NAME     = os.environ["DB_NAME"]
S3_BUCKET   = os.environ["S3_BUCKET"]

MAX_PAYLOAD_BYTES = 10 * 1024 * 1024  # 10MB hard limit


# -------------------------------------------------------
# Entry point
# -------------------------------------------------------
def lambda_handler(event, context):
    for record in event.get("Records", []):
        bucket = record["s3"]["bucket"]["name"]
        key    = urllib.parse.unquote_plus(record["s3"]["object"]["key"])

        logger.info(f"Processing s3://{bucket}/{key}")

        try:
            process_report(bucket, key)
        except Exception as e:
            logger.error(f"Failed to process {key}: {e}", exc_info=True)
            raise

    return {"statusCode": 200, "body": "OK"}


# -------------------------------------------------------
# Fetch and decompress
# -------------------------------------------------------
def process_report(bucket: str, key: str):
    obj      = s3.get_object(Bucket=bucket, Key=key)
    raw      = obj["Body"].read()
    size     = len(raw)

    if size > MAX_PAYLOAD_BYTES:
        raise ValueError(f"Payload too large: {size} bytes")

    xml_data = decompress(key, raw)
    parsed   = parse_dmarc_xml(xml_data)

    ingestion_path = "email" if key.startswith("raw/email/") else "web"
    write_to_aurora(parsed, key, ingestion_path)
    logger.info(f"Stored report {parsed['report_metadata']['report_id']}")


def decompress(key: str, data: bytes) -> str:
    lower = key.lower()

    if lower.endswith(".gz") or lower.endswith(".gzip"):
        return gzip.decompress(data).decode("utf-8")

    if lower.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            for name in zf.namelist():
                if name.lower().endswith(".xml"):
                    return zf.read(name).decode("utf-8")
            raise ValueError(f"No XML found inside ZIP: {key}")

    if lower.endswith(".xml"):
        return data.decode("utf-8")

    # Try sniffing magic bytes
    if data[:2] == b"\x1f\x8b":
        return gzip.decompress(data).decode("utf-8")
    if data[:4] == b"PK\x03\x04":
        return decompress(key + ".zip", data)

    # Assume raw XML
    return data.decode("utf-8")


# -------------------------------------------------------
# XML parsing
# -------------------------------------------------------
def parse_dmarc_xml(xml_str: str) -> dict:
    root = ET.fromstring(xml_str)

    # Report metadata
    meta     = root.find("report_metadata")
    policy   = root.find("policy_published")

    begin_ts = int(meta.findtext("date_range/begin", 0))
    end_ts   = int(meta.findtext("date_range/end",   0))

    report = {
        "report_metadata": {
            "report_id":  meta.findtext("report_id", ""),
            "org_name":   meta.findtext("org_name",  ""),
            "email":      meta.findtext("email",     ""),
            "begin":      datetime.fromtimestamp(begin_ts, tz=timezone.utc).isoformat(),
            "end":        datetime.fromtimestamp(end_ts,   tz=timezone.utc).isoformat(),
        },
        "policy_published": {
            "domain":  policy.findtext("domain",  "") if policy is not None else "",
            "adkim":   policy.findtext("adkim",   "r") if policy is not None else "r",
            "aspf":    policy.findtext("aspf",    "r") if policy is not None else "r",
            "p":       policy.findtext("p",       "none") if policy is not None else "none",
            "sp":      policy.findtext("sp",      "none") if policy is not None else "none",
            "pct":     int(policy.findtext("pct", "100") if policy is not None else "100"),
        },
        "records": []
    }

    for rec in root.findall("record"):
        row_elem   = rec.find("row")
        auth_elem  = rec.find("auth_results")
        ids_elem   = rec.find("identifiers")

        dkim_elem  = auth_elem.find("dkim")  if auth_elem is not None else None
        spf_elem   = auth_elem.find("spf")   if auth_elem is not None else None

        reasons         = row_elem.findall("policy_evaluated/reason") if row_elem else []
        override_reason  = ",".join(filter(None, (r.findtext("type",    "") for r in reasons)))
        override_comment = ";".join(filter(None, (r.findtext("comment", "") for r in reasons)))

        record = {
            "source_ip":       row_elem.findtext("source_ip",        "") if row_elem else "",
            "message_count":   int(row_elem.findtext("count",        "0") if row_elem else 0),
            "disposition":     row_elem.findtext("policy_evaluated/disposition", "none") if row_elem else "none",
            "dkim_result":     row_elem.findtext("policy_evaluated/dkim", "none") if row_elem else "none",
            "spf_result":      row_elem.findtext("policy_evaluated/spf",  "none") if row_elem else "none",
            "override_reason":  override_reason,
            "override_comment": override_comment,
            "dkim_auth_domain":    dkim_elem.findtext("domain",   "") if dkim_elem is not None else "",
            "dkim_auth_result":    dkim_elem.findtext("result",   "") if dkim_elem is not None else "",
            "dkim_selector":       dkim_elem.findtext("selector", "") if dkim_elem is not None else "",
            "spf_auth_domain":     spf_elem.findtext("domain",   "") if spf_elem is not None else "",
            "spf_auth_result":     spf_elem.findtext("result",   "") if spf_elem is not None else "",
            "header_from":    ids_elem.findtext("header_from",   "") if ids_elem is not None else "",
            "envelope_from":  ids_elem.findtext("envelope_from", "") if ids_elem is not None else "",
            "envelope_to":    ids_elem.findtext("envelope_to",   "") if ids_elem is not None else "",
        }
        report["records"].append(record)

    return report


# -------------------------------------------------------
# Aurora Data API writes
# -------------------------------------------------------
def execute_statement(sql: str, params: list):
    return rds.execute_statement(
        resourceArn = CLUSTER_ARN,
        secretArn   = SECRET_ARN,
        database    = DB_NAME,
        sql         = sql,
        parameters  = params,
    )


def write_to_aurora(parsed: dict, s3_key: str, ingestion_path: str):
    meta   = parsed["report_metadata"]
    policy = parsed["policy_published"]

    # Upsert report — skip if report_id already exists
    execute_statement(
        """
        INSERT INTO reports (
            report_id, org_name, email, report_begin, report_end,
            domain, adkim, aspf, policy_p, policy_sp, policy_pct,
            source_path, ingestion_path
        ) VALUES (
            :report_id, :org_name, :email, :report_begin::timestamp, :report_end::timestamp,
            :domain, :adkim, :aspf, :policy_p, :policy_sp, :policy_pct,
            :source_path, :ingestion_path
        )
        ON CONFLICT (report_id) DO NOTHING
        """,
        [
            {"name": "report_id",       "value": {"stringValue":  meta["report_id"]}},
            {"name": "org_name",        "value": {"stringValue":  meta["org_name"]}},
            {"name": "email",           "value": {"stringValue":  meta["email"]}},
            {"name": "report_begin",    "value": {"stringValue":  meta["begin"]}},
            {"name": "report_end",      "value": {"stringValue":  meta["end"]}},
            {"name": "domain",          "value": {"stringValue":  policy["domain"]}},
            {"name": "adkim",           "value": {"stringValue":  policy["adkim"]}},
            {"name": "aspf",            "value": {"stringValue":  policy["aspf"]}},
            {"name": "policy_p",        "value": {"stringValue":  policy["p"]}},
            {"name": "policy_sp",       "value": {"stringValue":  policy["sp"]}},
            {"name": "policy_pct",      "value": {"longValue":    policy["pct"]}},
            {"name": "source_path",     "value": {"stringValue":  s3_key}},
            {"name": "ingestion_path",  "value": {"stringValue":  ingestion_path}},
        ]
    )

    # Insert records
    for rec in parsed["records"]:
        execute_statement(
            """
            INSERT INTO records (
                report_id, source_ip, message_count, disposition,
                dkim_result, spf_result, dkim_domain, dkim_selector,
                spf_domain, header_from, envelope_from, envelope_to,
                override_reason, override_comment
            ) VALUES (
                :report_id, :source_ip, :message_count, :disposition,
                :dkim_result, :spf_result, :dkim_domain, :dkim_selector,
                :spf_domain, :header_from, :envelope_from, :envelope_to,
                :override_reason, :override_comment
            )
            """,
            [
                {"name": "report_id",      "value": {"stringValue": meta["report_id"]}},
                {"name": "source_ip",      "value": {"stringValue": rec["source_ip"]}},
                {"name": "message_count",  "value": {"longValue":   rec["message_count"]}},
                {"name": "disposition",    "value": {"stringValue": rec["disposition"]}},
                {"name": "dkim_result",    "value": {"stringValue": rec["dkim_result"]}},
                {"name": "spf_result",     "value": {"stringValue": rec["spf_result"]}},
                {"name": "dkim_domain",    "value": {"stringValue": rec["dkim_auth_domain"]}},
                {"name": "dkim_selector",  "value": {"stringValue": rec["dkim_selector"]}},
                {"name": "spf_domain",     "value": {"stringValue": rec["spf_auth_domain"]}},
                {"name": "header_from",    "value": {"stringValue": rec["header_from"]}},
                {"name": "envelope_from",    "value": {"stringValue": rec["envelope_from"]}},
                {"name": "envelope_to",      "value": {"stringValue": rec["envelope_to"]}},
                {"name": "override_reason",  "value": {"stringValue": rec["override_reason"]}},
                {"name": "override_comment", "value": {"stringValue": rec["override_comment"]}},
            ]
        )
