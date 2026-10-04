#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: tmp-path-lint.py (the lint-tmp-path pre-push part) refuses a fixed
#          /tmp or /var/tmp write in a test file, and only that.
#   1. an e2e quoted path and a /var/tmp quoted path are flagged at file:line
#   2. mkdtemp, mktemp -d, t.TempDir and SHOT_DIR pass
#   3. a baselined hit passes; a second literal in that file fails
#   4. not a write: a comment, a longer fixture string, a shell grep of a path
#   5. a shell redirect, a $$ redirect and an assignment are flagged
#   6. a Go quoted path is flagged
#   7. MUTATION: the same plant passes once forbidden() is cut out
#   8. a missing baseline fails closed
#   9. the pre-push part: a pushed test is a FAIL and names its command;
#      mktemp passes. One scanner only, so this file stays under the
#      per-test timeout.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
LINT="$TEST_DIR/../scripts/tmp-path-lint.py"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
printf '%s\n' '# none' >"$T/base.txt"
run() { local rc=0; python3 "$LINT" --baseline "$T/base.txt" "$@" >"$T/out" 2>"$T/err" || rc=$?; echo "$rc"; }

# 1. quoted fixed paths
printf '%s\n' "const SHOT = '/tmp/shared-shot.png'" >"$T/bad.mjs"
printf '%s\n' "const OUT = process.env.OUT || '/var/tmp/fixed-proof'" >"$T/var.mjs"
rc="$(run "$T/bad.mjs" "$T/var.mjs")"
[[ "$rc" == 1 ]] && grep -q "$T/bad.mjs:1: /tmp/shared-shot.png" "$T/out" \
  && grep -q "$T/var.mjs:1: /var/tmp/fixed-proof" "$T/out" \
  && pass "1. a quoted /tmp path and a quoted /var/tmp path are flagged" \
  || fail "1. quoted paths" "rc=$rc $(cat "$T/out" "$T/err")"

# 2. the per-run forms
cat >"$T/ok.mjs" <<'EOF'
import { mkdtempSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
const dir = process.env.SHOT_DIR || mkdtempSync(join(tmpdir(), 'shot-'))
EOF
printf '%s\n' '#!/bin/bash' 'd=$(mktemp -d)' 'echo x >"$d/out"' 'rm -rf "$d"' >"$T/ok.tst.sh"
cat >"$T/ok_test.go" <<'EOF'
package p

import "testing"

func TestA(t *testing.T) {
	dir := t.TempDir()
	_ = dir
}
EOF
rc="$(run "$T/ok.mjs" "$T/ok.tst.sh" "$T/ok_test.go")"
[[ "$rc" == 0 ]] && pass "2. mkdtemp, mktemp -d, t.TempDir and SHOT_DIR pass" \
  || fail "2. allowed forms" "rc=$rc $(cat "$T/out" "$T/err")"

# 3. ratchet: the baselined literal passes, a new one fails
printf '%s\n' "$T/old.mjs|/tmp/old-shot.png|1" >"$T/base.txt"
printf '%s\n' "const SHOT = '/tmp/old-shot.png'" >"$T/old.mjs"
rc="$(run "$T/old.mjs")"
[[ "$rc" == 0 ]] && pass "3a. a baselined literal is not a new hit" \
  || fail "3a. baseline holds" "rc=$rc $(cat "$T/out" "$T/err")"
printf '%s\n' "const SHOT = '/tmp/old-shot.png'" "const OTHER = '/tmp/new-shot.png'" >"$T/old.mjs"
rc="$(run "$T/old.mjs")"
[[ "$rc" == 1 ]] && grep -q "/tmp/new-shot.png" "$T/out" && ! grep -q "/tmp/old-shot.png" "$T/out" \
  && pass "3b. a second literal fails and the baselined one stays quiet" \
  || fail "3b. new literal" "rc=$rc $(cat "$T/out" "$T/err")"
printf '%s\n' '# none' >"$T/base.txt"

# 4. not a write
printf '%s\n' "// const SHOT = '/tmp/commented.png'" 'const dir = process.env.SHOT_DIR' >"$T/comment.mjs"
printf '%s\n' "line=\$(python3 -c 'print(\"/tmp/d.md\")')" >"$T/fixture.tst.sh"
printf '%s\n' "grep -q '/tmp/needle' \"\$f\"" >"$T/grep.tst.sh"
rc="$(run "$T/comment.mjs" "$T/fixture.tst.sh" "$T/grep.tst.sh")"
[[ "$rc" == 0 ]] && pass "4. a comment, a fixture string and a grep needle pass" \
  || fail "4. non-writes" "rc=$rc $(cat "$T/out" "$T/err")"

# 5. shell writes
printf '%s\n' '#!/bin/bash' 'echo out >/tmp/shared-shot' >"$T/redir.tst.sh"
printf '%s\n' '#!/bin/bash' 'echo out >/tmp/gmv.$$' >"$T/pid.tst.sh"
printf '%s\n' '#!/bin/bash' "OUT='/var/tmp/fixed-proof'" >"$T/assign.tst.sh"
rc="$(run "$T/redir.tst.sh" "$T/pid.tst.sh" "$T/assign.tst.sh")"
[[ "$rc" == 1 ]] && grep -q "/tmp/shared-shot" "$T/out" && grep -qF '/tmp/gmv.$$' "$T/out" \
  && grep -q "/var/tmp/fixed-proof" "$T/out" \
  && pass "5. a redirect, a \$\$ redirect and an assignment are flagged" \
  || fail "5. shell writes" "rc=$rc $(cat "$T/out" "$T/err")"

# 6. Go
printf '%s\n' 'package p' 'import "os"' 'func init() { os.WriteFile("/tmp/fixed-go", []byte("x"), 0o644) }' >"$T/bad_test.go"
rc="$(run "$T/bad_test.go")"
[[ "$rc" == 1 ]] && grep -q "$T/bad_test.go:3: /tmp/fixed-go" "$T/out" \
  && pass "6. a Go quoted /tmp path is flagged" \
  || fail "6. go" "rc=$rc $(cat "$T/out" "$T/err")"

# 7. mutation: cut the rule out, the plant passes
sed 's/return token.startswith("\/tmp\/") or token.startswith("\/var\/tmp\/")/return False/' "$LINT" >"$T/neutered.py"
rc=0
python3 "$T/neutered.py" --baseline "$T/base.txt" "$T/bad.mjs" >"$T/out" 2>"$T/err" || rc=$?
[[ "$rc" == 0 ]] && pass "7. MUTATION: neutering forbidden() lets the plant pass" \
  || fail "7. mutation" "rc=$rc $(cat "$T/out" "$T/err")"

# 8. missing baseline
rc=0
python3 "$LINT" --baseline "$T/absent.txt" "$T/bad.mjs" >"$T/out" 2>"$T/err" || rc=$?
[[ "$rc" == 1 ]] && grep -q 'no .*/absent.txt' "$T/err" \
  && pass "8. a missing baseline fails closed" \
  || fail "8. missing baseline" "rc=$rc $(cat "$T/out" "$T/err")"


# 9. the pre-push part refuses the push and names the reproduce command
RUN_DIR="$TEST_DIR/../run"
do_log() { echo "$*"; }
do_check_dist_hygiene() { return 0; }
# shellcheck source=../run/check-pre-push.func.sh
. "$RUN_DIR/check-pre-push.func.sh"
R="$T/repo"
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
rm -rf "$R"
mkdir -p "$R/csi-spl-orc/src/bash/tests"
git -C "$R" init -q
printf '%s\n' '# none' >"$R/.tmp-path-baseline.txt"
git -C "$R" add .tmp-path-baseline.txt
git -C "$R" commit -qm baseline
git -C "$R" branch -f base
LOG="$T/pre-push.log"
gate() {
  local rc=0 out
  : >"$LOG"
  out="$(PRE_PUSH_LINT_ONLY=lint-tmp-path PRE_PUSH_EXTRA_PATH='' PRE_PUSH_ONLY=lint \
    PRE_PUSH_TREE="$R" PRE_PUSH_BASE=base PRE_PUSH_LOG="$LOG" PRE_PUSH_NO_CACHE=1 \
    PRE_PUSH_CACHE="$T/cache" do_check_pre_push 2>&1)" || rc=$?
  printf '%s\n' "$out" >"$T/out"
  echo "$rc"
}
verdict() { sed -nE "s/.* PART $1 ([A-Za-z-]+) .*/\\1/p" "$LOG" | tail -1; }
printf '%s\n' '#!/bin/bash' 'echo out >/tmp/shared-shot' >"$R/csi-spl-orc/src/bash/tests/shot.tst.sh"
git -C "$R" add -A
git -C "$R" commit -qm tmp-path
rc="$(gate)"
[[ "$rc" == 1 && "$(verdict lint-tmp-path)" == FAIL ]] \
  && grep -q "tmp-path-lint.py csi-spl-orc/src/bash/tests/shot.tst.sh" "$T/out" \
  && grep -q "PART lint-shellcheck SKIP-untouched" "$LOG" \
  && pass "9a. a fixed /tmp write in a pushed test is a lint-tmp-path FAIL" \
  || fail "9a. gate" "rc=$rc verdict=$(verdict lint-tmp-path)"
printf '%s\n' '#!/bin/bash' 'out=$(mktemp)' 'echo out >"$out"' 'rm -f "$out"' >"$R/csi-spl-orc/src/bash/tests/shot.tst.sh"
git -C "$R" add -A
git -C "$R" commit -qm tmp-path-fix
rc="$(gate)"
[[ "$rc" == 0 && "$(verdict lint-tmp-path)" == PASS ]] \
  && pass "9b. mktemp passes lint-tmp-path" \
  || fail "9b. gate fixed" "rc=$rc verdict=$(verdict lint-tmp-path)"

[[ "$fails" -eq 0 ]] && echo "PASS: all $(basename "$0") assertions"
exit "$fails"
