#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_run_paths / spl_main_checkout / spl_cnf_path_expand
# (csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh, SPL-5527): box paths are
# derived at run time, never read from a literal in the cnf or the code.
#   1. a fixture <base>/opt/acme/acme-app main checkout and its worktree
#      <base>/opt/acme/acme-app-wt/c-901 derive the SAME paths:
#      SPL_ORG_DIR <base>/opt/acme, SPL_VAR_APP_DIR <base>/var/acme/acme-app,
#      SPL_WT_ROOT <main>-wt, SPL_DESK_DIR <main>-desk-cron; an env value wins.
#      Red control: run.sh's own ORG_PATH rule (dirname of APP_PATH) on the
#      worktree reads <base>/opt/acme/acme-app-wt, which is why the helper exists.
#   2. spl_cnf_path_expand replaces only the two tokens, never another $.
#   3. the cnf readers expand the tokens: spl_landed_repo_rows (a src_dir
#      ${SPL_ORG_DIR}/<repo> row resolves to the clone; red control: a
#      non-absolute org dir drops the row, never a relative path),
#      spl_file_stream_folders and spl_agent_log_pipe_paths.
#   4. the live cnf: every src_dir / file_streams path value is a token form.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
LIB="$PROJ_ROOT/lib/bash/funcs/spl-run-paths.func.sh"
unset SPL_ORG_DIR SPL_VAR_APP_DIR SPL_WT_ROOT SPL_DESK_DIR
B="$T/b"; M="$B/opt/acme/acme-app"; mkdir -p "$M"
git -C "$M" init -q && git -C "$M" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m a
git -C "$M" worktree add -q "$B/opt/acme/acme-app-wt/c-901" -b c-901 2>/dev/null
W="$B/opt/acme/acme-app-wt/c-901"
paths() { env -u SPL_ORG_DIR -u SPL_VAR_APP_DIR -u SPL_WT_ROOT -u SPL_DESK_DIR APP_PATH="$1" "${@:2}" bash -c 'source "$0"; spl_run_paths && echo "$SPL_ORG_DIR|$SPL_VAR_APP_DIR|$SPL_WT_ROOT|$SPL_DESK_DIR"' "$LIB"; }
want="$B/opt/acme|$B/var/acme/acme-app|$M-wt|$M-desk-cron"
[[ "$(paths "$M")" == "$want" ]] && pass "1. main checkout derives $want" || fail "1. main: $(paths "$M")"
[[ "$(paths "$W")" == "$want" ]] && pass "1. its worktree derives the same paths" || fail "1. worktree: $(paths "$W")"
[[ "$(dirname "$W")" != "$B/opt/acme" ]] && pass "1. red control: run.sh's ORG_PATH rule on the worktree reads $(dirname "$W"), not the org dir" || fail "1. red control"
[[ "$(paths "$W" SPL_WT_ROOT=/x/wt)" == "$B/opt/acme|$B/var/acme/acme-app|/x/wt|$M-desk-cron" ]] && pass "1. an env SPL_WT_ROOT wins" || fail "1. env override: $(paths "$W" SPL_WT_ROOT=/x/wt)"
out="$(env -u APP_PATH -u PROJ_PATH bash -c 'source "$0"; spl_run_paths; echo rc=$?' "$LIB")"
[[ "$out" == "rc=1" ]] && pass "1. no APP_PATH and no dir: rc 1" || fail "1. no tree: $out"

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

# 4. the live cnf
bad="$(yq -r '.. | select(tag == "!!map") | (.src_dir // empty), (.path // empty)' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml" 2>/dev/null |
  grep -vE '^\$\{SPL_(ORG_DIR|VAR_APP_DIR)\}/|^\$HOME/' | grep '^/' || true)"
[[ -z "$bad" ]] && pass "4. all.env.yaml: every src_dir and path value is a token form" || fail "4. literal path values: $bad"
(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1
