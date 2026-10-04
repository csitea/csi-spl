#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: sigpipe-lint.sh (the lint-sigpipe pre-push part) flags an
#          early-exit consumer after a producer under pipefail, and only that.
#   1. CONTROL (the hazard is real): under pipefail `big | grep -q x` and
#      `big | head -1` read FALSE (141); the fix forms read true
#   2. a planted `| grep -q` in a pipefail file is flagged with file:line
#   3. the fix forms (grep >/dev/null, sed -n 1p, here-string) pass
#   4. a file that never sets pipefail is out of scope; a *.func.sh (run by
#      ./run, which sets pipefail) is in scope without setting it
#   5. `# sigpipe-ok: <why>` opts a reviewed site out, and --list-optouts lists it
#   6. not shell code / not early-exit: heredoc body, comment, quoted text
#      that runs no command, `||`, `| grep -c`, `| head -n -1`, `| grep -q x || true`
#   7. a continued pipeline (`\` or a trailing `|`) is caught at its first line;
#      `| grep -m1`, `| grep -qxF`, `| head -n 3` are caught, also inside
#      "$(... "q" | grep -m1 "x")" (nested quotes)
#   8. MUTATION control: the same planted line passes once the rule is cut
#      out of a copy of the script -- leg 2 proves the rule, not the harness
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
LINT="$TEST_DIR/../scripts/sigpipe-lint.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
run() { local rc=0; bash "$LINT" "$@" >"$T/out" 2>&1 || rc=$?; echo "$rc"; }

# 1. CONTROL: the class is real on this box (the producer outlives the consumer)
big() { echo x; seq 1 2000000; }
rc_q=0; big | grep -q x || rc_q=$?  # sigpipe-ok: the control plants it
rc_h=0; big | head -1 >/dev/null || rc_h=$?  # sigpipe-ok: the control plants it
rc_fq=0; big | grep x >/dev/null || rc_fq=$?
rc_fh=0; big | sed -n 1p >/dev/null || rc_fh=$?
[[ "$rc_q" -ne 0 && "$rc_h" -ne 0 && "$rc_fq" -eq 0 && "$rc_fh" -eq 0 ]] \
  && pass "1. CONTROL: | grep -q rc=$rc_q, | head -1 rc=$rc_h (false); fix forms rc=$rc_fq/$rc_fh" \
  || fail "1. control" "grep -q=$rc_q head=$rc_h grep>null=$rc_fq sed=$rc_fh"

# 2. a planted bad line is flagged
printf '#!/usr/bin/env bash\nset -euo pipefail\nok=1\nif git ls-files | grep -q x; then echo y; fi\n' >"$T/bad.sh"
rc="$(run "$T/bad.sh")"
[[ "$rc" == 1 ]] && grep -q "$T/bad.sh:4: SIGPIPE \`| grep -q\`" "$T/out" \
  && pass "2. a planted | grep -q under pipefail is flagged at file:line" || fail "2. planted" "rc=$rc $(cat "$T/out")"

# 3. the fix forms pass
cat >"$T/good.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if git ls-files | grep x >/dev/null; then echo y; fi
first="$(git ls-files | sed -n 1p)"
grep -q x <<<"$first"
grep -qF x "$first"
EOF
rc="$(run "$T/good.sh")"
[[ "$rc" == 0 ]] && pass "3. grep >/dev/null, sed -n 1p and a here-string pass" || fail "3. fix forms" "rc=$rc $(cat "$T/out")"

# 4. scope: no pipefail -> out; *.func.sh -> in
printf '#!/usr/bin/env bash\nset -u\nls | grep -q x\n' >"$T/nopf.sh"
printf 'do_x() {\n  ls | head -1\n}\n' >"$T/x.func.sh"
rc_n="$(run "$T/nopf.sh")"; rc_f="$(run "$T/x.func.sh")"
[[ "$rc_n" == 0 && "$rc_f" == 1 ]] \
  && pass "4. no pipefail is out of scope; a *.func.sh is in scope" || fail "4. scope" "nopf=$rc_n func=$rc_f"

# 5. opt-out marker
printf '#!/bin/bash\nset -o pipefail\nprintf "%%s" "$v" | grep -q x  # sigpipe-ok: one short write\n' >"$T/opt.sh"
rc="$(run "$T/opt.sh")"
bash "$LINT" --list-optouts "$T/opt.sh" >"$T/list" 2>&1
[[ "$rc" == 0 ]] && grep -q "opt.sh:3: OPT-OUT grep -q -- sigpipe-ok: one short write" "$T/list" \
  && pass "5. # sigpipe-ok opts a site out, and --list-optouts lists it" || fail "5. opt-out" "rc=$rc $(cat "$T/list")"

# 6. not shell code here, or not an early exit
cat >"$T/quiet.sh" <<'OUTER'
#!/usr/bin/env bash
set -euo pipefail
# a comment: ls | grep -q x
cat >stub <<'EOF'
ls | grep -q x
EOF
cat <<-EOF
	ls | head -1
	EOF
echo 'say: ls | head -1'
echo "say: ls | grep -q $x"
[[ -n "${a:-}" ]] || true
n=$(ls | grep -c x)
all_but_last="$(ls | head -n -1)"
ls | grep -q x || true
x=$(( 1 << 2 ))
OUTER
rc="$(run "$T/quiet.sh")"
[[ "$rc" == 0 ]] && pass "6. heredoc, comment, quoted text, ||, grep -c, head -n -1, || true: not flagged" \
  || fail "6. false positives" "rc=$rc $(cat "$T/out")"

# 7. continued pipelines and the other early-exit forms
cat >"$T/more.sh" <<'EOF'
#!/usr/bin/env bash
set -o pipefail
a=$(find . -type f \
  | grep -m1 x)
b=$(git log |
  grep -qxF y)
c=$(ls | head -n 3)
d="$(sed -n "s/a/b/p" "$f" | grep -m1 "x")"
EOF
rc="$(run "$T/more.sh")"
[[ "$rc" == 1 && "$(grep -c SIGPIPE "$T/out")" == 4 ]] && grep -q 'more.sh:8: .*grep -m1' "$T/out" \
  && grep -q 'more.sh:3: .*grep -m1' "$T/out" && grep -q 'more.sh:5: .*grep -qxF' "$T/out" && grep -q 'more.sh:7: .*head' "$T/out" \
  && pass "7. continued pipelines caught at line 1; grep -m1, -qxF, head -n 3, and a pipe in a quoted command substitution with nested quotes caught" || fail "7. forms" "rc=$rc $(cat "$T/out")"

# 8. MUTATION control: cut the rule out of a copy -> the planted line passes
sed 's/return "grep " w\[i\]/return ""/; s/^        return "head"$/        return ""/' "$LINT" >"$T/cut.sh"
rc_cut=0; bash "$T/cut.sh" "$T/bad.sh" "$T/x.func.sh" >/dev/null 2>&1 || rc_cut=$?
[[ "$rc_cut" == 0 ]] && ! cmp -s "$LINT" "$T/cut.sh" \
  && pass "8. MUTATION control: with the rule cut out, the planted lines pass (rc=0)" || fail "8. mutation" "rc=$rc_cut"

echo "-- sigpipe-lint.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
