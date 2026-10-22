#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_gh_box_token_put / do_gh_box_token_check (SPL-2897) put and prove
#          one fine-grained GitHub token per box (secret-rotation.md 5.2).
#   1. put, dry run (DRY_RUN unset): token on stdin, names the login; writes
#      nothing, no gh login
#   2. put, DRY_RUN=0: the token file is the token, mode 600; the old one kept
#      as token.prev (600); gh's stored login replaced via stdin; the token is
#      in neither gh's argv nor the output
#   3. RED CONTROL: put with the token on argv -> refused, nothing written,
#      no gh call
#   4. a classic token on stdin -> refused, nothing written
#   5. RED CONTROL: check on a classic file token reports "classic", exit 1
#   6. check on a fine-grained file token, gh login the same -> exit 0 with
#      login, type, expiry and permissions; no token in the output
#   7. check: gh's stored login is another token -> same-as-file=no, exit 1
#   8. put refused while token.prev exists; GH_BOX_TOKEN_DROP_PREV=1 is a dry
#      run, then removes it with DRY_RUN=0
#   9. GitHub does not answer to the token -> put refuses, nothing written
#  10. DRY_RUN=2 -> refused before any gh call
#  11. CONTROL: a put that logs the token is caught by the leak check
#  12. check with no token file still reports gh's stored login, exit 1
#  13. both actions are reachable through ./run (one action per file: run.sh
#      registers only do_<file name>); CONTROL: an action name with no file
#      of its own is "NOT found" through the same probe
# gh is a stub. No network, no GitHub.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
ACTION="$PROJ_ROOT/src/bash/run/gh-box-token-put.func.sh"
CHECK_ACTION="$PROJ_ROOT/src/bash/run/gh-box-token-check.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
require_action "$ACTION"
require_action "$CHECK_ACTION"

# built from pieces and short, so no secret scanner sees a token shape here
FG="github""_pat_""FAKEFGNEW0001"
FG2="github""_pat_""FAKEFGOTHER02"
CL="ghp""_FAKECLASSIC1"
mkdir -p "$T/home/.github" "$T/stub"

cat >"$T/stub/gh" <<'EOF_GH'
#!/usr/bin/env bash
echo "$*" >>"$STUB_LOG"
good() { [[ " $STUB_GOOD " == *" ${GH_TOKEN:-} "* ]]; }
case "$*" in
  "api user --jq .login") good || { echo "HTTP 401: Bad credentials" >&2; exit 1; }; echo box-bot ;;
  "api -i user") good || exit 1
    printf 'HTTP/2.0 200 OK\nGithub-Authentication-Token-Expiration: 2027-04-20 10:00:00 UTC\n\n{"login":"box-bot"}\n' ;;
  "api repos/"*) good || exit 1; echo "pull,push,triage" ;;
  "auth token -h github.com") [[ -z "${GH_TOKEN:-}" && -s "$STUB_GH_LOGIN" ]] || exit 1; cat "$STUB_GH_LOGIN" ;;
  "auth login -h github.com --with-token") [[ -z "${GH_TOKEN:-}" ]] || exit 1; cat >"$STUB_GH_LOGIN" ;;
  *) echo "gh stub: unexpected $*" >&2; exit 3 ;;
esac
EOF_GH
chmod +x "$T/stub/gh"

# act_file <action file> <func> <stdin text> [VAR=value ...] [-- argv...] -> rc;
# output in $T/out, gh argv in $T/gh.log
act_file() {
  local file="$1" func="$2" in="$3"; shift 3
  local envs=() argv=()
  while (($#)); do [[ "$1" == -- ]] && { shift; argv=("$@"); break; }; envs+=("$1"); shift; done
  : >"$T/gh.log"
  printf '%s\n' "$in" | env -u DRY_RUN -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOX_TOKEN_DROP_PREV \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/gh.log" STUB_GH_LOGIN="$T/gh-login" \
    STUB_GOOD="$FG $FG2 $CL" GH_BOX_TOKEN_REPO=example-org/example-repo \
    ACTION_FILE="$file" CHECK_FILE="$CHECK_ACTION" FUNC="$func" "${envs[@]}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }; do_require_bin() { :; }
    source "$CHECK_FILE"; source "$ACTION_FILE"
    "$FUNC" "$@"' _ "${argv[@]}" >"$T/out" 2>&1
}
put() { local in="$1"; shift; act_file "$ACTION" do_gh_box_token_put "$in" "$@"; }
check() { act_file "$CHECK_ACTION" do_gh_box_token_check ""; }
tokfile="$T/home/.github/token"
set_file() { (umask 077; printf '%s\n' "$1" >"$tokfile"); }
reset() { rm -f "$tokfile" "$tokfile.prev" "$T/gh-login"; set_file "$CL"; (umask 077; printf '%s\n' "$CL" >"$T/gh-login"); }
# no_leak <token> - the token is in neither gh's argv nor the action's output
no_leak() { ! grep -qF "$1" "$T/gh.log" "$T/out"; }
same() { [[ "$(cat "$1")" == "$2" ]]; }

# --- 1. put, dry run ------------------------------------------------------------------------
reset; put "$FG"; rc=$?
[[ $rc -eq 0 ]] && same "$tokfile" "$CL" && [[ ! -e "$tokfile.prev" ]] && same "$T/gh-login" "$CL" && no_leak "$FG" \
  && grep -q 'OK DRY_RUN the token is fine-grained and answers as box-bot; nothing written' "$T/out" \
  && pass "1. put dry run: names the login, writes nothing" || fail "1. rc=$rc $(cat "$T/out" "$T/gh.log")"

# --- 2. put, DRY_RUN=0 --------------------------------------------------------------------------
reset; put "$FG" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && same "$tokfile" "$FG" && [[ "$(stat -c %a "$tokfile")" == 600 ]] \
  && same "$tokfile.prev" "$CL" && [[ "$(stat -c %a "$tokfile.prev")" == 600 ]] \
  && same "$T/gh-login" "$FG" && grep -qx 'auth login -h github.com --with-token' "$T/gh.log" && no_leak "$FG" \
  && pass "2. put DRY_RUN=0: file 600 = token, old kept as .prev 600, gh login via stdin, no leak" || fail "2. rc=$rc $(cat "$T/out" "$T/gh.log")"

# --- 3. RED CONTROL: the token on argv ---------------------------------------------------------------
reset; put "" DRY_RUN=0 -- "$FG"; rc=$?
[[ $rc -eq 2 && ! -s "$T/gh.log" ]] && same "$tokfile" "$CL" && no_leak "$FG" && grep -q 'takes no argument: the token goes on stdin only' "$T/out" \
  && pass "3. CONTROL: put with the token on argv -> refused, nothing written, no gh call" || fail "3. rc=$rc $(cat "$T/out" "$T/gh.log")"

# --- 4. a classic token on stdin ----------------------------------------------------------------------
reset; set_file "$FG2"; put "$CL" DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/gh.log" ]] && same "$tokfile" "$FG2" && no_leak "$CL" && grep -q 'is classic, not fine-grained' "$T/out" \
  && pass "4. a classic token on stdin -> refused, nothing written" || fail "4. rc=$rc $(cat "$T/out" "$T/gh.log")"

# --- 5. RED CONTROL: check on a classic token -----------------------------------------------------------
reset; check; rc=$?
[[ $rc -eq 1 ]] && grep -q 'login=box-bot type=classic' "$T/out" && grep -q 'FAIL file token is classic' "$T/out" && no_leak "$CL" \
  && pass "5. CONTROL: check on a classic token reports classic, exit 1" || fail "5. rc=$rc $(cat "$T/out")"

# --- 6. check on a fine-grained token -------------------------------------------------------------------
reset; put "$FG" DRY_RUN=0 >/dev/null; check; rc=$?
[[ $rc -eq 0 ]] && grep -q 'file token: login=box-bot type=fine-grained expires=2027-04-20 10:00:00 UTC repo=example-org/example-repo permissions=pull,push,triage' "$T/out" \
  && grep -q 'gh stored login: type=fine-grained same-as-file=yes' "$T/out" && grep -q 'INFO .*token.prev is still on this box' "$T/out" && no_leak "$FG" \
  && pass "6. check fine-grained: exit 0, login, type, expiry, permissions, no leak" || fail "6. rc=$rc $(cat "$T/out")"

# --- 7. gh's stored login is another token ----------------------------------------------------------------
(umask 077; printf '%s\n' "$FG2" >"$T/gh-login"); check; rc=$?
[[ $rc -eq 1 ]] && grep -q 'same-as-file=no' "$T/out" && no_leak "$FG2" \
  && pass "7. check: gh login is another token -> same-as-file=no, exit 1" || fail "7. rc=$rc $(cat "$T/out")"

# --- 8. token.prev blocks a second put; drop it ---------------------------------------------------------------
put "$FG2" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && same "$tokfile" "$FG" && grep -q 'token.prev exists' "$T/out" \
  && pass "8. put refused while token.prev exists" || fail "8. rc=$rc $(cat "$T/out")"
put "" GH_BOX_TOKEN_DROP_PREV=1; rc=$?
[[ $rc -eq 0 && -e "$tokfile.prev" ]] && grep -q 'DRY_RUN would remove' "$T/out" \
  && pass "8. drop-prev dry run keeps it" || fail "8b. rc=$rc $(cat "$T/out")"
put "" GH_BOX_TOKEN_DROP_PREV=1 DRY_RUN=0; rc=$?
[[ $rc -eq 0 && ! -e "$tokfile.prev" ]] && same "$tokfile" "$FG" \
  && pass "8. drop-prev DRY_RUN=0 removes only token.prev" || fail "8c. rc=$rc $(cat "$T/out")"

# --- 9. GitHub does not answer -----------------------------------------------------------------------------------
reset; put "github""_pat_""FAKEREVOKED9" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && same "$tokfile" "$CL" && [[ ! -e "$tokfile.prev" ]] && grep -q 'GitHub does not answer' "$T/out" \
  && pass "9. a token GitHub refuses -> nothing written" || fail "9. rc=$rc $(cat "$T/out")"

# --- 10. DRY_RUN=2 ------------------------------------------------------------------------------------------------
reset; put "$FG" DRY_RUN=2; rc=$?
[[ $rc -eq 2 && ! -s "$T/gh.log" ]] && same "$tokfile" "$CL" && pass "10. DRY_RUN=2 -> refused before any gh call" || fail "10. rc=$rc $(cat "$T/out")"

# --- 11. CONTROL: the leak check sees a logged token ----------------------------------------------------------------
sed 's#^  type="\$(gh_box_token_type "\$tok")"$#&; echo "got $tok"#' "$ACTION" >"$T/leaky.func.sh"
if cmp -s "$ACTION" "$T/leaky.func.sh"; then fail "11. CONTROL could not plant the leak (the type line changed): update the sed"
else reset; act_file "$T/leaky.func.sh" do_gh_box_token_put "$FG"; ! no_leak "$FG" && pass "11. CONTROL: a logged token is caught by the leak check" || fail "11. CONTROL: the leak check missed it"; fi

# --- 12. no token file: gh's stored login is still reported ------------------------------------------------------------
reset; rm -f "$tokfile"; check; rc=$?
[[ $rc -eq 1 ]] && grep -q 'FAIL no readable token file' "$T/out" && grep -q 'gh stored login: type=classic same-as-file=no' "$T/out" && no_leak "$CL" \
  && pass "12. no token file -> FAIL, and gh's stored login is still reported" || fail "12. rc=$rc $(cat "$T/out")"

# --- 13. reachable through ./run --------------------------------------------------------------------------------------
# via_run <action> <stdin> -> rc; output in $T/out. The real ./run, the stub gh, a throwaway HOME.
via_run() {
  printf '%s\n' "$2" | (cd "$PROJ_ROOT" && env -u DRY_RUN -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOX_TOKEN_DROP_PREV \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/gh.log" STUB_GH_LOGIN="$T/gh-login" \
    STUB_GOOD="$FG $FG2 $CL" GH_BOX_TOKEN_REPO=example-org/example-repo ./run -a "$1") >"$T/out" 2>&1
}
reset; via_run do_gh_box_token_check ""; rc=$?
[[ $rc -ne 0 ]] && ! grep -q 'NOT found' "$T/out" && grep -q 'login=box-bot type=classic' "$T/out" && no_leak "$CL" \
  && pass "13. ./run -a do_gh_box_token_check runs the action" || fail "13. rc=$rc $(tail -5 "$T/out")"
reset; via_run do_gh_box_token_put "$FG"; rc=$?
[[ $rc -eq 0 ]] && ! grep -q 'NOT found' "$T/out" && grep -q 'OK DRY_RUN the token is fine-grained and answers as box-bot' "$T/out" && same "$tokfile" "$CL" && no_leak "$FG" \
  && pass "13. ./run -a do_gh_box_token_put runs the action (dry run)" || fail "13. rc=$rc $(tail -5 "$T/out")"
via_run do_gh_box_token ""; rc=$?
[[ $rc -ne 0 ]] && grep -q 'NOT found' "$T/out" \
  && pass "13. CONTROL: ./run -a do_gh_box_token (no file of its own) -> NOT found" || fail "13. CONTROL rc=$rc $(tail -5 "$T/out")"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
