# 107 Hours tracking: suggested, approved, frozen

**Feature ID**: `107-hours-tracking` · **Milestone**: M3 · **Status**: **v2.0-draft** (2026-10-10: the business-needs gaps, sections 14..17, FR-14..FR-37, for the v2 review panel) · v1.2 (v1.0 unanimous consensus: seats s107-1..4 agree with changes, section 12; owner questions Q1..Q7 in section 13; **v1.2: the owner moved the member UI into the calendar**, R8 and R9 in section 0, section 5)
**Created**: 2026-10-07 · **Drafter / folder**: c-522 (seat s107-1) · **Topic**: t1 `ef217164-daaa-43bb-8343-f55ddb2f53a8` · lane dispatch `dispatch-ef217164`
**Authority**: this file for behaviour; [tasks.md](tasks.md) for what is built. Docs only: this spec builds nothing (`../README.md` §2.4). v2 input: [business-needs.md](business-needs.md) (consensus `2c6c36732`) and its seats [bn-agy](reviews/bn-agy.md) · [bn-mistral](reviews/bn-mistral.md) · [bn-claude](reviews/bn-claude.md) · [bn-claude-2](reviews/bn-claude-2.md). Status vocabulary: `../README.md` §2.3; every FR below is **Planned**.

Reviews, unchanged beside this file: [s107-2](reviews/s107-2.md) (`a231ea1e`) · [s107-3](reviews/s107-3.md) (`ec87f9b4`) · [s107-4](reviews/s107-4.md) (`efdbd856`).

Builds on:
- [089 the Calendar section](../089-calendar-section/spec.md), [097 full editing](../097-calendar-full-editing/spec.md), [106 the phone calendar](../106-calendar-phone-rewrite/spec.md): read-only source of meetings (section 7), and since v1.2 **the home of the member's hours UI**: a "Working hours" line on every working day and an entry type "Working hours" in the event dialog (section 5). Their tables and routes do not change.
- [039 issues](../039-spool-issues/spec.md): an issue's discussion is an ordinary topic on `issues.task_id` (section 8).
- [025 tenant RBAC](../025-spool-tenant-rbac/spec.md): roles and permissions; two new permissions (section 6).
- [098 tenant settings jsonb](../098-tenant-settings-jsonb/spec.md): four registered scalar keys for the workspace's hours settings.
- [043 mobile WUI](../043-spool-wui-mobile/spec.md): the phone stack (level 1/2/3, Back).
- [027 performance](../027-spool-performance/spec.md): the 155 KB initial chunk; the hours UI rides the calendar's lazy chunks and no always-on client plugin is added.
- v2 also: [095 Web Push](../095-web-push/spec.md) (the nudge, FR-36), [072 guest rule R1](../072-rapid-deployability/spec.md) (`access_until`, FR-21), [025 section 9](../025-spool-tenant-rbac/spec.md) (several roles per member, FR-20).

Prose says **workspace** (a tenant), **member** (a HUM-* in it) and **biz owner** (a member whose role is `biz_owner`, `internal/rbac/rbac.go`). Agents (roster ids) do not log hours in v1.

---

## 0. The owner's requirements (verbatim, t1 `ef217164`)

| # | msg | text | answered in |
|---|---|---|---|
| R0 | `bcbdbab9` | "discussion for hours tracking ... 4 agents with consensus" | 12 |
| R1 | `89bbeb2e` | "should be light weight" | 3, 11 |
| R2 | `f0071818` | "very userfriendly ..." | 5 |
| R3 | `61ed1fa4` | "the system should fill in the working hours as suggestions based on the time worked in the system" | 1, 2 |
| R3a | `360b2635` | "the devil is in the details - time worked - how to define that ?!" | **1** |
| R4 | `364d912c` | "the hours should be prefilled and the workers should approve them , there should be "freezes" per period - weekly by default , but configurable" | 4 |
| R5 | `30389671` | "it should be somehow integretable with the calendar" | 7 |
| R6 | `9b9080af` | "it should be integrated with the issues as well .." | 8 |
| R7 | `e7197854` | "biz owners should be able to approve the hours and download them in csv , xls etc." | 4.4, 6 |

The owner's design change of 2026-10-08 (HUM-10, t1 `a28dc5c9`, after asking "but how can I as a regular user track my hours , what is the interface for it", msg `7d1d63ff`):

| # | msg | text | answered in |
|---|---|---|---|
| R8 | `57d94c2a` | "it should be integrated with the calendar , just add a new daily entry - hours" | **5** (v1.2) |
| R9 | `37805fdf` | "or as a simple line in the calendar by default for every working day , which clicks will pop - up the dialog fo r the calendar entry of type "workfing hours"" | **5** (v1.2) |
| R10 | `8ab9bf08` | "than each time a user participates in a discussion those discussion links will be shown in the description of the hours ... and he / she would be able to modify additionally for those automatic entries more notes" | **5.2** (v1.2) |
| R11 | `5134bd6b` | "than the right side of the calendar will have tabs for hours" | **5.4** (v1.2) |

R8 and R9 replace the v1.0 rail item and page: there is **no Hours rail entry and no `/hours` page**.

R4 and R7 are requirements, not options: hours are **prefilled** from suggestions, the **worker approves** them, a **freeze** locks a period (**weekly by default, configurable**), the **biz owner approves** them a second time and **downloads** them as CSV and XLSX.

---

## 1. What "time worked" means (R3a, settled first)

### 1.1 The definition

> **Time worked on a day = the member's active minutes in the workspace, joined into blocks, plus the meetings they accepted or created. It is a suggestion until the member approves it.**

1. **An active minute** is a wall-clock minute in which the member did at least one *counted action* (1.2) in this workspace.
2. **A block** joins active minutes whose gap is **at most N minutes** (N = the idle cutoff, `hours.idle_minutes`, default **10**). The bridged gap counts as worked: it is the reading and thinking between two actions.
3. **A gap longer than N ends the block.** Nothing of that gap counts, and the block gets no "idle tail": it ends at the end of its last active minute.
4. **The 3-minute floor**: a block shorter than 3 minutes that contains **no post** (tab minutes only) is dropped; a glance at the phone is not work. A block with a post is never dropped: a reply the hub can prove is work, however short.
5. **Each minute belongs to exactly one target** (1.3). A minute is never counted twice, also not across two tabs or two devices: the minute is the unit, not the device.
6. **Order of the rules**: blocks, then the floor, then the per-target sums, then the "other" fold (1.3). A dropped block is never folded back in.
7. **The result is a suggestion.** Nothing counts until the member approves it (section 4).

Worked example (N = 10): posts at 09:00 and 09:04; reading 09:05..09:20; nothing until 09:45; a tab glance 09:46. Blocks: 09:00..09:21 (21 min, the 09:00..09:04 gap is bridged) and 09:46..09:47 (1 min, tab only, under the floor, dropped). Suggested: 0:21. Had 09:46 been a reply, it would count 0:01.

### 1.2 Counted actions: which signals exist today, and which are reliable

Measured on trunk `aa7523ea` (2026-10-07), checked again by s107-3 and s107-4 on `dae04f97`.

| signal | stored today? | reliable for a past day? | in v1 |
|---|---|---|---|
| **posts and replies** (`messages`: `from_box = box-wui`, `from_id` = HUM-*, `ts`, `task_id`) | yes, but **expires**: `messages.expires_at` (rdb 0001), `ts + RetentionChannels`, default `720h` (`internal/config/config.go:304`; `alerts` 168 h); `Sweep` deletes expired rows | only for 30 days, and less if an operator shortens retention: a `month` period + 2 grace days would lose its first days | **counted, but written into `hours_minutes` when posted** (below) |
| **message edits, reactions** (`edited_at`, rdb 0026; `message_reactions.created_at`, rdb 0037) | yes, and they go with their message | as posts | **counted, written into `hours_minutes`** |
| **issue field edits** (`issues.updated_by/updated_at`, rdb 0047) | only the LAST edit per issue, no history | no | not counted (8, I3) |
| **reading** (`read_marks.updated_at`, rdb 0098) | one row per (member, key), **overwritten** on every sync (`PRIMARY KEY (tenant_id, member_id, mark_key)`) | **no**: the past is gone | replaced by the active-tab minute |
| **online / presence** (`humanOnline`, `internal/hub/channels.go:399`) | **in memory**, per hub instance, never written | **no** | not usable |
| **typing** | no hub signal (`grep -rli typing internal/hub/*.go \| grep -v _test \| wc -l` -> 0) | no | not usable |
| **sign-in / sign-out** (`member_activity`, rdb 0091) | yes, durable | a session, not work | not counted |
| **calendar events** (`calendar_events` + `calendar_guests.response`, rdb 0125/0139) | yes, durable | yes, but it is the *plan*, not the work | **counted as meetings** (1.4) |

(v0.1 cited `internal/store/retention.go` `CommittedRetention` for the 720 h; that is the **deliveries** window, spec 059 S4. The number matched, the source did not: S3-1, S4-1.)

So today the hub can prove *what you wrote*, for 30 days, and nothing of *what you read*. v1 therefore keeps its **own** activity record, `hours_minutes` (3.2), with **two writers**:

- **The hub (post minutes).** When it stores a post, an edit or a reaction from `box-wui` by a member, it upserts that minute into `hours_minutes` (`src = 'post'`, target `t:<task_id>`) in the same transaction: one indexed upsert per write. Suggestions no longer read `messages`, so message retention does not affect hours.
- **The WUI (active-tab minutes).** A minute is recorded when the tab is **visible and focused** (`document.visibilityState === 'visible' && document.hasFocus()`) **and** the member gave input (key, pointer, touch, wheel, scroll) in the last 60 s. A background tab, a tab visible on a second monitor but not focused, a locked phone, a tab left open overnight: **no minute**. The WUI keeps the minutes in a small in-memory buffer and sends them (`src = 'tab'`) every 5 min, on `visibilitychange` to hidden, and on `pagehide` with `fetch(..., {keepalive: true})`; a crash loses at most 5 minutes of a suggestion. (Read-sync pushes every 5 s, `utils/read-sync.mjs:19`; this is its own timer, not a piggyback.)
- **The recorder is a lazy chunk**, started from the feed pages the way read-sync is (`utils/read-sync.mjs` header: "A lazy chunk started from the feed pages"), never in the initial chunk (027).
- **A member can turn tab minutes off**: "Count my reading time" in their settings (a key in the membership settings jsonb, rdb 0078, no DDL), on by default when owner Q1 = A. Off: the WUI sends no tab minutes and that member's suggestions come from posts and meetings only.

Owner question Q1 (section 13) is whether tab minutes exist at all.

### 1.3 Which target a minute goes to

**Precedence for each minute: meeting > post > tab.**

| the minute had | target |
|---|---|
| inside an accepted meeting (1.4) | the meeting `cal:<event_id>` (or its `topic_id`, 1.4) |
| a post, edit or reaction | that message's topic `t:<task_id>` |
| an active-tab minute | what was open: a topic `t:<task_id>`, an issue (= its topic, section 8), a channel `ch:<name>`, a DM `dm:<peer>`; anything else (settings, lists, the calendar page) is `ws` (the workspace) |
| a bridged gap minute | the target of the minute before the gap |

The post-over-tab rule is enforced **at write time**: the hub's upsert overwrites a `tab` row's target (`ON CONFLICT ... DO UPDATE ... WHERE hours_minutes.src = 'tab'`), and a tab write never overwrites a `post` row.

A day's suggestions are **one row per target**, sorted by minutes. Targets under 5 minutes in the day fold into one `ws` row ("other"), so a day is 3..6 rows, not 40.

### 1.4 Meetings (calendar)

A timed (not all-day), `confirmed` calendar event of **kind `other`** in this workspace where the member is the **creator or a guest who answered `yes`** is a meeting. The hub cannot see attendance, only acceptance: a meeting is a suggestion like the rest.
- Meeting minutes are the **union** of the member's meetings' spans; a minute in two overlapping meetings goes to the one that started first. Two overlapping meetings never suggest more than the wall-clock time they cover.
- Active minutes inside a meeting go to the meeting (precedence 1.3), not to a topic.
- An event whose `topic_id` is set suggests against that topic instead of `cal:<event_id>`.
- Not counted: all-day, `cancelled`, a guest answer of `no`, `maybe` or none, and every other kind (`release`, `deploy`, `maintenance`, `freeze`, `agent_task`, `reminder`, rdb 0125 CHECK): a deploy window or a reminder is not a meeting (S2-3, owner Q6).
- Calendar events are durable, so meetings are read from the calendar tables at suggestion time; they are not copied into `hours_minutes`.

### 1.5 Time outside the app

Calls, an editor, a whiteboard: the hub cannot see them and v1 **does not guess**. The member adds them, without a form:
- **Extend** a suggested row by one tap: `+15`.
- **Add** a row (5.3): pick a target, set minutes.
- **Time it** (owner Q7 = B, section 13; T019): a start/stop timer in the app header. Start picks the target (the 5.3 picker); the running time shows in the header and survives a reload. Stop writes the interval once (`POST /v1/me/hours/timer`): the hub splits it at the member's local midnight (1.6) and adds each day's piece to that day's row for the target (an approved entry, else the open suggestion, else 0), approved, all days or none; a frozen day is 409 `period_frozen`, a day above 1440 minutes is refused, a run over 24 hours is refused. The running timer is kept on the device (localStorage, per workspace and member), never on the hub: nobody, the hub included, sees it until it is stopped (1.7).

### 1.6 Day, time zone, rounding

- A **day** is the member's local day. The zone is the member's chosen zone in this workspace (membership settings `time_zone`, rdb 0078) if set, else the zone the WUI sent with its last tab batch, else the workspace's `hours.tz`. Hub-written post minutes use the same order. A block over midnight splits at midnight.
- **Minutes are stored exactly**; the UI shows `h:mm`. No rounding in v1 (a spreadsheet can round the download).

### 1.7 Privacy of raw signals

- **Only `/v1/me/hours*` serves raw minutes and unapproved suggestions, always filtered `member_id = caller`.** No other route reads `hours_minutes`; a test asserts it (the table name appears only in the hours store file and the hub's post-write upsert).
- Nobody else sees them: not a biz owner, not an admin, not `hours.read`. Others see only **approved** entries and period states (section 6).
- `hours_minutes` is tenant-scoped by RLS (FORCE). RLS separates workspaces, not members: the per-member line is the routes above. `operator_scope` exists for the prune sweep only, and no operator route reads the table. Direct database access by an operator is outside the WUI and outside this spec.
- Raw minutes are deleted **when their period freezes** (after any auto-approval, if owner Q2 = B), and in any case after 45 days. Entries and period rows stay.

---

## 2. Suggestions: how a day is prefilled (R3, R4)

1. The hub computes a (member, day)'s suggestions **on read**, from **one** table plus the calendar: `hours_minutes` by its primary key and the member's meetings by the calendar range index. No job, no cache table.
2. **No suggestion is computed for a frozen day, nor for a day in a returned period** (4.3). In a returned period the worker edits, rejects and adds entries only; the period's raw minutes are already pruned.
3. Once the member approves, edits or rejects a row, it is **an entry** (3.2) and replaces the suggestion for that (day, target). Activity later that day shows as a **delta** on the row ("+0:20 since you approved") with its own one-tap accept **✓ +0:20**; an approved number never changes silently.
4. **Prefilled** means a day's "Working hours" dialog (5.2) opens with that day filled; the member never starts from an empty grid.

---

## 3. Data: what is new and why (R1)

### 3.1 Reused

| need | reused |
|---|---|
| meetings | `calendar_events`, `calendar_guests` (read only) |
| issues | `issues.task_id`, key and title (read only) |
| workspace settings | four registered scalar keys in `tenants.settings` (098): `hours.period`, `hours.freeze_grace_days`, `hours.idle_minutes`, `hours.tz` |
| the member's zone, "Count my reading time" | membership settings jsonb (rdb 0078) |
| who sees whose hours | RBAC (rdb 0021, `internal/rbac/rbac.go` `Defaults`): two new permission rows |
| audit of a return | `member_activity`, new kind `hours_returned` (**with a CHECK widening**, see 3.3) |
| names of topics, issues, channels, members | the existing view, issue and roster reads |
| the day totals of the "Working hours" lines | `GET /v1/me/hours?period=` (T006), read by the calendar's lazy chunk (5.1) |

### 3.2 New: three tables, each FORCE RLS

All three in the 0098 shape: `tenant_id` first, `ENABLE` + `FORCE ROW LEVEL SECURITY`, `tenant_scope` with the `NULLIF(current_setting('app.tenant_id', true), '')` guard, `operator_scope`.

**`hours_minutes`**: the only activity record (1.2). Justified: without it reading counts zero and posts vanish after 30 days.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | HUM-* |
| `minute` | timestamptz | `CHECK (minute = date_trunc('minute', minute))` |
| `target` | text | `CHECK (target ~ '^(t\|ch\|dm):.{1,200}$' OR target = 'ws')` |
| `src` | text | `post` or `tab`, CHECK; a post overrides a tab (1.3) |
| `tz` | text | the IANA zone used for this minute's day (1.6) |

PK `(tenant_id, member_id, minute)`: two tabs or devices write the same row. A busy day is ~500 rows per member; pruned at freeze and at 45 days.

**`hours_entries`**: what the worker decided, per row. Justified: approval needs state.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | HUM-* |
| `day` | date | the member's local day |
| `target` | text | 1.3 targets plus `cal:<event_id>`: `CHECK (target ~ '^(t\|ch\|dm\|cal):.{1,200}$' OR target = 'ws')` |
| `minutes` | integer | 0..1440 |
| `suggested_minutes` | integer | what the system proposed (0 for an added row); reports show "edited" |
| `state` | text | `approved` or `rejected` |
| `note` | text | optional, <= 500 |
| `updated_at`, `updated_by` | | |

PK `(tenant_id, member_id, day, target)`, the natural key: no surrogate id, writes are `ON CONFLICT` upserts (S2-4). A day's total is refused above 1440 minutes.

**`hours_periods`**: one row per (member, period). It **is** the freeze, the return and the biz owner's approval; there is no watermark (S4-2, S4-3). Justified: the freeze cannot be a settings key (any `tenant.settings` holder could unfreeze it through the generic 098 route, unaudited), a date watermark cannot remember past period bounds, and the second approval is per member.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | HUM-* |
| `period_start`, `period_end` | date | the bounds in force when the sweep froze it |
| `state` | text | `frozen`, `returned` or `approved` |
| `minutes` | integer | the approved total when frozen or approved (a later change shows as a difference) |
| `note` | text | the biz owner's note; required for `returned` |
| `decided_by`, `decided_at` | | the sweep or the biz owner |

PK `(tenant_id, member_id, period_start)`.

### 3.3 The one migration

One forward-only migration, the next free number, holds:
1. the three tables of 3.2;
2. the two permission rows `hours.read`, `hours.approve`, granted to `biz_owner` (6.1);
3. a widening of `member_activity_kind_check` (0091, last redefined in `0148_session_revocations.sql:30`) that adds `hours_returned`, the 0148 pattern; the auth-row 90-day sweep must not prune it;
4. a widening of `humans_rail_order_check` (0133) with a 12-entry branch that adds `hours`, the 0133 pattern. Since v1.2 (no rail entry) nothing writes that branch; it stays, harmless, as rdb 0151 shipped it (forward-only).

---

## 4. Two approvals and the freeze (R4, R7)

The life of a member's period:

```
 open (no row) ──worker approves rows──► open ──sweep: end+grace──► frozen ──biz owner──► approved (final)
                                                                      │
                                                                      └─ biz owner returns ─► returned
                                                                         (note)                  │ worker fixes, Resubmit
                                                                                                 └──► frozen
```

| `hours_periods.state` | set by | the worker can edit | the biz owner can |
|---|---|---|---|
| (no row) | | yes, unless the period's end + grace has passed (4.2) | see approved rows |
| `frozen` | the sweep | no | approve, return |
| `returned` | the biz owner (note) | yes, then **Resubmit** -> `frozen` | |
| `approved` | the biz owner | no (final) | |

### 4.1 First approval: the worker

- **Approve day** and **Approve week** (the period) approve **closed days only**: days before the member's today. Approving Friday morning must not lock Friday at a partial number.
- **Today** has its own **Approve so far**, a separate tap.
- A **delta** (2.3) has its own **✓ +h:mm**, one tap.
- **Approve week** stays enabled while any closed day of the period has open suggestions or deltas, and shows the count ("Approve week · 2 open").
- **Edit**: change minutes (stepper ±15, or type), change the target, add a note: the row is `approved` with the new number.
- **Reject**: the row becomes `rejected` (counts 0); Undo for 10 s, and changeable until the freeze.

### 4.2 The period and the freeze

| setting (registered 098 key) | kind | default | range |
|---|---|---|---|
| `hours.period` | string | `week` (Mon..Sun) | `week`, `two_weeks`, `month` |
| `hours.freeze_grace_days` | int | `2` (a week freezes Wednesday 00:00) | 0..7 |
| `hours.idle_minutes` | int | `10` | 5..30 |
| `hours.tz` | string | the workspace's zone | IANA |

Set by a holder of `tenant.settings` (biz owner, admin) through the existing tenant settings route.

- **The freeze is exact, whether or not the sweep has run** (S3-10). The write path treats a day as frozen when an `hours_periods` row covers it in state `frozen` or `approved`, **or** when no row covers it and its period's end + grace, in `hours.tz`, has passed. A late or failed sweep cannot leak a write into a closed period.
- **The sweep persists it.** At `period end + grace`, the hub's existing sweep writes an `hours_periods` row `frozen` for **every current human member at sweep time, plus any member with an `hours_entries` or `hours_minutes` row in the period** (a member removed mid-period who logged time). A member with nothing gets a row with 0 minutes: the biz owner signs off a zero, never a missing row. Agents never get a row. Then it prunes the period's `hours_minutes`.
- **Unapproved suggestions at the freeze** count **zero** and disappear (owner Q2: A zero, B auto-approved; under B the sweep writes those entries **before** it prunes).
- **Changing `hours.period`** takes effect from the first day after the member's latest `hours_periods.period_end` (or after the workspace's last frozen period, for a member with no row). A switch week -> month never pulls passed days into a new period.
- **Reminder** (v1.2): each working day's "Working hours" line shows the day's total and marks a day with open suggestions or deltas; the dialog's **banner** says "2 days not approved · freezes Wed 00:00 · [Approve 2 days]". No rail badge and no pop-up in v1 (5.1).
- The calendar's `kind = 'freeze'` (a deploy freeze, rdb 0125) is a different thing; the hours freeze never writes a calendar event.

### 4.3 Return

- **Return** (one member, a required note) sets that member's row to `returned`: it **reopens that period for that member only**. The return marks the worker's "Working hours" lines of that period and the dialog's banner shows the note with [Review] (S2-7); the worker sees the note on top of the period, fixes entries (no suggestions, 2.2) and taps **Resubmit**; the row goes back to `frozen` and into the biz owner's list. A `member_activity` row `hours_returned` records each return.
- **Return all** (Team header, one note) returns every `frozen` member row of the period: the mass correction.
- **No workspace-wide unfreeze and no "freeze now" in v1** (S4-5, S3-10; owner Q4). Return and Return all are the only ways back.

### 4.4 Second approval: the biz owner (R7)

- The biz owner approves **frozen** periods, per member: the Team tab (5.4) lists each member's `frozen` row with its total.
- **Approve** (one tap per member) or **Approve all** (every `frozen` row of the period): the row becomes `approved`, final.
- The biz owner never edits a worker's minutes: approve or return. "The worker approves their hours" stays true.
- Before the freeze the biz owner sees the worker's approved rows (to watch progress) but cannot sign off.

---

## 5. Screens: inside the calendar, phone and desktop (R2, R8, R9)

v1.2 (owner R8, R9): the member's hours live **in the existing calendar**. There is no Hours rail entry and no `/hours` page (the v1.0 design, kept below only where the dialog reuses it).

### 5.1 Where: one "Working hours" line per working day

- **Every working day** (Monday..Friday of the civil date; the day is the member's day in their zone, 1.6) shows, **by default**, one simple line **Working hours** in the calendar: the all-day row of that day in the desktop week (089 / 097 `CalendarMainView`), and the day's list in the phone Day, Week and Month views (106). Saturday and Sunday show the line only when the day has minutes, entries or suggestions.
- The line carries the **day's total** (`h:mm`: approved entries plus open suggestions) when there are minutes, and a mark when the day has open suggestions or deltas (the reminder of 4.2), "Final" / a lock for a frozen day.
- **It is not a calendar event**: no `calendar_events` row, no event route, not in search, reminders, the trash, `/public-calendar` or a calendar export. It is drawn from `GET /v1/me/hours?period=` (T006), one call per period the shown range touches, by the calendar's own lazy chunk.
- **A click (tap) opens the existing calendar entry dialog** (desktop `CalendarEventDialog`, phone `CalendarPhoneSheet`) with the entry type **Working hours** (5.2): the owner's "pop-up the dialog for the calendar entry of type working hours". The type is the dialog's, not the hub's: the event kinds and `calendar_events` do not change, so no hub change is needed for it.
- **No always-on client code** (s107-4's condition): the hours code loads with the calendar chunks (lazy, 027), nothing at app start, no new client plugin. The acceptance test runs the 155 KB budget check (`perf-budget.py`).
- **No rail badge**: the v1.0 `hours_open_days` field (T010) has no consumer under v1.2 and is dropped; the lines and the dialog's banner are the reminder.
- **No pop-up in v1**: the only notification pop-up is the calendar's (`CalendarReminderPopup.vue`, `calendar-reminder-timer.ts`, 089 code). A pop-up with [Approve N days] is a later hook (P1, section 11).

### 5.2 The "Working hours" dialog: Mine (the default tab)

The dialog of type Working hours opens on the clicked day and shows that day's per-target rows; its banner and **Approve week** cover the period (the layout below is the period at a glance; the dialog scrolls to the clicked day).

**Description: the day's discussions, with notes (owner R10).** The dialog's description lists, for the day, **one line per discussion the member took part in** (every row whose target is a topic `t:<task_id>`, recorded by the hub on a post, an edit or a reaction, T005, plus the tab minutes when counted): the topic's subject as a **link** to the topic, its time `h:mm` and its blocks (`09:12-10:40`). Meetings (`cal:`), channels and "other" follow as plain rows. Each line takes a **free-text note** (<= 500 characters):
- **One note per line**, i.e. per (day, target) entry; **no separate per-day note** in v1 (a note for the day as a whole goes on its "other" row).
- **No hub change**: `hours_entries.note` (rdb 0151) and `PUT /v1/me/hours` `entries[].note` (T006) already hold it, and `GET /v1/me/hours` returns it per row. A note typed on an open suggestion is saved with that line's approval (the entry is written `approved` with the suggested minutes and the note); a note on an approved line is an edit of that entry. A frozen day's notes are read-only (409 `period_frozen`).
- The note reaches the biz owner's Team view and the download's `note` column (6.2) once the line is approved, as any entry note does.

```
 Hours                                   Week 41  < >
 ┌───────────────────────────────────────────────────────────┐
 │ 2 days not approved · freezes Wed 00:00   [Approve 2 days]│
 └───────────────────────────────────────────────────────────┘
 Fri 10 Oct (today)  3:05 so far                [Approve so far]
   <PREFIX>-212 Calendar phone rewrite   1:50   +15  ✕
   #<channel>                            1:15   +15  ✕
 Thu 9 Oct     6:40 suggested                    [Approve day]
   <PREFIX>-212 Calendar phone rewrite   2:10   +15  ✕
   Meeting: weekly sync                  1:00   +15  ✕
   other                                 0:55   +15  ✕
 Wed 8 Oct     5:15 ✓ approved   ✓ +0:20
 ...
 Week  31:05 suggested · 18:20 approved     [Approve week · 2 open]
```

- **Common case, desktop**: in the calendar, click a day's **Working hours** line -> **Approve 2 days** in the banner (or **Approve day** / **Approve week**): 2 clicks.
- **Common case, phone**: in the calendar, tap a day's **Working hours** line -> **Approve 2 days**: 2 taps from the calendar view. **Approve week** is the sticky bottom button of the sheet.
- A row's number opens the stepper in place; the row's name opens the "why" sheet (its blocks, `09:12-10:40`, 1.7).
- Frozen days carry a lock and no buttons; an approved period says "Final"; a returned one shows the biz owner's note and **Resubmit**.
- No horizontal scroll on the phone (the 106 rule); controls 44..48 px.

### 5.3 Add a row

`+ Add` in the day's Working hours dialog: a target picker (recent topics, issues, channels first; search) and a minutes stepper (default 0:30). Two taps plus the pick. In-app time is measured; off-app time is added, extended or timed with the header timer (1.5, owner Q7 = B). The picker is one component (`HoursTargetPicker.vue`), shared by `+ Add` and the timer.

### 5.4 The calendar's right side: hours tabs (owner R11)

v1.2: the calendar page gets a **right-side panel with tabs for hours** (desktop, > 820 px: a third column after the year strip and the main view, about 320 px, collapsible from its header; its open / closed state is kept in this browser). The per-day entry stays the day's Working hours line and dialog (5.1, 5.2); the panel holds the period-wide views:

| tab | who | holds | task |
|---|---|---|---|
| **Mine** (default) | every member | the open period's days, newest first: each day's total and state (open mark, approved, frozen lock, Final), the banner "2 days not approved · freezes Wed 00:00 · [Approve 2 days]", **Approve week**, a returned period's note and **Resubmit**; a click on a day opens its Working hours dialog | T011 (read), T013 (approve) |
| **Team** | `hours.read` | the grid below, Approve / Return for `hours.approve` | T015 |
| **Download** | `hours.read` | period picker, CSV / XLSX, Final only (6.2) | T015 on T009 |

A member without `hours.read` sees Mine only (no tab strip). The panel loads with the calendar's lazy chunks; its data is `GET /v1/me/hours` (Mine) and `GET /v1/hours` (Team), fetched when the tab shows.

**Phone (<= 820 px, 390 px):** no third column; the phone calendar's header menu (`calphone-menu`) gains **Hours**, which opens the same tabs as a full-height sheet (the 106 sheet pattern, Back / swipe down closes it): Mine, and Team and Download for `hours.read`. No sideways scroll, controls 44..48 px.

**Team (holders of `hours.read`):** members x days of the period, approved minutes per cell, totals per row and column, a per-target breakdown on tap. Each member row shows its period state (open / frozen / returned / final) and, for a holder of `hours.approve`, **Approve** and **Return**; the header has **Approve all** and **Return all**. Filters: member, target type, issue. **Download** (its own tab): CSV or XLSX (6.2). On the phone, one card per member with total and Approve / Return.

---

## 6. Who sees what, reports, download (R7)

### 6.1 Visibility

| who | sees | can |
|---|---|---|
| the member | own suggestions, raw minutes, entries, period rows | approve, edit, reject, add, resubmit |
| **`hours.read`** (new; default `biz_owner`) | every member's **approved** entries and period states | Team view, download |
| **`hours.approve`** (new; default `biz_owner`) | as `hours.read` | approve or return a frozen period, Approve all, Return all |
| `tenant.settings` (biz owner, admin) | | the four `hours.*` settings |
| everyone else | nothing of others | |

Admins and product owners get neither new permission by default (owner Q5); a biz owner can grant them through the existing role editor. Tenant isolation is RLS with FORCE (3.2); a cross-workspace test is part of the store task, and it asserts that a `hours.read` holder never receives raw minutes or unapproved suggestions (1.7).

### 6.2 Reports and download

- **Periods only** in v1 (the workspace period, or a past one): every report lines up with a freeze and its approvals.
- Grouped by member, target (topic / issue / channel / meeting / other) or day.
- **CSV** and **XLSX**, the same columns, one line per approved entry: `date, member_id, member_name, target_type, target_id, target_name, issue_key, minutes, hours_decimal, suggested_minutes, note, period_state, approved_by, approved_at`.
- **Final only** (biz-owner-approved periods) is the default; it can be switched off to include frozen and open periods.
- XLSX is **one sheet** with the CSV's columns, written by a small `internal/xlsx` package with Go's standard `archive/zip` and `encoding/xml` (`[Content_Types].xml`, `_rels/.rels`, `xl/workbook.xml`, `xl/_rels/workbook.xml.rels`, `xl/worksheets/sheet1.xml`): no new dependency. Minutes and decimal hours are **numeric cells** (`t="n"`), so the spreadsheet sums them.
- Response headers: `Content-Type: text/csv; charset=utf-8` or `application/vnd.openxmlformats-officedocument.spreadsheetml.sheet`; `Content-Disposition: attachment; filename="hours-<tenant>-<period_start>-<period_end>.<ext>"`.
- Rejected rows and open suggestions never appear.

### 6.3 Routes (new; existing auth and `X-Spool-Tenant`)

| route | who | what |
|---|---|---|
| `PUT /v1/me/hours/minutes` | member | the WUI's tab-minute batch (<= 60 rows, one `tz`) |
| `GET /v1/me/hours?period=` | member | days with suggestions, entries, deltas, period state |
| `PUT /v1/me/hours` | member | approve / edit / reject / add / resubmit, a batch; a frozen day is 409 `period_frozen` (4.2) |
| `POST /v1/me/hours/timer` | member | a stopped header timer `{target, start, end}`: split at local midnight, added to each day's row (1.5, owner Q7 = B) |
| `GET /v1/hours?period=&member=&target=` | `hours.read` | approved entries and period rows |
| `GET /v1/hours/export?period=&format=csv\|xlsx&final=` | `hours.read` | the download |
| `PUT /v1/hours/periods` | `hours.approve` | approve or return member periods, a batch (Approve all / Return all) |

Seven routes. Settings go through the existing tenant settings route (098); the calendar's Working hours lines read `GET /v1/me/hours` (5.1, v1.2).

---

## 7. Calendar (R5): v1 and later

**v1** (calendar tables and routes read only):
- Meetings become suggestions (1.4).
- An entry with target `cal:<event_id>` shows the event's title in the Working hours dialog and the download.
- **v1.2 (R8, R9)**: the Working hours line on every working day and the dialog's entry type Working hours (5.1, 5.2). These change the 089 / 097 / 106 **WUI files** that draw the day and the dialog (`CalendarMainView`, `CalendarEventDialog`, `CalendarPhone*`), never their tables or routes. This replaces the later hooks C1 and C2.

**Later** (hooks the calendar would need; later tasks for a calendar lane, `tasks.md` "Later"):
- **C1** an Hours lane in the desktop Day / Week view (089 / 097): approved hours per day, read from `GET /v1/me/hours`.
- **C2** the same lane in the phone Day view (106 `CalendarPhone*`).
- **C3** "Log this" in the event pop-over / peek: one tap approves the meeting's suggestion.
- **C4** the freeze date as a month-view marker (not a calendar event).

---

## 8. Issues (R6): v1 and later

An issue's discussion is a topic on `issues.task_id` (`internal/store/issues.go`: "The discussion is an ordinary topic on the issue's task_id"). So:

**v1** (no issue code change):
- Hours on an issue = hours on its topic: posts in it and tab minutes with the issue open are suggested against it.
- Hours and the download show the issue key and title for a target whose topic is an issue's.
- `+ Add` picks an issue by key or title.
- The Team tab filters by issue.

**Later** (hooks for an issues lane):
- **I1** the issue's right pane shows "Booked 12:30" (approved entries on its topic), from `GET /v1/hours?target=t:<task_id>`.
- **I2** booked hours next to the `level` estimate on the issue list.
- **I3** issue field edits as activity: needs an issue-history table first (`issues` keeps only the last edit).
- **I4** Team filter and grouping by epic (walks issue parents).

---

## 9. Requirements

| id | requirement | status |
|---|---|---|
| FR-01 | Active minutes and blocks (1.1): N from settings; 3-min floor for tab-only blocks; rule order | Planned |
| FR-02 | `hours_minutes` with two writers: hub post/edit/reaction upsert, WUI tab minutes with visible + focus + 60 s input; per-member off switch (1.2) | Planned |
| FR-03 | Precedence meeting > post > tab; meeting union; small targets fold to "other" (1.3, 1.4) | Planned |
| FR-04 | Suggestions on read from one table + calendar; none for frozen or returned days; deltas with one-tap accept (2) | Planned |
| FR-05 | Worker: Approve day / week on closed days, Approve so far, edit, reject, add (4.1, 5.3) | Planned |
| FR-06 | `hours_periods`: freeze exact on write, sweep rows for every member, period change from the next unfrozen day (4.2) | Planned |
| FR-07 | Return / Return all / Resubmit; biz owner Approve / Approve all (4.3, 4.4) | Planned |
| FR-08 | Raw minutes only through `/v1/me/hours*`; pruned at freeze / 45 days (1.7) | Planned |
| FR-09 | `hours.read`, `hours.approve`; Team view; CSV and one-sheet XLSX, periods only (6) | Planned |
| FR-10 | Three tables FORCE RLS; cross-tenant and no-leak test (3.2, 6.1) | Planned |
| FR-11 | v1.2: a Working hours line on every working day in the calendar (desktop week, phone Day / Week / Month) with the day's total; a click opens the event dialog of type Working hours, its description the day's discussions as links with a note each; the calendar's right-side hours tabs Mine / Team / Download (a sheet on the phone); no rail entry, no page, no always-on client code; banner (5.1) | Planned |
| FR-12 | Phone: 2 taps from the calendar view for the common case, no sideways scroll, 44..48 px controls (5.2) | Planned |
| FR-13 | Meetings suggested (7 v1); issues via their topics (8 v1) | Planned |
| FR-14..FR-37 | v2.0-draft: the business-needs gaps, each citing its BN / U id (section 14; map in section 17) | Planned |

**Acceptance** (the live proof task): a seeded member with posts, tab minutes and a meeting on Monday opens the calendar at 390 px and at 1440 px, sees a Working hours line with Monday's total, opens it and sees Monday prefilled with the fixture's rows; approves the closed days in 2 taps from the calendar view; today stays open until **Approve so far**; after the freeze (with and without the sweep having run) the week is read-only and its open suggestions are gone; the biz owner returns it with a note, the member resubmits, the biz owner approves; the biz owner's CSV and XLSX hold exactly the approved lines with `period_state = approved`; a second workspace's biz owner reads none of them; a `hours.read` holder never receives a raw minute; `perf-budget.py` stays under 155 KB.

---

## 10. Phone and desktop

v1.2: the calendar's own two layouts at 820 px. Desktop: the line in the week's all-day row, the Working hours dialog (`CalendarEventDialog`) per day, and the right-side hours panel with Mine / Team / Download (5.4). Phone: the line in the Day / Week / Month lists, the dialog as the phone's entry sheet (`CalendarPhoneSheet`), the hours tabs as a sheet from the calendar menu; the Team grid becomes one card per member.

---

## 11. Not in v1

v2.0-draft takes in, from this list: overtime and the other rate categories as labels (FR-28), leave as absence types without balances (FR-30), holidays (FR-29), the foreman entering a crew member's minutes before the freeze (FR-23), and a push nudge (FR-36). **Money stays out of hours tracking** (FR-19): rates live in a separate accounting view, seen only by the time-accountant role (FR-20).

- **Money**: rates, invoices, overtime, leave and holidays.
- **Agents' hours** (roster ids), box or agent runtime as cost.
- The biz owner editing a worker's minutes (approve or return only).
- **Workspace-wide unfreeze** and **freeze now** (owner Q4 = B).
- A per-member idle cutoff (owner Q3 = A).
- **P1** a reminder pop-up with [Approve N days]; e-mail reminders.
- XLSX totals row and totals sheet; rounding in the export; free from..to ranges; ODS, PDF or other formats.
- Cross-workspace totals for a member in several workspaces.
- Calendar hooks C3, C4 (C1 and C2 are replaced by the v1.2 Working hours line, 7), issue hooks I1..I4.
- A rail entry or a page for hours (v1.0 design, replaced by R8, R9).
- Activity outside the hub's write path and the WUI tab (the `spool` CLI, git, an editor).
- Editing raw minutes (the member edits entries, not signals).

---

## 12. Panel and consensus (R0)

| seat | agent | harness | review | verdict |
|---|---|---|---|---|
| s107-1 | c-522 | claude | drafter and folder | |
| s107-2 | a-530 | agy | [reviews/s107-2.md](reviews/s107-2.md) `a231ea1e` | agree with changes (S2-1..S2-8) |
| s107-3 | c-523 | claude | [reviews/s107-3.md](reviews/s107-3.md) `ec87f9b4` | agree with changes (S3-1..S3-12) |
| s107-4 | c-524 | claude | [reviews/s107-4.md](reviews/s107-4.md) `efdbd856` | agree with changes (S4-1..S4-7) |

### 12.1 Agreed (all seats)

- Time worked = active blocks with an idle cutoff, N = 10, nothing counts until approved (section 1).
- One new signal, the active-tab minute; reading leaves no history today (`read_marks` overwritten, presence in memory).
- Three tables, none droppable; the third (`hours_periods`) replaces the watermark.
- Rail item + one page is the smallest UI.
- Owner questions: Q1 A, Q2 A, Q3 A, **Q4 B** (changed from A in v0.1), Q5 A, Q6 A, Q7 A.

### 12.2 What v1.0 changed from v0.1

| change | from | where |
|---|---|---|
| Post/edit/reaction minutes written by the hub into `hours_minutes` (`src` column), suggestions read one table; retention citation fixed | S3-1, S4-1 | 1.2, 1.3, 2, 3.2 |
| No watermark: four registered scalar settings + `hours_periods` (frozen / returned / approved) | S4-2, S4-3 | 3.2, 4 |
| Freeze computed on write, the sweep only persists it | S3-10 | 4.2 |
| Sweep rows for every current human member + anyone with rows in the period; agents never | S3 + S4 (settled on the spool) | 4.2 |
| `hours.period` change starts after the member's latest frozen period | S3 (settled on the spool) | 4.2 |
| No unfreeze, no freeze now; Return all added | S3-10, S4-5 | 4.3, 11, 13 |
| Approve day / week = closed days; Approve so far; one-tap delta | S3-3 | 2, 4.1, 5.2 |
| No suggestions for frozen or returned days | S3-2 | 2 |
| Precedence meeting > post > tab; meeting union; "attended" -> "accepted" | S3-4 | 1.1, 1.3, 1.4 |
| Tab minute: `hasFocus()`, own 5-min flush, `pagehide` keepalive | S3-5 | 1.2 |
| Per-member "Count my reading time" off switch | S4-6 | 1.2 |
| Privacy stated as route-enforced; no-leak test | S3-12, S4-6 | 1.7, 6.1 |
| 3-min floor for tab-only blocks; floor before the fold | S3-11, S4 (answer 2) | 1.1 |
| No pop-up (089 code): badge from the existing view + banner with [Approve N days]; no always-on client code; perf budget in acceptance | S3-6, S4-7 (settled on the spool) | 4.2, 5.1 |
| Migration widens the rail-order and `member_activity` kind CHECKs | S3-7, S3-8, S4-4 | 3.3 |
| Export cut to CSV + one-sheet XLSX, periods only; epic filter later | S3-9 | 6.2, 8, 11 |
| XLSX headers, numeric cells, `internal/xlsx` | S2-8 | 6.2 |
| Meetings = calendar kind `other` only | S2-3 | 1.4 |
| `hours_entries` natural PK, no `entry_id` | S2-4 | 3.2 |
| CHECKs on `minute` and `target` | S2-6 | 3.2 |
| Blocks with a post count at real length (no 3-min credit) | S2-2 (settled on the spool) | 1.1 |
| A returned period counts in the badge, the banner shows the note | S2-7 (settled on the spool) | 4.3, 5.1 |
| Nothing reads `messages`, `message_revisions` or `message_reactions` at suggestion time | S2-1 (settled on the spool) | 1.2, 2 |

### 12.3 Disagreements and how they were settled

Settled seat to seat on `dispatch-ef217164`, no override:
- **Pop-up (S4-7) vs badge (S3-6)**: s107-4 agreed to the badge + banner, on the condition that the badge adds no always-on client code (5.1).
- **Watermark (S3-10) vs period rows (S4-3)**: s107-3 agreed to `hours_periods` with its own on-write rule kept; "freeze now" dropped by both.
- **Which members get a period row**: s107-3 "every member", s107-4 "only members with something"; both agreed to "every current human member at sweep time, plus any member with rows in the period".
- **s107-2 on v0.1 vs the s107-3/4 folds** (a-530 agreed to all five): no reads of `messages` (S2-1 folded into S3-1/S4-1); post blocks at real length, no 3-min credit (S2-2); return notice by badge + banner, pop-up later (S2-7); `hours_periods` instead of the watermark; Q4 = B.

**Result: unanimous, 4 of 4 seats.**

---

## 13. Questions for the owner (A/B, the panel's recommendation first)

The build starts on the recommendations (owner rule 10-05); each answer changes one task, named here.

| # | question | A | B | panel | changes |
|---|---|---|---|---|---|
| Q1 | Count reading time (the active-tab minute)? | yes, on by default; each member can turn it off | no; suggestions from posts and meetings only (numbers come out low) | **A** | T012 (dropped under B), T016 toggle |
| Q2 | Suggestions the worker did not approve by the freeze | count zero ("nothing counts until accepted") | auto-approved by the sweep | **A** | T007 |
| Q3 | Idle cutoff N | one value per workspace (default 10 min) | each member sets their own | **A** | T004, T016 |
| Q4 | A workspace-wide unfreeze | yes, audited | **none in v1**; Return / Return all per member | **B** | none under B |
| Q5 | Who sees and approves team hours by default | biz owner only, grantable to other roles | biz owner and admin | **A** | T002 |
| Q6 | Which calendar events are suggested as meetings | kind `other` only (no deploy, maintenance, freeze, reminder, release, agent task) | every timed, accepted event of any kind | **A** | T006 |
| Q7 | Time outside the app | `+15` on a row and `+ Add` (no timer) | a start/stop timer in the app header | **A** | T019 (owner: **B**) |

### 13.1 The owner's answers

HUM-10, msg `54eda621` (2026-10-08): "accept the suggestions from the panel , except - q2 b and q7 b".

- **Q7 = B**: a start/stop timer in the app header, built as T019 (1.5, 5.3; `POST /v1/me/hours/timer`).

### 13.2 The owner's design change (v1.2)

HUM-10, t1 `a28dc5c9`, 2026-10-08, msgs `57d94c2a`, `37805fdf`, `8ab9bf08` and `5134bd6b` (R8..R11, verbatim in section 0): the member UI moves into the calendar, the dialog's description lists the day's discussions with a note each, and the calendar's right side carries the hours tabs. What it changes:

| v1.0 | v1.2 | tasks |
|---|---|---|
| Hours rail item (12th entry), `/hours` page | a Working hours line on every working day in the calendar; a click opens the event dialog of type Working hours | T011 rewritten |
| rail badge `hours_open_days` on the rail's view | dropped: no consumer; the line shows the day's total and open mark from `GET /v1/me/hours` | T010 dropped |
| Mine tab of the page (cards, approve, stepper, add, why) | the same controls inside the Working hours dialog | T013, T014 |
| a row's note (edit only) | the description lists the day's discussions as links with their time, each with a note (R10); no hub change | T011 (links), T014 (notes) |
| Mine / Team tabs of the page, Download button | the calendar's right-side hours panel (R11): Mine, Team (`hours.read`), Download (`hours.read`); on a phone a sheet from the calendar menu | T011 (panel + Mine read), T013, T015 |
| "no 089 / 097 / 106 file changes" | their WUI files that draw the day and the dialog change; their tables and routes do not | rules in `tasks.md` |

The panel's v1.0 consensus ("rail item + one page is the smallest UI", 12.1) is superseded on this one point by the owner; every other section stands.

---

## 14. v2: the business-needs gaps (v2.0-draft)

Source: [business-needs.md](business-needs.md) section 6 (consensus at `2c6c36732`, four seats in `reviews/bn-*.md`, owner answers Q1 = A, Q2 = A, Q3 = A). Section 6.6 lists what v1.2 lacks; every requirement below fills one of those gaps and cites its BN or U id. The section 6.6 to requirement map is section 17.

**What stays.** Sections 1..13 still hold, unless a v2 requirement names the v1 rule it changes. v1's activity engine (sections 1, 2) remains the prefill for a member with in-app activity. v2 adds a second prefill source for the site worker (Persona 1), who has almost no in-app activity: the shift plan and the standard day (business-needs 6.2).

**Two rules, scored per requirement.** Rule 1 (site worker): the normal week approved on a phone in <= 3 taps, prefilled, big targets, offline. Rule 2 (IT person): a standing standard day, split automatically, zero typing. Both from business-needs section 1.

### 14.0 Owner input carried into v2 (verbatim)

| # | msg | text | requirement |
|---|---|---|---|
| O1 | `e5ed523c` | "No I meant that in some countries the standard working day is 7.5h in some other 8h" | FR-14 |
| O2 | `28636f76` | "and this might vary both by organisation and even for different people" | FR-14 |
| O3 | `d2c8d7e9` | "some people are hired to work only half day" | FR-14 |
| O4 | `5105fdf7` | "the hourly rate will be configured elsewhere ... in sone accounting view" | FR-19 |
| O5 | `b42c0301` | "and only a separate role is concerned with the calculation of the hourly rates times the worked hours ..." | FR-20 |
| O6 | `4f8e6c54` | "let's call it time-accountant , but this role MIGHT be assigned to the let's say the foreman human , aka he could have the same 2 roles at the same time" | FR-20 |
| O7 | `21187c98` | "or it might be a role which is assignd to some accounant in the organisation or even to an accountant outside of the organisation" | FR-21 |
| O8 | `3a121342` | hours are per workspace (owner confirmation) | FR-37 |

O5 is corrected by O6: visibility is per **role**, not per person. Roles combine.

### 14.1 Per workspace (owner `3a121342`)

| id | requirement | cites |
|---|---|---|
| **FR-37** | Hours are **per workspace**. Every v2 object (standard day, plan, jobs, crews, holidays, terminals, the change log) belongs to one workspace, under the same FORCE RLS as section 3.2. Tracking time for one person across several workspaces of the same hub (double counting, a limit across workspaces, different standard days per workspace, a person-only view of all of them) is **out of scope here**: it is its own new spec (t1 `cee5a73e`, owner msgs `de2cdf88`, `690c4ad1`, `0c3b1bf7`), written separately. | owner `3a121342` |

### 14.2 The standard day and the prefill chain (BN-14, Q3 = A, BN-8, BN-1)

| id | requirement | cites |
|---|---|---|
| **FR-14** | **Standard day, per organisation and per person.** A workspace (= the organisation) has a standard day in minutes: a new registered 098 key `hours.standard_day_minutes` (int, default `480` = 8 h, range `0..1440`; e.g. `450` = 7.5 h), set by a holder of `tenant.settings`. A person may have an **override** (e.g. `240` for a half-day contract), set by their foreman from the list of their crew (FR-22) or by a holder of workspace-wide `hours.approve`. **Resolution: the person's value wins, else the organisation's.** Each value has the date it takes effect; a change never rewrites an approved or frozen day. The prefill (FR-17), an absence day (FR-30), the Standard Day (FR-15) and every full-day check (FR-26 break rule, FR-28 overtime base, the "full day" mark) use **the person's resolved standard day**. It is hours per day, never an hourly rate (business-needs 6.1). | BN-14, O1, O2, O3 |
| **FR-15** | **The Standard Day (Q3 = A).** A per-member switch "Standard Day", on by default (the workspace may turn the default off with `hours.standard_day_default`, bool, default `true`); the member, their foreman or the office can turn it off for that person. On, a closed working day that has no absence and no plan row is suggested at the person's standard day: the day's tracked activity (sections 1, 2) is **scaled proportionally** across its targets to reach the standard day (largest remainder to whole minutes); with no activity, one row of the standard day goes to the member's default target (the last planned job, else `ws`). A day whose activity already exceeds the standard day keeps its real minutes (the excess is visible, it feeds FR-28 overtime), it is never cut. Rule 2 pass: zero typing, and under owner Q2 = B (13.1) an open suggestion is approved by the sweep at the freeze. | Q3 = A, BN-1, BN-2 |
| **FR-16** | **The shift plan.** Per (member, day) the plan holds the job (FR-18) and the shift's start and end time; a day may hold up to two rows (two jobs, U3, section 15). Editable by the member's foreman (FR-22) and the office (workspace-wide `hours.approve`). **Repeated from last week by default**: a day with no plan row reads the member's most recent plan row for the same weekday within the last 28 days, at read time (no copy job); the foreman's "Copy last week" writes the rows when the week must be fixed. It is the planned work, not a calendar event: no `calendar_events` row (as 5.1). | BN-8 |
| **FR-17** | **The prefill chain**, per (member, day), first match wins: (1) an absence or holiday row (FR-29, FR-30) for its minutes; (2) a foreman-entered row (FR-23); (3) the plan (FR-16): the shift's net minutes (start..end minus the break, FR-26) to the planned job; (4) the Standard Day (FR-15); (5) v1 activity suggestions only (sections 1, 2), when the Standard Day is off. Clock exceptions (FR-24) change the start or end of whatever (2)..(4) produced. Like v1 (2.1), plan and Standard Day suggestions are computed on read; nothing is stored until approved. Rule 1 pass: the week opens prefilled, the worker confirms. | BN-1, BN-8, BN-14, Q3 = A |

### 14.3 Jobs and the quote (BN-2, BN-15)

| id | requirement | cites |
|---|---|---|
| **FR-18** | **Job, a new target.** A job (`job:<job_id>`) has a name, a site (free text, e.g. an address), an optional linked topic, a **quote in hours** (`quote_minutes`) and a state (`open`, `closed`). Created and closed by the office (workspace-wide `hours.approve`). The target CHECKs of `hours_entries` (3.2) widen to `job:`. A site worker's day defaults to their planned job (FR-17); an office member's to tracked activity; the worker changes it only on a day that differed. A post in the job's linked topic is suggested against the job, not the topic. A closed job is no longer offered in pickers; its rows stay. | BN-2, BN-15 |
| **FR-19** | **No money in hours tracking (owner `5105fdf7`).** Hours tracking has **no rate editor and no rate field**. A person's rate lives in a future **accounting view**, a separate spec (not written; a dependency of 107 v2, out of its scope). Hours tracking only **reads** a rate from it to compare a job's labour cost (approved hours x the person's rate on that day) with the job's quote; a quote in money, if any, lives there too. Until the accounting view exists, a job compares approved hours with `quote_minutes` only. | BN-15, BN-10, O4 |

### 14.4 Roles: the time-accountant, the external accountant (owner O5..O7)

| id | requirement | cites |
|---|---|---|
| **FR-20** | **The time-accountant role.** A new system role `time_accountant` holds `hours.read` and a new permission **`hours.rates`** ("see rates and labour cost; compute approved hours x rate"). **Only holders of the time-accountant role see rates, whatever other roles they hold**: every rate, money amount, labour cost and the BN-15 cost-against-quote comparison is served only to `hours.rates`, by route (as 1.7). Workers, foremen and approvers without that role see hours, never money. `hours.rates` is in no other default role, the biz owner's included; a biz owner who needs it assigns the role to themself. **Roles combine**: one person may hold, e.g., a foreman's crew leadership (FR-22) and the time-accountant role at once. This needs **several roles per member** (025 section 9, phase 2: `tenant_member_roles`, the authorizer takes the union): a dependency of 107 v2. | BN-15, O5, O6 |
| **FR-21** | **The external accountant seat.** A time-accountant may be a foreman (combined roles), an internal accountant, or an **accountant outside the organisation**. The external seat: **invite**: a holder of `members.invite` invites an e-mail with the role `time_accountant` as the membership's **only** role, with an optional end date (`access_until`, the 072 guest rule R1: scoped, revocable, expiring); **visibility**: hours and rates only (`hours.read`, `hours.rates`): the Team and Download tabs and the job cost view, member names as they appear on hours rows; **no** `topics.read` (no WUI socket, no topics, channels, docs, files, roster or calendar beyond the hours panel), none of the four permissions every member role holds today (`rbac.go` `withMember`); the WUI opens an hours-only shell. The seat gets no period row (the sweep, 4.2, skips a membership whose only role is `time_accountant`, as it skips agents). **Removal**: a holder of `members.invite` removes the seat, or `access_until` passes; access ends at once; the downloads it made stay in the change log (FR-33). Whether the seat is billed is the billing spec's call, not 107's. | O7, BN-15 |

### 14.5 Crews and the foreman (BN-6, BN-14, BN-5)

| id | requirement | cites |
|---|---|---|
| **FR-22** | **`hours.approve` scoped to a crew.** A crew is a named set of members with one or more foremen. A worker is a member of at most one crew at a time; a foreman may lead several crews. Crews and their foremen are set by the office (workspace-wide `hours.approve`). **Leading a crew is the scope**: a foreman has, **for the members of the crews they lead only**, the hours rights of v1 `hours.read` and `hours.approve` (see approved hours, Approve, Return) plus the v2 crew rights: plan (FR-16), enter and fix (FR-23), set the person's standard day (FR-14), set worker type (FR-31). A role grant of `hours.approve` (the office, the biz owner) stays **workspace-wide** and sees every crew. **Approve crew**: one tap approves every frozen period of the foreman's crews (as 4.4 Approve all, crew-scoped), on a phone. A correction after approval needs a reason and is logged with its author (FR-33). | BN-6, BN-14 |
| **FR-23** | **Foreman entry with Dispute (Q1 = A).** Before the freeze, a foreman enters or fixes a day for any member of their crew, including members without a login (FR-25). Each such row records its author (`entered_by`) and lands in the worker's week as **proposed** (prefilled, step (2) of FR-17). The worker's Approve week covers it (0 extra taps). **Dispute** (one tap, plus an optional note) marks it **disputed** and puts it in the foreman's list; the foreman fixes it (proposed again) or keeps it with a note. At the freeze a still-disputed row freezes as disputed and is shown to the approver, who approves (the foreman's value) or returns (4.3). A foreman's fix of a row the worker had approved returns it to proposed. After the freeze nobody edits minutes; Return (4.3) is the way back. This changes 4.4's "the biz owner never edits a worker's minutes" for the foreman, before the freeze, for their crew. | BN-5, Q1 = A |

### 14.6 Clock exceptions and the shared terminal (BN-1, U2)

| id | requirement | cites |
|---|---|---|
| **FR-24** | **Clock in and out is an exception.** The normal day is confirmed, not clocked (FR-17). **Clock in** / **Clock out** (one tap each, on the phone in the day's Working hours dialog, or on a terminal, FR-25) records a time that replaces the day's start or end: a late start, an early leave, extra hours, or a day with no plan. The clock time is the server's time, or the device's time marked `offline` (FR-35). A foreman may set a crew member's clock time (FR-23 rules). | BN-1 |
| **FR-25** | **Shared terminal identity.** An admin (`tenant.settings`) registers a device as a **terminal** of the workspace: a terminal token, revocable, holding no member's rights. A worker identifies on it with a **badge** (a scanned code) or a **PIN** (4..6 digits, stored hashed, 5 wrong tries lock that PIN for 15 min). The terminal shows the worker's name, Clock in / Clock out and today's hours, and nothing else; the worker's session ends after the action or after 30 s. **A worker without an e-mail or a smartphone** (U2): the foreman or the office creates the member with a name and no e-mail login, and sets the PIN or badge; that member clocks on a terminal or is logged by the foreman (FR-23). Creating a member with no e-mail login is a dependency on the membership code (today a member signs in by e-mail). | BN-1, U2, BN-11 |

### 14.7 Breaks, travel, waiting (BN-3)

| id | requirement | cites |
|---|---|---|
| **FR-26** | **The break rule.** Registered 098 keys `hours.break_after_minutes` (default `360`) and `hours.break_minutes` (default `30`): a day whose start..end span exceeds the threshold has the break deducted, unless the worker or foreman marks **No break** on that day (one tap). It applies to days with start and end times (plan, clock); the standard day (FR-14) is already net. A person whose standard day is under the threshold (a half day) never gets the deduction from the prefill. | BN-3 |
| **FR-27** | **Travel and waiting rows.** An entry gets a **kind**: `work` (default), `travel`, `wait`, `absence`. **+ Travel** and **+ Waiting** in the day's dialog add one row each (one tap), with a default length (`hours.travel_default_minutes`, `hours.wait_default_minutes`, default `30`) and an optional reason (e.g. a weather delay, bn-agy). Travel between two planned jobs on one day (U3) is prefilled from the plan. Only on days it happened; the normal day has none. | BN-3, U3 |

### 14.8 Rate categories and the holiday calendar (BN-4, U5)

| id | requirement | cites |
|---|---|---|
| **FR-28** | **Derived rate categories.** Every approved minute with a time of day gets its categories **derived, never chosen by the worker**: `evening` and `night` from workspace windows (`hours.evening_window` default `18:00-22:00`, `hours.night_window` default `22:00-06:00`), `weekend` (Saturday, Sunday), `holiday` (FR-29), else `normal`; one of these per minute, precedence holiday > night > weekend > evening > normal. **Overtime** is a separate flag: minutes past the weekly threshold (`hours.overtime_weekly_minutes`, default 5 x the person's standard day). Minutes without times (v1 activity rows) take the day's start from `hours.day_start` (default `08:00`). A category is a label on hours: it carries **no money** (FR-19, FR-20). | BN-4, BN-12 |
| **FR-29** | **The public-holiday calendar.** Per workspace, with an optional **region** per member (membership setting): a list of (region, date, name), kept by the office, entered by hand or imported from a CSV or iCal file. A holiday on a working day prefills an absence row of kind `holiday` at the person's standard day (FR-17 step 1); work done on it is category `holiday` (FR-28). It is drawn in the calendar like the Working hours line (5.1), not as a calendar event. | U5, BN-4 |

### 14.9 Absences and the worker type (BN-7, BN-11)

| id | requirement | cites |
|---|---|---|
| **FR-30** | **Absence types (Q2 = A).** A row of kind `absence` with a type from a fixed list: `sick`, `vacation`, `unpaid`, `training`, `holiday`. Whole day = the person's standard day (FR-14; 4 h for a half-day contract), or part day in minutes. Picked from the day in 2 taps (**Absent** -> type), or entered once as a **date range** by the worker, their foreman or the office. An absence beats the plan and the Standard Day (FR-17 step 1). **No balances in v2**; the worker sees the days taken this year per type (U6, section 15). | BN-7, Q2 = A |
| **FR-31** | **Worker type.** A member is typed `employee` (default), `agency` (with the agency's name) or `subcontractor` (with the company's name), in the membership settings jsonb (no DDL), set by the office or the member's foreman. Members without a login are logged by their foreman (FR-23, FR-25). Reports and the download split by type; subcontractor hours roll up per company for invoice checking and stay **out of the payroll export** (BN-9, section 15). | BN-11 |

### 14.10 Start and end times, the change log, retention (BN-12)

| id | requirement | cites |
|---|---|---|
| **FR-32** | **The day record.** Per (member, day) the hub keeps **start, end, break minutes**, the standard day in force and the source (`plan`, `standard`, `clock`, `foreman`, `self`). Start and end are prefilled from the plan, else from `hours.day_start` + the standard day + the break; **never typed** in the normal case (clock exceptions, FR-24, change them). | BN-12 |
| **FR-33** | **Every change is logged.** Each write to an entry, a day record or a period row (and each rate-bearing download, FR-21) writes one change-log row: who, when, before, after, and why. A reason is **required** for a change after approval (BN-6). The log is append-only for every route. | BN-12, BN-6 |
| **FR-34** | **Retention.** A registered 098 key `hours.retention_years` (int, default `5`, range `1..30`), set by `tenant.settings`: the law varies by country, so the workspace sets it. Day records, entries, period rows and the change log are kept that long after their period ends, then deleted by the sweep. (v1's 1.7 pruning of raw minutes at the freeze is unchanged.) **The inspector's export**: read-only, per worker and period, CSV and XLSX (6.2's writer), holding start, end, breaks, minutes per day and every change; served to `hours.read` (workspace-wide). | BN-12 |

### 14.11 Offline, and the nudge (BN-13, U1)

| id | requirement | cites |
|---|---|---|
| **FR-35** | **Offline approval, minimum scope.** Without a network: the week view, **Approve week**, an absence pick (FR-30) and a clock exception (FR-24). The hours lazy chunk and the open period's data are cached on the device; writes are queued with an operation id (idempotent on replay) and the device time, and sync on reconnect. **On sync a frozen period wins**: the write is refused (409 `period_frozen`) and the worker sees why. A foreman edit made meanwhile shows both values and asks the worker once. Nothing of this enters the initial chunk (027). | BN-13 |
| **FR-36** | **The approve nudge.** One phone notification through Web Push (095): "Your week: 40:00 at Site A · [Approve]". Sent on the period's last working day at 14:00 local, and again the day before the freeze if days are still open; never for a fully approved period; quiet hours as 095 section 6.6; a per-member off switch. Tapping it opens the Working hours dialog on its banner (tap 1); **Approve week** (tap 2). A foreman gets "Crew week ready · [Approve crew]" after the freeze. Rule 1 pass: 2 taps from the lock screen. This replaces 11's "no pop-up in v1" for v2. | U1, BN-6 |

### 14.12 What v2 adds to the data and routes (sketch, for the tasks round)

Not the tasks: the tasks round sizes them. New tables, each in the 3.2 shape (tenant first, FORCE RLS, `tenant_scope`, `operator_scope`): `hours_standard_days` (member overrides with their effective date, FR-14), `hours_plan` (FR-16), `hours_jobs` (FR-18), `hours_crews` and `hours_crew_members` (FR-22), `hours_days` (FR-32), `hours_changes` (FR-33), `hours_holidays` (FR-29), `hours_terminals` (FR-25). `hours_entries` gains `kind`, `absence_type`, `entered_by`, `reason`, and states `proposed`, `disputed`; its target CHECK widens to `job:`. New registered keys: `hours.standard_day_minutes`, `hours.standard_day_default`, `hours.day_start`, `hours.break_after_minutes`, `hours.break_minutes`, `hours.travel_default_minutes`, `hours.wait_default_minutes`, `hours.evening_window`, `hours.night_window`, `hours.overtime_weekly_minutes`, `hours.retention_years`. New permission `hours.rates`, new role `time_accountant`. Routes grow under `/v1/hours/*` (plan, jobs, crews, standard days, holidays, inspector export) and `/v1/me/hours*` (dispute, clock, absence range); a terminal route takes a terminal token, never a member session.

**Dependencies outside 107**: the accounting view (FR-19, a separate spec, not written); several roles per member (025 section 9, FR-20); a member with no e-mail login (FR-25); cross-workspace tracking (FR-37, its own new spec).

---

## 15. v2 candidates, ranked

Business-needs 6.6 leaves these for the round to rank. Ranked by Rule 1 value against cost; the panel may reorder.

| rank | item | recommendation | why |
|---|---|---|---|
| 1 | **U3** two sites in one day | **in v2**: up to two plan rows per day (FR-16), **Split** in one tap, travel between them prefilled (FR-27) | Rule 1; common on sites; cheap once the plan exists |
| 2 | **BN-9** payroll column map | **in v2**: the download carries FR-28 categories, FR-30 absence types and FR-31 worker type as columns; a per-workspace column map (rename, order, drop) sets the payroll file's layout; subcontractor hours left out; no payroll API | the export is useless to payroll without the categories |
| 3 | **U6** the worker sees their own numbers | **in v2**: hours this week and month, overtime, absence days per type this year, in the Mine tab (5.4) | Rule 1 trust in prefilled hours; read only |
| 4 | **U7** the worker's language | **in v2**: the phone hours UI uses the member's language, icons with short labels; every translation gets the agy language review before it ships (fleet language rule) | Rule 1 for mixed-language crews |
| 5 | **U9** working-time limit warnings | **v2.1**: warn the foreman and the office before a day or week passes the maximum or the minimum rest, from FR-32 start and end | legal risk; cheap after FR-32 |
| 6 | **U8** a correction after the payroll export | **v2.1**: an adjustment row with a reason in the next open period; a paid period is never rewritten | needed once exports feed payroll |
| 7 | **U10** who is on site now | **later**: a read view over the plan plus clock exceptions | useful, not Rule 1 |
| 8 | **U4** allowances and expenses | **out**: its own spec (money, receipts); it belongs next to the accounting view | a separate data domain |
| 9 | **U12** equipment and machine hours | **out**: job costing, not people's hours | one seat; not hours tracking |
| - | **U11** a leaver's final pay | **open owner question** (section 16) | the owner decides |

---

## 16. v2 open owner question

The build of FR-14..FR-37 does not wait on it; it changes one later task.

**Q8: a leaver's final pay (U11).** A member leaving mid-period needs their hours closed early for the final payslip. v1 has no "freeze now" (owner Q4 = B, 4.3).

- **A. Close now, per member.** A holder of `hours.approve` (or the member's foreman) closes one member's open period at a chosen last day; the period row ends that day, audited (FR-33). A manual early freeze for one member only.
- **B. No early close.** The leaver's last period freezes on the normal schedule (period end + grace); the final payslip waits up to one period.
- **C. Close on the leave date.** The office sets the member's leave date (the membership's `access_until`, 072 A27); the sweep freezes that member's period at the leave date + grace, by itself. No new button.
- **Recommendation: C.** It reuses the existing expiry date, keeps Q4 = B's "no manual freeze", and the leave-date change is itself the audit line.

**Status: OPEN. The owner decides; this draft does not.**

---

## 17. v2 map: business-needs section 6.6 to requirements

| 6.6 item | requirement |
|---|---|
| the shift plan as the prefill source (BN-8) | FR-16, FR-17 |
| default hours per day (BN-14) | FR-14 |
| the Standard Day (Q3 = A) | FR-15 |
| exception clock in and out (BN-1) | FR-24 |
| a shared terminal identity (U2) | FR-25 |
| a job target with a quote (BN-2, BN-15) | FR-18, FR-19; roles FR-20, FR-21 |
| the break rule (BN-3) | FR-26 |
| travel and waiting rows (BN-3) | FR-27 |
| derived rate categories (BN-4) | FR-28 |
| a holiday calendar (U5) | FR-29 |
| foreman entry with Dispute (BN-5) | FR-23 |
| `hours.approve` scoped to a crew (BN-6, BN-14) | FR-22 |
| absence types (BN-7) | FR-30 |
| worker type (BN-11) | FR-31 |
| start and end times (BN-12) | FR-32, FR-33 |
| retention (BN-12) | FR-34 |
| offline approval (BN-13) | FR-35 |
| the approve nudge (U1) | FR-36 |
| hours per workspace (owner `3a121342`) | FR-37 |
| candidates: BN-9, U3, U4, U6..U10, U12 | section 15 (ranked) |
| U11 | section 16, Q8 (open) |

---

## 18. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-10-07 | c-522 (s107-1) | first draft: definition of time worked, signals measured on `aa7523ea`, worker approval, freeze, biz-owner approval, CSV/XLSX, calendar and issue v1/later, owner questions Q1..Q5 |
| 1.0 | 2026-10-07 | c-522 (s107-1) | fold of reviews s107-2, s107-3, s107-4 (section 12.2); unanimous consensus recorded; owner Q1..Q7; `tasks.md` |
| 1.1 | 2026-10-08 | c-566 | owner Q7 = B recorded (13.1): the header timer, 1.5, 5.3, 11; task T019 |
| 1.2 | 2026-10-08 | c-713 | owner R8..R11 (t1 `a28dc5c9`, 13.2): discussion links with a note per line (5.2); the calendar's right-side hours tabs Mine / Team / Download, a sheet on the phone (5.4); no rail entry, no page; a Working hours line on every working day in the calendar opens the event dialog of type Working hours (5, 7, 9, 10, 11); T010 dropped, T011 rewritten, T013..T015 inside the dialog |
| 2.0-draft | 2026-10-10 | c-734 | the business-needs gaps (business-needs.md 6.6, consensus `2c6c36732`): FR-14..FR-37 in section 14 (standard day per organisation and person, the prefill chain from the shift plan, jobs and quotes, no money in hours tracking, the time-accountant role and the external accountant seat, crew scope, foreman entry with Dispute, clock exceptions and the shared terminal, breaks, travel and waiting, derived rate categories, holidays, absences, worker type, start and end times, the change log, retention, offline approval, the nudge, hours per workspace); candidates ranked (15); U11 as open owner Q8 (16); the 6.6 map (17); for the v2 review panel |

<!-- version: 2.0.0-draft · updated: 2026-10-10 · last-edit: 2026-10-10T09:00:00Z -->
