#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every pnpm install the pre-push gate runs is NON-INTERACTIVE
#          (SPL-1935). After a lockfile bump pnpm asks "The modules directory
#          will be removed and reinstalled from scratch. Proceed?" and the
#          hook waited on a prompt nobody sees (c-296, 2026-10-15).
#   1. each of the four install sites runs pnpm with CI=1 and stdin from
#      /dev/null: the WUI part, the e2e part, the lint SFC modules install
#      and lint-wui-lock
#   2. CONTROL: on a copy of the gate with CI=1 or </dev/null removed from any
#      one site, that site's check FAILS (the stub "prompts")
#   pnpm is a stub that logs a violation and "prompts" (reads stdin for at most
#   2 s) when CI is not 1 or its stdin is not /dev/null. Every call runs with a
#   live stdin pipe and under a timeout, so no leg can hang.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
for v in $(compgen -e); do [[ "$v" == PRE_PUSH_* ]] && unset "$v"; done
# CI runners export CI=true: the gate must set it itself, so the test drops it.
unset CI
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fail() { echo "FAIL: $1${2:+ -- $2}"; fails=$((fails + 1)); }
RUN="$PROJ_ROOT/src/bash/run"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
# The e2e part puts $HOME/.local/bin first on PATH: an empty HOME keeps a real pnpm out.
export HOME="$T/home"; mkdir -p "$HOME"

mkdir -p "$T/bin"
cat >"$T/bin/pnpm" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == install ]]; then
  bad=""
  [[ "${CI:-}" == 1 ]] || bad+=" ci"
  [[ "$(readlink /proc/self/fd/0)" == /dev/null ]] || bad+=" stdin"
  if [[ -n "$bad" ]]; then
    echo "PROMPT$bad" >>"$PNPM_LOG"
    echo "The modules directory will be removed and reinstalled from scratch. Proceed? (Y/n)"
    read -r -t 2 _ || true
    exit 1
  fi
  echo "OK" >>"$PNPM_LOG"
  [[ " $* " == *" --lockfile-only "* ]] || mkdir -p node_modules/.pnpm node_modules/typescript node_modules/vue
  exit 0
fi
exit 0
EOF
chmod +x "$T/bin/pnpm"
export PATH="$T/bin:$PATH"

# A tree with a WUI and no node_modules; a git repo for the e2e bundle key.
new_tree() {
  local r="$1"; rm -rf "$r"; mkdir -p "$r/csi-spl-wui"
  echo lock >"$r/csi-spl-wui/pnpm-lock.yaml"; echo '{}' >"$r/csi-spl-wui/package.json"
  git -C "$r" init -q && git -C "$r" add -A && git -C "$r" commit -qm base
}

# call_site <run dir> <site> <tree>: one install site, in a fresh bash with
# that gate copy sourced, stdin a live pipe that never sends, under a timeout.
call_site() {
  timeout -k 2 20 bash -c '
    run="$1" site="$2" r="$3"
    do_log() { echo "$*"; }
    do_check_dist_hygiene() { return 0; }
    APP_PATH="$r"
    . "$run/check-pre-push.func.sh"
    case "$site" in
      wui) _pp_part_wui "$r" ;;
      e2e) _PPE_FILES="tests/e2e/x.test.mjs" PRE_PUSH_E2E_GENERATE=true PRE_PUSH_E2E_BUNDLES="$r/.bundles" \
             _pp_part_wui_e2e "$r" ;;
      modules) _PP_TOP="$r" _ppl_wui_modules ;;
      lock) _PPL_FILES[lint-wui-lock]=ALL; _ppl_run_one lint-wui-lock "$r" ;;
    esac' _ "$1" "$2" "$3" >"$T/out.$2" 2>&1 < <(exec sleep 25 2>/dev/null)
}

# check <run dir> <site>: 0 when the site ran pnpm install non-interactively.
check() {
  local r="$T/tree.$2"; new_tree "$r"
  : >"$T/pnpm.log"
  PNPM_LOG="$T/pnpm.log" call_site "$1" "$2" "$r"
  grep -qx OK "$T/pnpm.log" && ! grep -q PROMPT "$T/pnpm.log"
}

SITES="wui e2e modules lock"

# 1. the real gate
for s in $SITES; do
  if check "$RUN" "$s"; then pass "1. $s: pnpm install runs with CI=1 and stdin </dev/null"
  else fail "1. $s: pnpm install runs with CI=1 and stdin </dev/null -- $(paste -sd' ' "$T/pnpm.log") / $(tail -3 "$T/out.$s" | paste -sd' ')"; fi
done

# 2. CONTROL: strip CI=1, then </dev/null, from one site's install line only.
declare -A FILE=([wui]=check-pre-push.func.sh [e2e]=check-pre-push-e2e.func.sh
                 [modules]=check-pre-push-lint.func.sh [lock]=check-pre-push-lint.func.sh)
# shellcheck disable=SC2016  # literal source text to find, not expansions
declare -A LINE=([wui]='"$2" install --frozen-lockfile'
                 [e2e]='"$(_pp_pnpm)" install --frozen-lockfile'
                 [modules]='"$pn" install --frozen-lockfile --reporter=silent'
                 [lock]='"$(_pp_pnpm)" install --frozen-lockfile --lockfile-only')
for s in $SITES; do
  for cut in 'CI=1 ' ' </dev/null'; do
    c="$T/ctl"; rm -rf "$c"; mkdir -p "$c"; cp "$RUN"/check-pre-push*.func.sh "$c/"
    f="$c/${FILE[$s]}"
    n="$(grep -cF -- "${LINE[$s]}" "$f")"
    if [[ "$n" != 1 ]]; then fail "2. $s: the control finds its install line once in ${FILE[$s]}" "found $n"; continue; fi
    CUT="$cut" KEY="${LINE[$s]}" perl -i -pe 'if (index($_, $ENV{KEY}) >= 0) { s/\Q$ENV{CUT}\E//; }' "$f"
    if cmp -s "$f" "$RUN/${FILE[$s]}"; then fail "2. $s: the control removes '${cut# }' from its install line" "line unchanged"; continue; fi
    if check "$c" "$s"; then fail "2. CONTROL $s without '${cut# }': the check must fail" "it passed"
    else pass "2. CONTROL $s without '${cut# }': the check fails"; fi
  done
done

[[ "$fails" -eq 0 ]] && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
