#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl-cmd-guard gives the Python guard's verdict (SPL-5392; spec 011
# rust-candidates-analysis.md 6.1 and 6.3 row 1). Needs the built binary:
#   SPL_CMD_GUARD_BIN=<path> bash parity.sh      (CI: the rust-suite job)
# A missing binary FAILS: nothing here skips.
#   1. the binary: --self-test, --version, a bad call is rc 64
#   2. the guard suites against Rust: force-push-guard.tst.sh asks the binary
#      for every case; kill-target-guard.tst.sh, heredoc-collision-guard.tst.sh
#      and test-y13-force-push-guard.sh run through the hook with
#      SPL_CMD_GUARD_IMPL=rust, then =shadow, and every shadow line they
#      leave says match=1
#   3. the differential: force-push-guard.tst.sh's cases plus the generated
#      soup and struct corpora (PARITY_N each, default 20000, fixed seed),
#      Python's verdict and reason vs Rust's, every line identical; and
#      PARITY_PAYLOADS (default 300) generated hook payloads, the hook's own
#      extractor vs `spl-cmd-guard hook`
#   4. RED controls: a binary that flips one verdict, and one that misreads
#      one payload, are each caught by 3
#------------------------------------------------------------------------------
set -uo pipefail
P="$(cd "$(dirname "$0")" && pwd)"
ORC="$(cd "$P/../../../.." && pwd)"
LIB="$ORC/src/bash/features/spawn-agents/lib/force-push-guard.inc.sh"
HOOK="$ORC/src/bash/features/spawn-agents/scripts/force-push-guard-hook.sh"
B="${SPL_CMD_GUARD_BIN:-}"
N="${PARITY_N:-20000}" NP="${PARITY_PAYLOADS:-300}" SEED="${PARITY_SEED:-5392}"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fails=0 n=0
pass() { n=$((n + 1)); echo "PASS: $1"; }
fail() { n=$((n + 1)); echo "FAIL: $1"; fails=$((fails + 1)); }
if [ -z "$B" ] || [ ! -x "$B" ]; then
  echo "FAIL: SPL_CMD_GUARD_BIN is not an executable spl-cmd-guard (${B:-unset}); build it first"
  exit 1
fi

# 1. the binary
"$B" --self-test >/dev/null && pass "--self-test" || fail "--self-test"
v="$("$B" --version)" && [[ "$v" == "spl-cmd-guard "* ]] && pass "--version: $v" || fail "--version: $v"
"$B" nope 2>/dev/null; rc=$?
[ "$rc" = 64 ] && pass "a bad call is rc 64" || fail "bad call rc=$rc"

# 2. the guard suites against Rust
suite() {  # LABEL VAR=VAL... -- SCRIPT
  local label="$1" out rc; shift
  local -a envs=(); while [ "$1" != -- ]; do envs+=("$1"); shift; done; shift
  out="$(env "${envs[@]}" bash "$1" 2>&1)"; rc=$?
  if [ "$rc" = 0 ]; then pass "$label: $(printf '%s\n' "$out" | tail -1)"
  else fail "$label rc=$rc"; printf '%s\n' "$out" | grep -E '^FAIL' | sed -n '1,20p'; fi
}
suite "force-push-guard.tst.sh, every case asked of the binary" SPL_CMD_GUARD_TEST_BIN="$B" \
  FORCE_PUSH_GUARD_TEST_DUMP="$T/cases.bin" -- "$ORC/src/bash/tests/force-push-guard.tst.sh"
SH="$T/shadow.tsv"
for mode in rust shadow; do
  for s in src/bash/tests/kill-target-guard.tst.sh src/bash/tests/heredoc-collision-guard.tst.sh \
    src/bash/features/spool-install/tests/test-y13-force-push-guard.sh; do
    suite "${s##*/} under SPL_CMD_GUARD_IMPL=$mode" SPL_CMD_GUARD_IMPL="$mode" SPL_CMD_GUARD_BIN="$B" \
      SPL_CMD_GUARD_SHADOW_LOG="$SH" -- "$ORC/$s"
  done
done
lines=$(wc -l <"$SH" 2>/dev/null || echo 0); bad=$(grep -vc $'\tmatch=1\t' "$SH" 2>/dev/null)
if [ "$lines" -gt 0 ] && [ "$bad" = 0 ]; then pass "shadow: all $lines hook calls of those suites match"
else fail "shadow: $bad of $lines lines do not match"; grep -v $'\tmatch=1\t' "$SH" | sed -n '1,5p'; fi

# 3. the differential
# differ BIN CORPUS: prints the number of commands whose verdict lines differ
differ() {
  python3 "$P/py-batch.py" verdicts "$LIB" <"$2" >"$T/py.out" || { echo py-error; return; }
  "$1" batch <"$2" >"$T/rs.out" || { echo rust-error; return; }
  diff "$T/py.out" "$T/rs.out" | grep -c '^<'
}
python3 "$P/corpus-gen.py" soup "$SEED" "$N" >"$T/soup.bin"
python3 "$P/corpus-gen.py" struct "$SEED" "$N" >"$T/struct.bin"
for c in cases soup struct; do
  k="$(tr -cd '\0' <"$T/$c.bin" | wc -c)"; d="$(differ "$B" "$T/$c.bin")"
  r="$(grep -c '^2' "$T/rs.out")"
  [ "$d" = 0 ] && [ "$k" -gt 0 ] && pass "differential $c: $k commands ($r refused), every verdict and reason identical" ||
    fail "differential $c: $d of $k differ"
done
# pdiffer BIN: the number of payloads the hook's extractor and BIN read differently
pdiffer() {
  local f payload b rc
  python3 "$P/py-batch.py" payloads "$HOOK" "$T"/pl/*.json >"$T/pe.out" || { echo py-error; return; }
  for f in "$T"/pl/*.json; do
    payload="$(cat "$f")"
    b="$(printf '%s' "$payload" | "$1" hook 2>/dev/null)"; rc=$?
    case "$rc" in 3) b=unreadable ;; 2) b=REFUSED ;; 0) ;; *) b="rc$rc" ;; esac
    printf '%s|%s\n' "$f" "${b//$'\n'/\\n}"
  done >"$T/re.out" 2>/dev/null
  # a refusal means the command was read: compare it with the Python read
  paste -d '\n' "$T/pe.out" "$T/re.out" | awk -F'|' '
    NR % 2 { f = $1; a = substr($0, length($1) + 2); next }
    { b = substr($0, length($1) + 2); if (b == "REFUSED" && a ~ /^CMD:/) b = a; if (a != b || f != $1) d++ }
    END { print d + 0 }'
}
mkdir -p "$T/pl"; python3 "$P/corpus-gen.py" payload "$SEED" "$NP" "$T/pl"
d="$(pdiffer "$B")"
[ "$d" = 0 ] && pass "differential payloads: $NP payloads read the same (NONE / CMD / unreadable)" ||
  fail "differential payloads: $d of $NP differ"

# 4. RED controls: a planted mismatch is caught
cat >"$T/flip" <<EOF
#!/usr/bin/env bash
# the real binary, with the verdict of the 7th command flipped
if [ "\${1-}" = batch ]; then "$B" batch | awk 'NR == 7 { print (\$0 == "0") ? "2\tplanted" : "0"; next } 1'; else exec "$B" "\$@"; fi
EOF
cat >"$T/misread" <<EOF
#!/usr/bin/env bash
# the real binary, except that it reads one shell call as not a shell call
p="\$(cat)"; o="\$(printf '%s' "\$p" | "$B" "\$@")"; rc=\$?
[ "\$o" = "CMD:git status" ] && { printf NONE; exit 0; }
printf '%s' "\$o"; exit \$rc
EOF
chmod +x "$T/flip" "$T/misread"
d="$(differ "$T/flip" "$T/cases.bin")"
[ "$d" = 1 ] && pass "RED control: one flipped verdict is caught (1 differs)" || fail "RED control flip: $d differ"
d="$(pdiffer "$T/misread")"
[ "$d" -gt 0 ] && pass "RED control: a misread payload is caught ($d differ)" || fail "RED control misread: $d differ"

echo "spl-cmd-guard parity: $((n - fails))/$n passed"
[ "$fails" = 0 ]
