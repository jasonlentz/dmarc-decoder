"""
DMARC Decoder — Query Handler

Serves reporting queries from the frontend dashboard.
Runs parameterized SQL against Aurora Serverless v2 via the Data API.

Routes (dispatched by report_type path parameter):
  summary          — overall pass/fail totals
  top-ips          — top sending IPs by volume
  trend            — daily pass/fail trend
  disposition      — breakdown by disposition
  failure-detail   — records where DKIM or SPF failed
  reports          — list of all reports received (with per-report DKIM/SPF counts)
  report-detail    — all records for a specific report_id
  policy-readiness — pass rates + recommendation for tightening policy
"""

import boto3
import json
import logging
import os

logger = logging.getLogger()
logger.setLevel(logging.INFO)

rds = boto3.client("rds-data", region_name=os.environ["AWS_REGION"])

CLUSTER_ARN = os.environ["AURORA_CLUSTER_ARN"]
SECRET_ARN  = os.environ["AURORA_SECRET_ARN"]
DB_NAME     = os.environ["DB_NAME"]


# -------------------------------------------------------
# Entry point
# -------------------------------------------------------
def lambda_handler(event, context):
    report_type = (event.get("pathParameters") or {}).get("report_type", "")
    params      = event.get("queryStringParameters") or {}

    handlers = {
        "summary":          query_summary,
        "top-ips":          query_top_ips,
        "trend":            query_trend,
        "disposition":      query_disposition,
        "failure-detail":   query_failure_detail,
        "reports":          query_reports,
        "report-detail":    query_report_detail,
        "policy-readiness": query_policy_readiness,
    }

    handler_fn = handlers.get(report_type)
    if not handler_fn:
        return response(400, {"error": f"Unknown report type: {report_type}"})

    try:
        data = handler_fn(params)
        return response(200, data)
    except Exception as e:
        logger.error(f"Query failed [{report_type}]: {e}", exc_info=True)
        return response(500, {"error": "Query failed — database may be warming up, please retry in a moment"})


# -------------------------------------------------------
# Query definitions
# -------------------------------------------------------
def query_summary(params: dict) -> dict:
    """Overall pass/fail summary across all reports."""
    rows = execute("""
        SELECT
            COUNT(DISTINCT r.report_id)                                       AS total_reports,
            SUM(rec.message_count)                                            AS total_messages,
            SUM(CASE WHEN rec.dkim_result = 'pass' OR rec.spf_result = 'pass'
                     THEN rec.message_count ELSE 0 END)                       AS passed,
            SUM(CASE WHEN rec.disposition != 'none'
                     THEN rec.message_count ELSE 0 END)                       AS failed,
            COUNT(DISTINCT rec.source_ip)                                     AS unique_ips,
            COUNT(DISTINCT r.domain)                                          AS domains
        FROM reports r
        JOIN records rec ON r.report_id = rec.report_id
    """, [])

    return {"summary": rows[0] if rows else {}}


def query_top_ips(params: dict) -> dict:
    """Top sending IPs by message volume."""
    limit = min(int(params.get("limit", 20)), 100)

    rows = execute("""
        SELECT
            rec.source_ip,
            SUM(rec.message_count)                                            AS total_messages,
            SUM(CASE WHEN rec.dkim_result = 'pass'
                     THEN rec.message_count ELSE 0 END)                       AS dkim_pass,
            SUM(CASE WHEN rec.spf_result = 'pass'
                     THEN rec.message_count ELSE 0 END)                       AS spf_pass,
            SUM(CASE WHEN rec.disposition != 'none'
                     THEN rec.message_count ELSE 0 END)                       AS failed,
            COUNT(DISTINCT rec.report_id)                                     AS report_count
        FROM records rec
        GROUP BY rec.source_ip
        ORDER BY total_messages DESC
        LIMIT :limit
    """, [
        {"name": "limit", "value": {"longValue": limit}}
    ])

    return {"top_ips": rows}


def query_trend(params: dict) -> dict:
    """Daily message volume trend — pass vs fail."""
    days = min(int(params.get("days", 30)), 365)

    rows = execute("""
        SELECT
            DATE_TRUNC('day', r.report_begin)                                 AS day,
            SUM(rec.message_count)                                            AS total_messages,
            SUM(CASE WHEN rec.disposition = 'none'
                     THEN rec.message_count ELSE 0 END)                       AS passed,
            SUM(CASE WHEN rec.disposition != 'none'
                     THEN rec.message_count ELSE 0 END)                       AS failed
        FROM reports r
        JOIN records rec ON r.report_id = rec.report_id
        WHERE r.report_begin >= NOW() - (:days * INTERVAL '1 day')
        GROUP BY DATE_TRUNC('day', r.report_begin)
        ORDER BY day ASC
    """, [
        {"name": "days", "value": {"longValue": days}}
    ])

    return {"trend": rows, "days": days}


def query_disposition(params: dict) -> dict:
    """Breakdown by disposition: none / quarantine / reject."""
    rows = execute("""
        SELECT
            rec.disposition,
            SUM(rec.message_count) AS message_count
        FROM records rec
        GROUP BY rec.disposition
        ORDER BY message_count DESC
    """, [])

    return {"disposition": rows}


def query_failure_detail(params: dict) -> dict:
    """Records where DKIM or SPF failed — for investigation."""
    limit = min(int(params.get("limit", 50)), 200)

    rows = execute("""
        SELECT
            r.domain,
            r.org_name,
            r.report_begin,
            rec.source_ip,
            rec.message_count,
            rec.disposition,
            rec.dkim_result,
            rec.spf_result,
            rec.dkim_domain,
            rec.spf_domain,
            rec.header_from,
            rec.override_reason,
            rec.override_comment
        FROM reports r
        JOIN records rec ON r.report_id = rec.report_id
        WHERE rec.dkim_result != 'pass'
           OR rec.spf_result  != 'pass'
        ORDER BY r.report_begin DESC, rec.message_count DESC
        LIMIT :limit
    """, [
        {"name": "limit", "value": {"longValue": limit}}
    ])

    return {"failures": rows}


def query_reports(params: dict) -> dict:
    """List of all reports, with per-report DKIM/SPF pass/fail counts."""
    limit = min(int(params.get("limit", 50)), 200)

    rows = execute("""
        SELECT
            r.report_id,
            r.org_name,
            r.domain,
            r.report_begin,
            r.report_end,
            r.policy_p,
            r.ingestion_path,
            COUNT(rec.id)                                                         AS record_count,
            SUM(rec.message_count)                                                AS total_messages,
            SUM(CASE WHEN rec.dkim_result = 'pass'
                     THEN rec.message_count ELSE 0 END)                           AS dkim_pass,
            SUM(CASE WHEN rec.spf_result = 'pass'
                     THEN rec.message_count ELSE 0 END)                           AS spf_pass,
            SUM(CASE WHEN rec.dkim_result != 'pass' AND rec.spf_result != 'pass'
                     THEN rec.message_count ELSE 0 END)                           AS both_fail,
            SUM(CASE WHEN rec.dkim_result = 'pass' AND rec.spf_result != 'pass'
                     THEN rec.message_count ELSE 0 END)                           AS dkim_only_pass,
            r.created_at
        FROM reports r
        JOIN records rec ON r.report_id = rec.report_id
        GROUP BY
            r.report_id, r.org_name, r.domain,
            r.report_begin, r.report_end, r.policy_p,
            r.ingestion_path, r.created_at
        ORDER BY r.report_begin DESC
        LIMIT :limit
    """, [
        {"name": "limit", "value": {"longValue": limit}}
    ])

    return {"reports": rows}


def query_report_detail(params: dict) -> dict:
    """All records for a specific report — source IPs, DKIM/SPF results, disposition."""
    report_id = params.get("report_id", "")
    if not report_id:
        return {"error": "report_id parameter required"}

    meta = execute("""
        SELECT report_id, org_name, domain, report_begin, report_end,
               policy_p, adkim, aspf, ingestion_path
        FROM reports
        WHERE report_id = :report_id
    """, [
        {"name": "report_id", "value": {"stringValue": report_id}}
    ])

    records = execute("""
        SELECT
            source_ip,
            message_count,
            disposition,
            dkim_result,
            spf_result,
            dkim_domain,
            dkim_selector,
            spf_domain,
            header_from,
            envelope_from,
            envelope_to,
            override_reason,
            override_comment
        FROM records
        WHERE report_id = :report_id
        ORDER BY message_count DESC
    """, [
        {"name": "report_id", "value": {"stringValue": report_id}}
    ])

    return {
        "report":  meta[0] if meta else {},
        "records": records,
    }


def query_policy_readiness(params: dict) -> dict:
    """Pass rates over 7 and 30 days with a recommendation for tightening policy."""

    def pass_rate(days: int):
        rows = execute("""
            SELECT
                SUM(rec.message_count) AS total,
                SUM(CASE WHEN rec.dkim_result = 'pass' OR rec.spf_result = 'pass'
                         THEN rec.message_count ELSE 0 END) AS passed
            FROM reports r
            JOIN records rec ON r.report_id = rec.report_id
            WHERE r.report_begin >= NOW() - (:days * INTERVAL '1 day')
        """, [
            {"name": "days", "value": {"longValue": days}}
        ])
        if not rows:
            return None, None
        total  = rows[0].get("total")  or 0
        passed = rows[0].get("passed") or 0
        if total == 0:
            return None, None
        return round(passed / total * 100, 1), int(total)

    rate_7d,  msgs_7d  = pass_rate(7)
    rate_30d, msgs_30d = pass_rate(30)

    policy_rows = execute("""
        SELECT policy_p FROM reports ORDER BY report_begin DESC LIMIT 1
    """, [])
    current_policy = policy_rows[0].get("policy_p") if policy_rows else "none"

    if rate_7d is None:
        recommendation = "no_data"
        message = "Not enough recent data to make a recommendation."
    elif rate_7d >= 98 and (rate_30d is None or rate_30d >= 95):
        recommendation = "tighten"
        message = f"{rate_7d}% pass rate over 7 days. Ready to move to p=reject."
    elif rate_7d >= 90:
        recommendation = "monitor"
        message = f"{rate_7d}% pass rate over 7 days. Keep monitoring before tightening."
    else:
        recommendation = "investigate"
        message = f"{rate_7d}% pass rate over 7 days. Investigate failures before tightening."

    return {
        "current_policy": current_policy,
        "pass_rate_7d":   rate_7d,
        "pass_rate_30d":  rate_30d,
        "messages_7d":    msgs_7d,
        "messages_30d":   msgs_30d,
        "recommendation": recommendation,
        "message":        message,
    }


# -------------------------------------------------------
# Aurora Data API helpers
# -------------------------------------------------------
def execute(sql: str, params: list) -> list:
    result = rds.execute_statement(
        resourceArn           = CLUSTER_ARN,
        secretArn             = SECRET_ARN,
        database              = DB_NAME,
        sql                   = sql,
        parameters            = params,
        includeResultMetadata = True,
    )
    return format_results(result)


def format_results(result: dict) -> list:
    """Convert Aurora Data API response into a list of plain dicts."""
    cols = [c["name"] for c in result.get("columnMetadata", [])]
    rows = []
    for row in result.get("records", []):
        record = {}
        for col, cell in zip(cols, row):
            if cell.get("isNull"):
                record[col] = None
            else:
                record[col] = list(cell.values())[0]
        rows.append(record)
    return rows


def response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {
            "Content-Type":                "application/json",
            "Access-Control-Allow-Origin": "*",
        },
        "body": json.dumps(body, default=str),
    }
