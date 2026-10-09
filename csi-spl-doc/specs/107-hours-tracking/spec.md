# 107 Hours tracking: suggested, approved, frozen

**Feature ID**: `107-hours-tracking` · **Milestone**: M3 · **Status**: v1.2 (v1.0 unanimous consensus: seats s107-1..4 agree with changes, section 12; owner questions Q1..Q7 in section 13; **v1.2: the owner moved the member UI into the calendar**, R8 and R9 in section 0, section 5)
**Created**: 2026-10-07 · **Drafter / folder**: c-522 (seat s107-1) · **Topic**: t1 `ef217164-daaa-43bb-8343-f55ddb2f53a8` · lane dispatch `dispatch-ef217164`
**Authority**: this file for behaviour; [tasks.md](tasks.md) for what is built. Docs only: this spec builds nothing (`../README.md` §2.4). Status vocabulary: `../README.md` §2.3; every FR below is **Planned**.

Reviews, unchanged beside this file: [s107-2](reviews/s107-2.md) (`a231ea1e`) · [s107-3](reviews/s107-3.md) (`ec87f9b4`) · [s107-4](reviews/s107-4.md) (`efdbd856`).

Builds on:
- [089 the Calendar section](../089-calendar-section/spec.md), [097 full editing](../097-calendar-full-editing/spec.md), [106 the phone calendar](../106-calendar-phone-rewrite/spec.md): read-only source of meetings (section 7), and since v1.2 **the home of the member's hours UI**: a "Working hours" line on every working day and an entry type "Working hours" in the event dialog (section 5). Their tables and routes do not change.
- [039 issues](../039-spool-issues/spec.md): an issue's discussion is an ordinary topic on `issues.task_id` (section 8).
- [025 tenant RBAC](../025-spool-tenant-rbac/spec.md): roles and permissions; two new permissions (section 6).
- [098 tenant settings jsonb](../098-tenant-settings-jsonb/spec.md): four registered scalar keys for the workspace's hours settings.
- [043 mobile WUI](../043-spool-wui-mobile/spec.md): the phone stack (level 1/2/3, Back).
- [027 performance](../027-spool-performance/spec.md): the 155 KB initial chunk; the hours UI rides the calendar's lazy chunks and no always-on client plugin is added.

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

**Acceptance** (the live proof task): a seeded member with posts, tab minutes and a meeting on Monday opens the calendar at 390 px and at 1440 px, sees a Working hours line with Monday's total, opens it and sees Monday prefilled with the fixture's rows; approves the closed days in 2 taps from the calendar view; today stays open until **Approve so far**; after the freeze (with and without the sweep having run) the week is read-only and its open suggestions are gone; the biz owner returns it with a note, the member resubmits, the biz owner approves; the biz owner's CSV and XLSX hold exactly the approved lines with `period_state = approved`; a second workspace's biz owner reads none of them; a `hours.read` holder never receives a raw minute; `perf-budget.py` stays under 155 KB.

---

## 10. Phone and desktop

v1.2: the calendar's own two layouts at 820 px. Desktop: the line in the week's all-day row, the Working hours dialog (`CalendarEventDialog`) per day, and the right-side hours panel with Mine / Team / Download (5.4). Phone: the line in the Day / Week / Month lists, the dialog as the phone's entry sheet (`CalendarPhoneSheet`), the hours tabs as a sheet from the calendar menu; the Team grid becomes one card per member.

---

## 11. Not in v1

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

## 14. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-10-07 | c-522 (s107-1) | first draft: definition of time worked, signals measured on `aa7523ea`, worker approval, freeze, biz-owner approval, CSV/XLSX, calendar and issue v1/later, owner questions Q1..Q5 |
| 1.0 | 2026-10-07 | c-522 (s107-1) | fold of reviews s107-2, s107-3, s107-4 (section 12.2); unanimous consensus recorded; owner Q1..Q7; `tasks.md` |
| 1.1 | 2026-10-08 | c-566 | owner Q7 = B recorded (13.1): the header timer, 1.5, 5.3, 11; task T019 |
| 1.2 | 2026-10-08 | c-713 | owner R8..R11 (t1 `a28dc5c9`, 13.2): discussion links with a note per line (5.2); the calendar's right-side hours tabs Mine / Team / Download, a sheet on the phone (5.4); no rail entry, no page; a Working hours line on every working day in the calendar opens the event dialog of type Working hours (5, 7, 9, 10, 11); T010 dropped, T011 rewritten, T013..T015 inside the dialog |

<!-- version: 1.2.0 · updated: 2026-10-08 · last-edit: 2026-10-08T20:00:00Z -->
