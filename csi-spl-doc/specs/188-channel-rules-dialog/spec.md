# Spec 188: Channel rules dialog

Status: **Draft v0.1** (2026-11-20). Lane `c-489` (`claude`, backup for
`specs_and_docs`: no agy cli on this box). Nothing below is built.
Epic: **SPL-2403**. Issue: **SPL-6084**. Class: `feature`. Kind: `specs_and_docs`.
Discussion: `topic:b1fe7670-8e80-4e67-b4d0-2a5484328981` (`t1`), task
`dispatch-b1fe7670`.
Builds on: [005 spool WUI](../005-spool-wui/spec.md) (the sidebar and its
row menu), [113 workspace docs](../113-workspace-docs-qto/spec.md) (the qto
doc tree, its API and its editor) and the SPL-3500 channel-rules map
(`csi-spl-orc/src/bash/features/spawn-agents/lib/channel-rules.inc.sh`).

Number: the highest spec on `origin/master` `cbbc11996` is
`187-scheduled-tasks-activities`
(`git ls-tree --name-only origin/master csi-spl-doc/specs/ | tail -2`), and
no worktree of this box holds a `188-` or `189-` folder (`ls -d` of
`csi-spl-doc/specs/18[89]*` in every `git worktree list` path -> none), so
this is 188.

Paths below: `api/` = `csi-spl-api/src/go/spool-hub-api/internal/`,
`wui/` = `csi-spl-wui/src/`, `orc/` = `csi-spl-orc/src/bash/`,
`sa/` = `orc/features/spawn-agents/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`.

## 0. The owner's ask (verbatim)

HUM-10, t1 topic b1fe7670, msg d0bd827c-8148-4f9b-bb64-0f8e3ddab371:

> "I should be able to specify custom set of rules and way of working which
> are channel specific , by right clicking on the channel and have an dialog
> box with claude.md like typical things which the agents must know while
> working on this channel"

The same hour, in a seat's channel (msg 846ae507), the owner asked a seat to
"write somewhere in the instructions for this channel ... that each
discussion may have 0..1 current tickets only". Per-channel instructions are
wanted now; today they have no owner-facing editor.

## 1. Owner questions (one form)

Q1 to Q6 are open; every part of sections 3 to 7 that depends on one is
marked **[Qn]**. The recommendation is the first option of each question.

```poll
Q1 Where do a channel's rules live?
(A) The existing qto rules doc per channel, linked from the hub and edited from the dialog
(B) A new hub column on channels (plain markdown)
(C) Both: the column, exported into the qto doc
Q2 Who may edit a channel's rules?
(A) The channel owner and workspace admins
(B) The workspace owner only
(C) Any member of the channel
Q3 Who must read them?
(A) Every agent that posts or works in the channel, dispatchers included
(B) Only the seats on the channel
Q4 When does a change reach a live agent?
(A) Both: a note at once, and the next seed re-exports it
(B) At the next rotation or restart only
(C) A note at once only
Q5 What is the dialog?
(A) A markdown textarea with a preview tab, and a link to the full doc editor
(B) The full qto doc editor inside the dialog
Q6 A workspace-wide default as well?
(A) Yes: workspace rules, then the channel's rules on top
(B) Per channel only
```

Why each recommendation:

- **Q1 A.** The qto doc already is the one source a seat reads (section 2.2);
  the gap is that the map from channel to doc is box-local. Keeping the doc
  and moving only the link to the hub reuses the export, the doc history
  (spec 113 D-Q1) and the editor. B forks the source in two; C needs a sync.
- **Q2 A.** The channel owner already owns its other settings (section 2.4);
  admins already hold `tenant.settings`. B blocks a member-run channel; C lets
  any member rewrite what every agent obeys.
- **Q3 A.** The 0..1-tickets rule of msg 846ae507 is one a dispatcher filing
  an issue must know; today a dispatcher never reads the doc (section 2.3).
- **Q4 A.** A seat that lives for hours would miss a change until its next
  rotation; the note is cheap and the re-export keeps the seed path true.
- **Q5 A.** A rules text is short; the dialog stays small and loads no
  editor chunk on the sidebar (the async dialog rule, section 2.1). The link
  opens the full editor for a long doc.
- **Q6 A.** A workspace-wide way of working (e.g. the ticket rule for every
  channel) is otherwise copied into every channel's doc.

## 2. What exists (measured on `origin/master` `cbbc11996`)

### 2.1 The channel menu and dialogs

- A channel row opens its menu on right-click:
  `wui/components/ChannelSidebar.vue:325`
  (`@contextmenu.prevent="openChannelMenu('ch:' + c.channel_id)"`); a DM row
  at `:231`. `openChannelMenu` sets `rowMenu` (`:765`).
- The items: `rowMenuItems` in `wui/utils/sidebar-row-menu.mjs:17`. A channel
  row today offers Open, Copy link, Mark as read (unread only), Mute / Unmute,
  Move up / Move down, **Properties**, Archive channel and Delete channel
  (`:18-37`).
- Properties opens `wui/components/ChannelPropertiesDialog.vue`, loaded
  async (`ChannelSidebar.vue:672`). Its tabs: `about`, `people`, `agents`,
  `settings` (`ChannelPropertiesDialog.vue:453-457`). The About tab shows
  `channels.description` read-only (`:23-36`).
- Properties is shown to every signed-in viewer
  (`wui/composables/useSidebarChannelAdmin.ts:48`).

### 2.2 How the rules doc reaches a seat

- The box map `$SPOOL_ROOT/channel-rules.tsv` (never in git), one row per
  channel: `<tenant> <channel> <doc id> <env> <desk agent> [<sole seat>]
  [<no-auto-post>]` (`sa/lib/channel-rules.inc.sh:11`). Written only by
  `do_spl_channel_rule` (`orc/run/spl-channel-rule.func.sh:38`).
- A seat brief names its channel with one `Channel: <tenant> #<channel>`
  line. At a first, rotation or restart seed, `spawn-core` finds it
  (`sa/scripts/spawn-core.inc.sh:591`), exports the doc to
  `<spool>/<id>/lifetime/channel-rules.md` (`:601-615`) through
  `cr_prepare` -> `cr_export` (`channel-rules.inc.sh:182`, `:148`; the read
  is `do_spl_desk_doctree export <doc>`), and the seed carries the one line
  of `cr_seed_line` (`:174`): read that file before acting and after every
  rotation ack; it wins over the brief.
- `do_spl_lane_restart` does the same for its distil
  (`orc/run/spl-lane-restart.func.sh:376`).
- Between seeds nothing re-exports: an edit of the doc reaches a seat at its
  next rotation or restart, not before.
- Guard: `sa/tests/test-seed-channel-rules.sh`.

### 2.3 Who else reads it

- Only the two seed paths above export the doc:
  `grep -rn "channel-rules.md\|cr_prepare" --include=*.sh csi-spl-orc | grep -v /tests/ | grep -v lib/channel-rules.inc.sh`
  -> `spawn-core.inc.sh` and `spl-lane-restart.func.sh` only.
- The take, take-auto, desk poll-ack, archived-followup and workspace-move
  actions read the MAP (columns 6 and 7: sole seat, no-auto-post), never the
  doc (`grep -ln "channel-rules\|cr_no_auto_post\|cr_sole_seat" orc/run/` ->
  those files, plus the two of 2.2 and `do_spl_channel_rule`).
- So a dispatcher, an orchestrator or a lane placed from a channel topic
  never reads the channel's rules: their briefs carry no `Channel:` line
  (this lane's brief has none).

### 2.4 Who may change a channel

- `PATCH /v1/channels/{channel}` (invite setting): the channel owner only
  (`api/hub/channel_members.go:515`, `channelOwner` at `:103`); a default
  channel is 409.
- `PATCH /v1/tenant/channels/{channel}` (`no_fallback`): permission
  `tenant.settings` (`api/hub/tenant_settings.go:432`), an administer-stage
  grant (`api/rbac/lifecycle.go:46`).
- Delete and Archive: the creator only (`wui/utils/channel-members.ts:169`).
- `channels.description` (`rdb/0027_channel_description.sql`) is set at
  create; whether any route edits it later I did not check.

### 2.5 The qto doc editor

- Hub routes `/v1/workspace/doctree...` (`api/hub/wsdoc_tree.go:123-135`);
  writes need `docs.write` (`api/hub/wsdoc_nodes.go:54`,
  `rdb/0123_docs_permissions.sql`).
- WUI: `wui/components/workspace-docs/WorkspaceDocView.vue` (the editor) and
  its client `-doctree-api.ts`.

## 3. The flow, end to end

1. **Right-click** a channel row -> the menu shows **Channel rules** right
   after Properties (7.1 C1).
2. **The dialog** loads the channel's rules: `GET /v1/channels/{channel}/rules`
   -> `{doc_id, markdown, revision, can_edit, inherited}` **[Q1, Q6]**. A
   viewer without the right sees it read-only **[Q2]**. Its body is a
   markdown textarea with a preview tab **[Q5]**.
3. **Save** -> `PUT /v1/channels/{channel}/rules {markdown, base_revision}`.
   The hub checks the right **[Q2]**, writes the doc (Q1 A: through the
   doctree store, a new revision of the rules doc, made on first save under a
   `channel-rules/` folder of the workspace tree; Q1 B: the new column), and
   refuses a stale `base_revision` with 409.
4. **Store** -> the link channel -> doc lives on the hub (`channel_rules`
   table, section 4), not only in the box map.
5. **Every agent on the channel reads it** **[Q3, Q4]**:
   - the seed paths of 2.2 resolve the doc from the hub first, the box map
     second (the map keeps columns 6 and 7, which this spec does not move);
   - a seat on the channel gets a spool note `CHANNEL RULES CHANGED
     <tenant> #<channel> rev <n>` and re-exports the file (Q4 A or C);
   - a dispatcher or lane placed from a channel topic gets the `Channel:`
     line in its brief, so the same seed path exports it (Q3 A).

### 3.1 Reused

- The qto doc and its export (`do_spl_desk_doctree export`), `cr_export`'s
  retry, the seed line, the rotation and restart paths.
- `ChannelPropertiesDialog.vue`'s `UiDialog`, the async load, the role
  checks of 2.4.
- The doctree store's revisions and lock (spec 113 sections 2.3, 3.3).

### 3.2 Gaps

- **G1** the map is box-local: a box without the row exports nothing, and
  the WUI cannot find a channel's doc. A hub link replaces columns 3-5 of the
  map (doc, env, desk agent) as the source; the map stays as the fallback
  and for columns 6-7.
- **G2** no owner-facing editor reaches the rules from the channel.
- **G3** no change reaches a live agent between seeds **[Q4]**.
- **G4** non-seat agents never read the rules (2.3) **[Q3]**.
- **G5** no workspace default **[Q6]**.

## 4. Data (rdb) **[Q1, Q6]**

Q1 A (recommended): one new table, no column on `channels`.

```sql
CREATE TABLE channel_rules (
  tenant_id   uuid NOT NULL,
  channel     text NOT NULL,          -- '*' = the workspace default [Q6]
  doc_id      uuid NOT NULL,          -- the qto doc (spec 113)
  revision    bigint NOT NULL DEFAULT 0,
  updated_by  text NOT NULL DEFAULT '',
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (tenant_id, channel)
);
```

With RLS by `tenant_id` (developer guide 2.6.4). Q1 B instead: `ALTER TABLE
channels ADD COLUMN rules_md text NOT NULL DEFAULT ''` plus `rules_rev`.
Q1 C: both, the column the edited copy and the doc its export.

## 5. Reading order for an agent **[Q6]**

The exported file is the workspace default (`channel = '*'`), then the
channel's own rules under a heading naming the channel; the channel's rules
win where they differ. The seed line of `cr_seed_line` is kept word for word
apart from naming the two parts. Q6 B: the channel's rules only, as today.

## 6. Build order (rows a later lane can take in parallel)

| row | part | files | depends on | done test | red control |
|---|---|---|---|---|---|
| R1 | rdb: `channel_rules` + RLS **[Q1, Q6]** | `rdb/<next>_channel_rules.sql` (number from `do_rdb_migration_next`) | the answers | `TestRLSCoversEveryTenantTable` green; `PRE_PUSH_TIER=full` | the table without its policy fails `TestRLSCoversEveryTenantTable` |
| R2 | hub: `GET` / `PUT /v1/channels/{channel}/rules` **[Q1, Q2, Q6]** | `api/hub/channel_rules.go`, `api/store/channel_rules.go`, their tests | R1 for the Postgres test; the mock store lets it start on 7.1 C2 | handler tests: editor 200, non-editor 403, stale revision 409, unknown channel 404, other tenant 404 | a `PUT` without the role check passes the non-editor case: the test turns red |
| R3 | WUI: menu item + dialog **[Q2, Q5]** | `wui/utils/sidebar-row-menu.mjs`, `wui/components/ChannelRulesDialog.vue` (async), `ChannelSidebar.vue`, `useSidebarChannelAdmin.ts`, unit tests | 7.1 C1-C2 only (mock api) | unit: the item on a channel row, not on a DM row; save sends `base_revision` | the item shown on a DM row fails the unit test |
| R4 | orc: hub-first resolve + change note **[Q3, Q4]** | `sa/lib/channel-rules.inc.sh`, `sa/scripts/spawn-core.inc.sh`, `orc/run/spl-lane-restart.func.sh`, a new `orc/run/spl-channel-rules-notify.func.sh`, `sa/tests/test-seed-channel-rules.sh` | 7.1 C2-C4 (stub hub) | a seed for a channel with a hub link and no map row names a non-empty file; a change note reaches each seat of the channel once | the resolver reading the map only, with the hub stub serving the doc: the new seed case is red |
| R5 | e2e: right-click -> edit -> save -> reload | `csi-spl-wui/tests/e2e/channel-rules.spec.ts` | R3 (mock), then R2 deployed for the dev run | Chrome run green on the mock bundle | Save not wired: the reload shows the old text, red |
| R6 | briefs: a `Channel:` line for dispatcher and lane briefs **[Q3]** | the brief writer of `do_spl_spawn_enqueue` and the desk's placement code, their tests | R4 | a lane placed from a channel topic carries the line | a placement without it fails the new case |
| R7 | docs | a `csi-spl-doc/doc/md/` channel-rules page, the `channel-rules.inc.sh` header, this spec's status | R2-R4 | `do_check_fleet_rules_drift` green | - |
| R8 | i18n (language rule) | `csi-spl-wui/i18n/locales/*.json`, the keys of R3 | R3 | `i18n-parity` and `i18n-untranslated` green; an agy review is the last step before it ships | a key missing in one locale fails `i18n-parity` |

R1, R3 and R4 start at once on 7.1; R2 needs R1's table for its Postgres
test only. Every row waits for the answers to the questions it is marked
with.

## 7. Contracts

### 7.1 Binding contracts

- **C1 the menu item.** `rowMenuItems(unread, {channel: true, rules: true})`
  adds `{id: 'rules', icon: 'settings', labelKey: 'sidebar.row_menu.channel_rules'}`
  right after `properties`, emitted as `rules`. Shown to every signed-in
  viewer, read-only for a non-editor **[Q2]**. Never on a DM row.
- **C2 the API.**
  - `GET /v1/channels/{channel}/rules` -> 200
    `{"channel": "<name>", "doc_id": "<uuid or empty>", "markdown": "<text>",
    "revision": <n>, "can_edit": <bool>, "inherited": "<markdown of '*'>"}`;
    no rules yet = 200 with `doc_id ""`, `markdown ""`, `revision 0`.
    404 for an unknown channel or a non-member.
  - `PUT /v1/channels/{channel}/rules` `{"markdown": "<text>",
    "base_revision": <n>}` -> 200 `{"revision": <n>, "doc_id": "<uuid>"}`;
    403 without the right **[Q2]**; 409 `stale_revision` when
    `base_revision` is not the current one; 413 over 64 KiB.
  - `channel = "*"` addresses the workspace default **[Q6]**; editing it
    needs `tenant.settings`.
- **C3 the change note** **[Q4]**: kind `note`, task
  `channel-rules-<tenant8>-<channel>`, body first line
  `CHANNEL RULES CHANGED <tenant> #<channel> rev <n>`, to every live agent
  whose brief carries that `Channel:` line. The agent re-exports with the
  existing `cr_export` and reads the file before its next act.
- **C4 resolve order.** `cr_row` asks the hub link first (through the desk,
  as the export does), the box map second; columns 6-7 always from the map.
  Hub silent: the map row, and a WARN; neither: no rules line (today's
  behaviour).
- **C5 org-neutral.** No channel or tenant name in git: tests use
  generated ids; the map stays out of git.

### 7.2 Not in this spec

Moving the sole-seat and no-auto-post columns to the hub; rules for DMs;
rules per topic.

## 8. Review

v0.1 goes to the dispatch holder with the form of section 1. v0.2 folds the
answers.
