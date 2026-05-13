#!/usr/bin/env bash
# =============================================================================
# DMARC Decoder — Deploy Script
# Provisions all AWS infrastructure, initializes the database schema,
# writes the frontend config, and syncs the frontend to S3.
# Run from the repo root: ./scripts/deploy.sh
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$ROOT_DIR/infrastructure"
FRONTEND_DIR="$ROOT_DIR/frontend"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
AMBER='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

step() { echo -e "\n${GREEN}[$1/$TOTAL]${RESET} $2"; }
info() { echo -e "  ${DIM}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
fail() { echo -e "  ${RED}✗ $1${RESET}"; exit 1; }

TOTAL=5
LOG_FILE=$(mktemp /tmp/dmarc-deploy-XXXXXX)

# Show elapsed time while a background process runs.
# Usage: show_progress <pid> <message>
show_progress() {
  local pid=$1 msg=$2 elapsed=0
  printf "  ${DIM}%s${RESET}" "$msg"
  while kill -0 "$pid" 2>/dev/null; do
    sleep 5
    elapsed=$((elapsed + 5))
    printf "\r  ${DIM}%s — %ds${RESET}" "$msg" "$elapsed"
  done
  printf "\r%-72s\r" " "
}

# Extract and print the error block from the log, then exit.
tf_fail() {
  local msg="$1"
  echo ""
  echo -e "  ${RED}── Error ──────────────────────────────────────────${RESET}"
  grep -A 8 "^│ Error\|^Error:" "$LOG_FILE" 2>/dev/null | head -40 \
    || tail -20 "$LOG_FILE"
  echo ""
  info "Full log: $LOG_FILE"
  fail "$msg"
}

# =============================================================================
# Pre-flight checks
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DMARC Decoder — Deploy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

for cmd in terraform aws; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "$cmd is not installed or not in PATH — see README prerequisites"
  fi
done

if [ ! -f "$INFRA_DIR/terraform.tfvars" ]; then
  fail "infrastructure/terraform.tfvars not found.
       Copy infrastructure/terraform.tfvars.example to terraform.tfvars and fill in your values."
fi

# =============================================================================
# Step 1 — Terraform init + apply
# =============================================================================
step 1 "Provisioning infrastructure (Terraform)..."
info "This step can take 10-15 minutes, mostly spinning up the RDS Writer instance."
cd "$INFRA_DIR"

if [ ! -d ".terraform" ]; then
  terraform init -upgrade > "$LOG_FILE" 2>&1 &
  INIT_PID=$!
  show_progress "$INIT_PID" "Initializing Terraform providers..."
  set +e; wait "$INIT_PID"; INIT_EXIT=$?; set -e
  [ $INIT_EXIT -ne 0 ] && tf_fail "terraform init failed"
  ok "Providers initialized"
fi

terraform apply -auto-approve >> "$LOG_FILE" 2>&1 &
APPLY_PID=$!
show_progress "$APPLY_PID" "Applying infrastructure changes..."
set +e; wait "$APPLY_PID"; APPLY_EXIT=$?; set -e
[ $APPLY_EXIT -ne 0 ] && tf_fail "terraform apply failed"

SUMMARY=$(grep -E "^Apply complete!" "$LOG_FILE" | tail -1)
ok "Infrastructure provisioned${SUMMARY:+ — ${SUMMARY}}"
rm -f "$LOG_FILE"

# =============================================================================
# Step 2 — Extract Terraform outputs
# =============================================================================
step 2 "Extracting Terraform outputs..."

AURORA_CLUSTER_ARN=$(terraform output -raw aurora_cluster_arn)
AURORA_SECRET_ARN=$(terraform output -raw aurora_secret_arn)
API_URL=$(terraform output -raw api_gateway_url)
S3_BUCKET=$(terraform output -raw s3_bucket_name)
AWS_REGION=$(terraform output -raw aws_region 2>/dev/null) || fail "Could not read aws_region from Terraform outputs — has terraform apply been run?"
DB_NAME=$(terraform output -raw db_name)

info "Aurora cluster : $AURORA_CLUSTER_ARN"
info "API Gateway    : $API_URL"
info "S3 bucket      : $S3_BUCKET"
ok "Outputs extracted"

# =============================================================================
# Step 3 — Initialize database schema
# Each statement is executed individually — Aurora Data API does not
# support multiple statements in a single call.
# CREATE TABLE IF NOT EXISTS and CREATE OR REPLACE VIEW are idempotent —
# safe to run on every deploy.
# =============================================================================
step 3 "Initializing database schema..."

run_sql() {
  local label="$1"
  local sql="$2"
  aws rds-data execute-statement \
    --region        "$AWS_REGION" \
    --resource-arn  "$AURORA_CLUSTER_ARN" \
    --secret-arn    "$AURORA_SECRET_ARN" \
    --database      "$DB_NAME" \
    --sql           "$sql" \
    --output        text \
    --query         'numberOfRecordsUpdated' \
    > /dev/null 2>&1 || fail "Schema statement failed: $label"
  ok "$label"
}

info "Waiting for Aurora to accept connections..."
for i in $(seq 1 6); do
  if aws rds-data execute-statement \
      --region       "$AWS_REGION" \
      --resource-arn "$AURORA_CLUSTER_ARN" \
      --secret-arn   "$AURORA_SECRET_ARN" \
      --database     "$DB_NAME" \
      --sql          "SELECT 1" \
      --output       text \
      --query        'numberOfRecordsUpdated' \
      > /dev/null 2>&1; then
    ok "Aurora is ready"
    break
  fi
  if [ "$i" -eq 6 ]; then
    fail "Aurora did not become ready after 60 seconds. Try re-running deploy.sh."
  fi
  info "Not ready yet — retrying in 10 seconds... ($i/6)"
  sleep 10
done

run_sql "CREATE table: reports" \
"CREATE TABLE IF NOT EXISTS reports (
    id              SERIAL PRIMARY KEY,
    report_id       VARCHAR(255) UNIQUE NOT NULL,
    org_name        VARCHAR(255),
    email           VARCHAR(255),
    report_begin    TIMESTAMP NOT NULL,
    report_end      TIMESTAMP NOT NULL,
    domain          VARCHAR(255) NOT NULL,
    adkim           VARCHAR(10),
    aspf            VARCHAR(10),
    policy_p        VARCHAR(20),
    policy_sp       VARCHAR(20),
    policy_pct      INTEGER,
    source_path     VARCHAR(500),
    ingestion_path  VARCHAR(20),
    created_at      TIMESTAMP DEFAULT NOW()
)"

run_sql "CREATE index: idx_reports_domain"  "CREATE INDEX IF NOT EXISTS idx_reports_domain  ON reports(domain)"
run_sql "CREATE index: idx_reports_begin"   "CREATE INDEX IF NOT EXISTS idx_reports_begin   ON reports(report_begin)"
run_sql "CREATE index: idx_reports_org"     "CREATE INDEX IF NOT EXISTS idx_reports_org     ON reports(org_name)"

run_sql "CREATE table: records" \
"CREATE TABLE IF NOT EXISTS records (
    id              SERIAL PRIMARY KEY,
    report_id       VARCHAR(255) NOT NULL REFERENCES reports(report_id),
    source_ip       VARCHAR(45)  NOT NULL,
    message_count   INTEGER      NOT NULL DEFAULT 0,
    disposition     VARCHAR(20),
    dkim_result     VARCHAR(20),
    spf_result      VARCHAR(20),
    dkim_domain     VARCHAR(255),
    dkim_selector   VARCHAR(255),
    spf_domain      VARCHAR(255),
    header_from     VARCHAR(255),
    envelope_from   VARCHAR(255),
    envelope_to     VARCHAR(255),
    override_reason  VARCHAR(100),
    override_comment VARCHAR(500),
    created_at      TIMESTAMP DEFAULT NOW()
)"

run_sql "ALTER records: add override_reason"  "ALTER TABLE records ADD COLUMN IF NOT EXISTS override_reason  VARCHAR(100)"
run_sql "ALTER records: add override_comment" "ALTER TABLE records ADD COLUMN IF NOT EXISTS override_comment VARCHAR(500)"

run_sql "CREATE index: idx_records_report_id"   "CREATE INDEX IF NOT EXISTS idx_records_report_id   ON records(report_id)"
run_sql "CREATE index: idx_records_source_ip"   "CREATE INDEX IF NOT EXISTS idx_records_source_ip   ON records(source_ip)"
run_sql "CREATE index: idx_records_disposition" "CREATE INDEX IF NOT EXISTS idx_records_disposition ON records(disposition)"
run_sql "CREATE index: idx_records_dkim"        "CREATE INDEX IF NOT EXISTS idx_records_dkim        ON records(dkim_result)"
run_sql "CREATE index: idx_records_spf"         "CREATE INDEX IF NOT EXISTS idx_records_spf         ON records(spf_result)"

run_sql "CREATE view: v_dmarc_summary" \
"CREATE OR REPLACE VIEW v_dmarc_summary AS
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
JOIN records rec ON r.report_id = rec.report_id"

# =============================================================================
# Step 4 — Write frontend config
# =============================================================================
step 4 "Writing frontend config..."

cat > "$FRONTEND_DIR/config.js" <<EOF
// Auto-generated by deploy.sh — do not edit manually.
// This file is gitignored and overwritten on every deploy.
const CONFIG = {
  apiBaseUrl: "$API_URL",
};
EOF

ok "Written: frontend/config.js"

# =============================================================================
# Step 5 — Sync frontend to S3
# =============================================================================
step 5 "Syncing frontend to S3..."

aws s3 sync "$FRONTEND_DIR" "s3://$S3_BUCKET/frontend/" \
  --exclude "*.example" \
  --exclude "*.template.*" \
  --delete \
  --quiet \
  --region "$AWS_REGION"

ok "Frontend synced"

S3_URL="http://$S3_BUCKET.s3-website-${AWS_REGION}.amazonaws.com/frontend/"

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Deploy complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo -e "  Frontend : ${GREEN}$S3_URL${RESET}"
echo -e "  API      : ${GREEN}$API_URL${RESET}"
echo ""
echo -e "  ${DIM}Note: Aurora may take 20-40 seconds to warm up on first"
echo -e "  query if it has been idle. The frontend handles this gracefully.${RESET}"
echo ""
