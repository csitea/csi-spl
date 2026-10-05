# Refactor round 3, row 20: Say why each bare `.catch(() => {})` is safe

Plan: `csi-spl-doc/doc/md/refactor-round-3-plan.md`, row 20. Owner topic `3e0809fe-16f6-46e3-a225-616ac6cd555b` (HUM-10, prd t1). Sites measured on trunk `755e86235`. Language: TS/Vue. Kind: clean. Risk: low. Run on: **PC**. Agent: **claude**. Batch: 2.

## 0. The owner's order, verbatim

1. msg 5461b323: "New refactoring for clean code round"
2. msg caa8f01c: "No more than two agents at a time. Keep all of the existing features. During the first checkout from the master, identify at least 30 best practices, and for each one of them, perform at least 5 changes on the source code. If you cannot find 5 candidates, then a smaller amount."
3. msg ab4a0356: "Do keep less than two agents per box for performing this refactoring round, and the aim is to improve the stability and to get cleaner code."
4. msg 2caccc14: "Also, if you find out that there is technical documentation missing or the comments of the code can be improved, do that as well."
5. msg f2b0afc0: "Should you find that testability for certain elements should be improved, do that as well."
6. msg a4930378 (later, relayed by c-001): "for the next 1hour you can increase the amount of the agents up till 8 agents working on this feature per box - have at least 2 groks per box as well ..."

This round: up to 8 round-3 lanes per box (owner msg a4930378), so other rows run while you do; that is why section 7 matters. Every existing feature stays: behaviour-preserving only, no new dependency.

## 1. The practice

These rejections are swallowed on purpose (best-effort re-read, warm-up import, a browser API with nothing to do on failure), but unlike `lobby-warm.mjs:37` the reason is not written down, so a deliberate swallow reads like a forgotten error path. Add a one-line reason at each. Do NOT replace them with reporting: `chunk-reload.client.ts` and `error-journal.client.ts` listen to `unhandledrejection` and would see new events.

Apply it at the 5 site(s) below and nowhere else. If a site has moved, find it by the excerpt; if it is gone or already fixed on `origin/master`, say so in your result and do not substitute another site.

## 2. The sites

### 2.1 Site 1

`csi-spl-wui/src/composables/useArchiveUndo.ts` lines 27-33 on `755e86235`:

```
export async function rereadFeeds() {
  await useChannelStore().catchUp().catch(() => {})
  await useViewerStore().catchUp().catch(() => {})
  for (const key of ['main', 'pane'] as const) {
    const feed = useLiveFeed(key)
    if (feed.taskId) await feed.open(String(feed.taskId)).catch(() => {})
  }
```

Change: a reason comment: a failed re-read leaves the card hidden until the next live frame or reconnect catch-up.

### 2.2 Site 2

`csi-spl-wui/src/utils/read-sync-boot.ts` lines 81-81 on `755e86235`:

```
  if (moved.some((k) => k.startsWith('ch:'))) void channel.loadChannels().catch(() => {})
```

Change: a reason comment; keep `k.startsWith('dm:')` / `k.startsWith('ch:')` and the order (dm-counts-parity.test.mjs:97-100).

### 2.3 Site 3

`csi-spl-wui/src/plugins/0.boot-early.client.ts` lines 24-27 on `755e86235`:

```
    if (isProductScreen(window.location.pathname + window.location.search)) {
      void import('~/layouts/default.vue').catch(() => {})
      void import('~/components/LanguageSwitcher.vue').catch(() => {})
    }
```

Change: a comment: warm-up only; the real import on render retries and triggers chunk-reload, which is why a stale chunk here does not reload the tab.

### 2.4 Site 4

`csi-spl-wui/src/utils/flow-badge.mjs` lines 143-147 on `755e86235`:

```
    let p
    if (v && typeof nav.setAppBadge === 'function') p = nav.setAppBadge(v)
    else if (!v && typeof nav.clearAppBadge === 'function') p = nav.clearAppBadge()
    else return false
    if (p && typeof p.catch === 'function') p.catch(() => {})
```

Change: a comment: a denied badge permission is not an app error.

### 2.5 Site 5

`csi-spl-wui/src/utils/early-session.mjs` lines 35-41 on `755e86235`:

```
/** Start `probe()` once per page load; the same promise if already started. */
export function startEarlySession(probe) {
  if (!early) {
    const p = probe()
    p.catch(() => {})
    early = p
  }
```

Change: a comment: the caller awaits `early` and handles it; this only stops an unhandledrejection while nobody is awaiting yet.

## 3. Docs, comments and testability (same files, same lane)

- `csi-spl-wui/src/composables/useArchiveUndo.ts:20-26`: the `rereadFeeds` doc should say every step is best effort and sequential (one failing step does not stop the next).
- `csi-spl-wui/src/utils/flow-badge.mjs:133-138`: the `syncAppBadge` doc: "the badge promise is not awaited; a rejection is ignored".
- `csi-spl-wui/src/utils/early-session.mjs:35`: extend the one-line doc with the swallow's purpose.
- Testability: NEW `tests/unit/swallow-reasons.test.mjs`: every `.catch(() => {})` in `src/` has a comment on the same or previous line; starts with these five files plus an allow-list that only shrinks (the cleancode LONG pattern).

## 4. Tests: before and after

Run these BEFORE you edit and record the counts, then again AFTER. The counts must match, or grow by exactly the cases you add; every new test must pass on the refactored code (and, where it pins old behaviour, on the old code too). A count that drops is a regression, not a cleanup.

- `cd csi-spl-wui && node tests/unit/dm-counts-parity.test.mjs` (12 pass on 755e86235, n=1); `early-session-script.test.mjs`; `flow-badge.test.mjs` (21)
- `pnpm run typecheck` (needs `pnpm install`)
- e2e: `tests/e2e/archive-undo.test.mjs`

## 5. Gate (repo CLAUDE.md, for the trees this row touches)

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (~1 s)
- `cd csi-spl-iac && ./run -a do_check_pre_push` before EVERY push and again after the mandatory rebase
- `cd csi-spl-wui && pnpm run typecheck`
- `cd csi-spl-wui && pnpm run test:unit` (whole unit suite, file and pass counts before = after)
- `BASE_URL=<generated bundle> pnpm run test:e2e` for the specs named in section 4 (typecheck does not drive Chrome)
- the 160 KB initial-chunk budget: load nothing new eagerly

## 6. Deploy

This row touches the WUI: **deploy dev+prd, prove live via build.json or /version** (the version minted for your commit by `do_release_version`). Watch `gh run list --commit <sha>` until green and deployed on both (`./run -a do_check_deploy_lag`); report `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for dev and prd.

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
- `csi-spl-orc/src/bash/tests/desk-mirror-actions.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/agent-mcp.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/channel-agent-add-op.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/desk-owners.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/desk-welcome.tst.sh` (row 14)
- `csi-spl-orc/src/bash/tests/test-lib.inc.sh` (row 14)
- `csi-spl-orc/src/bash/tests/tests-hermetic.tst.sh` (row 14)
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

Your own files: `csi-spl-wui/src/composables/useArchiveUndo.ts`, `csi-spl-wui/src/utils/read-sync-boot.ts`, `csi-spl-wui/src/plugins/0.boot-early.client.ts`, `csi-spl-wui/src/utils/flow-badge.mjs`, `csi-spl-wui/src/utils/early-session.mjs`, `csi-spl-wui/tests/unit/swallow-reasons.test.mjs`. Before you start, `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-wui/src/composables/useArchiveUndo.ts,csi-spl-wui/src/utils/read-sync-boot.ts,csi-spl-wui/src/plugins/0.boot-early.client.ts,csi-spl-wui/src/utils/flow-badge.mjs,csi-spl-wui/src/utils/early-session.mjs,csi-spl-wui/tests/unit/swallow-reasons.test.mjs --agent <you>` must exit 0.

## 8. Commit and report

- Commit as the owner identity on the `Commits:` line of the repo CLAUDE.md (name + csitea.net address; the hygiene sweep bans the literal name in shipped files, so it is not spelled out here), no AI trailers (no `Co-Authored-By:`, `Generated with`, `Claude-Session:`). Explicit pathspecs on `git add`.
- Subject: `refactor(r3-20): Say why each bare `.catch(() => {})` is safe` (one commit per site is fine; push each at once).
- Land on `origin/master` (`git merge-base --is-ancestor HEAD origin/master` exits 0).
- Send ONE result to the orchestrator on task `3e0809fe-16f6-46e3-a225-616ac6cd555b`: the sha(s), each site done / moved / skipped (why), the doc, comment and testability items done, and the before/after test counts.
