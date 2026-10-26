#!/bin/bash
#------------------------------------------------------------------------------
# @description The pre-push part `iac-cross`: the csi-spl-iac tests that READ
# @description files of other parts (csi-spl-orc, -api, -doc, -rdb, the whole
# @description tree), run when a push touches what they read but not the iac
# @description part's own paths (then the whole iac suite runs them anyway).
# @description Before it an orc-only push ran no iac test: 16b39bb9f and
# @description 947ec0844 each changed one orc file + its test, passed the gate
# @description and turned wf 10 job 'iac: tfvars parity, step contracts,
# @description terraform validate' red on comment-refs-exist.tst.sh
# @description (run 38249861366, a dangling *.sh name in an orc comment).
# @description THE MAP (_PPX_MAP): one row per test, the paths it reads outside
# @description the iac part's own. A path is a dir or file prefix, a glob
# @description ('*.sh': any shell file anywhere, as git ls-files sees it) or
# @description '.' (the whole tree: those tests run on every push, ~2 s).
# @description A test that reads only fixtures, or only what another part
# @description already runs, has no row; _PPX_NONE names the latter. The guard
# @description is check-pre-push-scope.tst.sh: a fast-tier iac test that names
# @description another part's tree under $APP_ROOT or $PROJ_PATH/.. and is in
# @description neither list fails it.
# @description The selected files run through the iac suite's own runner
# @description (run-all-tests.sh, IAC_TEST_ONLY), so the timeout, the job pool
# @description and the fast-tier SKIP rule are CI's.
# @param PRE_PUSH_CROSS (optional) - 0 = never select the part, default 1
# @example CROSS_CHANGED="csi-spl-orc/src/bash/run/box-disk-sweep.func.sh" ./run -a do_check_pre_push_cross
# @example CROSS_RANGE=origin/master...HEAD ./run -a do_check_pre_push_cross
#------------------------------------------------------------------------------

# "<test basename> <path>..." -- what each test reads outside the iac part's
# own paths (_pp_paths iac). Measured 2026-10-12 on the first box (16 cpus,
# load ~5, n=1): every row under 2.2 s but gate10-fail-fast (81 s, selected
# only by the script it drives).
_PPX_MAP=(
  "comment-refs-exist.tst.sh csi-spl-orc/src/bash csi-spl-orc/lib/bash *.sh"
  "gcp-sm-secrets-dead.tst.sh csi-spl-orc/src/bash csi-spl-orc/lib/bash csi-spl-api/backend_api"
  "gcp-owner-login-bootstrap-only.tst.sh csi-spl-orc/src/bash/run csi-spl-orc/lib"
  "gcloud-account-pinned.tst.sh ."
  "gcp-sa-key-email.tst.sh csi-spl-orc/lib/bash/funcs csi-spl-orc/src/bash/run/box-copy-gcp-key.func.sh"
  "satellite-ansible.tst.sh csi-spl-orc/src/bash csi-spl-api/src/go/spool-hub-api/go.mod"
  "satellite-actions.tst.sh csi-spl-orc/src/make/tf-tasks.func.mk csi-spl-orc/src/bash/features/spool-install/render-yield.sh"
  "satellite-steps.tst.sh csi-spl-orc/src/make/tf-tasks.func.mk"
  "env-order-gate.tst.sh csi-spl-orc/src/make/tf-tasks.func.mk"
  "gcp-alert-snooze.tst.sh csi-spl-orc/src/make/tf-tasks.func.mk csi-spl-orc/Makefile csi-spl-orc/lib/make"
  "tenant-host-workflow-40.tst.sh csi-spl-orc/src/bash/run/spl-tenant-host-reconcile.func.sh"
  "gate10-fail-fast.tst.sh csi-spl-orc/src/bash/scripts/gate-fail-fast.sh"
  "ci-doc-only.tst.sh csi-spl-orc/src/bash/scripts/ci-doc-only.sh"
  "help-connect-agent.tst.sh csi-spl-doc/doc/help README.md"
  "owner-acceptance-register.tst.sh csi-spl-doc/specs/031-spool-owner-acceptance csi-spl-orc/src/bash csi-spl-wui/tests csi-spl-api/src/go"
  "compose-healthchecks.tst.sh docker-compose.yml csi-spl-api/src/docker/hub-entrypoint.sh"
  "compose-secrets.tst.sh docker-compose.yml .gitignore csi-spl-api/src/docker/secret-env.sh csi-spl-api/src/docker/local-secrets"
  "hub-env-typed-values.tst.sh csi-spl-api/src/go/spool-hub-api"
  "workflow-go-mod-verify.tst.sh csi-spl-api/src/go/spool-hub-api/go.mod"
  "rdb-no-store-entities.tst.sh csi-spl-rdb/src/sql"
  "domain-single-source.tst.sh ."
  "no-key-material-in-tree.tst.sh ."
  "hub-version-digits.tst.sh *.version *package.json"
  "hub-version-tag-parity.tst.sh *.version"
  "hub-marketing-kms-key-030.tst.sh csi-spl-api/src/go/spool-hub-api/internal/config/config.go"
  "check-pre-push.tst.sh csi-spl-api/src/bash/tests/no-payment-vendor-wui.tst.sh csi-spl-orc/src/bash/tests/run-all-tests.sh csi-spl-orc/src/bash/tests/changed-tests.sh"
)
# Tests that name another part's tree but need no row: what they read is
# run by another part.
_PPX_NONE=(
  "bash-cleancode.tst.sh the orc part runs it"
)

# do_check_pre_push_cross - print the iac tests a change selects, one per
# line. The change: CROSS_CHANGED (paths, space or newline separated) or the
# files of CROSS_RANGE (a git range), in PRE_PUSH_TREE (default the checkout).
do_check_pre_push_cross() {
  local tree="${PRE_PUSH_TREE:-$(git rev-parse --show-toplevel 2>/dev/null)}" changed
  if [[ -n "${CROSS_RANGE:-}" ]]; then
    changed="$(git -C "$tree" diff --name-only "$CROSS_RANGE" 2>/dev/null)" \
      || { do_log "FATAL iac-cross: cannot diff $CROSS_RANGE"; return 1; }
  else
    changed="$(tr ' ' '\n' <<<"${CROSS_CHANGED:-}")"
  fi
  _ppx_select "$changed"
}

# _ppx_select <changed-list> - the tests whose row a changed path falls under
# ('.' rows: every change).
_ppx_select() {
  local row
  local -a r
  for row in "${_PPX_MAP[@]}"; do
    read -r -a r <<<"$row"
    if [[ " ${r[*]:1} " == *" . "* ]] || _pp_touches "$1" "${r[@]:1}"; then echo "${r[0]}"; fi
  done
  return 0
}

# _ppx_paths - the paths the selected tests read, plus the test files and
# their runner: the part's cache key (_pp_key) changes when any of them does.
_ppx_paths() {
  local row out="csi-spl-iac/src/bash/tests/run-all-tests.sh csi-spl-iac/src/bash/tests/test-lib.inc.sh"
  local -a r
  for row in "${_PPX_MAP[@]}"; do
    read -r -a r <<<"$row"
    [[ " $_PPX_TESTS " == *" ${r[0]} "* ]] && out+=" csi-spl-iac/src/bash/tests/${r[0]} ${r[*]:1}"
  done
  # shellcheck disable=SC2086 # one path per word; set -f keeps the globs literal
  ( set -f; printf '%s\n' $out | sort -u | tr '\n' ' ' )
}

# _ppx_parts <changed-list> - do_check_pre_push's `parts` gets iac-cross when
# the change selects a test and the iac part (the whole suite) is not
# selected; _PPX_TESTS holds them for the part and its trunk re-check.
_ppx_parts() {
  _PPX_TESTS=""
  [[ "${PRE_PUSH_CROSS:-1}" == 0 || " $parts " == *" iac "* ]] && return 0
  _PPX_TESTS="$(_ppx_select "$1" | tr '\n' ' ')"
  _PPX_TESTS="${_PPX_TESTS% }"
  [[ -n "$_PPX_TESTS" ]] && parts+=" iac-cross"
  return 0
}

# _pp_part_iac_cross <tree> - the selected tests that exist in <tree>, through
# the iac runner. A test new in the push is absent on trunk: the re-check
# runs what is left, so the push's red stays its own.
_pp_part_iac_cross() {
  local tree="$1" t only=""
  for t in $_PPX_TESTS; do [[ -f "$tree/csi-spl-iac/src/bash/tests/$t" ]] && only+=" $t"; done
  [[ -n "$only" ]] || { echo "iac-cross: no selected test in this tree"; return 0; }
  echo "iac-cross: runs${only}"
  IAC_TEST_ONLY="${only# }" IAC_TEST_TIER="${_PP_TIER:-fast}" \
    timeout -k 10 "$(_pp_budget _pp_part_iac_cross)" bash "$tree/csi-spl-iac/src/bash/tests/run-all-tests.sh"
}
