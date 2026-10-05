# Refactor round 3, row 14: Make bash tests hermetic and date-proof

Plan: `csi-spl-doc/doc/md/refactor-round-3-plan.md`, row 14. Owner topic `3e0809fe-16f6-46e3-a225-616ac6cd555b` (HUM-10, prd t1). Sites measured on trunk `755e86235`. Language: bash. Kind: stability. Risk: low. Run on: **sat**. Agent: **grok**. Batch: 1.

## 0. The owner's order, verbatim

1. msg 5461b323: "New refactoring for clean code round"
2. msg caa8f01c: "No more than two agents at a time. Keep all of the existing features. During the first checkout from the master, identify at least 30 best practices, and for each one of them, perform at least 5 changes on the source code. If you cannot find 5 candidates, then a smaller amount."
3. msg ab4a0356: "Do keep less than two agents per box for performing this refactoring round, and the aim is to improve the stability and to get cleaner code."
4. msg 2caccc14: "Also, if you find out that there is technical documentation missing or the comments of the code can be improved, do that as well."
5. msg f2b0afc0: "Should you find that testability for certain elements should be improved, do that as well."
6. msg a4930378 (later, relayed by c-001): "for the next 1hour you can increase the amount of the agents up till 8 agents working on this feature per box - have at least 2 groks per box as well ..."

This round: up to 8 round-3 lanes per box (owner msg a4930378), so other rows run while you do; that is why section 7 matters. Every existing feature stays: behaviour-preserving only, no new dependency.

## 1. The practice

On 755e86235 these orc tests are red without any code change: five use `CLE-n` fixture ids that `spool-env.inc.sh:80` retired at 2026-10-03T20:59:59Z, and desk-owners / desk-welcome never set `SPOOL_TEST=1` or `SPOOL_BOX_ENV`, so they read the live `/var/spool-hub/box.env` and their verdict depends on the box. Measured once each on PC: desk-mirror-actions 11 FAIL, agent-mcp 2, channel-agent-add-op 16, desk-owners 7, desk-welcome 29. Run this row BEFORE rows 27 and 29, whose tests are among them. Before you start: `git fetch origin master` and re-run; if another lane already fixed a file, skip it and say so.

Apply it at the 5 site(s) below and nowhere else. If a site has moved, find it by the excerpt; if it is gone or already fixed on `origin/master`, say so in your result and do not substitute another site.

Same cause, not sites of this row (left for a follow-up lane, named in the plan's section 4): channel-agent-remove-op (9 FAIL), desk-install-service-envs (6), asks (47).

## 2. The sites

### 2.1 Site 1

`csi-spl-orc/src/bash/tests/desk-mirror-actions.tst.sh` lines 52-57 on `755e86235`:

```
mkdir -p "$SEAT/spool/CLE-7/inbox" "$SEAT/spool/CLE-8" "$SEAT/spool/.hub" "$SEAT/keys"
echo HUM-9 >"$SEAT/mirror-to"   # the desk's human (spec 036: no literal default id)

# --- 1. dry run and refusals --------------------------------------------------------
: >"$T/calls.log"
SNIPPET=do_spl_desk_session_upload in_orc TENANT_ID=t1 DESK_AGENT=CLE-7 SESSION_TOKEN=tok >"$T/o" 2>&1
```

Change: spec-061 ids (`c-007`, `c-008`) in the fixture and the asserted strings.

### 2.2 Site 2

`csi-spl-orc/src/bash/tests/agent-mcp.tst.sh` lines 33-52 on `755e86235`:

```
mkdir -p "$MCP" "$D/spool/CLE-07/inbox" "$D/spool/.hub" "$D/keys"
cp "$SH" "$MCP/spool-mcp.sh"
cat >"$MCP/spool" <<EOF
#!/usr/bin/env bash
{ printf 'ARGV %s\n' "\$*"; env | grep -E '^(SPOOL_|LEAK)' | sort; } >"$T/served"
EOF
chmod +x "$MCP/spool" "$MCP/spool-mcp.sh"
box() { env LEAK=caller "$MCP/spool-mcp.sh" --serve "$@" >"$T/out" 2>&1 </dev/null; }

# ── 1. the box half refuses to start unseated ───────────────────────────────
for bad in "" "not-an-id" "BOX-1" "cle-07"; do
  rm -f "$T/served"
  if [ -z "$bad" ]; then box dev; else box --as "$bad" dev; fi; rc=$?
  [[ $rc -eq 4 && ! -e "$T/served" ]] && pass "1. --as '$bad' refuses (4), nothing served" ||
    fail "1. --as '$bad': rc $rc served=$([ -e "$T/served" ] && echo yes) $(cat "$T/out")"
done

# ── 2. no seat / no sidecar ─────────────────────────────────────────────────
box --as CLE-08 dev; rc=$?
[[ $rc -eq 5 ]] && grep -q 'CLE-08 has 0 seats' "$T/out" && pass "2. an unseated id refuses (5)" || fail "2. unseated: rc $rc $(cat "$T/out")"
```

Change: `c-007` / `c-008`.

### 2.3 Site 3

`csi-spl-orc/src/bash/tests/channel-agent-add-op.tst.sh` lines 53-88 on `755e86235`:

```
  printf '%s\n' 'added | CLE-7'
fi
exit "${STUB_PSQL_RC:-0}"
EOF
for b in cloud-sql-proxy docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
done
chmod +x "$T/stub/"*

in_orc() {
  local snip="$1"; shift
  : >"$T/calls.log"; : >"$T/stdin"
  env -u CLOUDSDK_CONFIG -u ACCOUNT -u GCP_ACCOUNT -u DRY_RUN -u HUMAN_ID -u EMAIL \
    -u TENANT_ID -u CHANNEL -u AGENTS -u AGENT_BOX -u STUB_PSQL_OUT -u STUB_PSQL_FILE -u STUB_PSQL_RC \
    HOME="$T/home" PATH="$T/stub:$PATH" STUB_LOG="$T/calls.log" T_STDIN="$T/stdin" \
    PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state" \
    ENV=dev SNIPPET="$snip" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    spl_sql_proxy_start() { SPL_PROXY_PORT=1; echo "proxy-start as $GCP_ACCOUNT" >>"$STUB_LOG"; }
    spl_sql_proxy_stop() { echo proxy-stop >>"$STUB_LOG"; }
    eval "$SNIPPET"' >"$T/out" 2>&1 </dev/null
}

FUNC="$PROJ_ROOT/src/bash/run/spl-channel-agent-add-op.func.sh"
bash -n "$FUNC" && pass "0. action parses" || fail "0. action syntax"
sqlbody=$(awk 'index($0, "<<'\''SQL'\''") {p=1; next} $0=="SQL" {p=0} p' "$FUNC")
[[ -n "$sqlbody" ]] && ! grep -q '\$' <<<"$sqlbody" \
  && pass "0. the SQL heredoc has no shell expansion" \
  || fail "0. the SQL heredoc is empty or expanded by the shell"

# --- 1. DRY_RUN plan, no cloud ------------------------------------------------
in_orc 'do_spl_channel_agent_add_op' TENANT_ID=t1 CHANNEL=release-notes AGENTS='CLE-7 CLE-8'; rc=$?
[[ $rc -eq 0 && ! -s "$T/calls.log" ]] \
  && grep -q 'DRY_RUN would add CLE-7 CLE-8 on box-desk to #release-notes in t1 (origin=invite)' "$T/out" \
```

Change: new-form ids in AGENTS and in the asserted DRY_RUN lines.

### 2.4 Site 4

`csi-spl-orc/src/bash/tests/desk-owners.tst.sh` lines 20-29 on `755e86235`:

```
in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/prd" ENV=prd "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    do_spl_desk_owners'
}

SEAT="$T/state/prd/desk/t1/box-desk"
```

Change: `SPOOL_TEST=1` (or `SPOOL_DESK_BOX=box-desk`) on the `env` line; new-form ids at :30-43.

### 2.5 Site 5

`csi-spl-orc/src/bash/tests/desk-welcome.tst.sh` lines 1-12 on `755e86235`:

```
#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_desk_welcome (SPL-961). No cloud call, no tmux: the admit
# read, the #lobby post and the live-window list are stubbed; the ledger, the
# plan and the texts are the real ones. Each run is a FRESH process, so a
# second run is exactly what a cron tick after a restart is.
#   1. the first run writes the tenant baseline; an older admit is never greeted
#   2. CLE-77896: no greeter configured = nobody greets, decided once; a new
#      admit gets ONE post into #lobby, from the configured greeter only,
#      naming the person - never one per seated bot
#   3. a second run (a restart) posts nothing more - exactly once
#   4. a greeter that is seated but dead, or live but unseated, waits for a
```

Change: same as desk-owners: hermetic env plus the 26 `CLE-n` ids.

## 3. Docs, comments and testability (same files, same lane)

- `csi-spl-orc/src/bash/tests/test-lib.inc.sh`: `grep -c SPOOL_TEST` -> 0; export `SPOOL_TEST=1` and an empty `SPOOL_BOX_ENV` there so every test that sources it is hermetic by default (check the 17 tests that already set it still pass).
- `desk-owners.tst.sh:1-15` and `desk-welcome.tst.sh:1-10`: say in the purpose header which box id the fixture assumes (`box-desk`) and why.
- Testability: NEW `csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh`: fail on a `*.tst.sh` using a `CLE-[0-9]+` id without asserting a refusal (allow-list the not-yet-fixed three), and on a test that sources `run/*.func.sh` and calls a desk action without `SPOOL_TEST=1` / `SPOOL_BOX_ENV`. A grep ban cannot prove absence; say so in its header.

## 4. Tests: before and after

Run these BEFORE you edit and record the counts, then again AFTER. The counts must match, or grow by exactly the cases you add; every new test must pass on the refactored code (and, where it pins old behaviour, on the old code too). A count that drops is a regression, not a cleanup.

- each site: `sudo -u <DEV_USER> bash <file>` -> 0 FAIL, run both with `/var/spool-hub/box.env` present AND with `SPOOL_DESK_BOX=zzz` exported (the before counts are FAILs; after must be all PASS with the same assertion count)
- `sudo -u <DEV_USER> bash csi-spl-orc/src/bash/tests/run-all-tests.sh` before = after except the five files going green

## 5. Gate (repo CLAUDE.md, for the trees this row touches)

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (~1 s)
- `cd csi-spl-iac && ./run -a do_check_pre_push` before EVERY push and again after the mandatory rebase
- `cd csi-spl-iac && ./run -a do_check_pre_push_lint` (shellcheck and the other scanners on touched files; missing scanner: `./run -a do_install_lint_tools`)
- `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh`: no function grows past 80 lines unless already on its LONG list
- `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` for iac files, `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` for orc files (run as the checkout owner: `sudo -u <DEV_USER> bash <test>`, `<DEV_USER>` = the user that owns the checkout)

## 6. Deploy

Watch `gh run list --commit <sha>` until your runs are green. This tree does not deploy an image; say so in your result.

## 7. Files you must NOT touch

Every other row of this round owns these; the row running on the other box at the same time is among them. Also off limits: migrations, `internal/msg/msg.go`, `internal/store/fleet_*.go`, the rotation / lease / spawn / dispatch scripts.

- `csi-spl-api/src/go/spool-hub-api/internal/hub/view_dm_counts.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/cmd/spool/doc.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/search/values.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/auth/config.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/action/action.go` (row 1)
- `csi-spl-api/src/go/spool-hub-api/internal/auth/idp.go` (row 2)
- `csi-spl-api/src/go/spool-hub-api/internal/auth/oidc.go` (row 2)
- `csi-spl-api/src/go/spool-hub-api/internal/auth/microsoft.go` (row 2)
- `csi-spl-api/src/go/spool-hub-api/internal/auth/idtoken.go` (row 2)
- `csi-spl-api/src/go/spool-hub-api/internal/auth/password.go` (row 2)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/perf_ingest.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/payments/paypal_signature.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/payments/paypal_payments.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/fileusage.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/notify/queue.go` (row 3)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/operator_workspaces.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/hubclient/flush.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/hub/rest.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/action/pin.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/invitemail/invitemail.go` (row 4)
- `csi-spl-api/src/go/spool-hub-api/internal/hubclient/hubclient.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/internal/hubclient/commit.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/internal/notify/notify.go` (row 5)
- `csi-spl-api/src/go/spool-hub-api/internal/store/migrate.go` (row 5)
- `csi-spl-wui/src/composables/useLive.ts` (row 6)
- `csi-spl-wui/src/composables/usePaletteItems.ts` (row 6)
- `csi-spl-wui/src/composables/useWorkspaceDocs.ts` (row 6)
- `csi-spl-wui/src/pages/docs.vue` (row 6)
- `csi-spl-wui/src/pages/help/[[page]].vue` (row 6)
- `csi-spl-wui/src/utils/fetch-timeouts.mjs` (row 6)
- `csi-spl-wui/tests/unit/fetch-timeouts.test.mjs` (row 6)
- `csi-spl-wui/src/utils/build-watch.mjs` (row 7)
- `csi-spl-wui/src/utils/build-stamp.mjs` (row 7)
- `csi-spl-wui/src/utils/avatar.mjs` (row 7)
- `csi-spl-wui/src/utils/tenant-host-boot.mjs` (row 7)
- `csi-spl-wui/src/utils/auth-client.mjs` (row 7)
- `csi-spl-wui/src/components/MergeConfirmDialog.vue` (row 8)
- `csi-spl-wui/src/components/TopicDeleteDialog.vue` (row 8)
- `csi-spl-wui/src/components/PersonActivityDialog.vue` (row 8)
- `csi-spl-wui/src/components/ActAsPicker.vue` (row 8)
- `csi-spl-wui/src/pages/archive.vue` (row 8)
- `csi-spl-wui/src/utils/latest-only.mjs` (row 8)
- `csi-spl-wui/tests/unit/latest-only.test.mjs` (row 8)
- `csi-spl-wui/tests/unit/topic-archive.test.mjs` (row 8)
- `csi-spl-wui/src/components/LanguageSetting.vue` (row 9)
- `csi-spl-wui/src/components/IssuesSortSetting.vue` (row 9)
- `csi-spl-wui/src/components/DisplayNameSetting.vue` (row 9)
- `csi-spl-wui/src/components/ViewPrefsSetting.vue` (row 9)
- `csi-spl-wui/src/components/MovePickerDialog.vue` (row 9)
- `csi-spl-wui/tests/unit/busy-finally.test.mjs` (row 9)
- `csi-spl-wui/src/utils/pane-collapse.mjs` (row 10)
- `csi-spl-wui/src/utils/hidden-cards.mjs` (row 10)
- `csi-spl-wui/src/utils/fleet-load.mjs` (row 10)
- `csi-spl-wui/src/utils/operator-console.mjs` (row 10)
- `csi-spl-wui/src/utils/card-clip.mjs` (row 10)
- `csi-spl-orc/lib/bash/funcs/spl-db-roles.func.sh` (row 11)
- `csi-spl-orc/lib/bash/funcs/gandi-api.func.sh` (row 11)
- `csi-spl-orc/src/bash/run/spl-db-health.func.sh` (row 11)
- `csi-spl-orc/src/bash/run/spl-checkout-fake-buy.func.sh` (row 11)
- `csi-spl-orc/src/bash/run/setup-app-inf.func.sh` (row 11)
- `csi-spl-orc/src/bash/tests/curl-time-bounded.tst.sh` (row 11)
- `csi-spl-orc/src/bash/scripts/verify-hub-endpoints.sh` (row 12)
- `csi-spl-iac/src/bash/run/measure-wui-edge-warm.func.sh` (row 12)
- `csi-spl-orc/src/bash/run/spl-hub-member-list.func.sh` (row 12)
- `csi-spl-orc/src/bash/run/spl-db-message-show.func.sh` (row 12)
- `csi-spl-orc/src/bash/run/spl-consumer-lag.func.sh` (row 12)
- `csi-spl-iac/lib/bash/funcs/gcp-project-apis.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-bkp-state-bucket-create.func.sh` (row 13)
- `csi-spl-iac/lib/bash/funcs/export-json-section-vars.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-004-project-apis-enable.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/gcp-000-bootstrap-gcp-env.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/tf-apply-local-step-bucket.func.sh` (row 13)
- `csi-spl-iac/src/bash/run/tf-destroy-local-step-bucket.func.sh` (row 13)
- `csi-spl-orc/src/bash/scripts/docker-init-tf-runner.sh` (row 15)
- `csi-spl-orc/src/bash/scripts/docker-init-tpl-gen.sh` (row 15)
- `csi-spl-orc/src/bash/scripts/docker-init-conf-validator.sh` (row 15)
- `csi-spl-orc/src/bash/tests/docker-init-scripts.tst.sh` (row 15)
- `csi-spl-orc/src/bash/run/spl-desk-rebox.func.sh` (row 16)
- `csi-spl-orc/src/bash/run/spl-m3-e2e.func.sh` (row 16)
- `csi-spl-orc/src/bash/features/mcp-bot/scripts/mcp-start-chrome.sh` (row 16)
- `csi-spl-orc/lib/bash/funcs/spl-newest-tenant-key.func.sh` (row 16)
- `csi-spl-orc/src/bash/tests/newest-tenant-key.tst.sh` (row 16)
- `csi-spl-api/src/go/spool-hub-api/internal/config/config.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/payments/config.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/cicdlogs/cicdlogs.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/action/react.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/store/answer_once.go` (row 17)
- `csi-spl-api/src/go/spool-hub-api/internal/store/memory.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/id_lookup.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/channel_humans.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/agent_lifecycle.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/perf_samples.go` (row 18)
- `csi-spl-api/src/go/spool-hub-api/internal/store/operator_flag.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/agent_seats.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/operator_workspaces.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/humans_memory.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/spool/retired.go` (row 19)
- `csi-spl-api/src/go/spool-hub-api/internal/store/postgres.go` (row 19)
- `csi-spl-wui/src/composables/useArchiveUndo.ts` (row 20)
- `csi-spl-wui/src/utils/read-sync-boot.ts` (row 20)
- `csi-spl-wui/src/plugins/0.boot-early.client.ts` (row 20)
- `csi-spl-wui/src/utils/flow-badge.mjs` (row 20)
- `csi-spl-wui/src/utils/early-session.mjs` (row 20)
- `csi-spl-wui/tests/unit/swallow-reasons.test.mjs` (row 20)
- `csi-spl-wui/src/utils/palette.mjs` (row 21)
- `csi-spl-wui/src/utils/side-hit-list.mjs` (row 21)
- `csi-spl-wui/src/utils/sidebar-row-menu.mjs` (row 21)
- `csi-spl-wui/src/components/LiveFeed.vue` (row 21)
- `csi-spl-wui/src/composables/useIssueColumnGrips.ts` (row 21)
- `csi-spl-wui/tests/unit/view-prefs.test.mjs` (row 21)
- `csi-spl-wui/src/utils/verbosity.mjs` (row 22)
- `csi-spl-wui/src/utils/slash-focus.mjs` (row 22)
- `csi-spl-wui/src/utils/font-size.mjs` (row 22)
- `csi-spl-wui/src/utils/theme.mjs` (row 22)
- `csi-spl-wui/src/utils/pane-widths.mjs` (row 22)
- `csi-spl-wui/tests/unit/util-docs.test.mjs` (row 22)
- `csi-spl-wui/src/utils/open-message.mjs` (row 23)
- `csi-spl-wui/src/utils/link-target.mjs` (row 23)
- `csi-spl-wui/src/utils/read-cursor.mjs` (row 23)
- `csi-spl-wui/src/utils/tenant-users-mock.mjs` (row 23)
- `csi-spl-wui/src/utils/perf-mark.mjs` (row 23)
- `csi-spl-wui/tests/unit/open-message.test.mjs` (row 23)
- `csi-spl-wui/src/components/IssueDescription.vue` (row 24)
- `csi-spl-wui/src/components/OmniboxGrip.vue` (row 24)
- `csi-spl-wui/src/composables/useDragReorder.ts` (row 24)
- `csi-spl-wui/src/utils/place-popover.mjs` (row 24)
- `csi-spl-wui/src/composables/useMsgShortcuts.ts` (row 24)
- `csi-spl-wui/tests/unit/place-popover-stop.test.mjs` (row 24)
- `csi-spl-wui/src/plugins/chunk-reload.client.ts` (row 25)
- `csi-spl-wui/src/plugins/preferred-locale.client.ts` (row 25)
- `csi-spl-wui/src/plugins/preferred-theme.client.ts` (row 25)
- `csi-spl-wui/src/plugins/event-log.client.ts` (row 25)
- `csi-spl-wui/src/plugins/lobby-warm.client.ts` (row 25)
- `csi-spl-wui/tests/unit/client-plugins-no-guard.test.mjs` (row 25)
- `csi-spl-wui/src/utils/move-mock.mjs` (row 26)
- `csi-spl-wui/src/utils/mock-merge.mjs` (row 26)
- `csi-spl-wui/src/utils/tenant-users.mjs` (row 26)
- `csi-spl-wui/src/utils/iso-seconds.mjs` (row 26)
- `csi-spl-wui/tests/unit/iso-seconds.test.mjs` (row 26)
- `csi-spl-orc/src/bash/features/spool-install/install.sh` (row 27)
- `csi-spl-orc/src/bash/run/spl-backfill-probe.func.sh` (row 27)
- `csi-spl-orc/src/bash/run/spl-desk-session-upload.func.sh` (row 27)
- `csi-spl-iac/lib/bash/funcs/parse-metadata.func.sh` (row 28)
- `csi-spl-iac/lib/bash/funcs/validate-params.func.sh` (row 28)
- `csi-spl-orc/lib/bash/funcs/validate-params.func.sh` (row 28)
- `csi-spl-iac/src/bash/run/tf-destroy-local-step-bucket.func.sh` (row 28)
- `csi-spl-iac/lib/bash/funcs/require-var.func.sh` (row 28)
- `csi-spl-orc/src/bash/tests/parse-metadata-nofork.tst.sh` (row 28)
- `csi-spl-iac/lib/bash/funcs/satellite.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/spl-hub-operator.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/spl-stripe.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh` (row 29)
- `csi-spl-orc/src/bash/run/spl-desk-welcome.func.sh` (row 29)
- `csi-spl-orc/lib/bash/funcs/define-all-run-vars.func.sh` (row 30)
- `csi-spl-orc/src/bash/run/spl-tenant-host-provision.func.sh` (row 30)
- `csi-spl-orc/src/bash/run/tf-030-import-existing-cloud-run.func.sh` (row 30)
- `csi-spl-orc/lib/bash/funcs/parse-metadata.func.sh` (row 30)
- `csi-spl-iac/src/bash/run/gcp-sm-secrets-to-env-file.func.sh` (row 30)
- `csi-spl-iac/src/bash/tests/comment-refs-exist.tst.sh` (row 30)

Your own files: `csi-spl-orc/src/bash/tests/desk-mirror-actions.tst.sh`, `csi-spl-orc/src/bash/tests/agent-mcp.tst.sh`, `csi-spl-orc/src/bash/tests/channel-agent-add-op.tst.sh`, `csi-spl-orc/src/bash/tests/desk-owners.tst.sh`, `csi-spl-orc/src/bash/tests/desk-welcome.tst.sh`, `csi-spl-orc/src/bash/tests/test-lib.inc.sh`, `csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh`. Before you start, `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/tests/desk-mirror-actions.tst.sh,csi-spl-orc/src/bash/tests/agent-mcp.tst.sh,csi-spl-orc/src/bash/tests/channel-agent-add-op.tst.sh,csi-spl-orc/src/bash/tests/desk-owners.tst.sh,csi-spl-orc/src/bash/tests/desk-welcome.tst.sh,csi-spl-orc/src/bash/tests/test-lib.inc.sh,csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh --agent <you>` must exit 0.

## 8. Commit and report

- Commit as the owner identity on the `Commits:` line of the repo CLAUDE.md (name + csitea.net address; the hygiene sweep bans the literal name in shipped files, so it is not spelled out here), no AI trailers (no `Co-Authored-By:`, `Generated with`, `Claude-Session:`). Explicit pathspecs on `git add`.
- Subject: `refactor(r3-14): Make bash tests hermetic and date-proof` (one commit per site is fine; push each at once).
- Land on `origin/master` (`git merge-base --is-ancestor HEAD origin/master` exits 0).
- Send ONE result to the orchestrator on task `3e0809fe-16f6-46e3-a225-616ac6cd555b`: the sha(s), each site done / moved / skipped (why), the doc, comment and testability items done, and the before/after test counts.
