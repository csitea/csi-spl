#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: no tracked *.func.sh turns on errexit at TOP LEVEL (SPL-2315).
#          ./run sources every *.func.sh into ONE shell, so a top-level
#          `set -euo pipefail` in any of them turns errexit on for every
#          action, the pre-push gate included: measured 2026-10-17, a lane's
#          file did it and the gate died after 1 s with no PART line and no
#          summary (a grep with no match under pipefail).
#   1. CONTROL: a fixture with a top-level `set -euo pipefail` is flagged at
#      file:line; so are `set -e`, `set -Eeu`, `set -o errexit`, `x; set -e`
#   2. not top level: inside a function body (also `f() (` subshell bodies),
#      inside a heredoc (quoted, unquoted, `<<-`), in a comment, `set +e`,
#      `set -u -o pipefail`, `set --` -- all pass
#   3. every tracked *.func.sh in the repo passes
#   4. MUTATION: the same files with a top-level `set -e` appended all fail
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# Prints <file>:<line>: <text> for each top-level errexit; exit 1 on any.
# The repo's layout: a function opens with a column-0 `name()` and ends at a
# column-0 `}` or `)`; a one-line `f() { ...; }` opens and closes on its line.
errexit_scan() {
  awk '
    # an odd count of " or \047 before a << means it sits inside a string
    function quoted(pre,  d, q) { d = gsub(/"/, "", pre); q = gsub(/\047/, "", pre); return d % 2 || q % 2 }
    FNR == 1 { infn = 0; hd = "" }
    hd != "" { l = $0; if (hdtab) sub(/^\t+/, "", l); if (l == hd) hd = ""; next }
    {
      line = $0
      code = line; sub(/(^|[ \t])#.*$/, "", code)
      if (infn) { if (code ~ /^[})]/) infn = 0 }
      else if (code ~ /^(function[ \t]+)?[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*\(\)[ \t]*[{(]?[ \t]*$/ \
            || code ~ /^function[ \t]+[A-Za-z_][A-Za-z0-9_:.-]*[ \t]*[{(]?[ \t]*$/) infn = 1
      else if (code !~ /\(\)[ \t]*[{(].*[})][ \t;]*$/) {
        s = code
        while (match(s, /(^|[;&|][ \t]*)set[ \t]+[^;&|]*/)) {
          seg = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
          sub(/^[;&|][ \t]*/, "", seg)
          if (seg ~ /^set[ \t]+(.*[ \t])?-[A-Za-z]*e[A-Za-z]*([ \t]|$)/ \
           || seg ~ /^set[ \t]+(.*[ \t])?-[A-Za-z]*o[ \t]+errexit([ \t]|$)/) {
            printf "%s:%d: top-level errexit: %s\n", FILENAME, FNR, line; bad = 1; break
          }
        }
      }
      hs = code; gsub(/<<</, "\001", hs)
      if (match(hs, /<<-?[ \t]*["\047]?[A-Za-z_][A-Za-z0-9_]*["\047]?/) && !quoted(substr(hs, 1, RSTART - 1))) {
        t = substr(hs, RSTART, RLENGTH); hdtab = (t ~ /^<<-/)
        sub(/^<<-?[ \t]*/, "", t); gsub(/["\047]/, "", t); hd = t
      }
    }
    END { exit bad }
  ' "$@"
}

# 1. CONTROL: top-level errexit in every spelling is flagged
cat >"$T/bad.func.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
do_x() { :; }
EOF
out="$(errexit_scan "$T/bad.func.sh")"; rc=$?
[[ "$rc" == 1 && "$out" == "$T/bad.func.sh:2: top-level errexit: set -euo pipefail" ]] \
  && pass "1. CONTROL: a top-level set -euo pipefail is flagged at file:line" || fail "1. control" "rc=$rc out=$out"
for spell in 'set -e' 'set -Eeu' 'set -o errexit' 'set -u -o errexit' 'x=1; set -e' 'true && set -e'; do
  printf '%s\n' "$spell" >"$T/spell.func.sh"
  errexit_scan "$T/spell.func.sh" >/dev/null && fail "1. '$spell' is flagged" "passed" || pass "1. '$spell' is flagged"
done

# 2. not top level, or not errexit: passes
cat >"$T/good.func.sh" <<'EOF'
#!/usr/bin/env bash
# set -euo pipefail  (a comment)
set +e
set -u -o pipefail
set -- "$@"
do_a() {
  set -euo pipefail
  if true; then
    set -e
  fi
}
function do_b {
  set -e
}
_c() (
  set -e
)
_d() { set -e; }
_remote() {
  cat <<'REMOTE'
set -euo pipefail
REMOTE
}
cat <<EOS
set -e
EOS
	cat <<-INDENTED
	set -e
	INDENTED
x="$(cmd 3<<<"Authorization: x")"
log "FATAL the renderer (<<'EOF_PY' ... EOF_PY) is missing"
PROG='
  END {
    flush()
  }'

echo "done"
EOF
out="$(errexit_scan "$T/good.func.sh")"; rc=$?
[[ "$rc" == 0 && -z "$out" ]] && pass "2. function bodies, heredocs, comments, set +e / -u -o pipefail / -- pass" \
  || fail "2. not top level" "rc=$rc out=$out"
# a heredoc must not end early: errexit after it, at top level, is still caught
printf 'cat <<X\nset -e\nX\nset -e\n' >"$T/after.func.sh"
out="$(errexit_scan "$T/after.func.sh")"
[[ "$out" == "$T/after.func.sh:4: top-level errexit: set -e" ]] && pass "2. errexit after a heredoc is caught" \
  || fail "2. after heredoc" "$out"

# a here-string is not a heredoc: errexit after one is still caught
printf 'cat 3<<<"Auth: x"\nset -e\n' >"$T/hs.func.sh"
out="$(errexit_scan "$T/hs.func.sh")"
[[ "$out" == "$T/hs.func.sh:2: top-level errexit: set -e" ]] && pass "2. a here-string (3<<<\"x\") opens no heredoc" \
  || fail "2. here-string" "$out"

# 3. every tracked *.func.sh
mapfile -t files < <(git -C "$REPO_ROOT" ls-files '*.func.sh')
if [[ "${#files[@]}" -lt 100 ]]; then
  fail "3. tracked *.func.sh" "only ${#files[@]} found under $REPO_ROOT"
elif out="$(cd "$REPO_ROOT" && errexit_scan "${files[@]}")"; then
  pass "3. none of the ${#files[@]} tracked *.func.sh sets errexit at top level"
else
  fail "3. tracked *.func.sh set errexit at top level (./run sources them all into one shell)" "$out"
fi

# 4. MUTATION control: a top-level `set -e` appended to a copy of every
#    tracked file is caught in each one -- no file leaves the scanner blind
#    (stuck in a heredoc or a function body) by its end, so leg 3 proves absence
mkdir -p "$T/mut"; i=0
for f in "${files[@]}"; do i=$((i + 1)); { cat "$REPO_ROOT/$f"; printf '\nset -e\n'; } >"$T/mut/$i.func.sh"; done
hits="$(errexit_scan "$T"/mut/*.func.sh | grep -c ': top-level errexit: set -e$')"
[[ "$hits" == "${#files[@]}" ]] && pass "4. MUTATION: an appended top-level set -e is caught in all $hits copies" \
  || fail "4. mutation" "caught in $hits of ${#files[@]} copies"

echo ""
if [[ "$fails" -eq 0 ]]; then echo "func-sh-no-top-level-errexit: ALL PASS"; exit 0; fi
echo "func-sh-no-top-level-errexit: $fails FAILED"; exit 1
