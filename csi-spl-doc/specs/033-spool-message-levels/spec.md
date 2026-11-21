# Feature Specification: Message Levels — the Opening Card and the Thread Line

**Feature ID**: `033-spool-message-levels` · **Milestone**: M3 · **Status**: Implemented (the live proof in CI skips until the secrets `SPL_PROBE_PW_<ENV>` are set, `tasks.md` T015); section "Message kinds: seven more" (SPL-5884) Partial (T020-T023, T024 (b)-(g) and T025 built; T024 (a), T026 and T027 Planned)
**Created**: 2026-09-25 · **Lane**: MESSAGE-LEVELS (hub + DB + browser)
**Authority**: this file for the rule; `tasks.md` for what is built and where.

Status vocabulary follows `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**.

## Naming

The owner calls the flag `is_topic`. The column, the wire field and the code call it
`is_parent`. They are the same bit: `is_topic=1` ≡ `is_parent = 1` ≡ **level 1**;
`is_topic=0` ≡ `is_parent = 0` ≡ **level 2**.

## The owner's request, verbatim (2026-09-25)

> A spool message is one of two levels.
>
> Level 1 is the opening message of a topic. It is the card in the middle pane (channel
> feed, direct-message feed, lobby feed, topics home). One card per topic. The card is
> that opening message. Later activity may move the card up. The card's text stays the
> opening message.
>
> Level 2 is a message written while the right-hand topic pane is open. The reader got
> there by clicking replies. That click opens the right pane and leaves the left tab where
> it was (Channels, DMs, Topics, or Flow). A level-2 message is stored with is_parent = 0.
> It is drawn only inside the open topic on the right. It is never a row in the middle
> pane, never a new topic card, and never a new row on the topics home list.

Refined the same day, after trying the build:

> there is still bug in the cration of the msgs ... whenever the last selected pane was
> the middle pane - check test-02 typing on the omnibox and hitting enter should have
> created an is_topic=1 msg , not a thread msg with is_topic=0

> test-03 when the right threads / topic content panel is visible and last selected the
> typing of msgs should produce an is_topic=0 msg

> it should be possible to also edit the is_topic=1 msgs by double clicking them

> delete all of te msgs data from the dev and prd , to start clean with the testing

## Clarifications

### Session 2026-09-25

- **The pane selected last decides, not "is the pane open".** **OWNER-STATED** (test-02,
  test-03 above). The first three builds keyed the level on the left tab (`69cdf97`), then
  on the pane being open (`5b16c0f`); the owner's test-02 was stored as a thread line
  because the pane was still open although the owner had gone back to the middle.
- **Opening a topic puts the reader on the right.** A replies click, a card click, Enter on
  a focused card and a topics-home row click all count as selecting the right pane.
  **OWNER-STATED** for the replies click (the original request); the other three are the
  same action by another input, **INFERRED**.
- **The sidebar, the top bar (Omnibox) and a pane divider select nothing.** Typing in the
  Omnibox must not itself move the choice. **INFERRED** — the Omnibox is where every line
  is typed, so it cannot be the signal.
- **A pane opened from a `?topic=` URL with no click yet counts as the right pane.**
  **INFERRED**: it is the newest thing on screen.
- **`in: <title>` still names the topic**, whatever pane was selected. **OWNER-STATED**.
- **A box or agent send is always level 1.** The hub stores `is_parent = 1` for it; only a
  browser chooses. Decided with the hub change (`69cdf97`). **Amended in 0.5.7
  (FR-ML-013):** except a line on a channel topic's task, which is stored level 2
  (`internal/hub/channels.go` `boxLevel`); a new task, a DM topic and the legacy lobby
  task stay level 1.
- **`is_parent` is hub metadata, not part of the signed envelope** — same reason as 032's
  edit marker: no signature covers a field the browser chooses.
- **Double-click edits a level-1 card too.** **OWNER-STATED**. `82ddd5e` (another lane)
  shipped it for right-pane lines only and kept the middle card click-to-open; `618851f`
  extends it to the viewer's own middle card. The first click of the double click still
  opens that card's topic.

## User stories

### US1 — start a topic (P1)

With the right pane closed, or with the middle pane selected last, a member types a line
in the Omnibox and sends it. One new card appears in the middle pane; the hub stores the
line with `is_parent = 1` on a new `task_id`.

### US2 — write inside a topic (P1)

The member clicks replies on a card. The right pane opens on that topic, the left tab does
not change. The next line is stored with `is_parent = 0` on **that topic's** `task_id`,
appears in the right pane only, and the middle still shows exactly one card for the topic,
reading the opening line.

### US3 — go back to the middle (P1, test-02)

With the right pane still open, the member clicks in the middle pane and sends. The line
is a new topic (US1), not a line of the open one.

### US4 — it survives a reload and a second reader (P1)

After a reload, and in a second tab that only receives lines over the live socket, a
level-2 line is still absent from the middle and present when its topic is opened.

### US5 — fix a typo with a double click (P2)

A double click on the member's own message — a middle card or a right-pane line — opens
the same in-place editor as `e` (032).

## Functional requirements

| id | requirement | status |
|---|---|---|
| FR-ML-001 | `messages.is_parent smallint NOT NULL`, 0 or 1; existing topic openers backfilled to 1 | Implemented — rdb `0034`, `0035` |
| FR-ML-002 | Browser send frame carries `is_parent`; absent = 1, other values rejected; box sends stored as 1 (except FR-ML-013) | Implemented — `internal/hub/wui.go` `uiParent` |
| FR-ML-003 | The topic read and the live `message` frame return `is_parent` | Implemented — `69cdf97` |
| FR-ML-004 | A send is level 2 into the open topic iff the right pane is open; otherwise level 1 on a new task; `in:` wins. Was "open **and** selected last" (`618851f`); SPL-996 owner answer B (topic e0b12a2c, 2026-09-27) retired the selected-last half | Implemented — `a3f49471b` (`utils/pane-focus.mjs` `paneTakesLine`, `utils/omnibox-topic.mjs`) |
| FR-ML-005 | The middle list never shows an `is_parent = 0` line as a card; one card per topic, reading the opening line | Implemented — `66de3bc`, `778cf49` |
| FR-ML-006 | The right pane keeps its topic's level-2 lines after the send is confirmed | Implemented — `778cf49` |
| FR-ML-007 | The topics home list never gets a new row for a level-2 line | Implemented — `topic-list.mjs` `bumpTopic` |
| FR-ML-008 | After a reload a topic keeps its card even when its newest page is all level 2 | Implemented — `618851f` (`listMessages`) |
| FR-ML-009 | A new lobby topic reaches every open `/lobby` live, not only its sender | Implemented — `618851f` (`pages/lobby.vue`) |
| FR-ML-010 | Double click opens the editor on the viewer's own message at either level | Implemented — `82ddd5e` + `618851f` |
| FR-ML-011 | `/t/<task_id>` shows the level-2 line in the topic and adds no second card | Implemented — `pages/t/[task_id].vue` sends level 2 (`isParentFlag({ paneVisible: true })`); proof surface `t`, verified on dev (SPL-860), run by every WUI deploy (`tasks.md` T014, T015) |
| FR-ML-012 | A level-2 reply is stored in its topic root's channel, whatever client sent it untagged | Implemented — hub `7b6e0ae` (0.5.4); backfill rdb 0042 applied dev + prd, `tasks.md` T017 |
| FR-ML-013 | An agent's line on a channel topic's task is a level-2 reply, as the same line from the WUI reply pane is | Partial — hub 0.5.7 `boxLevel` built; rdb 0043 backfill applied on dev/prd is not recorded, `tasks.md` T018 |

## Level-1 card presentation in the middle pane (CLE-34989)

The owner, 2026-09-25 18:48:43Z, PRD #spool-hub-devel topic `db0f9d71`, verbatim:

> implement the feagture to clip the size of the msg with is_parent=1 to max 5 rows of text or max 30% of the screen if picture is involved ... the rest should be expandable via the similar expandable graggable handle which exists in the ommibox ... so that the middle topics pane where the is_parent=1 msgs are displayed will stay by default tighty. There should be a control which sets the height of those posts to 3 different ways - only titles ( where title is the first 90 chars , this default of 5 rows max and all size

| id | requirement | status |
|---|---|---|
| FR-ML-020 | A level-1 card in the MIDDLE pane (lobby, channel, DM) is clipped by default at 5 text rows of its body; the thread pane and the new-topic cards above it are never clipped | Implemented — `utils/card-clip.mjs` `cardClipPx`, `LiveFeed` `clip` (middle hosts only) |
| FR-ML-021 | A card carrying an inline picture or a link preview takes the same 5-row box as a text card: the picture counts inside the box, is cut like long text, and the grip shows all of it. Superseded 2026-10-16 (SPL-2121, owner t1 28559e83 msg 5d02bac2): it had 30% of the window with its text capped at 5 rows | Implemented — `cardClipPx` (no picture branch); e2e `card-height-rows.test.mjs` |
| FR-ML-022 | A clipped card shows it (the last line fades) and carries a grip like the omnibox's: a drag sets its height, from one row to all of it; Enter / Space shows all or goes back; Arrow Up / Down step two rows. The drag is per card and not stored | Implemented — `MessageCard.vue` `.card-grip` |
| FR-ML-023 | A 3-way control in every middle-pane header: `titles` (first 90 characters of the body on one line), `5 rows` (default), `full`; a keyboard radiogroup | Implemented — `CardClipControl.vue` |
| FR-ML-024 | The mode is one per browser and survives a reload (localStorage `spool-card-clip`, try/catch; a bad value reads as the default) | Implemented — `useCardClip.ts` |
| FR-ML-025 | The row cap follows the font-size setting (measured line height; rem fallback) | Implemented — `measure()` reads the rendered line height |
| FR-ML-026 | Every new string in all 19 locales (i18n parity) | Implemented — GRK-3512 `885e144` |

## Success criteria

- **SC-ML-1**: the live proof `csi-spl-wui/tests/e2e/parent-level-live.proof.mjs` passes
  every step on dev and prd (channel, DM, lobby, topics home; sender tab and watcher tab;
  reload; test-02; test-03; double click). Measured `618851f`: dev 80/80, prd 80/80, n=1
  per surface (`tasks.md` T011).
- **SC-ML-2**: `tests/unit/parent-level.test.mjs` green in the unit runner.
- **SC-ML-3** (CLE-34989): signed in on dev and prd, the computed card heights per mode
  match FR-ML-020..FR-ML-023, a grip drag grows a card, the thread pane stays unclipped,
  and the mode survives a reload (`tasks.md` T019).

## Message kinds: seven more (SPL-5884)

**Status**: Partial: T020 (`rdb/0300_message_kinds_seven.sql`, test `api/internal/store/message_kinds_seven_test.go`) and T021 (`msg.validKinds` holds the 13; exception E1 in `api/internal/hub/human_post_guard.go` `dmOpensKind`) are built, SPL-6055; T022 (the `is:` enum holds the 13 kinds, test `api/internal/search/kinds_test.go`, `api/internal/store/search_kinds_test.go`) and T023 (hello feature `kinds13`, `api/internal/hub/kinds13.go` `acceptsEnv` at all 5 accepts sites, test `api/internal/hub/kinds13_test.go`) are built, SPL-6094; T024 (b) (`SPOOL_KINDS`, `SPOOL_NOTE_KINDS`, `spool_kind_in` in `orc/features/spawn-agents/lib/spool-env.inc.sh`, parity test `orc/features/spawn-agents/tests/test-spool-kinds.sh`), (c) (`spool-send.sh --kind` reads `SPOOL_KINDS`), (d), (e), (f) (`DESK_KIND` of the desk post and reply takes `SPOOL_NOTE_KINDS`) and (g) are built, SPL-6107; T025 (the WUI lists the 13: `wui/src/utils/msg-kind.mjs`, `kind-picker-keys.ts` F U A Q I D O, the seven glyphs, the `--color-kind-*` tokens, `is:` suggestions, 19 locales; tests `wui/tests/unit/msg-kind.test.mjs`, `kind-picker-keys.test.mjs`, `kind-tokens.test.mjs`, `search.test.mjs`, e2e `wui/tests/e2e/kind-picker-keys.test.mjs`) is built, SPL-6123, its locale words waiting on the agy review (K.6); T024 (a) (the box refresh, a box operation), T026 and T027 Planned. The owner answered K.8 (Q1-Q5) · **Issue**: SPL-5884 ·
**Epic**: SPL-2403 · **Discussion**: t1 #spool-hub-ui topic `f4165bc3`.

Spec 033 holds this section because the issue names it. The kind itself is
spec 020's field (`contracts/message-schema-v2.md` line 21), and T026 below
updates that row. The code sites below are cited as `file:line` on
origin/master `405fe0885`. Paths are relative to these roots: `api/` =
`csi-spl-api/src/go/spool-hub-api/`, `wui/` = `csi-spl-wui/`, `orc/` =
`csi-spl-orc/src/bash/`, `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`.

### K.1 The owner's request, verbatim (HUM-10, 2026-11-18)

> we need to add this in this menu also the options for feature , bug , alert , etc.
> suggest proper type of kinds for the msg cards

(msg `3ca36ae0`, a screenshot of the kind menu: message, note, task, blocker,
result, reject.) The dispatcher's poll `c7ef50a3` offered A, a separate type
field, or B, new kinds in the same menu. The owner answered (msg `890eadfb`):

> Answer 1: B — New kinds in the same menu  Answer 2: F,B,AL,Q,I,D,DOC — feature;
> bug; alert; question; idea; decision; docs

The dispatcher's post `ddc6f29a` named what B touches: the hub's allowed
kinds, the WUI menu and search, the spool CLI and the agents, and the help.
It also set the routing rule: the 7 new kinds route as a note. This section
follows that. It adds one thing the post does not name, the old-box
delivery gate (K.4.3). Not checked: the full text of `ddc6f29a`. This seat
could not read the topic (`spool tail --url` from the desk box answered "no
messages visible"), so the scope above comes from the brief's summary of
that post.

### K.2 The seven kinds

| kind | means | icon (lucide name, added to `wui/src/utils/uiIcons.ts`) | colour token | dark theme | light themes (`data-theme^="light"`) | picker key | search |
|---|---|---|---|---|---|---|---|
| `feature` | a capability asked for | `puzzle` | `--color-kind-feature` | `#8c9eff` | `#3f51b5` | `F` | `is:feature` |
| `bug` | something broken | `bug` | `--color-kind-bug` | `#ff8a5c` | `#c43e00` | `U` (b**U**g; B is blocker) | `is:bug` |
| `alert` | a live problem now | `siren` | `--color-kind-alert` (fill) and `--color-kind-alert-fg` (glyph) | fill `#ffd54f`, glyph `#1b1b1b` | fill `#f6bf26`, glyph `#1b1b1b` | `A` | `is:alert` |
| `question` | needs an answer | `circle-help` | `--color-kind-question` | `#c770e0` | `#8e24aa` | `Q` | `is:question` |
| `idea` | for later | `lightbulb` | `--color-kind-idea` | `#f2a29c` | `#c2185b` | `I` | `is:idea` |
| `decision` | a recorded decision | `scale` | `--color-kind-decision` | `#2dd4bf` | `#0f766e` | `D` | `is:decision` |
| `docs` | documentation | `file-text` | `--color-kind-docs` | `#a0a0a0` | `#616161` | `O` (d**O**cs; D is decision) | `is:docs` |

- **Keys.** The picker keeps M N T B R J (`wui/src/utils/kind-picker-keys.ts:13`).
  The new letters are F U A Q I D O, so all 13 are unique. The keys work only
  while the picker is open (`wui/src/components/KindPicker.vue:107`), so they
  cannot clash with the message menu's keys.
- **Order.** The picker lists the old six first, then the owner's order:
  `MSG_KINDS = ['msg','note','task','blocker','result','reject','feature','bug','alert','question','idea','decision','docs']`
  (`wui/src/utils/msg-kind.mjs:9`).
- **Look.** The six old kinds keep their colours (`wui/src/assets/css/main.css:566-573`).
  A new kind is a bare glyph in its colour, with no frame. That is the rule
  of `main.css:573`, which keeps a frame only on the blocker.
  - **`alert` is filled**: yellow, with a dark glyph. Blocker is the only
    other filled badge, and it is red. A live problem stands out, and the
    two filled badges do not look alike.
  - Six of the seven dark colours are hexes of the dark calendar palette
    (`wui/src/assets/css/variables.css:420-446`). `decision` (`#2dd4bf`,
    light `#0f766e`) is a new teal, in neither palette. On light, `feature`,
    `question` and `docs` reuse calendar hexes (`#3f51b5`, `#8e24aa`,
    `#616161`) and `alert` reuses `#f6bf26`; `bug` (`#c43e00`) and `idea`
    (`#c2185b`) are new darker values, picked to clear 3:1 on the light
    surfaces (T025's contrast test proves it).
  - **The alert is measured by its glyph.** The light alert fill `#f6bf26`
    reads 1.29-1.43:1 on the six light `--color-bg-2` values, so it cannot
    clear 3:1 as the bare glyphs do (the dark fill reads 13.07:1). The owner
    asked for a yellow badge (Q1 A), so the fill stays, and
    `wui/tests/unit/kind-tokens.test.mjs` holds the alert's glyph
    (`--color-kind-alert-fg`, `#1b1b1b`) at 3:1 on its fill: 10.17:1 light,
    12.21:1 dark. T025's planted `--color-kind-alert: #ffffff` on light
    therefore stays green (the dark glyph reads on white too); its red
    control is a white glyph (`--color-kind-alert-fg: #ffffff` on light),
    which fails in all six light themes. The other six kinds clear 3:1 on
    `--color-bg-2` in all 8 themes; the lowest is `bug` on light-violet,
    3.98:1.
  - The tokens go in one `:root` block and one `:root[data-theme^="light"]`
    block, as the row-alt and mode tokens do (`variables.css:391-398`), so
    every light-* theme shares one set.
- **Search.** The `is:` enum gets the seven values
  (`api/internal/search/grammar.go:181-182`). The match is generic, so a new
  value needs nothing more: `api/internal/search/match.go:104`
  (`m.Kind == t.Enum`) and `api/internal/store/search_postgres.go:241`
  (`m.kind = $n`). The WUI suggestion list is `wui/src/utils/search.mjs:60`.
  `is:docs` and `type:doc` (a doc section) are different operators, and the
  parser keeps them apart. `is:feature` matches messages only; issues keep
  their own kind field (`rdb/0053_issue_kinds.sql`).

### K.3 Routing: the seven behave as a note, with three exceptions

A new kind changes the badge and the search. It changes no agent rule:

- it raises no ask;
- it closes no lane;
- it escalates no blocker;
- it moves no Flow line.

The owner made three exceptions (K.8, msg `67193a13`: Q2 B, Q3 B, Q4 B).
They are the only places a new kind is treated differently from a note:

| # | exception | site, on origin/master `648ff3b0a` | today | change | build row |
|---|---|---|---|---|---|
| E1 (Q2 B) | an agent may DM a person a `question` unasked, as it may a `blocker` | `api/internal/hub/human_post_guard.go:75` (`dmRuleRefusal`) and `:86` (the follow-up of a blocker DM) | only `m.Kind == "blocker"` passes `dm_not_blocker`; only a topic opened by a blocker DM to that person lets the agent follow up there | `:75` passes `blocker` or `question`; `:86` passes a follow-up in a topic opened by a `blocker` or a `question` DM to that person, so the question can be followed up the way a blocker is. The token stays `dm_not_blocker` (the desk matches it, `orc/run/spl-desk-reply.func.sh:296`); the refusal text (`:97`) and the comments (`:18-19`, `api/internal/store/human_post_guard.go:13`) name both kinds | T021 (hub), T024 (desk text), T026 (rule 18) |
| E2 (Q3 B) | an unanswered `question` is an open item at a lane handover, listed next to blockers | `orc/run/spl-agent-handoff.func.sh:266` (section 6, "open questions") | `m.get("kind") in ("blocker", "msg")` | `("blocker", "question", "msg")` | T024 |
| E3 (Q4 B) | desk posts may set the seven too | `orc/run/spl-desk-post.func.sh:62`, `orc/run/spl-desk-reply.func.sh:529` (`DESK_KIND`) | `note\|task\|result\|blocker\|msg`, `note\|result\|reject\|blocker\|msg` | each keeps the kinds it allows today and takes `SPOOL_NOTE_KINDS` (`note` + the 7) for the rest; the `@param DESK_KIND` lines (`spl-desk-post.func.sh:35`, `spl-desk-reply.func.sh:134`) list them | T024 |

E1 narrows an earlier owner rule (how-to-post rule 18, msg `6c089b4a`:
a DM only "about blocked task"); msg `67193a13` is the newer word, for
`question` only. Every other new kind, `alert` included, is still refused
as a DM like a note. E3 does not cover `do_spl_fleet_notice`: Q4 names only
`do_spl_desk_post` and `do_spl_desk_reply`, so `spl-fleet-notice.func.sh:27`
stays `note|blocker` and widening it would need its own owner answer.
E3 sends through `spool send --kind`
(`spl-desk-post.func.sh:96`, `spl-desk-reply.func.sh:315,325,342`), whose
check is `msg.Validate` on the box (`api/internal/spool/spool.go:261`, in `Compose`), so a desk box must
run the refreshed CLI (T024 (a)) before it posts a new kind.

Every other site that branches on a kind falls into one of three groups (E1 and E2 left group 1 for the table above).

**Already note-like (the branch tests named kinds, and a new kind falls to
the default). No change; T024's tests prove it:**

| site | what it does with a kind |
|---|---|
| `api/internal/store/fleet_ask.go:342` | an ask is only `blocker`, `task` or `escalation` |
| `api/internal/store/flow.go:204` | only `blocker` makes a Flow line `blocked` |
| `api/internal/store/blocker_issue.go:281,338,383,432`, `api/internal/hub/blocker_issue.go:76,431` | only `blocker` files or keeps a blocker issue |
| `api/internal/hub/blocker_issue.go:427` | `kindBeforeBlocker` restores the kind a blocker had before. It goes through `msg.ValidKind`, so after T021 a `bug` set to blocker and back is a `bug` again |
| `api/internal/action/action.go:148` | `--accept` needs `result` |
| `api/internal/hub/dispatch.go:138`, `api/internal/hubclient/hubclient.go:1069` | a browser command to an agent is only `task` or `note`. The menu sets a kind AFTER the send (`PATCH /v1/messages/{id}/kind`, `api/internal/hub/message_kind.go:58`), so the browser never signs a new kind |
| `orc/features/spawn-agents/lib/spool-asks.inc.sh:65`, `orc/features/spawn-agents/scripts/spool-send.sh:590` | only `blocker` / `task` raise an ask |
| `orc/run/spl-orch-inbox.func.sh:48,54,86` | only `blocker` / `task` are open items; the rest are grouped as FYI and age out |
| `orc/features/spawn-agents/scripts/kill-your-self-report.sh:193,196` | only `reject` is a send-back |
| `orc/run/spl-done-claim-check.func.sh:271`, `orc/run/spl-topic-archive-suggest.func.sh:316`, `orc/run/spl-agent-restart.func.sh:767` | only `result` / `blocker` |
| `orc/run/spl-desk-reply.func.sh:552` | only `blocker` skips the done-claim check (how-to-post rule 22) |
| `orc/features/spawn-agents/scripts/spool-send.sh:231` | only `task` counts as a recent task |
| `orc/run/spl-watchdog.func.sh:996`, `orc/run/spl-lane-rotate.func.sh:963`, `orc/run/spl-rotate-lib.func.sh:1844` | only `result` is a result the agent sent |

**Lists the note by name. These must list the 7 next to it, or a new kind
would be treated differently from a note:**

| site | today | change (T024) |
|---|---|---|
| `orc/features/spawn-agents/lib/spool-notify-take.inc.sh:23` | a person's post auto-taken only for `task\|note\|msg` | add the 7 |
| `orc/run/spl-review-go.func.sh:202` | review lines read only from `result` / `note` | add the 7 |
| `orc/run/spl-watchdog.func.sh:1010` (`spl_wd_job_after`) | only a `note` (or the agent's own line) is not a job; any other kind wakes the agent | add the 7 |
| `orc/features/watchdog/situations/s1.sh:58` (`s1_jobs`) | the same rule for situation S1: an inbox line that is not a `note` is a job | add the 7 |

**Allow-lists of what may be SENT. These widen, or stay closed by choice:**

| site | today | change |
|---|---|---|
| `api/internal/msg/msg.go:50-56` (`validKinds`, `KindList`) | 6 kinds | 13 (T021). `msg.Validate` (`:199`), `Sealed.Validate` (`:385`), the PATCH (`message_kind.go:58`) and `spool send --kind` (`api/cmd/spool/main.go:498`) all read it |
| `rdb/0058_message_kinds.sql:12`, `rdb/0060_message_kind_changes.sql:36` | two CHECKs, 6 kinds | widened by the new migration (T020) |
| `orc/features/spawn-agents/scripts/spool-send.sh:414` (and usage `:12`, `:66`), `agent-send.sh:12`, `spool-notify.sh:17` | 6 kinds | 13 (T024), read from one list (below) |
| `orc/run/spl-desk-post.func.sh:62`, `spl-desk-reply.func.sh:529`, `spl-fleet-notice.func.sh:27` (`DESK_KIND`) | 5, 5 and 2 kinds | desk post and desk reply: 12 each, today's kinds plus the 7 (T024, exception E3, owner Q4 B); fleet notice: unchanged, Q4 does not name it |

**One list in orc.** T024 adds `SPOOL_KINDS` (13) and `SPOOL_NOTE_KINDS`
(`note` + the 7: the kinds that route as a note) to
`orc/features/spawn-agents/lib/spool-env.inc.sh`. `spool-send.sh:414` reads
`SPOOL_KINDS`. The four group-2 sites read `SPOOL_NOTE_KINDS` and keep the
kinds they name today: `spool-notify-take.inc.sh` keeps `task` and `msg`, and
`spl-review-go.func.sh` keeps `result`. The two watchdog sites take
`SPOOL_NOTE_KINDS` alone, so `msg` stays a job there, as it is today. An orc
test fails when `SPOOL_KINDS` differs from `msg.KindList`. (The rows of K.3
come from two sweeps over `csi-spl-orc/src/bash` on `405fe0885`, tests left
out, every hit read: `git grep -nE "kind.*(blocker|result|reject)"` and
`git grep -nE '\.kind ?(==|!=)|get\("kind"\)|\$3 ?(==|!=) ?"'`. Hits on an
issue kind, a vendor kind or a channel/dm turn kind are not message kinds and
are left out. The two watchdog rows of group 2 and the `:231`, `:996`, `:963`,
`:1844` rows of group 1 were added after the review of `94e046bbf`, W1.)

### K.4 Old clients: nothing breaks

#### K.4.1 An old WUI meets a new kind

The badge shows the kind's word, with no glyph and no colour:

- the label falls back to the word when the locale has no key
  (`wui/src/components/KindGlyph.vue:29`, `KindBadge.vue:81`);
- `kindIcon` returns `''` for an unknown kind (`msg-kind.mjs:21-23`).

The old picker lists its six kinds with none checked. Choosing one still
works, because the hub validates each change. Shift+K still opens the menu.
The old search suggestions lack `is:bug`, but the hub accepts the typed
query. Not run: this is read from the code, not tested in a browser.

#### K.4.2 An old hub meets a new kind

A new CLI sends `--kind bug` to a hub without T021. The hub's
`env.Inner()` calls `msg.Validate`, which refuses the envelope with
`bad_json` (`api/internal/hub/ws.go:657-659`), and no row is written.

Not traced in this lane: whether the sending box then moves the envelope to
`rejected/` (`api/internal/hubclient/flush.go:340`) or keeps it pending. That is why the hub ships first (K.6) and the orc
allow-list widens last.

#### K.4.3 An old box meets a new kind

This is the one real hazard. An old box gets a recv frame whose inner kind
is new. It goes like this:

1. `Session.open` calls `Envelope.Inner`, which calls `msg.Validate`
   (`api/internal/hubclient/hubclient.go:1063`, `api/internal/wire/wire.go:1056`).
   The validation fails, and the frame is logged as `recv frame refused`.
2. `commit` cannot parse the inner message either
   (`api/internal/hubclient/commit.go:36`), so it sends no commit.
3. The frame stays unacked, and the hub sends it again on every pass, which
   also never lands.

The fix is the same gate the hub already uses for inner versions. `session.accepts(v)`
(`api/internal/hub/ws.go:82`) keeps a v:2 frame queued for a box whose hello
lacks v:2. T023 adds:

- a hello feature `wire.FeatureKinds13 = "kinds13"`, next to
  `FeatureCommit` / `FeatureLiveAck` (`api/internal/wire/wire.go:115-135`).
  The new client announces it.
- `session.acceptsKind(k)`: true for the old six, and true for any kind when
  the box announced `kinds13`.
- At every site that calls `x.accepts` (`api/internal/hub/commit.go:65`,
  `backfill.go:209`, `fallback.go:88`, `message_move_notice.go:97`, and the
  live push `ws.go:479`, which this list first missed; T023 found it), a frame
  whose inner kind the box cannot read is skipped. It stays queued, the same
  as a v:2 frame for a v:1 box. It is delivered once the box runs the new
  binary (`do_spl_spool_refresh`). Nothing is dropped.

A kind set in the WUI never reaches a box as a new kind. The change is hub
metadata, and the signed envelope keeps its first kind
(`rdb/0060_message_kind_changes.sql:5-11`). Only a CLI send of a new kind
needs the gate.

### K.5 The hub migration

The new migration is forward-only. It takes the number that
`cd csi-spl-orc && DRY_RUN=0 ./run -a do_rdb_migration_next` claims at
build time; the head on `405fe0885` is `0294`. Its name is
`<NNNN>_message_kinds_seven.sql`. Built as `0300_message_kinds_seven.sql`
(T020, SPL-6055). It does the following:

- `ALTER TABLE messages DROP CONSTRAINT IF EXISTS messages_kind_check`, then
  `ADD CONSTRAINT messages_kind_check CHECK (kind IN (<the 13>))`. This
  repeats the `0058` pattern.
- The same for `message_kind_changes_kind_to_check` on
  `message_kind_changes.kind_to` (`0060:34-36`). `kind_from` has no CHECK
  and stays that way: it holds whatever the message had.
- No data change. Existing rows keep their kind. The file applies before the
  image that writes a new kind, as `0060` did.

### K.6 i18n

There is one key per kind, `feed.kind.<kind>`, beside the six at
`wui/i18n/locales/en.json:694-701`, in all 19 locale files
(`i18n-parity.test.mjs`).

- The values below are claude's drafts.
- **agy has the final word.** An agy language review (`/agy-spawn`,
  `LANE_MIX_KIND=i18n`) is the last step before T025 ships, as the fleet
  language rule requires. The WUI does not deploy before it.

| locale | feature | bug | alert | question | idea | decision | docs |
|---|---|---|---|---|---|---|---|
| en | feature | bug | alert | question | idea | decision | docs |
| bg | функция | грешка | тревога | въпрос | идея | решение | документация |
| el | λειτουργία | σφάλμα | ειδοποίηση | ερώτηση | ιδέα | απόφαση | τεκμηρίωση |
| es | funcionalidad | error | alerta | pregunta | idea | decisión | documentación |
| et | funktsioon | viga | häire | küsimus | idee | otsus | dokumentatsioon |
| fi | ominaisuus | vika | hälytys | kysymys | idea | päätös | dokumentaatio |
| he | תכונה | באג | התראה | שאלה | רעיון | החלטה | תיעוד |
| lt | funkcija | klaida | perspėjimas | klausimas | idėja | sprendimas | dokumentacija |
| lv | funkcija | kļūda | trauksme | jautājums | ideja | lēmums | dokumentācija |
| mk | функција | грешка | тревога | прашање | идеја | одлука | документација |
| nl | functie | fout | alarm | vraag | idee | besluit | documentatie |
| pl | funkcja | błąd | alarm | pytanie | pomysł | decyzja | dokumentacja |
| ro | funcționalitate | eroare | alertă | întrebare | idee | decizie | documentație |
| ru | функция | ошибка | тревога | вопрос | идея | решение | документация |
| sk | funkcia | chyba | upozornenie | otázka | nápad | rozhodnutie | dokumentácia |
| sr | функција | грешка | узбуна | питање | идеја | одлука | документација |
| sv | funktion | bugg | larm | fråga | idé | beslut | dokumentation |
| tr | özellik | hata | uyarı | soru | fikir | karar | belgeler |
| uk | функція | помилка | тривога | питання | ідея | рішення | документація |

`idea` is the correct word in es and fi, and it is identical to English, so
`i18n-untranslated.test.mjs` would count it. T025 adds `feed.kind.idea` for
es and fi to `wui/i18n/i18n-keep-english.json`, with that reason. The
baseline is never raised.

### K.7 Build rows

The rows are in dependency order: the hub first (one deploy), then the CLI
on every machine, then the WUI, then the help. Each row lands on master with
its test. Each new gate shows its red control in the commit body: seen RED
on the planted defect, then GREEN (developer guide 2.12.1).

| row | what | depends on | test | red control |
|---|---|---|---|---|
| T020 | Migration `<NNNN>_message_kinds_seven.sql` (K.5) | none | a store test on Postgres (`PRE_PUSH_TIER=full`, the `hub-pg` CI job): insert a message of each of the 13 kinds, and record a kind change to each | the same test before the file applies: the insert of `bug` fails with `messages_kind_check` |
| T021 | (a) `msg.go:50-56`: `validKinds` and `KindList` get the 7. (b) Exception E1 (Q2 B): `human_post_guard.go:75` passes `blocker` or `question`, `:86` lets the agent follow up a topic opened by a `blocker` or `question` DM; the refusal text `:97` and the comments `:18-19`, `store/human_post_guard.go:13` name both | T020 in the same push | (a) `api/internal/msg/msg_test.go:61`, which loops over the 6 today, is widened to loop over all 13; a hub test: `PATCH /v1/messages/{id}/kind {"kind":"bug"}` gives 200 and `{"kind":"bogus"}` gives 400 `bad_kind`. (b) `api/internal/hub/human_post_guard_test.go:51` (`TestHumanPostGuardDMRule`) gains: a `question` DM the person did not start passes, a `note` follow-up in it passes, the same follow-up to another person is refused `dm_not_blocker`; an `alert` and an `idea` DM are refused `dm_not_blocker` like the note | (a) drop `bug` from `validKinds`: the loop and the PATCH test go red. (b) leave `:75` at `m.Kind == "blocker"`: the `question` DM case goes red; leave `:86` at `o.Kind == "blocker"`: the follow-up case goes red |
| T022 | `grammar.go:181-182`: the `is:` enum gets the 7 | T021 | search tests: the `is:` enum holds 14 values (the 13 kinds plus `relay`), `is:bug` parses, and matches a `bug` message in the mock store and on Postgres | drop the `bug` enum entry: `is:bug` is refused as an unknown value |
| T023 | The old-box gate (K.4.3): `FeatureKinds13` in `wire`, the client hello announces it, `session.acceptsKind` at the 4 `accepts` sites | T021 | a hub test: a box whose hello lacks `kinds13` gets no frame for a `bug` message and the row stays unacked; the same box with the feature gets it; a `note` reaches both | remove the `acceptsKind` check: the no-feature box gets the frame and the test goes red |
| — | **Hub deploy** (T020-T023), dev then prd, through the normal push (`20_hub-build-deploy.yml`) | | `ENV=<dev\|prd> ./run -a do_check_deploy_lag` | |
| T024 | The CLI and orc. (a) `do_spl_spool_refresh` on every machine, so every box announces `kinds13`. (b) `SPOOL_KINDS` / `SPOOL_NOTE_KINDS` in `spool-env.inc.sh`. (c) `spool-send.sh:414` and its usage lines, `agent-send.sh:12`, `spool-notify.sh:17` read `SPOOL_KINDS`. (d) `spool-notify-take.inc.sh:23`, `spl-review-go.func.sh:202`, `spl-watchdog.func.sh:1010` and `watchdog/situations/s1.sh:58` read `SPOOL_NOTE_KINDS`. (e) Exception E2 (Q3 B): `spl-agent-handoff.func.sh:266` lists `question` with `blocker` / `msg`. (f) Exception E3 (Q4 B): `DESK_KIND` at `spl-desk-post.func.sh:62` and `spl-desk-reply.func.sh:529` takes today's kinds plus `SPOOL_NOTE_KINDS`, with their `@param` lines (`:35`, `:134`); `spl-fleet-notice.func.sh:27` is not changed. (g) E1's desk text: the `dm_not_blocker` FATAL at `spl-desk-reply.func.sh:297` names `blocker` or `question` | hub deploy on prd; (c) and (f) only after (a) is true on every machine | orc tests: `spool-send.sh --kind bug` passes the check and `--kind bogus` exits 2; a person's `idea` post is auto-taken like a note; a review line in a `docs` message is read; a `bug` from another agent is not a job for `spl_wd_job_after` or `s1_jobs`, while a `msg` still is; `SPOOL_KINDS` equals `msg.KindList`; a `bug` sent to `blocker`-watching code raises no ask (`spool_ask_wanted` gives `''`); (e) `orc/tests/agent-handoff.tst.sh` (beside its `:100` blocker case): an unanswered `question` in the outbox is listed under open questions, an answered one is not, an unanswered `idea` is not; (f) `orc/tests/desk-actions.tst.sh:582` keeps `DESK_KIND=reject` refused for `do_spl_desk_post` and adds `DESK_KIND=bogus` refused, while `DESK_KIND=bug` passes the check for `do_spl_desk_post` and `do_spl_desk_reply`, and `do_spl_fleet_notice` still refuses `DESK_KIND=bug`; (g) `orc/tests/desk-reply-human-guard.tst.sh:66`, which greps the FATAL text, follows the new wording | (1) drop `bug` from `SPOOL_KINDS`: the parity test goes red; (2) leave `spool-notify-take.inc.sh:23` at `task\|note\|msg`: the `idea` take test goes red; (3) leave `spl-watchdog.func.sh:1010` at `.kind == "note"`: the watchdog `bug` test goes red; (4) leave `spl-agent-handoff.func.sh:266` at `("blocker", "msg")`: the `question` handoff test goes red; (5) leave `spl-desk-post.func.sh:62` at its 5 kinds: the `DESK_KIND=bug` desk post test goes red; (6) leave the FATAL at `spl-desk-reply.func.sh:297` naming only `blocker`: the `desk-reply-human-guard.tst.sh:66` grep for the new wording goes red |
| T025 | The WUI. `msg-kind.mjs` (`MSG_KINDS`, `KIND_ICONS`), `kind-picker-keys.ts` (`KIND_KEYS` F U A Q I D O), `uiIcons.ts` (7 glyphs), `src/types/spool.ts:1` (`MsgKind`), `main.css` (7 `.kind-<k>` rules, alert filled), `variables.css` (the tokens of K.2), `search.mjs:60`, 19 locales, `i18n-keep-english.json` | hub deploy on prd; the agy language review before it ships | unit: `msg-kind.test.mjs` (13 kinds, each with a glyph), `kind-picker-keys.test.mjs` (13 unique letters, `U` gives `bug`, `O` gives `docs`), a token test like `calendar-phone-tokens.test.mjs` (`kind-tokens.test.mjs`: each bare glyph `--color-kind-*` is at least 3:1 against `--color-bg-2` in all 8 themes, and the alert's glyph `--color-kind-alert-fg` is at least 3:1 against its fill `--color-kind-alert`, K.2), `i18n-parity`, `i18n-untranslated`; e2e: `kind-picker-keys.test.mjs` (open, press `U`, the badge reads bug), `pnpm run typecheck` | give `docs` the letter `D`: the uniqueness test goes red; set `--color-kind-alert-fg` to `#ffffff` on light: the contrast test goes red (a white `--color-kind-alert` stays green, K.2) |
| T026 | Help and docs. Each is changed in its own home: `csi-spl-doc/doc/help/how-to-post.md` (Qto doc `0d291303-2b30-4b23-8541-cd2ff5863387`: one line on what each kind means, and that all 7 route as a note except K.3's E1-E3; rule 18 says a `question` DM passes like a `blocker` DM, E1) and `csi-spl-doc/doc/help/message-actions-and-formatting.md` (Qto doc `bf244c37-39b0-40c1-9567-b8ec5fd94913`, section 3.5: the kinds table, which today lists 4 of the 6) are edited in Qto, then `cd csi-spl-orc && ./run -a do_spl_doctree_export_md`. The two exports are never edited by hand. `specs/020-spool-message-v2/contracts/message-schema-v2.md:21` (git-native) gets the 13 kinds | T021 for the schema row; T025 for the help (it describes the menu) | the export leaves no diff beyond the change; `./run -a do_check_fleet_rules_drift` | a hand edit of an export: the next export overwrites it, and the diff shows it |
| T027 | Live proof on dev, then prd | T025 deployed | signed in: open the picker, press `U`; the badge is `bug` after a reload; `is:bug` finds the message; one CLI `spool send --kind idea` from a refreshed box arrives in the recipient's inbox | none (a measurement: the build, the tree and n are in the report) |

### K.8 The owner's answers (was: open questions)

All five are answered: owner HUM-10, t1 topic `f4165bc3`, msg
`67193a13-e177-48fd-a8b1-54ad7a410ea7`, on poll `4faee45c`. Verbatim:

> Answer 1: A — No: a yellow badge only, like a note
> Answer 2: B — Yes: a question is let through, as a blocker is
> Answer 3: B — Yes: it is listed next to blockers
> Answer 4: B — Yes: desk posts may set them too
> Answer 5: A — U (bUg) and O (dOcs)

| # | question | A (this spec's default) | B | answered | where the spec has it |
|---|---|---|---|---|---|
| Q1 | Does `alert` page anyone? | a note: a yellow badge only, no ask, no page | it also raises a fleet ask, the way a blocker does (`fleet_ask.go:342` gains `alert`) | **A** | the default: no change; `fleet_ask.go:342` stays `blocker` / `task` / `escalation` (K.3 group 1) |
| Q2 | May an agent DM a person cold with a `question`? | no: refused like a note (`dm_not_blocker`, `human_post_guard.go:75`) | yes: `question` is exempt, as `blocker` is | **B** | K.3 exception E1; built in T021 (b), T024 (g), T026 |
| Q3 | Is an unanswered `question` an open item at a lane handoff? | no: a note (`spl-agent-handoff.func.sh:266` lists only `blocker` / `msg`) | yes: add `question` there | **B** | K.3 exception E2; built in T024 (e) |
| Q4 | May desk posts (`do_spl_desk_post`, `do_spl_desk_reply`) use the 7? | no: only the menu and `spool send` set them | yes: widen `DESK_KIND` (`spl-desk-post.func.sh:62`, `spl-desk-reply.func.sh:529`) | **B** | K.3 exception E3, desk post and desk reply only (`do_spl_fleet_notice` is not named, so it is unchanged); built in T024 (f) |
| Q5 | Picker letters for bug and docs? | `U` (bUg) and `O` (dOcs) | `G` (buG) and `C` (doCs) | **A** | the default: no change; K.2 and T025 already use `U` and `O` |

<!-- version: 0.3.4 · updated: 2026-11-21 · last-edit: 2026-11-21T02:30:00Z -->
