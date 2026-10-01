#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the LINT parts of do_check_pre_push (check-pre-push-lint.func.sh)
#          run CI's scanner actions on the TOUCHED files and block a new
#          finding, but never a finding in a file the push does not touch.
#   1. a pushed .sh with an SC1087 error is REFUSED (PART lint-shellcheck FAIL)
#   2. a clean pushed .sh passes, although an UNTOUCHED file carries a finding
#   3. a touched file whose finding is already on the base -> WARN, not blocking
#   4. a missing shellcheck is a FAIL naming do_install_lint_tools, not a skip
#   5. a broken .json is a lint-syntax FAIL
#   6. routing: workflow -> actionlint, Dockerfile -> hadolint, wui .mjs ->
#      eslint, a hub .sh -> syntax but not shellcheck (not CI 67's scope), the
#      action sec-shellcheck itself -> its whole scope (ALL)
#   7. the FAIL prints the exact command that reproduces the finding
#   8. with the REAL shellcheck (when installed): SC1087 refused, clean passes
#   9. PRE_PUSH_LINT=0 skips every lint part (the rollback), and says so
#  10. an extension-less #!/bin/bash script with a syntax error -> lint-syntax FAIL
#   Scanners are stubs on PATH (hermetic: the CI runner has no shellcheck);
#   leg 8 uses the real binary that do_install_lint_tools puts on the box.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
RUN_DIR=$(cd "$TEST_DIR/../run" && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
REAL_SC="$(command -v shellcheck 2>/dev/null || true)"
[[ -z "$REAL_SC" && -x "$HOME/.local/bin/shellcheck" ]] && REAL_SC="$HOME/.local/bin/shellcheck"

# --- stub scanners --------------------------------------------------------
STUB="$T/stub"; mkdir -p "$STUB"
# The shellcheck stub flags the control, and any "$name[" (SC1087) in a scanned file.
cat >"$STUB/shellcheck" <<'EOF'
#!/usr/bin/env bash
[[ "${SEC_SHELLCHECK_PHASE:-}" == control ]] && { echo "bad.sh:2:1: error: glob [SC2144]"; exit 1; }
rc=0
for f in "$@"; do
  [[ -f "$f" ]] || continue
  if grep -qE '"\$[A-Za-z_]+\[' "$f"; then echo "$f:1:1: error: braces [SC1087]"; rc=1; fi
done
exit $rc
EOF
cat >"$STUB/trufflehog" <<'EOF'
#!/usr/bin/env bash
[[ "${SEC_TRUFFLEHOG_PHASE:-}" == control ]] && echo '{"DetectorName":"AWS"}'
exit 0
EOF
chmod +x "$STUB"/*
# yq/jq/python3 are real (/usr/bin, /usr/local/bin); shellcheck only via STUB.
BASE_PATH="$STUB:/usr/local/bin:/usr/bin:/bin"

do_log() { echo "$*"; }
do_check_dist_hygiene() { return 0; }
# shellcheck source=../run/sec-shellcheck.func.sh
. "$RUN_DIR/sec-shellcheck.func.sh"
# shellcheck source=../run/sec-trufflehog.func.sh
. "$RUN_DIR/sec-trufflehog.func.sh"
# shellcheck source=../run/check-pre-push.func.sh
. "$RUN_DIR/check-pre-push.func.sh"

# A repo whose base carries an UNTOUCHED script with a finding.
R="$T/repo"; SH="csi-spl-orc/src/bash/run"
new_repo() {
  rm -rf "$R"; mkdir -p "$R/$SH" "$R/csi-spl-api/src/bash"
  git -C "$R" init -q
  printf '#!/bin/bash\narr=(a b)\necho "$arr[1]"\n' >"$R/$SH/old-bad.sh"
  printf '#!/bin/bash\necho ok\n' >"$R/$SH/edited.sh"
  echo '{}' >"$R/seed.json"
  git -C "$R" add -A; git -C "$R" commit -qm seed; git -C "$R" branch -f base
}
commit() { git -C "$R" add -A; git -C "$R" commit -qm "$1"; }

# Run the lint parts; echo "rc|<verdict lines>".
LOG="$T/pre-push.log"
lint() {
  : >"$LOG"
  local out rc=0
  out="$(PATH="${PP_PATH:-$BASE_PATH}" PRE_PUSH_EXTRA_PATH='' PRE_PUSH_ONLY=lint PRE_PUSH_TREE="$R" \
    PRE_PUSH_BASE=base PRE_PUSH_LOG="$LOG" PRE_PUSH_NO_CACHE=1 PRE_PUSH_CACHE="$T/cache" \
    do_check_pre_push 2>&1)" || rc=$?
  printf '%s\n' "$out" >"$T/out"
  echo "$rc"
}
verdict() { sed -nE "s/.* PART $1 ([A-Za-z-]+) .*/\\1/p" "$LOG" | tail -1; }

# 1. a new .sh with SC1087 is refused
new_repo
printf '#!/bin/bash\narr=(a b)\necho "$arr[0]"\n' >"$R/$SH/new-bad.sh"; commit bad
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-shellcheck)" == FAIL ]] \
  && pass "1. SC1087 in a pushed .sh is REFUSED" || fail "1. SC1087 refused" "rc=$rc verdict=$(verdict lint-shellcheck)"
# 7. ... and the FAIL names the command that reproduces it
grep -q "SEC_SHELLCHECK_FILES=.*$SH/new-bad.sh.*do_sec_shellcheck" "$T/out" \
  && pass "7. the FAIL prints the reproduce command" || fail "7. reproduce command" "$(grep -m1 reproduce "$T/out")"

# 2. a clean new .sh passes; the untouched old-bad.sh is not scanned
new_repo
printf '#!/bin/bash\necho "${arr[0]:-}"\n' >"$R/$SH/new-good.sh"; commit good
rc="$(lint)"
[[ "$rc" == 0 && "$(verdict lint-shellcheck)" == PASS ]] \
  && pass "2. a clean .sh passes; an untouched file's finding does not block" \
  || fail "2. clean passes" "rc=$rc verdict=$(verdict lint-shellcheck) $(grep -m2 -E 'SC1087|FATAL' "$T/out")"

# 3. editing a file whose finding is already on base -> WARN-pre-existing
new_repo
echo '# touched' >>"$R/$SH/old-bad.sh"; commit touch-old
rc="$(lint)"
[[ "$rc" == 0 && "$(verdict lint-shellcheck)" == WARN-pre-existing ]] \
  && pass "3. a pre-existing finding in a touched file WARNs, not blocks" \
  || fail "3. pre-existing WARN" "rc=$rc verdict=$(verdict lint-shellcheck)"

# 4. no shellcheck on PATH -> FAIL naming the installer
new_repo
printf '#!/bin/bash\necho ok\n' >"$R/$SH/edited.sh"; echo '# x' >>"$R/$SH/edited.sh"; commit edit
NOSC="$T/nosc"; mkdir -p "$NOSC"; cp "$STUB/trufflehog" "$NOSC/"
rc="$(PP_PATH="$NOSC:/usr/local/bin:/usr/bin:/bin" lint)"
if command -v -p shellcheck >/dev/null 2>&1 || [[ -x /usr/local/bin/shellcheck ]]; then
  pass "4. (system shellcheck present; missing-tool leg not applicable on this host)"
else
  [[ "$rc" == 1 && "$(verdict lint-shellcheck)" == FAIL ]] && grep -q 'do_install_lint_tools' "$T/out" \
    && pass "4. a missing shellcheck is a FAIL naming do_install_lint_tools" \
    || fail "4. missing tool FAILs" "rc=$rc verdict=$(verdict lint-shellcheck)"
fi

# 5. broken JSON -> lint-syntax FAIL
new_repo
echo '{ "a": ' >"$R/broken.json"; commit json
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-syntax)" == FAIL ]] \
  && pass "5. a broken .json is a lint-syntax FAIL" || fail "5. json syntax" "rc=$rc verdict=$(verdict lint-syntax)"

# 9. PRE_PUSH_LINT=0: the one-variable rollback skips the lint parts, loudly
new_repo
printf '#!/bin/bash\narr=(a b)\necho "$arr[0]"\n' >"$R/$SH/new-bad.sh"; commit bad
rc="$(PRE_PUSH_LINT=0 lint)"
[[ "$rc" == 0 ]] && grep -q 'PRE_PUSH_LINT=0' "$T/out" \
  && pass "9. PRE_PUSH_LINT=0 skips the lint parts and says so" || fail "9. kill switch" "rc=$rc"

# 10. an extension-less shell script is syntax-checked
new_repo
printf '#!/bin/bash\nif true; then\n' >"$R/$SH/hook"; commit hook
rc="$(lint)"
[[ "$rc" == 1 && "$(verdict lint-syntax)" == FAIL ]] \
  && pass "10. an extension-less #!/bin/bash script is bash -n checked" || fail "10. shebang syntax" "rc=$rc verdict=$(verdict lint-syntax)"

# 6. routing (the planner alone)
plan_of() {  # <changed-files...>
  local -A _PPL_FILES=()
  local _PPL_SELECTED=""
  _ppl_plan "$(printf '%s\n' "$@")" fast fast "$R"
  echo "$_PPL_SELECTED"
}
new_repo
mkdir -p "$R/.github/workflows" "$R/csi-spl-orc/src/docker/x" "$R/csi-spl-wui/src/lib" "$R/csi-spl-iac/src/bash/run"
for f in .github/workflows/a.yml csi-spl-orc/src/docker/x/Dockerfile csi-spl-wui/src/lib/a.mjs \
         csi-spl-api/src/bash/h.sh csi-spl-iac/src/bash/run/sec-shellcheck.func.sh; do echo x >"$R/$f"; done
p="$(plan_of .github/workflows/a.yml)";              [[ " $p " == *" lint-actionlint "* ]] && pass "6a. workflow -> actionlint" || fail "6a" "$p"
p="$(plan_of csi-spl-orc/src/docker/x/Dockerfile)";  [[ " $p " == *" lint-hadolint "* ]]   && pass "6b. Dockerfile -> hadolint" || fail "6b" "$p"
p="$(plan_of csi-spl-wui/src/lib/a.mjs)";            [[ " $p " == *" lint-eslint "* ]]     && pass "6c. wui .mjs -> eslint" || fail "6c" "$p"
p="$(plan_of csi-spl-api/src/bash/h.sh)"
[[ " $p " == *" lint-syntax "* && " $p " != *" lint-shellcheck "* ]] && pass "6d. hub .sh -> syntax, not shellcheck (not CI 67 scope)" || fail "6d" "$p"
declare -A _PPL_FILES=()
_ppl_plan "csi-spl-iac/src/bash/run/sec-shellcheck.func.sh" fast fast "$R" >/dev/null
[[ "${_PPL_FILES[lint-shellcheck]:-}" == ALL ]] && pass "6e. the shellcheck action changed -> its whole scope" || fail "6e" "${_PPL_FILES[lint-shellcheck]:-none}"
p="$(plan_of doc/readme.md)"
[[ " $p " != *" lint-shellcheck "* && " $p " != *" lint-syntax "* ]] && pass "6f. a doc-only push runs no scanner but trufflehog" || fail "6f" "$p"
unset _PPL_FILES

# 8. the REAL shellcheck, when installed
if [[ -n "$REAL_SC" ]]; then
  REAL="$T/real"; mkdir -p "$REAL"; ln -s "$REAL_SC" "$REAL/shellcheck"; cp "$STUB/trufflehog" "$REAL/"
  new_repo
  printf '#!/bin/bash\narr=(a b)\necho "$arr[0]"\n' >"$R/$SH/new-bad.sh"; commit bad
  rc="$(PP_PATH="$REAL:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 1 ]] && grep -q 'SC1087' "$T/out" \
    && pass "8a. real shellcheck: SC1087 refused" || fail "8a. real SC1087" "rc=$rc"
  new_repo
  printf '#!/bin/bash\narr=(a b)\necho "${arr[0]}"\n' >"$R/$SH/new-good.sh"; commit good
  rc="$(PP_PATH="$REAL:/usr/local/bin:/usr/bin:/bin" lint)"
  [[ "$rc" == 0 ]] && pass "8b. real shellcheck: clean passes, untouched finding ignored" || fail "8b. real clean" "rc=$rc $(grep -m3 SC "$T/out")"
else
  echo "INFO: no real shellcheck on this host -- leg 8 not run (./run -a do_install_lint_tools)"
fi

echo "-- check-pre-push-lint.tst.sh: $fails failed"
[ "$fails" -eq 0 ]
