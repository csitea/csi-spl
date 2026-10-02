#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_setup_tpl_gen (016 T003: the CI iac-suite's tpl-gen) clones the
#          PINNED cnf/tpl-gen.ref and builds the venv where the render test
#          looks for it -- offline, against a local git repo and a stubbed
#          python3 (the stub venv's pip records its argv).
#   1. no TPL_GEN_REPO_URL -> refused, nothing cloned (no default URL)
#   2. fresh: HEAD == the pin (not the remote's tip), venv python executable,
#      pip asked for the dependency list
#   3. re-run: kept, pip not called again (idempotent)
#   CONTROLS: a clone at another sha is refused and NOT moved; a non-sha pin
#   is refused; a pin the remote lacks fails.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# a remote with two commits: the pin is the FIRST, the tip is the second
g() { git -C "$T/remote" -c user.name=t -c user.email=t@example.com "$@"; }
mkdir -p "$T/remote" && git -C "$T/remote" init -q
g commit -q --allow-empty -m pinned; PIN=$(g rev-parse HEAD)
g commit -q --allow-empty -m tip;    TIP=$(g rev-parse HEAD)

# python3 stub: `python3 -m venv <dir>` makes <dir>/bin/{python,pip}; pip logs
mkdir -p "$T/stub"
cat >"$T/stub/python3" <<'EOF'
#!/bin/sh
[ "$1" = -m ] && [ "$2" = venv ] || exit 9
mkdir -p "$3/bin" && printf '#!/bin/sh\n' >"$3/bin/python" \
  && printf '#!/bin/sh\necho "pip $*" >>"%s"\n' "$PIP_LOG" >"$3/bin/pip" && chmod +x "$3/bin/python" "$3/bin/pip"
EOF
chmod +x "$T/stub/python3"

# run_setup <ref> [VAR=value ...] -> rc; output in $T/out
run_setup() {
  local ref="$1"; shift
  mkdir -p "$T/proj/cnf"; echo "$ref" >"$T/proj/cnf/tpl-gen.ref"
  env PATH="$T/stub:$PATH" PIP_LOG="$T/pip.log" PROJ_PATH="$T/proj" APP_PATH="$T/app" "$@" bash -c '
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/setup-tpl-gen.func.sh"
    do_setup_tpl_gen' >"$T/out" 2>&1
}
URL="TPL_GEN_REPO_URL=file://$T/remote"

run_setup "$PIN"; rc=$?
[[ $rc -ne 0 && ! -e "$T/app/tpl-gen" ]] && grep -q 'TPL_GEN_REPO_URL must be set' "$T/out" \
  && pass "no TPL_GEN_REPO_URL: refused, nothing cloned" || fail "no TPL_GEN_REPO_URL: rc=$rc $(cat "$T/out")"

run_setup "$PIN" "$URL"; rc=$?
[[ $rc -eq 0 ]] && pass "fresh setup exits 0" || fail "fresh setup rc=$rc $(cat "$T/out")"
[[ "$(git -C "$T/app/tpl-gen" rev-parse HEAD 2>/dev/null)" == "$PIN" ]] \
  && pass "HEAD is the pin, not the remote tip" || fail "HEAD is not the pin $PIN (tip $TIP)"
[[ -x "$T/app/tpl-gen/src/python/tpl-gen/.venv/bin/python" ]] \
  && pass "venv python where the render test looks" || fail "no venv python"
grep -qx 'pip install -q jinja2 pyyaml jq colorama rich pprintjson requests' "$T/pip.log" 2>/dev/null \
  && pass "pip installs the do_tpl_gen dependency list" || fail "pip argv: $(cat "$T/pip.log" 2>/dev/null)"

run_setup "$PIN" "$URL"; rc=$?
[[ $rc -eq 0 && $(wc -l <"$T/pip.log") -eq 1 ]] && pass "re-run keeps the clone and the venv" \
  || fail "re-run rc=$rc, pip calls $(wc -l <"$T/pip.log")"

# CONTROL: a clone at another sha is refused and left where it is
git -C "$T/app/tpl-gen" -c advice.detachedHead=false checkout -q "$TIP"
run_setup "$PIN" "$URL"; rc=$?
[[ $rc -ne 0 && "$(git -C "$T/app/tpl-gen" rev-parse HEAD)" == "$TIP" ]] && grep -q 'not the pinned' "$T/out" \
  && pass "control: a clone off the pin is refused and not moved" || fail "control: off-pin clone rc=$rc"

rm -rf "$T/app"
run_setup "main" "$URL"; rc=$?
[[ $rc -ne 0 && ! -e "$T/app/tpl-gen" ]] && pass "control: a non-sha pin is refused" || fail "control: non-sha pin rc=$rc"
run_setup "0123456789abcdef0123456789abcdef01234567" "$URL"; rc=$?
[[ $rc -ne 0 ]] && pass "control: a pin the remote lacks fails" || fail "control: unknown pin accepted"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
