# Tasks — `033-spool-message-levels`

Ground rules: `../README.md` §2. Specs are docs; every code change is a task
here. Status: **Implemented** (cite the sha or the command), **Partial** (name
the missing part), **Planned**.

Measurement fields, where a task carries one: the build it ran against, the
tree, and **n**. The live proof is
`csi-spl-wui/tests/e2e/parent-level-live.proof.mjs`; each run writes
`results.json` under its `OUT` dir.

## T001 — the column

**Status**: Implemented — `69cdf97` (`0034_messages_is_parent.sql`), `66de3bc`
(`0035_messages_is_parent_roots.sql`); applied on dev and prd.

`messages.is_parent smallint NOT NULL`, `CHECK` 0 or 1. `0035` sets 1 on the
first message of each existing root task and makes 1 the column default.
Forward-only: neither file is edited after it was applied.

FR-ML-001.

## T002 — the hub stores what the browser chose

**Status**: Implemented — `69cdf97`; hub `0.3.12` (`/version` commit `66de3bc`
on dev and prd, 2026-09-25).

`internal/hub/wui.go` `uiParent`: an absent field is 1, 0 and 1 are stored,
any other number answers `bad_json`. A box send is stored as 1. The topic read
(`internal/hub/view.go` `viewMsg.IsParent`) and the live frame carry it; the
signed envelope does not.

FR-ML-002, FR-ML-003.

## T003 — the middle list and the right pane

**Status**: Implemented — `66de3bc`, `778cf49`.

`utils/channel-feed.mjs` `topicStarterCards` drops `is_parent 0` from the
cards; `rowsForRightPane` keeps a confirmed `is_parent 0` line of the open
topic on the right; `utils/topic-list.mjs` `bumpTopic` never starts a
topics-home row for one.

FR-ML-005, FR-ML-006, FR-ML-007.

## T004 — the flag follows the pane, not the left tab

**Status**: Implemented — `5b16c0f`; **superseded in part by T005**.

The first build (`69cdf97`) made a send level 2 only on the Topics tab with
the pane open, so a replies click from Channels still made a middle card.
`5b16c0f` keyed it on the pane being open. Measured on dev `5b16c0f`, sender
tab only, n=1 per surface: 49/49 steps pass. Not enough: see T005.

## T005 — the pane selected LAST decides (test-02, test-03)

**Status**: Implemented — `618851f`.

The owner's test-02 (dev, 2026-09-25) was stored `is_parent 0` on the open DM
topic although the owner had gone back to the middle pane. Now:

- `utils/pane-focus.mjs` `paneOfTarget` / `paneTakesLine`, `stores/pane-focus.ts`;
- `layouts/default.vue` records the pane of every `pointerdown` / `focusin`
  in the shell (middle, right, or nothing for sidebar, top bar, divider);
- `stores/topic.ts` `openTarget` and `stores/live.ts` `open` (pane store)
  put the reader on the right;
- channel, DM, lobby and topics home gate `paneOpen()` on `paneTakesLine`;
  `omniboxReplyTaskId` / `isParentFlag` take `lastPane`, so the Topics-tab
  fallback cannot reply either.

FR-ML-004.

## T006 — a reload never loses a topic's card

**Status**: Implemented — `618851f`.

`listMessages` read each topic newest first with `limit`; a topic with more
lines than that never loaded its opener, and with every loaded line
`is_parent 0` it had no card after a reload. It also capped the merged page
to the newest `limit` lines across topics, which could cut any topic's opener.
Now the opener is read on its own (`getTopic(id, { limit: 1 })`, oldest
first) when the topic row's `count` exceeds the page, and the cap never drops
a topic's earliest line. RED before the fix: `parent-level.test.mjs` 21/22.

FR-ML-008.

## T007 — the lobby follows its channel live

**Status**: Implemented — `618851f`.

A new lobby topic is a new task in channel `lobby`; the main lobby store only
merged frames of the room task. Measured on dev `5b16c0f` with a second tab,
n=1: the watcher never showed the new card (57 steps, that one FAIL).
`pages/lobby.vue` subscribes to channel `lobby` and admits its frames;
`channelView` keeps level-2 lines out of the middle. The follow is declared
above the immediate watch that calls it: an interim dev build (`57a7d4a`,
never on trunk) crashed `/lobby` with a temporal-dead-zone error for ~5
minutes; `parent-level.test.mjs` now pins the order.

FR-ML-009.

## T008 — double click edits either level

**Status**: Implemented — `82ddd5e` (right-pane lines, another lane),
`618851f` (the viewer's own middle card).

`utils/msg-edit.mjs` `wantsDblClickEdit` no longer refuses a clickable row;
`MessageCard.vue` clears the word the browser selected before the editor
takes the caret. `tests/unit/msg-edit.test.mjs` updated to the owner's rule.

FR-ML-010.

## T009 — unit tests

**Status**: Implemented — `618851f`,
`csi-spl-wui/tests/unit/parent-level.test.mjs`: 41 cases (`node --test` →
`# pass 41`), covering the send rule per tab, every wire leg (optimistic row,
ack, live frame, view read), the middle list, the right pane, topics home,
the reload read, test-02/test-03, the shell listener, and the lobby follow.
Unit runner at `618851f`: all 73 files pass; `nuxt typecheck` exit 0 (control:
a planted `TS2322` made it exit 2).

SC-ML-2.

## T010 — the live proof

**Status**: Implemented — `618851f`,
`csi-spl-wui/tests/e2e/parent-level-live.proof.mjs`.

Per surface (channel, DM to an offline e2e agent, lobby, topics home): L1 with
the pane closed → one card, `is_parent 1`; replies → pane opens, left tab
unchanged; L2 → right only, `is_parent 0` on the same task, one card reading
L1, in the sender tab AND a watcher tab; test-02 (click middle, L3 → new card,
`is_parent 1`); test-03 (click pane, L4 → `is_parent 0` in the open topic);
double click on the L1 card opens its editor; reload → still one card, L2 on
the right once opened.

    BASE=https://<fqdn> EMAIL=<member> PW_FILE=<0600 file> OUT=<dir> \
      TENANT=<tenant> PEER=<agent>@<box> node tests/e2e/parent-level-live.proof.mjs

The member is the m3-e2e one: `$SPL_STATE_DIR/m3-e2e/<tenant>/pw-human`.

## T011 — deployed and measured on both envs

**Status**: Implemented — trunk `618851f`, 2026-09-25.

| env | `build.json` commit | hub `/version` | live proof |
|---|---|---|---|
| dev | `618851f`, built 10:31:18Z | 0.3.12 `66de3bc` | 80/80 steps, n=1 per surface, tenant `t1` |
| prd | `618851f`, built 10:32:07Z | 0.3.12 `66de3bc` | 80/80 steps, n=1 per surface, tenant `e2e` |

The WUI was deployed by the local replay of the `30_wui` deploy job, not by a
CI run.

SC-ML-1.

## T012 — clean message data for the test round

**Status**: Implemented (ops, 2026-09-25) — owner order "delete all of te msgs
data from the dev and prd , to start clean with the testing".

Backups first (`do_spl_db_backup`, `SPL_BACKUP_PREFIX=<env>/pre-msg-wipe-20260925/`):
`gs://csi-spl-dev-db-backups/dev/pre-msg-wipe-20260925/spool-20260925T094504Z.sql.gz`,
`gs://csi-spl-prd-db-backups/prd/pre-msg-wipe-20260925/spool-20260925T094541Z.sql.gz`.
Then one transaction per env under the operator RLS scope: `DELETE FROM
messages` (dev 572, prd 84), cascading `deliveries` and `message_revisions`;
the `message_period_counts_sub` trigger decremented the period meters, whose
rows were kept. Re-read afterwards: 0 / 0 / 0 on both.

## T013 — make the wipe a named action

**Status**: Planned.

T012 ran through a one-off, uncommitted action, which the repo rule "nothing
ad hoc" forbids. Add `csi-spl-orc/src/bash/run/spl-msg-wipe.func.sh`
(`do_spl_msg_wipe`: `DRY_RUN=1` default printing before/after counts inside a
rolled-back transaction, backup required first, `TENANT_ID` optional) plus its
test.

## T014 — `/t/<task_id>`

**Status**: Planned.

The page is the topic in the main column; it sends with `paneVisible: true`
by design. Not covered by T010: add a surface that opens `/t/<task_id>`,
sends a level-2 line, and asserts it shows there and adds no second card on
the channel feed. FR-ML-011.

## T015 — the live proof in CI

**Status**: Planned.

T010 needs a member password, so it runs by hand today. Wire it into the
deploy workflow with the m3-e2e member's secret, so a regression on either
env is caught by the deploy, not by the owner.

<!-- version: 0.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T11:23:32Z -->
