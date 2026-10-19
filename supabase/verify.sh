#!/usr/bin/env bash
# Open Ledger Verification Script
# Phase 3: Verify accounting integrity after db reset/seed
#
# Usage: ./supabase/verify.sh
#
# This script verifies:
# 1. Trial Balance is balanced (total debits = total credits)
# 2. Reversal pair (j0005 + j0006) nets to zero on each account

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo "========================================="
echo "Open Ledger Accounting Verification"
echo "========================================="
echo ""

# Check if psql is available
if ! command -v psql &> /dev/null; then
    echo -e "${RED}✗ psql command not found${NC}"
    echo "  Please install PostgreSQL client tools to run this verification."
    exit 1
fi

# Try to get database URL from Supabase CLI
if command -v /tmp/supabase &> /dev/null; then
    DB_URL=$(/tmp/supabase status --override-name workspace 2>/dev/null | grep "DB URL" | awk '{print $3}' || echo "")
fi

# Fallback to manual DB URL if not found
if [ -z "${DB_URL:-}" ]; then
    DB_URL="${DATABASE_URL:-postgres://postgres:postgres@localhost:54322/postgres}"
fi

echo "Database: ${DB_URL%%\?*}"
echo ""

# ============================================================================
# TEST 1: Trial Balance
# ============================================================================

echo "Test 1: Trial Balance"
echo "---------------------"

TB_RESULT=$(psql "$DB_URL" -t -A -c "
SELECT
  sum(debit_cents) as total_debit,
  sum(credit_cents) as total_credit,
  sum(debit_cents) - sum(credit_cents) as difference
FROM get_trial_balance('00000000-0000-0000-0000-000000000001', '2026-08-31');
")

TOTAL_DEBIT=$(echo "$TB_RESULT" | cut -d'|' -f1)
TOTAL_CREDIT=$(echo "$TB_RESULT" | cut -d'|' -f2)
DIFFERENCE=$(echo "$TB_RESULT" | cut -d'|' -f3)

echo "  Total Debits:  $(printf "%'14d" $TOTAL_DEBIT) cents"
echo "  Total Credits: $(printf "%'14d" $TOTAL_CREDIT) cents"
echo "  Difference:    $(printf "%'14d" $DIFFERENCE) cents"
echo ""

if [ "$DIFFERENCE" -eq 0 ]; then
    echo -e "  ${GREEN}✓ Trial Balance is balanced${NC}"
else
    echo -e "  ${RED}✗ Trial Balance is NOT balanced (difference: $DIFFERENCE cents)${NC}"
    exit 1
fi

echo ""

# ============================================================================
# TEST 2: Reversal Pair
# ============================================================================

echo "Test 2: Reversal Pair (j0005 + j0006)"
echo "--------------------------------------"

REVERSAL_CHECK=$(psql "$DB_URL" -t -A -c "
SELECT
  a.code,
  a.name,
  sum(jl.debit_cents) - sum(jl.credit_cents) as net_cents
FROM journal_lines jl
JOIN accounts a ON a.id = jl.account_id
WHERE jl.journal_id IN ('j0005', 'j0006')
GROUP BY a.code, a.name, a.id
ORDER BY a.code;
")

ALL_ZERO=true

if [ -z "$REVERSAL_CHECK" ]; then
    echo -e "  ${YELLOW}⚠ No reversal pair found${NC}"
    exit 1
fi

while IFS='|' read -r code name net; do
    printf "  %-6s %-30s %14d cents\n" "$code" "$name" "$net"
    if [ "$net" -ne 0 ]; then
        ALL_ZERO=false
    fi
done <<< "$REVERSAL_CHECK"

echo ""

if $ALL_ZERO; then
    echo -e "  ${GREEN}✓ Reversal pair nets to zero on all accounts${NC}"
else
    echo -e "  ${RED}✗ Reversal pair does NOT net to zero${NC}"
    exit 1
fi

echo ""

# ============================================================================
# TEST 3: Balance Sheet Balances
# ============================================================================

echo "Test 3: Balance Sheet"
echo "---------------------"

BS_RESULT=$(psql "$DB_URL" -t -A -c "
WITH bs AS (
  SELECT * FROM get_balance_sheet('00000000-0000-0000-0000-000000000001', '2026-08-31')
)
SELECT
  (SELECT sum(balance_cents) FROM bs WHERE section = 'Assets') as total_assets,
  (SELECT sum(balance_cents) FROM bs WHERE section = 'Liabilities') as total_liabilities,
  (SELECT sum(balance_cents) FROM bs WHERE section = 'Equity') as total_equity;
")

TOTAL_ASSETS=$(echo "$BS_RESULT" | cut -d'|' -f1)
TOTAL_LIABILITIES=$(echo "$BS_RESULT" | cut -d'|' -f2)
TOTAL_EQUITY=$(echo "$BS_RESULT" | cut -d'|' -f3)

LIAB_PLUS_EQUITY=$((TOTAL_LIABILITIES + TOTAL_EQUITY))
BS_DIFFERENCE=$((TOTAL_ASSETS - LIAB_PLUS_EQUITY))

echo "  Assets:                 $(printf "%'14d" $TOTAL_ASSETS) cents"
echo "  Liabilities:            $(printf "%'14d" $TOTAL_LIABILITIES) cents"
echo "  Equity:                 $(printf "%'14d" $TOTAL_EQUITY) cents"
echo "  Liabilities + Equity:   $(printf "%'14d" $LIAB_PLUS_EQUITY) cents"
echo "  Difference:             $(printf "%'14d" $BS_DIFFERENCE) cents"
echo ""

if [ "$BS_DIFFERENCE" -eq 0 ]; then
    echo -e "  ${GREEN}✓ Balance Sheet balances (Assets = Liabilities + Equity)${NC}"
else
    echo -e "  ${RED}✗ Balance Sheet does NOT balance (difference: $BS_DIFFERENCE cents)${NC}"
    exit 1
fi

echo ""

# ============================================================================
# SUMMARY
# ============================================================================

echo "========================================="
echo -e "${GREEN}✓ All accounting verifications passed${NC}"
echo "========================================="
