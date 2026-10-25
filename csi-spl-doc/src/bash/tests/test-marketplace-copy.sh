#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: Verify Google Cloud Marketplace listing details and deployer guide
#          (Spec 156 GAP-07 and GAP-09).
#          Checks:
#          1. Required files exist on disk
#          2. Listing details required sections, title, tagline, descriptions
#          3. Category IDs (maximum 2, valid GCP Marketplace category IDs)
#          4. Keyword formatting (valid comma-separated tokens)
#          5. EULA and open-source license compliance links
#          6. Pricing model ($0 / Free) and tax category
#          7. Deployer infrastructure cost disclosures (e2-standard-2, e2-medium)
#          8. Deployer guide required sections, architecture, and runbooks
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

LISTING_FILE="$REPO_ROOT/csi-spl-doc/doc/marketplace/listing-details.md"
GUIDE_FILE="$REPO_ROOT/csi-spl-doc/doc/md/marketplace-deployer-guide.md"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

# Check that required files exist
check_files_exist() {
  if [[ -f "$LISTING_FILE" && -s "$LISTING_FILE" ]]; then
    pass "listing-details.md exists and is non-empty"
  else
    fail "listing-details.md exists and is non-empty" "Missing or empty: $LISTING_FILE"
  fi

  if [[ -f "$GUIDE_FILE" && -s "$GUIDE_FILE" ]]; then
    pass "marketplace-deployer-guide.md exists on disk and is non-empty"
  else
    fail "marketplace-deployer-guide.md exists on disk and is non-empty" "Missing or empty: $GUIDE_FILE"
  fi
}

# Check listing metadata: title, tagline, descriptions
check_listing_metadata() {
  local title tagline short_desc
  title=$(grep -E '^\- \*\*Product Title\*\*:' "$LISTING_FILE" | sed -E 's/^- \*\*Product Title\*\*:[[:space:]]*//')
  tagline=$(grep -E '^\- \*\*Tagline\*\*:' "$LISTING_FILE" | sed -E 's/^- \*\*Tagline\*\*:[[:space:]]*//')
  short_desc=$(grep -E '^\- \*\*Short Description\*\*:' "$LISTING_FILE" || true)

  if [[ -n "$title" && "$title" =~ Spool\ Hub ]]; then
    pass "Product title is present and valid ('$title')"
  else
    fail "Product title is present and valid" "Got: '$title'"
  fi

  if [[ -n "$tagline" ]]; then
    pass "Tagline is present"
  else
    fail "Tagline is present" "Tagline missing in $LISTING_FILE"
  fi

  if [[ -n "$short_desc" ]]; then
    pass "Short description is present"
  else
    fail "Short description is present" "Short description missing in $LISTING_FILE"
  fi
}

# Check Category IDs: up to 2, standard taxonomy IDs
check_category_ids() {
  local cat_lines count
  # shellcheck disable=SC2016 # pattern matches markdown backticks literally
  cat_lines=$(sed -n '/### 2.1 Category IDs/,/### 2.2 Search Keywords/p' "$LISTING_FILE" | grep -E '^[0-9]+\.\s+`[a-z0-9-]+`' || true)
  count=$(echo "$cat_lines" | grep -c '`' || true)

  if [[ "$count" -ge 1 && "$count" -le 2 ]]; then
    pass "Category IDs count is within limits (1 to 2, found $count)"
  else
    fail "Category IDs count is within limits (1 to 2)" "Found $count Category IDs"
  fi

  # shellcheck disable=SC2016 # matching backtick literals
  if grep -q '`developer-tools`' <<<"$cat_lines" && grep -q '`infrastructure-software`' <<<"$cat_lines"; then
    pass "Category IDs contain developer-tools and infrastructure-software"
  else
    fail "Category IDs contain valid categories" "Categories found: $cat_lines"
  fi
}

# Check search keyword formatting
check_keywords() {
  local kw_line
  # shellcheck disable=SC2016 # pattern matches markdown backticks literally
  kw_line=$(sed -n '/### 2.2 Search Keywords/,/## 3/p' "$LISTING_FILE" | grep -E '^`[a-z0-9, .-]+`' | tr -d '`' || true)

  if [[ -z "$kw_line" ]]; then
    fail "Search keywords line is present" "No keyword line found"
    return
  fi

  local bad_kw=0 kw_count=0
  IFS=',' read -ra kws <<<"$kw_line"
  for kw in "${kws[@]}"; do
    local trimmed
    trimmed=$(echo "$kw" | xargs)
    [[ -z "$trimmed" ]] && continue
    kw_count=$((kw_count + 1))
    if [[ ! "$trimmed" =~ ^[a-z0-9][a-z0-9.-]*$ ]]; then
      bad_kw=$((bad_kw + 1))
    fi
  done

  if [[ "$kw_count" -ge 5 && "$bad_kw" -eq 0 ]]; then
    pass "Search keywords are properly formatted ($kw_count valid keywords)"
  else
    fail "Search keywords formatting" "Total: $kw_count, Invalid: $bad_kw (line: $kw_line)"
  fi
}

# Check EULA link and open-source license compliance
check_licensing_and_eula() {
  local eula_url
  eula_url=$(grep -E '^\- \*\*End User License Agreement \(EULA\) URL\*\*:' "$LISTING_FILE" | sed -E 's/^- \*\*End User License Agreement \(EULA\) URL\*\*:[[:space:]]*//')

  if [[ -n "$eula_url" && "$eula_url" =~ ^https://github\.com/csitea/csi-spl/blob/master/LICENSE ]]; then
    pass "EULA URL points to repository LICENSE ($eula_url)"
  else
    fail "EULA URL points to repository LICENSE" "Got: '$eula_url'"
  fi

  if grep -qi 'AGPL-3.0' "$LISTING_FILE" && grep -qi 'Affero General Public License' "$LISTING_FILE"; then
    pass "AGPL-3.0 license is explicitly cited in listing details"
  else
    fail "AGPL-3.0 license cited in listing details" "AGPL-3.0 citation missing"
  fi

  if grep -q '/usr/local/share/doc/spool-hub/' "$LISTING_FILE"; then
    pass "Image copyleft source location documented (/usr/local/share/doc/spool-hub/)"
  else
    fail "Image copyleft source location documented" "Missing /usr/local/share/doc/spool-hub/"
  fi
}

# Check pricing model and infrastructure cost disclosures
check_pricing_and_costs() {
  if grep -E '^\- \*\*Pricing Model\*\*:\s*Free' "$LISTING_FILE" >/dev/null; then
    pass "Pricing model is Free (\$0 software fee)"
  else
    fail "Pricing model is Free (\$0 software fee)" "Pricing model not Free"
  fi

  if grep -E '^\- \*\*Tax Category\*\*:' "$LISTING_FILE" >/dev/null; then
    pass "Tax Category is declared in listing details"
  else
    fail "Tax Category is declared in listing details" "Tax Category missing"
  fi

  if grep -q 'e2-standard-2' "$LISTING_FILE" && grep -q 'e2-medium' "$LISTING_FILE"; then
    pass "Deployer infrastructure sizing options (e2-standard-2, e2-medium) are disclosed"
  else
    fail "Deployer infrastructure sizing options disclosed" "Missing e2-standard-2 or e2-medium"
  fi
}

# Check deployer guide contents on disk (GAP-09)
check_deployer_guide() {
  if grep -qi 'Overview & Architecture' "$GUIDE_FILE" && \
     grep -q 'Docker Compose' "$GUIDE_FILE" && \
     grep -q 'spool-hub.service' "$GUIDE_FILE"; then
    pass "Deployer guide architecture and Compose stack documented"
  else
    fail "Deployer guide architecture documented" "Missing architecture details in $GUIDE_FILE"
  fi

  if grep -q 'compute.googleapis.com' "$GUIDE_FILE" && \
     grep -q 'e2-standard-2' "$GUIDE_FILE"; then
    pass "Deployer guide prerequisites and machine sizing documented"
  else
    fail "Deployer guide prerequisites documented" "Missing prerequisites in $GUIDE_FILE"
  fi

  if grep -q 'systemctl status spool-hub' "$GUIDE_FILE" && \
     grep -q 'docker compose .* ps' "$GUIDE_FILE"; then
    pass "Deployer guide operations and management runbook commands documented"
  else
    fail "Deployer guide operations runbook commands documented" "Missing commands in $GUIDE_FILE"
  fi

  if grep -q 'https://github.com/csitea/csi-spl/blob/master/LICENSE' "$GUIDE_FILE" && \
     grep -q '/usr/local/share/doc/spool-hub/' "$GUIDE_FILE"; then
    pass "Deployer guide EULA and copyleft compliance documented"
  else
    fail "Deployer guide EULA and copyleft compliance documented" "Missing EULA or copyleft details"
  fi
}

main() {
  check_files_exist
  check_listing_metadata
  check_category_ids
  check_keywords
  check_licensing_and_eula
  check_pricing_and_costs
  check_deployer_guide

  echo "=========================================="
  if [[ "$fails" -eq 0 ]]; then
    echo "Marketplace copy tests PASSED (all checks green)"
    return 0
  else
    echo "Marketplace copy tests FAILED ($fails failure(s))"
    return 1
  fi
}

main "$@"
