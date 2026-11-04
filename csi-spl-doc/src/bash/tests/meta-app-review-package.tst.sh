#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: Verify the Meta App Review submission package (spec 090 T038,
#          SPL-4805):
#          1. meta-app-review-submission.md exists and is non-empty.
#          2. Live vs not-built scope is stated (T035 and T037 live on prd;
#             T036 and T007/T008/T010/T012 marked not built).
#          3. All five required permissions (pages_show_list,
#             pages_read_engagement, pages_manage_posts, instagram_basic,
#             instagram_content_publish) have non-empty submission
#             justifications (>= 80 chars).
#          4. Test user, test Facebook Page, and linked Instagram setup plus
#             >= 5 numbered reviewer reproduction steps and the credential
#             security note are present and non-empty.
#          5. 2-minute video screencast script (Scenes 1..5 covering OAuth
#             login, Page connection, post queue, human approval, and live
#             publishing) is present and non-empty.
#          6. Owner checklist (record screencast, click Submit for Review) and
#             no literal host or plaintext credential rules hold.
#          7. Self-contained red controls prove each planted defect fails with
#             exit 1.
#------------------------------------------------------------------------------
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)
DEFAULT_DOC="$REPO_ROOT/csi-spl-doc/specs/090-marketing-automation/meta-app-review-submission.md"
DOC_FILE="${META_REVIEW_DOC:-$DEFAULT_DOC}"

PERMS=(
  pages_show_list
  pages_read_engagement
  pages_manage_posts
  instagram_basic
  instagram_content_publish
)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

# section_text <file> <heading-regex> <stop-regex>: prints lines between the two headings.
section_text() {
  awk -v start="$2" -v stop="$3" '
    $0 ~ start { flag = 1; next }
    flag && $0 ~ stop { exit }
    flag { print }
  ' "$1"
}

check_file_and_scope() {
  local f="$1"
  if [[ ! -f "$f" || ! -s "$f" ]]; then
    fail "meta-app-review-submission.md exists and is non-empty" "missing or empty: $f"
    return
  fi
  pass "meta-app-review-submission.md exists and is non-empty"

  local live_sec unbuilt_sec
  live_sec=$(section_text "$f" '^### 1\.1 Live on `prd`' '^### 1\.2 Not Built')
  unbuilt_sec=$(section_text "$f" '^### 1\.2 Not Built' '^## 2\.')

  if grep -q 'T035' <<<"$live_sec" && grep -q 'T037' <<<"$live_sec"; then
    pass "Section 1.1 describes live T035 and T037 on prd"
  else
    fail "Section 1.1 describes live T035 and T037 on prd" "T035 or T037 missing in Section 1.1"
  fi

  if grep -qi 'not built' <<<"$unbuilt_sec" && grep -q 'T036' <<<"$unbuilt_sec" && grep -q 'T007' <<<"$unbuilt_sec"; then
    pass "Section 1.2 marks T036 and T007/T008/T010/T012 as not built"
  else
    fail "Section 1.2 marks unbuilt tasks as not built" "missing not-built disclosure in Section 1.2"
  fi
}

check_permissions() {
  local f="$1" p block just len
  for p in "${PERMS[@]}"; do
    # shellcheck disable=SC2016 # matching literal markdown backticks around the permission name
    block=$(section_text "$f" "^### 2\\.[0-9]+ \`${p}\`" '^### 2\.[0-9]+ |^## 3\.')
    just=$(grep -E '^[[:space:]]*>[[:space:]]+[A-Za-z]' <<<"$block" | sed -E 's/^[[:space:]]*>[[:space:]]+//' | tr '\n' ' ')
    len=${#just}
    if (( len >= 80 )) && grep -q "$p" <<<"$just"; then
      pass "Permission justification for $p is present and non-empty (${len} chars)"
    else
      fail "Permission justification for $p is present and non-empty" "found ${len} chars for $p"
    fi
  done
}

check_test_user_and_security() {
  local f="$1" sec setup repro steps
  sec=$(section_text "$f" '^## 3\. Test User' '^## 4\.')
  setup=$(section_text "$f" '^### 3\.1 ' '^### 3\.2 ')
  repro=$(section_text "$f" '^### 3\.2 ' '^## 4\.')
  steps=$(grep -cE '^[0-9]+\.[[:space:]]+\*\*' <<<"$repro" || true)

  if grep -q '\[!CAUTION\]' <<<"$sec" && grep -qi 'never.*commit.*git' <<<"$sec" && grep -qi 'log' <<<"$sec"; then
    pass "Security note against committing or logging credentials is present"
  else
    fail "Security note against committing or logging credentials is present" "missing [!CAUTION] or git/log ban in Section 3"
  fi

  if grep -qi 'Test Facebook Page' <<<"$setup" && grep -qi 'Instagram Professional' <<<"$setup" && grep -q 'MANAGE' <<<"$setup"; then
    pass "Test user, test Facebook Page, and linked Instagram setup steps are present"
  else
    fail "Test user, test Facebook Page, and linked Instagram setup steps are present" "incomplete setup in Section 3.1"
  fi

  if (( steps >= 5 )) && grep -q '<TEST_USER_EMAIL>' <<<"$repro" && grep -q '<TEST_USER_PASSWORD>' <<<"$repro"; then
    pass "Reviewer reproduction steps are present and complete (${steps} steps)"
  else
    fail "Reviewer reproduction steps are present and complete" "found ${steps} steps or missing placeholders in Section 3.2"
  fi
}

check_screencast_and_checklist() {
  local f="$1" sc scenes cl checks
  sc=$(section_text "$f" '^## 4\. Video Screencast Script' '^## 5\.')
  scenes=$(grep -cE '^### Scene [1-5] ' <<<"$sc" || true)

  if (( scenes == 5 )) && grep -q 'dialog/oauth' <<<"$sc" && grep -q 'Connect Facebook' <<<"$sc" \
     && grep -q 'Publish to' <<<"$sc" && grep -q 'Published\.' <<<"$sc"; then
    pass "2-minute video screencast script has all 5 scenes and live UI steps"
  else
    fail "2-minute video screencast script has all 5 scenes and live UI steps" "found ${scenes}/5 scenes in Section 4"
  fi

  cl=$(section_text "$f" '^## 5\. Owner Checklist' '^<!--')
  checks=$(grep -cE '^- \[ \] \*\*[1-6]\.' <<<"$cl" || true)
  if (( checks >= 5 )) && grep -q 'Submit for Review' <<<"$cl" && grep -qi 'screencast' <<<"$cl"; then
    pass "Owner checklist includes screencast recording and Submit for Review (${checks} items)"
  else
    fail "Owner checklist includes screencast recording and Submit for Review" "found ${checks} checklist items in Section 5"
  fi

  if grep -E 'spool-hub\.ai' "$f" >/dev/null; then
    fail "No literal host domain in submission guide" "found literal spool-hub.ai instead of <BASE_DOMAIN>"
  else
    pass "No literal host domain in submission guide (<BASE_DOMAIN> used)"
  fi
}

run_red_controls() {
  local tmp rc
  tmp=$(mktemp -d)

  # Control 1: missing permission justification for instagram_content_publish fails with exit 1.
  sed '/^### 2\.5 `instagram_content_publish`/,$d' "$DOC_FILE" >"$tmp/no-perm.md"
  grep -A 500 '^## 3\. Test User' "$DOC_FILE" >>"$tmp/no-perm.md"
  META_REVIEW_DOC="$tmp/no-perm.md" META_REVIEW_SKIP_CONTROLS=1 bash "$0" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 1 ]] && pass "RED CONTROL: missing instagram_content_publish justification exits 1" \
    || fail "RED CONTROL: missing instagram_content_publish justification" "expected exit 1, got $rc"

  # Control 2: incomplete test user reproduction steps fails with exit 1.
  sed '/^### 3\.2 Reviewer Reproduction Steps/,/^## 4\. Video Screencast Script/{/^[2-7]\./d;}' "$DOC_FILE" >"$tmp/bad-repro.md"
  META_REVIEW_DOC="$tmp/bad-repro.md" META_REVIEW_SKIP_CONTROLS=1 bash "$0" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 1 ]] && pass "RED CONTROL: incomplete test user reproduction steps exits 1" \
    || fail "RED CONTROL: incomplete test user reproduction steps" "expected exit 1, got $rc"

  # Control 3: missing security note fails with exit 1.
  grep -v '\[!CAUTION\]' "$DOC_FILE" >"$tmp/no-caution.md"
  META_REVIEW_DOC="$tmp/no-caution.md" META_REVIEW_SKIP_CONTROLS=1 bash "$0" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 1 ]] && pass "RED CONTROL: missing credential security note exits 1" \
    || fail "RED CONTROL: missing credential security note" "expected exit 1, got $rc"

  # Control 4: incomplete screencast script fails with exit 1.
  grep -v '^### Scene 4 ' "$DOC_FILE" >"$tmp/no-scene4.md"
  META_REVIEW_DOC="$tmp/no-scene4.md" META_REVIEW_SKIP_CONTROLS=1 bash "$0" >/dev/null 2>&1; rc=$?
  [[ "$rc" -eq 1 ]] && pass "RED CONTROL: incomplete video screencast script exits 1" \
    || fail "RED CONTROL: incomplete video screencast script" "expected exit 1, got $rc"

  rm -rf "$tmp"
}

main() {
  check_file_and_scope "$DOC_FILE"
  if [[ -f "$DOC_FILE" && -s "$DOC_FILE" ]]; then
    check_permissions "$DOC_FILE"
    check_test_user_and_security "$DOC_FILE"
    check_screencast_and_checklist "$DOC_FILE"
    if [[ "${META_REVIEW_SKIP_CONTROLS:-0}" != "1" ]]; then
      run_red_controls
    fi
  fi
  [[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; return 0; }
  echo "FAIL: $fails $(basename "$0") assertion(s) failed"
  return 1
}

main "$@"
