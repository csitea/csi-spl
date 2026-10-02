#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spec 031 — the owner acceptance register
#          (csi-spl-doc/specs/031-spool-owner-acceptance/cases.tsv) is the ONE
#          list of the cases the owner stated, and every row names the test
#          that proves it. This gate is what stops it rotting into a list of
#          promises: a row whose test file is not in the tree fails the build,
#          so deleting or renaming a test is caught by the register rather
#          than by the owner.
#
#          What is checked:
#            1. the file exists, is tab separated and has the 8 columns
#            2. every case_id matches ^OA-[0-9]{2}$ and is UNIQUE
#            3. `runner` and `status` are values this gate knows
#            4. a row that is NOT `pending` names a test path that EXISTS
#            5. a `pending` row names an INTENDED path (a test-shaped name)
#               and an owner, so the gap has an addressee rather than a shrug
#            6. every case_id is mentioned in spec.md, and every OA-NN in
#               spec.md is a row here — the prose and the register cannot drift
#            7. a MANUAL row has a procedure section in spec.md
#
#          CONTROLS (a guard that finds nothing proves nothing unless it is
#          shown to find something): the same checks are run over four planted
#          registers — a missing test path, a duplicate id, an unknown runner
#          and a pending row with no owner — and each MUST be rejected.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
SPEC_DIR="$APP_ROOT/csi-spl-doc/specs/031-spool-owner-acceptance"
TSV="$SPEC_DIR/cases.tsv"
SPEC="$SPEC_DIR/spec.md"
fails=0

RUNNERS='go node-unit node-e2e orc-tst orc-e2e spawn-tst manual pending'
STATUSES='PASS FAIL PENDING UNVERIFIED MANUAL'

# check_register <tsv> <tree-root> -> prints one reason per line; empty = valid.
# Pure: it reads only the two arguments, so a control can hand it a planted
# file and the same code decides.
check_register() {
  local tsv="$1" root="$2" seen=" " n=0
  [[ -s "$tsv" ]] || { echo "register $tsv is missing or empty"; return 0; }
  while IFS=$'\t' read -r id area title spec runner path status owner rest; do
    [[ -z "${id:-}" || "$id" == \#* ]] && continue
    n=$((n + 1))
    [[ -n "${rest:-}" ]] && echo "$id: more than 8 tab separated columns"
    [[ "$id" =~ ^OA-[0-9]{2}$ ]] || echo "$id: not a case id of the shape OA-NN"
    case "$seen" in *" $id "*) echo "$id: duplicate case id" ;; esac
    seen="$seen$id "
    [[ -n "${title:-}" ]] || echo "$id: empty title"
    [[ -n "${area:-}" ]] || echo "$id: empty area"
    [[ "${spec:-}" =~ ^[0-9]{3}$ ]] || echo "$id: spec '$spec' is not a three digit spec number"
    case " $RUNNERS " in *" ${runner:-} "*) : ;; *) echo "$id: unknown runner '${runner:-}'" ;; esac
    case " $STATUSES " in *" ${status:-} "*) : ;; *) echo "$id: unknown status '${status:-}'" ;; esac
    [[ -n "${owner:-}" ]] || echo "$id: no owner — a case nobody owns is a case nobody fixes"
    if [[ "${runner:-}" == pending || "${status:-}" == PENDING ]]; then
      [[ "${runner:-}" == pending && "${status:-}" == PENDING ]] ||
        echo "$id: runner 'pending' and status 'PENDING' go together"
      [[ "${path:-}" =~ (\.tst\.sh|\.test\.mjs|\.proof\.mjs|_test\.go|\.py)$ ]] ||
        echo "$id: pending rows must name the INTENDED test path, got '${path:-}'"
    elif [[ "${runner:-}" == manual ]]; then
      [[ "${status:-}" == MANUAL ]] || echo "$id: runner 'manual' and status 'MANUAL' go together"
      [[ -f "$root/${path:-}" ]] || echo "$id: a manual case must point at the page that holds its procedure: '${path:-}'"
    else
      [[ "${status:-}" == MANUAL ]] && echo "$id: status MANUAL needs runner 'manual'"
      [[ -f "$root/${path:-}" ]] || echo "$id: names a test that is not in the tree: '${path:-}'"
    fi
  done <"$tsv"
  [[ "$n" -ge 1 ]] || echo "the register holds no rows"
}

# --- 1..5 the real register ---------------------------------------------------
[[ -f "$TSV" ]] && pass "the register exists at ${TSV#$APP_ROOT/}" || { fail "no register at $TSV"; exit 1; }
[[ -f "$SPEC" ]] && pass "the spec page exists at ${SPEC#$APP_ROOT/}" || fail "no spec page at $SPEC"

reasons=$(check_register "$TSV" "$APP_ROOT")
if [[ -z "$reasons" ]]; then
  pass "every register row is well formed and names a test that is in the tree"
else
  fail "the register does not hold up:"
  echo "$reasons" | sed 's/^/    /'
fi

rows=$(grep -cvE '^(#|$)' "$TSV")
[[ "$rows" -ge 20 ]] && pass "the register holds $rows cases" ||
  fail "only $rows cases in the register — the owner stated more than that"

# --- 6. the prose and the register agree --------------------------------------
ids_tsv=$(grep -oE '^OA-[0-9]{2}' "$TSV" | sort -u)
ids_doc=$(grep -oE '\bOA-[0-9]{2}\b' "$SPEC" 2>/dev/null | sort -u)
missing_in_doc=$(comm -23 <(echo "$ids_tsv") <(echo "$ids_doc"))
missing_in_tsv=$(comm -13 <(echo "$ids_tsv") <(echo "$ids_doc"))
[[ -z "$missing_in_doc" ]] && pass "every case in the register is named in spec.md" ||
  fail "in the register but not in spec.md: $(echo $missing_in_doc)"
[[ -z "$missing_in_tsv" ]] && pass "every OA-NN in spec.md is a register row" ||
  fail "in spec.md but not in the register: $(echo $missing_in_tsv)"

# --- 7. a MANUAL case carries its procedure -----------------------------------
while IFS=$'\t' read -r id _ _ _ _ _ status _; do
  [[ "${status:-}" == MANUAL ]] || continue
  grep -qE "^#+ .*$id|$id.*manual procedure|Manual procedure" "$SPEC" &&
    pass "$id (manual) has a procedure in spec.md" ||
    fail "$id is MANUAL but spec.md gives no procedure a human could follow"
done < <(grep -vE '^(#|$)' "$TSV")

# --- CONTROLS: the gate must reject each planted defect ------------------------
tmp=$(mktemp -d) || exit 1
trap 'rm -rf "$tmp"' EXIT
ctl() {  # NAME  EXPECTED-SUBSTRING  <register on stdin>
  local name="$1" want="$2" f="$tmp/c.tsv" out
  cat >"$f"
  out=$(check_register "$f" "$APP_ROOT")
  if [[ "$out" == *"$want"* ]]; then pass "CONTROL $name is rejected"
  else fail "CONTROL $name was ACCEPTED (the gate proves nothing): got '${out:-<nothing>}'"; fi
}

printf 'OA-01\tx\tt\t028\tgo\tno/such/test_test.go\tPASS\tCLE-1\n' |
  ctl "a row naming a test that is not in the tree" "not in the tree"
printf 'OA-01\tx\tt\t028\tgo\tcsi-spl-doc/specs/README.md\tPASS\tCLE-1\nOA-01\tx\tt\t028\tgo\tcsi-spl-doc/specs/README.md\tPASS\tCLE-1\n' |
  ctl "a duplicate case id" "duplicate case id"
printf 'OA-02\tx\tt\t028\tsomehow\tcsi-spl-doc/specs/README.md\tPASS\tCLE-1\n' |
  ctl "an unknown runner" "unknown runner"
printf 'OA-03\tx\tt\t028\tpending\tcsi-spl-orc/src/bash/tests/nope.tst.sh\tPENDING\t\n' |
  ctl "a pending row with no owner" "no owner"
out=$(printf 'OA-04\tx\tt\t028\tpending\tcsi-spl-orc/src/bash/tests/nope.tst.sh\tPENDING\tCLE-1\n' >"$tmp/ok.tsv"; check_register "$tmp/ok.tsv" "$APP_ROOT")
[[ -z "$out" ]] && pass "CONTROL a well formed pending row is ACCEPTED" ||
  fail "CONTROL a well formed pending row was rejected: $out"

echo "=== owner-acceptance-register.tst.sh: $fails failure(s)"
[[ "$fails" -eq 0 ]]
