#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: lib/bash/funcs/gh-box-token.func.sh (SPL-5366) - every reader takes
#          the box's GitHub token from ONE file, $HOME/.github/.csi/crs, and
#          ONE variable in it, ALL_CSI_GITHUB_TOKEN (owner HUM-10, t1 2afa48b4).
#   1. the iac, orc and utl copies are byte-identical
#   2. the default file is $HOME/.github/.csi/crs, the variable ALL_CSI_GITHUB_TOKEN
#   3. read: the owner's layout (GITHUB_TOKEN on another line) -> only
#      ALL_CSI_GITHUB_TOKEN; export, quotes and CRLF are stripped; the last line wins
#   4. RED CONTROL: no file -> FATAL naming the file, rc 1, nothing on stdout
#   5. RED CONTROL: a file with only GITHUB_TOKEN -> FATAL naming the variable,
#      rc 1: no fallback to another name, and the old $HOME/.github/token is
#      never read
#   6. export: GH_TOKEN unset -> the file's token; already set -> kept
#   7. the file is parsed, never sourced: a command in it does not run
#   8. no token value in any error message
# Fake tokens and a throwaway HOME only; the real crs is never read.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
LIB="$PROJ_ROOT/lib/bash/funcs/gh-box-token.func.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
H="$T/home"; mkdir -p "$H/.github/.csi"
crs="$H/.github/.csi/crs"

# lib <snippet> -> rc; stdout in $T/out, stderr in $T/err. A throwaway HOME,
# no GH_BOX_TOKEN_FILE and no GH_TOKEN from the caller.
lib() {
  env -u GH_BOX_TOKEN_FILE -u GH_TOKEN HOME="$H" LIB="$LIB" "${@:2}" bash -c 'source "$LIB"; '"$1" >"$T/out" 2>"$T/err"
}

# --- 1. the three copies ------------------------------------------------------
if cmp -s "$LIB" "$APP_ROOT/csi-spl-orc/lib/bash/funcs/gh-box-token.func.sh" &&
  cmp -s "$LIB" "$APP_ROOT/csi-spl-utl/lib/bash/funcs/gh-box-token.func.sh"; then
  pass "1. iac, orc and utl hold the same gh-box-token.func.sh"
else fail "1. the gh-box-token.func.sh copies differ: copy the iac one to orc and utl"; fi

# --- 2. the one file and the one variable -------------------------------------
lib 'gh_box_token_file; gh_box_token_var'
[[ "$(cat "$T/out")" == "$crs"$'\n'ALL_CSI_GITHUB_TOKEN ]] \
  && pass "2. the file is \$HOME/.github/.csi/crs, the variable ALL_CSI_GITHUB_TOKEN" || fail "2. got: $(cat "$T/out")"

# --- 3. read ------------------------------------------------------------------
printf 'ALL_CSI_GITHUB_TOKEN=tok-first\nGITHUB_TOKEN=tok-other\n' >"$crs"
lib gh_box_token_read; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == tok-first ]] && pass "3. the owner's layout -> ALL_CSI_GITHUB_TOKEN only" || fail "3a. rc=$rc out=$(cat "$T/out")"
printf 'ALL_CSI_GITHUB_TOKEN=tok-old\nexport ALL_CSI_GITHUB_TOKEN="tok-new"\r\nGITHUB_TOKEN=tok-other\n' >"$crs"
lib gh_box_token_read; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == tok-new ]] && pass "3. export, quotes and CR stripped; the last line wins" || fail "3b. rc=$rc out=$(cat "$T/out")"

# --- 4. RED CONTROL: no file ----------------------------------------------------
rm -f "$crs"; printf 'tok-legacy\n' >"$H/.github/token"
lib gh_box_token_read; rc=$?
[[ $rc -eq 1 && ! -s "$T/out" ]] && grep -q "FATAL no readable GitHub credential file $crs" "$T/err" \
  && pass "4. RED CONTROL: no crs file -> FATAL naming it, rc 1, the old token file not read" || fail "4. rc=$rc out=$(cat "$T/out") err=$(cat "$T/err")"

# --- 5. RED CONTROL: no ALL_CSI_GITHUB_TOKEN line --------------------------------
printf 'GITHUB_TOKEN=tok-other\nGH_TOKEN=tok-gh\n' >"$crs"
lib gh_box_token_read; rc=$?
[[ $rc -eq 1 && ! -s "$T/out" ]] && grep -q "FATAL $crs has no ALL_CSI_GITHUB_TOKEN=<token> line" "$T/err" \
  && pass "5. RED CONTROL: only GITHUB_TOKEN -> FATAL naming the variable, no fallback" || fail "5. rc=$rc out=$(cat "$T/out") err=$(cat "$T/err")"

# --- 6. export ------------------------------------------------------------------
printf 'ALL_CSI_GITHUB_TOKEN=tok-file\n' >"$crs"
lib 'gh_box_token_export && echo "GH_TOKEN=$GH_TOKEN"'; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == GH_TOKEN=tok-file ]] && pass "6. GH_TOKEN unset -> the file's token" || fail "6a. rc=$rc out=$(cat "$T/out")"
lib 'gh_box_token_export && echo "GH_TOKEN=$GH_TOKEN"' GH_TOKEN=tok-caller; rc=$?
[[ $rc -eq 0 && "$(cat "$T/out")" == GH_TOKEN=tok-caller ]] && pass "6. a GH_TOKEN the caller set is kept" || fail "6b. rc=$rc out=$(cat "$T/out")"
lib 'gh_box_token_export; echo "rc=$? GH_TOKEN=${GH_TOKEN:-unset}"' GH_BOX_TOKEN_FILE="$T/none"; rc=$?
[[ "$(cat "$T/out")" == "rc=1 GH_TOKEN=unset" ]] && pass "6. no file -> export fails, GH_TOKEN stays unset" || fail "6c. out=$(cat "$T/out")"

# --- 7. parsed, never sourced -----------------------------------------------------
printf 'touch %s/ran\nALL_CSI_GITHUB_TOKEN=tok-file\n' "$T" >"$crs"
lib gh_box_token_read; rc=$?
[[ $rc -eq 0 && ! -e "$T/ran" ]] && pass "7. a command in the file does not run" || fail "7. rc=$rc ran=$([[ -e "$T/ran" ]] && echo yes)"

# --- 8. no value in an error --------------------------------------------------------
printf 'GITHUB_TOKEN=tok-secret-8\n' >"$crs"; lib gh_box_token_read
! grep -q tok-secret-8 "$T/err" "$T/out" && pass "8. no token value in an error" || fail "8. a token value leaked"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1
