-- DMARC Decoder — Aurora PostgreSQL Schema
-- Reference copy. Executed automatically by deploy.sh — do not run manually.
-- All statements use IF NOT EXISTS / CREATE OR REPLACE — safe to re-run.

-- -------------------------------------------------------
-- Reports table — one row per aggregate report received
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS reports (
    id              SERIAL PRIMARY KEY,
    report_id       VARCHAR(255) UNIQUE NOT NULL,
    org_name        VARCHAR(255),
    email           VARCHAR(255),
    report_begin    TIMESTAMP NOT NULL,
    report_end      TIMESTAMP NOT NULL,
    domain          VARCHAR(255) NOT NULL,
    adkim           VARCHAR(10),    -- alignment mode: r(elaxed) or s(trict)
    aspf            VARCHAR(10),    -- alignment mode: r(elaxed) or s(trict)
    policy_p        VARCHAR(20),    -- none | quarantine | reject
    policy_sp       VARCHAR(20),    -- subdomain policy
    policy_pct      INTEGER,        -- percentage
    source_path     VARCHAR(500),   -- S3 key of the raw report file
    ingestion_path  VARCHAR(20),    -- 'web' or 'email'
    created_at      TIMESTAMP DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_reports_domain  ON reports(domain);
CREATE INDEX IF NOT EXISTS idx_reports_begin   ON reports(report_begin);
CREATE INDEX IF NOT EXISTS idx_reports_org     ON reports(org_name);

-- -------------------------------------------------------
-- Records table — one row per source IP per report
-- -------------------------------------------------------
CREATE TABLE IF NOT EXISTS records (
    id              SERIAL PRIMARY KEY,
    report_id       VARCHAR(255) NOT NULL REFERENCES reports(report_id),
    source_ip       VARCHAR(45)  NOT NULL,  -- IPv4 and IPv6
    message_count   INTEGER      NOT NULL DEFAULT 0,
    disposition     VARCHAR(20),  -- none | quarantine | reject
    dkim_result     VARCHAR(20),  -- pass | fail | none | policy | neutral | temperror | permerror
    spf_result      VARCHAR(20),  -- pass | fail | none | neutral | softfail | temperror | permerror
    dkim_domain     VARCHAR(255),
    dkim_selector   VARCHAR(255),
    spf_domain      VARCHAR(255),
    header_from      VARCHAR(255),
    envelope_from    VARCHAR(255),
    envelope_to      VARCHAR(255),
    override_reason  VARCHAR(100),  -- policy_evaluated/reason/type (forwarded, mailing_list, etc.)
    override_comment VARCHAR(500),  -- policy_evaluated/reason/comment
    created_at       TIMESTAMP DEFAULT NOW()
);

ALTER TABLE records ADD COLUMN IF NOT EXISTS override_reason  VARCHAR(100);
ALTER TABLE records ADD COLUMN IF NOT EXISTS override_comment VARCHAR(500);

CREATE INDEX IF NOT EXISTS idx_records_report_id    ON records(report_id);
CREATE INDEX IF NOT EXISTS idx_records_source_ip    ON records(source_ip);
CREATE INDEX IF NOT EXISTS idx_records_disposition  ON records(disposition);
CREATE INDEX IF NOT EXISTS idx_records_dkim         ON records(dkim_result);
CREATE INDEX IF NOT EXISTS idx_records_spf          ON records(spf_result);

-- -------------------------------------------------------
-- Convenience view — joins reports + records for queries
-- -------------------------------------------------------
CREATE OR REPLACE VIEW v_dmarc_summary AS
SELECT
    r.domain,
    r.org_name,
    r.report_begin,
    r.report_end,
    r.policy_p,
    r.ingestion_path,
    rec.source_ip,
    rec.message_count,
    rec.disposition,
    rec.dkim_result,
    rec.spf_result,
    rec.dkim_domain,
    rec.spf_domain,
    r.report_id
FROM reports r
JOIN records rec ON r.report_id = rec.report_id;
