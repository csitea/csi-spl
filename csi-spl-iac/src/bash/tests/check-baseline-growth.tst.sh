#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_check_baseline_growth (SPL-2153) lets a security baseline grow
#          only when each new entry names its ticket (SPL-<n>).
#   1. no change since the anchor                          -> rc 0
#   2. RED CONTROL: a planted gosec row, no ticket          -> rc 1, names file:line
#   3. the same row with a trailing "# SPL-<n>"             -> rc 0
#   4. a "# SPL-<n> ..." comment line beside the row        -> rc 0
#   5. a count raised on an existing row, no ticket         -> rc 1
#   6. a count lowered, a row deleted, rows reordered       -> rc 0
#   7. a comment-only addition                              -> rc 0
#   8. a .trivyignore.yaml block with no ticket             -> rc 1;
#      with "# SPL-<n>" on its first line                   -> rc 0
#   9. a .gitleaks.toml allow-list regex with no ticket     -> rc 1
#  10. the checkov JSON (no comments): a new check id       -> rc 1;
#      the same with SPL-<n> in the commit message          -> rc 0
#  11. an anchor that is not in the tree                    -> rc 1 (refused)
#  12. the real tree, from the anchor in this repo's history -> rc 0
#      (skipped only when a shallow clone lacks the anchor)
#  13. a row with a trailing ticket survives the count gates' parser and
#      _sec_baseline_write (the ticket stays on the row)
# Hermetic: throwaway git repos; no network.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
FUNC="$PROJ_ROOT/src/bash/run/check-baseline-growth.func.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/sec-baseline.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$FUNC"

g() { git -C "$T/r" -c user.name=t -c user.email=t@example.org -c commit.gpgsign=false "$@"; }

# a fresh repo whose first commit (the anchor) holds a small baseline set
fresh() {
  rm -rf "$T/r"; mkdir -p "$T/r/csi-spl-iac/src/terraform"
  git init -q "$T/r"
  printf '# head\nG101|a.go|1\nG115|b.go|2\nG115|c.go|1\n' >"$T/r/.gosec-baseline.txt"
  printf 'misconfigurations:\n  - id: GCP-0017\n    paths:\n      - x.tf\n' >"$T/r/.trivyignore.yaml"
  printf '[allowlist]\nregexes = [\n  "a1",\n]\n' >"$T/r/.gitleaks.toml"
  printf '{\n  "failed_checks": [\n    {\n      "file": "/a.tf",\n      "findings": [\n        {\n          "resource": "r.a",\n          "check_ids": [\n            "CKV_GCP_62"\n          ]\n        }\n      ]\n    }\n  ]\n}\n' \
    >"$T/r/csi-spl-iac/src/terraform/.checkov.baseline"
  g add -A && g commit -qm anchor
  ANCHOR=$(g rev-parse HEAD)
}

# commit <msg>: commit the tree as it is
commit() { g add -A && g commit -qm "$1"; }

# check -> rc; output in $T/out
check() {
  env BASELINE_GROWTH_TREE="$T/r" BASELINE_GROWTH_ANCHOR="${1:-$ANCHOR}" APP_PATH="$T/r" bash -c '
    do_log() { echo "$*"; }
    source "'"$FUNC"'"
    do_check_baseline_growth' >"$T/out" 2>&1
}

# expect <rc> <label>
expect() {
  local rc=$?
  [[ "$rc" -eq "$1" ]] && pass "$2 (rc $rc)" || fail "$2: rc $rc, want $1: $(cat "$T/out")"
}

# 1
fresh; check; expect 0 "1. no change since the anchor"

# 2
fresh; sed -i 's/^G101|a.go|1$/G101|a.go|1\nG402|d.go|1/' "$T/r/.gosec-baseline.txt"; commit plant
check; expect 1 "2. RED CONTROL: a planted gosec row without a ticket fails"
grep -q 'NO-TICKET .gosec-baseline.txt:3: G402|d.go|1' "$T/out" && pass "2. the failure names the file, line and row" || fail "2. output: $(cat "$T/out")"

# 3
fresh; sed -i 's/^G101|a.go|1$/G101|a.go|1\nG402|d.go|1  # SPL-42 triaged: test-only TLS/' "$T/r/.gosec-baseline.txt"; commit t3
check; expect 0 "3. a row with a trailing SPL-<n> passes"

# 4
fresh; sed -i 's/^G101|a.go|1$/G101|a.go|1\n# SPL-43: G402 in d.go, a test-only client\nG402|d.go|1/' "$T/r/.gosec-baseline.txt"; commit t4
check; expect 0 "4. a comment line with SPL-<n> beside the row passes"

# 5
fresh; sed -i 's/^G115|b.go|2$/G115|b.go|3/' "$T/r/.gosec-baseline.txt"; commit t5
check; expect 1 "5. a raised count without a ticket fails"

# 6
fresh; printf '# head\nG115|c.go|1\nG101|a.go|1\nG115|b.go|1\n' >"$T/r/.gosec-baseline.txt"; commit t6
check; expect 0 "6. lowered, deleted and reordered rows pass"

# 7
fresh; sed -i '1a # a note on the triage, no ticket needed' "$T/r/.gosec-baseline.txt"
sed -i '1a # trivy note' "$T/r/.trivyignore.yaml"; commit t7
check; expect 0 "7. a comment-only addition passes"

# 8
fresh; printf '  - id: GCP-0099\n    paths:\n      - y.tf\n' >>"$T/r/.trivyignore.yaml"; commit t8
check; expect 1 "8. a new .trivyignore.yaml block without a ticket fails"
fresh; printf '  - id: GCP-0099  # SPL-44 reviewed\n    paths:\n      - y.tf\n' >>"$T/r/.trivyignore.yaml"; commit t8b
check; expect 0 "8. the same block with SPL-<n> on its first line passes"

# 9
fresh; sed -i 's/^  "a1",$/  "a1",\n  "b2",/' "$T/r/.gitleaks.toml"; commit t9
check; expect 1 "9. a new .gitleaks.toml allow-list regex without a ticket fails"

# 10
fresh; sed -i 's/^            "CKV_GCP_62"$/            "CKV_GCP_62",\n            "CKV_GCP_29"/' "$T/r/csi-spl-iac/src/terraform/.checkov.baseline"; commit "baseline: one more"
check; expect 1 "10. a new checkov check id without a ticket fails"
fresh; sed -i 's/^            "CKV_GCP_62"$/            "CKV_GCP_62",\n            "CKV_GCP_29"/' "$T/r/csi-spl-iac/src/terraform/.checkov.baseline"; commit "chore(iac, SPL-45): checkov baseline takes CKV_GCP_29"
check; expect 0 "10. the same with SPL-<n> in the commit message passes"

# 11
fresh; check 0123456789012345678901234567890123456789; expect 1 "11. an anchor outside the tree is refused"
grep -q 'FATAL baseline-growth: anchor' "$T/out" && pass "11. the refusal says why" || fail "11. output: $(cat "$T/out")"

# 12
if git -C "$APP_ROOT" rev-parse -q --verify "$(sed -n 's/^_BG_ANCHOR=//p' "$FUNC")^{commit}" >/dev/null 2>&1; then
  env APP_PATH="$APP_ROOT" bash -c 'do_log() { echo "$*"; }; source "'"$FUNC"'"; do_check_baseline_growth' >"$T/out" 2>&1
  expect 0 "12. the real tree: every baseline entry since the anchor names its ticket"
else
  echo "SKIP: 12. the anchor is not in this clone (shallow)"
fi

# 13
printf '# h\nG1|a.go|1  # SPL-46\n' >"$T/bl"; printf 'G1|a.go|1\n' >"$T/counts"
v=$(bash -c 'source "'"$LIB"'"; _sec_baseline_diff "$0" "$1"' "$T/counts" "$T/bl" 2>&1)
[[ -z "$v" ]] && pass "13. the count gates read a row with a trailing ticket" || fail "13. diff: $v"
printf 'G1|a.go|1\nG2|b.go|2\n' >"$T/counts"
bash -c 'source "'"$LIB"'"; _sec_baseline_write "$0" "$1"' "$T/counts" "$T/bl" >/dev/null 2>&1
[[ "$(cat "$T/bl")" == $'# h\nG1|a.go|1  # SPL-46\nG2|b.go|2' ]] && pass "13. a regenerated baseline keeps the row's ticket" || fail "13. wrote: $(cat "$T/bl")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
