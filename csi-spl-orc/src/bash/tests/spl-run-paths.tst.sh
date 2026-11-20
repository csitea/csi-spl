#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_run_paths / spl_main_checkout / spl_cnf_path_expand
# (csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh, SPL-5527): box paths are
# derived at run time, never read from a literal in the cnf or the code.
#   1. a fixture <base>/opt/acme/acme-app main checkout and its worktree
#      <base>/opt/acme/acme-app-wt/c-901 derive the SAME paths:
#      SPL_ORG_DIR <base>/opt/acme, SPL_VAR_APP_DIR <base>/var/acme/acme-app,
#      SPL_WT_ROOT <main>-wt, SPL_DESK_DIR <main>-desk-cron, SPL_VAR_ORG_DIR
#      <base>/var/acme (exported); an env value wins.
#      Red control: run.sh's own ORG_PATH rule (dirname of APP_PATH) on the
#      worktree reads <base>/opt/acme/acme-app-wt, which is why the helper exists.
#   2. spl_cnf_path_expand replaces only the two tokens, never another $.
#   3. the cnf readers expand the tokens: spl_landed_repo_rows (a src_dir
#      ${SPL_ORG_DIR}/<repo> row resolves to the clone; red control: a
#      non-absolute org dir drops the row, never a relative path),
#      spl_file_stream_folders and spl_agent_log_pipe_paths.
#      W1-W3 of the R7 review (a-718): a cron without ./run, PROJ_PATH alone,
#      box restart's desk step fail fast; N2 the agent-log filter.
#   4. the live cnf: every src_dir / file_streams path value is a token form.
#   5. spl_var_app_subdir <var> <sub> (r71-01): the caller's var set to
#      $SPL_VAR_APP_DIR/<sub>; no tree or a bad name: rc 1, var untouched.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
LIB="$PROJ_ROOT/lib/bash/funcs/spl-run-paths.func.sh"
unset SPL_ORG_DIR SPL_VAR_APP_DIR SPL_WT_ROOT SPL_DESK_DIR SPL_VAR_ORG_DIR
B="$T/b"; M="$B/opt/acme/acme-app"; mkdir -p "$M"
git -C "$M" init -q && git -C "$M" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m a
git -C "$M" worktree add -q "$B/opt/acme/acme-app-wt/c-901" -b c-901 2>/dev/null
W="$B/opt/acme/acme-app-wt/c-901"
paths() { env -u SPL_ORG_DIR -u SPL_VAR_APP_DIR -u SPL_WT_ROOT -u SPL_DESK_DIR -u SPL_VAR_ORG_DIR APP_PATH="$1" "${@:2}" bash -c 'source "$0"; spl_run_paths && echo "$SPL_ORG_DIR|$SPL_VAR_APP_DIR|$SPL_WT_ROOT|$SPL_DESK_DIR"' "$LIB"; }
# the org var dir as a child process sees it: exported, not only set
var_org() { env -u SPL_ORG_DIR -u SPL_VAR_APP_DIR -u SPL_WT_ROOT -u SPL_DESK_DIR -u SPL_VAR_ORG_DIR APP_PATH="$1" "${@:2}" bash -c 'source "$0"; spl_run_paths && printenv SPL_VAR_ORG_DIR' "$LIB"; }
want="$B/opt/acme|$B/var/acme/acme-app|$M-wt|$M-desk-cron"
[[ "$(paths "$M")" == "$want" ]] && pass "1. main checkout derives $want" || fail "1. main: $(paths "$M")"
[[ "$(paths "$W")" == "$want" ]] && pass "1. its worktree derives the same paths" || fail "1. worktree: $(paths "$W")"
[[ "$(dirname "$W")" != "$B/opt/acme" ]] && pass "1. red control: run.sh's ORG_PATH rule on the worktree reads $(dirname "$W"), not the org dir" || fail "1. red control"
[[ "$(var_org "$M")" == "$B/var/acme" ]] && pass "1. main checkout exports SPL_VAR_ORG_DIR $B/var/acme" || fail "1. var org dir, main: '$(var_org "$M")'"
[[ "$(var_org "$W")" == "$B/var/acme" ]] && pass "1. its worktree exports the same SPL_VAR_ORG_DIR" || fail "1. var org dir, worktree: '$(var_org "$W")'"
[[ "$(var_org "$W" SPL_VAR_ORG_DIR=/x/var-org)" == "/x/var-org" ]] && pass "1. an env SPL_VAR_ORG_DIR wins" || fail "1. var org dir override: '$(var_org "$W" SPL_VAR_ORG_DIR=/x/var-org)'"
[[ "$(paths "$W" SPL_WT_ROOT=/x/wt)" == "$B/opt/acme|$B/var/acme/acme-app|/x/wt|$M-desk-cron" ]] && pass "1. an env SPL_WT_ROOT wins" || fail "1. env override: $(paths "$W" SPL_WT_ROOT=/x/wt)"
out="$(env -u APP_PATH -u PROJ_PATH bash -c 'source "$0"; SPL_RUN_PATHS_TOP=; spl_run_paths; echo rc=$?' "$LIB")"
[[ "$out" == "rc=1" ]] && pass "1. no APP_PATH, no PROJ_PATH, no file dir: rc 1" || fail "1. no tree: $out"
# 5. spl_var_app_subdir <var> <sub> (r71-01): sets the caller's var to
# $SPL_VAR_APP_DIR/<sub>; rc 1 and the var untouched when no dir is known
sub() { env -u SPL_ORG_DIR -u SPL_VAR_APP_DIR -u SPL_WT_ROOT -u SPL_DESK_DIR -u SPL_VAR_ORG_DIR "$@" bash -c 'source "$0"; f() { local v=old; spl_var_app_subdir "${N:-v}" x; echo "rc=$? v=$v wt=${SPL_WT_ROOT:-}"; }; f' "$LIB" 2>&1; }
out="$(sub APP_PATH="$W")"
[[ "$out" == "rc=0 v=$B/var/acme/acme-app/x wt=$M-wt" ]] && pass "5. spl_var_app_subdir v x: rc 0, the caller's local v=$B/var/acme/acme-app/x, SPL_WT_ROOT set in the same shell" || fail "5. derive: '$out'"
out="$(sub -u APP_PATH -u PROJ_PATH SPL_RUN_PATHS_TOP=)"
[[ "$out" == "rc=1 v=old wt=" ]] && pass "5. no tree: rc 1, v keeps its old value" || fail "5. no tree: '$out'"
out="$(sub APP_PATH="$W" N='a b')"
[[ "$out" == "rc=1 v=old wt=" ]] && pass "5. a bad name 'a b': rc 1, nothing set" || fail "5. bad name: '$out'"
# W2 (R7 a-718): run.sh's PROJ_PATH is <top>/<module>, so the tree is its parent
mkdir -p "$W/csi-spl-orc"
out="$(env -u SPL_ORG_DIR -u SPL_VAR_APP_DIR -u SPL_WT_ROOT -u SPL_DESK_DIR -u APP_PATH PROJ_PATH="$W/csi-spl-orc" bash -c 'source "$0"; spl_run_paths && echo "$SPL_ORG_DIR|$SPL_VAR_APP_DIR|$SPL_WT_ROOT|$SPL_DESK_DIR"' "$LIB")"
[[ "$out" == "$want" ]] && pass "1. PROJ_PATH=<worktree>/csi-spl-orc alone derives the same paths" || fail "1. PROJ_PATH only: $out"
# a relative gitdir: line (git worktree --relative-paths) resolves too
R="$B/opt/acme/acme-app-wt/c-902"; mkdir -p "$R"; printf 'gitdir: ../../acme-app/.git/worktrees/c-902\n' >"$R/.git"
[[ "$(paths "$R")" == "$want" ]] && pass "1. a worktree with a relative gitdir derives the same paths" || fail "1. relative gitdir: $(paths "$R")"
# W1 (R7 a-718): a cron that sources an action without ./run (no APP_PATH,
# no PROJ_PATH) still expands the cnf tokens, from the checkout the helper
# file sits in. Red control: without that fallback the token stays literal.
mine="$(APP_PATH="$APP_ROOT" bash -c 'source "$0"; spl_run_paths && echo "$SPL_VAR_APP_DIR"' "$LIB")"
cron_folders() { env -u APP_PATH -u PROJ_PATH -u SPL_ORG_DIR -u SPL_VAR_APP_DIR -u SPL_WT_ROOT -u SPL_DESK_DIR SPOOL_TEST=1 FILE_STREAMS_FOLDERS= SPOOL_BOX_ENV=/nonexistent \
  bash -c 'source "$1"; [[ -n "$3" ]] && SPL_RUN_PATHS_TOP=; spl_file_stream_folders "$2"' _ "$PROJ_ROOT/src/bash/run/spl-file-stream-follow.func.sh" "$T/cnf.yaml" "${1:-}" 2>/dev/null; }

# shellcheck disable=SC2016 # the tokens are literal
got="$(printf '%s\n' 'a ${SPL_ORG_DIR}/r' '"${SPL_VAR_APP_DIR}/x.log" $HOME ${OTHER}' | APP_PATH="$W" bash -c 'source "$0"; spl_cnf_path_expand' "$LIB")"
[[ "$got" == "a $B/opt/acme/r"$'\n'"\"$B/var/acme/acme-app/x.log\" \$HOME \${OTHER}" ]] && pass "2. only the two tokens are replaced" || fail "2. expand: $got"

# 3. the readers
cat >"$T/cnf.yaml" <<'Y'
env:
  steps:
    021-firebase-hosted-sites:
      sites:
        s1: {src_dir: "${SPL_ORG_DIR}/site-web"}
  box:
    landed_repos:
      - {name: rel, src_dir: "${SPL_ORG_DIR}/rel", trunk: master}
    file_streams:
      allow:
        - {id: agent-c-901, path: "${SPL_VAR_APP_DIR}/agent-logs/c-901.log"}
      folders:
        - "${SPL_VAR_APP_DIR}"
        - /var/log
Y
rows() { SNIPPET='spl_landed_repo_rows' in_orc SPOOL_TEST=1 LANE_LANDED_CNF="$T/cnf.yaml" SPOOL_LANDED_REPOS_FILE= "$@" 2>/dev/null; }
out="$(rows APP_PATH="$W")"
[[ "$out" == *"rel	$B/opt/acme/rel	master"* && "$out" == *"site-web	$B/opt/acme/site-web"* ]] && pass "3. landed repo rows: \${SPL_ORG_DIR}/<repo> -> the clone" || fail "3. rows: $out"
out="$(rows APP_PATH="$W" SPL_ORG_DIR=not-absolute)"
[[ "$out" != *"/rel"* ]] && pass "3. red control: an org dir that is not absolute leaves no src_dir row" || fail "3. red control rows: $out"
out="$(SNIPPET='spl_file_stream_folders "$CNF"' in_orc FILE_STREAMS_FOLDERS= SPOOL_BOX_ENV=/nonexistent CNF="$T/cnf.yaml" APP_PATH="$W" 2>/dev/null)"
[[ "$out" == "[\"$B/var/acme/acme-app\",\"/var/log\"]" ]] && pass "3. file-stream folders expanded" || fail "3. folders: $out"
out="$(SNIPPET='spl_agent_log_pipe_paths "$CNF"' in_orc CNF="$T/cnf.yaml" APP_PATH="$W" 2>/dev/null)"
[[ "$out" == "$B/var/acme/acme-app/agent-logs/c-901.log" ]] && pass "3. agent-log-pipe paths expanded" || fail "3. log pipe: $out"
out="$(cron_folders)"
[[ -n "$mine" && "$out" == "[\"$mine\",\"/var/log\"]" ]] && pass "3. W1: sourced without ./run (cron), the folders expand to $mine" || fail "3. W1 cron folders: '$out' (want $mine)"
out="$(cron_folders red)"
# shellcheck disable=SC2016 # the token is literal
[[ "$out" == *'${SPL_VAR_APP_DIR}'* ]] && pass "3. W1 red control: with no file-dir fallback the token stays literal" || fail "3. W1 red control: $out"
# shellcheck disable=SC2016 # the token is literal: a value that could not be derived
out="$(SPL_VAR_APP_DIR='${SPL_VAR_APP_DIR}' bash -c 'source "$0"; spl_agent_log_pipe_paths "$1"; echo "rc=$?"' "$PROJ_ROOT/src/bash/run/spl-agent-log-pipe.func.sh" "$T/cnf.yaml" 2>/dev/null)"
[[ "$out" == "rc=0" ]] && pass "3. N2: an unexpanded token is not an agent-log path (only absolute paths pass)" || fail "3. N2 relative path passed: $out"
# W3 (R7 a-718): box restart's desk step fails fast on a desk that is not a
# directory, and never runs git on the caller's tree (git -C "" = $PWD)
C="$T/caller"; git init -q "$C" && git -C "$C" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m a
out="$(cd "$C" && BOX_RESTART_DESK="$T/no-desk" bash -c 'do_log(){ echo "$*"; }; source "$0"; spl_brs_desk 0; echo rc=$?' "$PROJ_ROOT/src/bash/run/spl-box-restart-prepare.func.sh" 2>&1)"
[[ "$out" == *"rc=1"* && "$out" == *"ERROR the desk-cron checkout is not known"* && "$(git -C "$C" symbolic-ref -q HEAD)" == refs/heads/* ]] &&
  pass "3. W3: a missing desk dir: rc 1, ERROR, the caller's checkout untouched" || fail "3. W3: $out"

# 4. the live cnf
bad="$(yq -r '.. | select(tag == "!!map") | (.src_dir // empty), (.path // empty)' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" 2>/dev/null |
  grep -vE '^\$\{SPL_(ORG_DIR|VAR_APP_DIR)\}/|^\$HOME/' | grep '^/' || true)"
[[ -z "$bad" ]] && pass "4. all.env.yaml: every src_dir and path value is a token form" || fail "4. literal path values: $bad"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
