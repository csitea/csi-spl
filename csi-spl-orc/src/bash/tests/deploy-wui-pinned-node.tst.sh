#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_deploy_wui runs firebase-tools on a pinned node (SPL-2001,
# SPL-2016). node v20 + node-fetch 2.7.0 broke 6/6 compressed oauth2 reads
# with "Premature close"; node 22.20.0 read 6/6. The test RUNS the firebase
# step, _deploy_wui_steps, with a stub pnpm first on PATH that logs its argv,
# and reads the deploy call from that log. Everything else the step calls
# (cnf read, mint, generate, stamp, render, hub wait, probe, publish) is
# stubbed: no network, no real deploy.
#   1. default: pnpm --config.use-node-version=22.20.0 dlx firebase-tools@13 deploy
#   2. FIREBASE_NODE_VERSION=24.11.0: --config.use-node-version=24.11.0
#   3. the deploy runs in the wui dir, as the key, with its own config dir
# DEPLOY_WUI_FUNC (optional) - the deploy-wui.func.sh under test, default this
#   tree's; a red control points it at e42286100^'s copy.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="${DEPLOY_WUI_FUNC:-$PROJ_ROOT/src/bash/run/deploy-wui.func.sh}"

# The stub pnpm: one line per call, "<cwd> | <argv> | <GAC> | <XDG_CONFIG_HOME>".
mkdir -p "$T/stub"
cat >"$T/stub/pnpm" <<'SH'
#!/bin/sh
echo "$(pwd) | $* | ${GOOGLE_APPLICATION_CREDENTIALS:-} | ${XDG_CONFIG_HOME:-}" >>"$STUB_LOG"
exit 0
SH
chmod +x "$T/stub/pnpm"

# A fake deploy checkout: the two scripts the step runs from it, and .version.
wt="$T/wt"
mkdir -p "$wt/csi-spl-wui" "$wt/csi-spl-orc/src/bash/scripts"
for s in render-wui-firebase-json.sh wait-for-hub-version.sh; do
  printf '#!/bin/sh\necho "%s" >>"$STUB_LOG"\n' "$s" >"$wt/csi-spl-orc/src/bash/scripts/$s"
done
echo 1.2.3 >"$wt/.version"

# run_step <name> [VAR=value]... - source the func file under test, stub the
# step's helpers, run _deploy_wui_steps on the fake checkout; log $T/<name>.log.
run_step() {
  local log="$T/$1.log" rc=0; shift
  : >"$log"
  env -u FIREBASE_NODE_VERSION PATH="$T/stub:$PATH" STUB_LOG="$log" FUNC="$FUNC" WT="$wt" \
    ENV=dev SPL_ORG_APP=csi-spl WUI_SUITE=0 "$@" bash -c '
    set -uo pipefail
    source "$FUNC"
    do_log() { echo "$*" >&2; }
    _deploy_wui_cfg() { printf "project=csi-spl-dev\nsite=spl-dev\napi_fqdn=api.example.com\n"; }
    spl_ld_predict() { echo 1.2.3; }
    spl_ld_mint() { SPL_LD_VERSION=1.2.3; }
    _deploy_wui_generate() { echo generate >>"$STUB_LOG"; }
    _deploy_wui_stamp() { echo stamp >>"$STUB_LOG"; }
    _deploy_wui_probe() { echo probe >>"$STUB_LOG"; }
    spl_ld_run() { echo "spl_ld_run $2" >>"$STUB_LOG"; }
    _deploy_wui_steps "$WT" 0123456789abcdef0123456789abcdef01234567 /keys/key-csi-spl-dev.json' \
    >"$T/out" 2>&1 || rc=$?
  ((rc == 0)) || { echo "  _deploy_wui_steps rc $rc:"; sed 's/^/    /' "$T/out"; }
}

# deploy_line <log> - the pnpm call that deploys firebase-tools
deploy_line() { awk '/firebase-tools/ && / deploy / {print; exit}' "$1"; }

# --- 1. default: node 22.20.0 ------------------------------------------------
run_step default
d="$(deploy_line "$T/default.log")"
if grep -qF "| --config.use-node-version=22.20.0 dlx firebase-tools@13 deploy --only hosting --project csi-spl-dev --non-interactive |" <<<"$d"; then
  pass "1. default deploy runs firebase-tools@13 on node 22.20.0"
else
  fail "1. default deploy does not pin node 22.20.0: '${d:-no firebase deploy call}'"
fi

# --- 2. FIREBASE_NODE_VERSION overrides it -----------------------------------
run_step override FIREBASE_NODE_VERSION=24.11.0
o="$(deploy_line "$T/override.log")"
if grep -qF "| --config.use-node-version=24.11.0 dlx firebase-tools@13 deploy " <<<"$o"; then
  pass "2. FIREBASE_NODE_VERSION=24.11.0 is the node firebase-tools runs on"
else
  fail "2. FIREBASE_NODE_VERSION=24.11.0 not used: '${o:-no firebase deploy call}'"
fi

# --- 3. the deploy runs in the wui dir, as the SA key, own config dir --------
cwd="" gac="" xdg=""
[[ -n "$d" ]] && IFS='|' read -r cwd _ gac xdg <<<"$d"
if [[ "${cwd% }" == "$wt/csi-spl-wui" && "${gac// /}" == /keys/key-csi-spl-dev.json && -n "${xdg// /}" ]]; then
  pass "3. deploy runs in the wui dir with the SA key and a throwaway config dir"
else
  fail "3. deploy context wrong: '${d:-no firebase deploy call}'"
fi

if [[ $fails -eq 0 ]]; then echo "ALL PASS"; else echo "$fails FAIL(S)"; exit 1; fi
