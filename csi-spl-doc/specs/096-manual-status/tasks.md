# 096 Manual status: tasks

Spec: [spec.md](spec.md) v0.2 (decided, section 12). One lane per task,
each one small; a task starts only when the ones it depends on are done.
L6 (dispatcher text) is dropped: Q7 decided no change.

| # | lane | depends on | done when |
|---|---|---|---|
| T001 | L1 rdb | owner go (msg cb7a9cec) | 0141 applied on dev and prd: done, ae4a3608 (wf 20 run 37513524382) |
| T002 | L2 hub | T001 | hub on dev and prd serves the contract: done, a71b55d3 (dev proof PUT/GET/roster/DELETE 200) |
| T003 | L3 WUI | T002 contract (may start on the mock) | WUI on dev and prd shows and sets a status: done, f524a1c01 (v2.3.7) |
| T004 | L4 help + proof | T002, T003 deployed | dev and prd proof posted |
| T005 | L5 notify | T003; c-376 landed; the 095 lane for the push half | the pause checkbox silences alerts |

## T001 - L1: rdb migration (spec 7.2)

- [x] `csi-spl-rdb/src/sql/postgres/spool-hub/0141_human_status.sql`:
      `human_status` keyed by the membership `(tenant_id, human_id)`, FK
      ON DELETE CASCADE, CHECKs on `status` and the 80-character note,
      `pause_notify` (Q1, default off), partial index on `until_at`,
      FORCE RLS with the NULLIF tenant policy and the operator policy.
- [x] Runtime grants: covered by the default privileges in
      `spool-hub-roles/runtime-grants.sql` (no edit).
- [x] Isolation guard: one seeded row in `seedTenantAll`
      (`internal/store/crosstenant_test.go`), plus
      `internal/store/human_status_test.go` (B reads 0 of A, CHECKs, FK,
      cascade).
- [x] `PRE_PUSH_TIER=full ./run -a do_check_pre_push`; land on master.
- [x] `ENV=dev` then `ENV=prd` `DRY_RUN=0 ./run -a do_spl_db_bootstrap`
      (per-env SA key); verify the table with `do_spl_db_query` on
      `information_schema.tables`.

## T002 - L2: hub (spec 7.3, 7.4, tests 10.1)

- [x] store: get / put / delete own row; reads treat `until_at <= now()` as
      absent; a missing-table probe until T001 is applied everywhere.
- [x] `PUT /v1/me/status` `{state, note?, until?}` and `DELETE
      /v1/me/status`: own row only, agents 403, note trimmed and
      control-stripped, `until` in the future and at most 90 days out
      (Q6), `"all_workspaces": true` writes one row per membership (Q2).
- [x] Roster (`viewHuman`) and search: optional `status {state, note,
      until}`, omitted when available or expired.
- [x] New `status` frame to the workspace's browser sockets on set, clear
      and expiry; `wuiWelcome` snapshot after presence; the presence frame
      unchanged byte for byte.
- [x] Expiry sweep on the relay tick, at most once a minute per tenant.
- [x] Tests 10.1; contract doc `view-v1.md` gains the field and the frame.
- [x] Landed a71b55d3; hub on dev and prd serves it (v2.2.9). Also built:
      `GET /v1/me/status` (own status incl. `pause_notify`, for the picker),
      `DELETE ?all_workspaces=true`, demo_user 403 on writes (`self.keys`),
      wui-live-ws §3.2 `status` row.

## T003 - L3: WUI (spec 5, 7.5, tests 10.2)

- [x] `statusByPeer` store map from the roster read and the `status`
      frame; client-side expiry check every minute.
- [x] One dot component with the ring (amber Busy, red Unavailable,
      `aria-label`), used in the People rail, member lists, DM list, DM
      header, mention picker, People card and search results; nothing on a
      post's author line (Q9). Search shows no people rows, so no ring there.
- [x] Picker (self row + avatar menu; bottom sheet on a phone), loaded
      lazily: state, note with counter, until choices, *Set in all my
      workspaces* (Q2), *Pause my notifications while unavailable* (Q1,
      off), *Save*, *Clear status*.
- [x] Composer line for Busy (softer) and Unavailable (Q3); no auto-reply
      (Q4).
- [x] i18n English and Bulgarian; "workspace", never "tenant".
- [x] Unit and e2e 10.2 (mock hub), phone width.
- [x] Landed f524a1c01 (+ comment fix bb1ed3399); dev and prd build.json
      serve bb1ed3399 (v2.3.7). Dev proof `tests/e2e/human-status-live.proof.mjs`
      6/6 (t1, test member: set Busy, roster carries it, reload, clear).
      Budget: initial JS 154.9 KB vs trunk 154.6 KB, ceiling 155 KB.

## T004 - L4: help and proof (spec 7.6, 10.3, 10.4)

- [x] `channels-and-direct-messages.md` 3.1: the ring rule and "Setting
      your status"; `user-settings.md` links to it. Landed fd9862014; dev,
      prd and e2e build.json serve it (v2.5.5).
- [x] Dev proof 10.3 with screenshots, then prd proof 10.4 on the e2e
      workspace host with the footer version.
      `tests/e2e/human-status-live.proof.mjs`, one test member, n=1 each:
      dev t1 6/6 PASS (v2.5.3); prd e2e workspace host 6/6 PASS (footer
      v3.8.3, hub 3.8.5): set Busy with a note and 30 min, amber ring with
      its words, a fresh tab gets it from the hub, still Busy after a
      reload, Clear status leaves no status.
      **Not proven live:** the two-member half of 10.3 (B's DM list, mention
      picker, DM header and composer line, expiry without a reload, grey dot
      with an amber ring). Neither workspace has a second test login, so
      these rest on the e2e 10.2 run against the mock hub.

## T005 - L5: pause notifications (spec 6, Q1)

- [x] `csi-spl-wui/src/utils/notify.mjs` `shouldPing`: after the c-376
      due-check, skip when the member is `unavailable` with `pause_notify`
      (the pause box) ticked; `busy` never silences. The reader's own status
      comes from the status store's state (`plugins/notify.client.ts`, no
      new import in the entry chunk: initial gzip 158409 -> 158488 B, n=1);
      the store reads `pause_notify` from GET /v1/me/status whenever the
      reader's own status turns Unavailable without a known pause.
      e2e: `tests/e2e/notify-pause-status.test.mjs`.
- [ ] Once spec 095 is built: one recipient filter in 095 section 6.2
      (only the levels below High, 095 section 13). NOT done: spec 095 is
      not built yet (c-431, 2026-10-07), so this half waits for it.
- [ ] Unit tests for both halves. The WUI half's are in
      `tests/unit/notify.test.mjs` and `tests/unit/human-status.test.mjs`;
      the 095 half's come with it.

<!-- version: 0.2.0 · updated: 2026-10-06 -->
