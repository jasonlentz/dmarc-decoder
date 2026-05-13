#!/usr/bin/env bash
# =============================================================================
# DMARC Decoder — Destroy Script
# Tears down all AWS infrastructure created by deploy.sh.
# Run from the repo root: ./scripts/destroy.sh
#
# WARNING: This will permanently delete all DMARC report data in Aurora.
# Raw report files in S3 are preserved unless s3_force_destroy = true
# in terraform.tfvars.
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
INFRA_DIR="$ROOT_DIR/infrastructure"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
AMBER='\033[0;33m'
DIM='\033[2m'
RESET='\033[0m'

info() { echo -e "  ${DIM}$1${RESET}"; }
ok()   { echo -e "  ${GREEN}✓${RESET} $1"; }
warn() { echo -e "  ${AMBER}⚠${RESET}  $1"; }
fail() { echo -e "  ${RED}✗ $1${RESET}"; exit 1; }

LOG_FILE=$(mktemp /tmp/dmarc-destroy-XXXXXX)

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

tf_fail() {
  echo ""
  echo -e "  ${RED}── Error ──────────────────────────────────────────${RESET}"
  grep -A 8 "^│ Error\|^Error:" "$LOG_FILE" 2>/dev/null | head -40 \
    || tail -20 "$LOG_FILE"
  echo ""
  info "Full log: $LOG_FILE"
  fail "$1"
}

# =============================================================================
# Pre-flight checks
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  DMARC Decoder — Destroy"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

for cmd in terraform aws; do
  if ! command -v "$cmd" &>/dev/null; then
    fail "$cmd is not installed or not in PATH"
  fi
done

if [ ! -f "$INFRA_DIR/terraform.tfvars" ]; then
  fail "infrastructure/terraform.tfvars not found — nothing to destroy"
fi

if [ ! -d "$INFRA_DIR/.terraform" ]; then
  fail ".terraform directory not found — has terraform init been run? Nothing to destroy."
fi

# =============================================================================
# Confirm intent
# =============================================================================
warn "This will permanently destroy all AWS resources for DMARC Decoder:"
echo ""
echo "    • Aurora Serverless v2 cluster and all report data"
echo "    • All Lambda functions"
echo "    • API Gateway"
echo "    • Secrets Manager secret"
echo "    • CloudWatch log groups"
echo ""

FORCE_DESTROY=$(grep 's3_force_destroy' "$INFRA_DIR/terraform.tfvars" 2>/dev/null | grep -i 'true' || true)
if [ -n "$FORCE_DESTROY" ]; then
  warn "s3_force_destroy = true — the S3 bucket and ALL raw report files will also be deleted."
else
  warn "s3_force_destroy = false — the S3 bucket will be preserved if it contains data."
  info "Set s3_force_destroy = true in terraform.tfvars for a complete teardown."
fi

echo ""
read -r -p "  Type 'destroy' to confirm: " CONFIRM
echo ""

if [ "$CONFIRM" != "destroy" ]; then
  echo "  Aborted — nothing was destroyed."
  echo ""
  exit 0
fi

# =============================================================================
# Terraform destroy
# =============================================================================
echo ""
info "Teardown typically takes 5-10 minutes."
cd "$INFRA_DIR"
terraform destroy -auto-approve > "$LOG_FILE" 2>&1 &
DESTROY_PID=$!
show_progress "$DESTROY_PID" "Destroying infrastructure..."
set +e; wait "$DESTROY_PID"; DESTROY_EXIT=$?; set -e
[ $DESTROY_EXIT -ne 0 ] && tf_fail "terraform destroy failed"

SUMMARY=$(grep -E "^Destroy complete!" "$LOG_FILE" | tail -1)
ok "Infrastructure destroyed${SUMMARY:+ — ${SUMMARY}}"
rm -f "$LOG_FILE"

# =============================================================================
# Clean up generated local files
# =============================================================================
FRONTEND_CONFIG="$ROOT_DIR/frontend/config.js"
if [ -f "$FRONTEND_CONFIG" ]; then
  rm "$FRONTEND_CONFIG"
  ok "Removed frontend/config.js"
fi

# =============================================================================
# Summary
# =============================================================================
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  Destroy complete"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

if [ -z "$FORCE_DESTROY" ]; then
  info "Raw report files in S3 were preserved."
  info "To delete them: set s3_force_destroy = true and re-run destroy.sh,"
  info "or delete the bucket manually: aws s3 rb s3://BUCKET-NAME --force"
fi

echo ""
