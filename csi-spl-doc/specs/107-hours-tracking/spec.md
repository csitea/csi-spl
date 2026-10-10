# 107 Hours tracking: suggested, approved, frozen

**Feature ID**: `107-hours-tracking` · **Milestone**: M3 · **Status**: **v2.2** (2026-10-10: owner answers Q9..Q25 folded into the FRs and design points) · v2.1 (2026-10-10: owner principle P0 at the top of section 0, msgs `4d6d200c` and `4fd07875`; owner rows R12, R13; the points that push toward exact tracing and the timer, keyword and UI-direction questions as owner questions Q9..Q25 in section 20; no FR changed) · v2.0 (2026-10-10: the business-needs gaps, sections 14..17, FR-14..FR-40; v2 panel consensus of four seats in section 18; owner Q8 = C) · v1.2 (v1.0 unanimous consensus: seats s107-1..4 agree with changes, section 12; owner questions Q1..Q7 in section 13; **v1.2: the owner moved the member UI into the calendar**, R8 and R9 in section 0, section 5)
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

### P0 The principle above every requirement (owner, HUM-10, t1 `6571d5ed`, 2026-10-10, verbatim)

> "I guess I'm getting once again philosophical here, but the aim of the time tracking is not to trace exactly what the people have been doing, but to have some kind of directional guidelines on where the time is spent." (msg `4d6d200c`)
>
> "Because the essence of this system is the collaboration and not the time tracking. The time tracking is just a beneficial side effect we can do on that." (msg `4fd07875`)

**P0 ranks above R1..R13 and every FR.** Where a requirement or a design point below could be read toward exact tracing (minute precision, per-person detail, raw-signal retention, a per-action audit), P0 decides: the aim is a directional picture of where the time goes, a side effect of the collaboration, not a trace of what a person did. v2.1 adds P0 and changes no FR: the points that pull against it are listed, each with a recommendation, as owner questions in section 20.

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

R8 and R9 replace the v1.0 rail item and page: there is **no Hours rail entry and no `/hours` page, but `/hours` in chat is added as a cheap extra**.

The owner's input of 2026-10-10 (HUM-10, t1 `6571d5ed`, with P0):

| # | msg | text | answered in |
|---|---|---|---|
| R12 | `4842ca88` | keywords typed while filling in the time pick issues and topics; the timer's placement (full text below) | **20**, Q23, Q24 (open) |
| R13 | `82efd47b` | "Propose some kind of new UI directions for the implementation of this use case." | **20**, Q25 (**decided**: 1 + 3, msg `e91fe1b5`) |

R12, verbatim (msg `4842ca88`):

> "Now, this could be done also in several ways. Whenever the people are inserting their time, they type keywords. Those keywords present them with some issues and things they can select to allocate to their time slots.
>
> For example, I don't know what exactly I did the last 4 hours, but I worked on the box of the Spool Hub. I worked on IAM things on the Spool Hub. I worked on the workspace definitions, and so on and so forth. Whenever I'm filling in the time spent for today, I could just type these keywords, and the system will present me with the suggestions, the same way it's presenting now in the start-stop timer as well.
>
> In this sense, I'm not sure if this time-stopped timer placement is the most correct one. Would it be better if it were in the calendar, for example?"


R4 and R7 are requirements, not options: hours are **prefilled** from suggestions, the **worker approves** them, a **freeze** locks a period (**weekly by default, configurable**), the **biz owner approves** them a second time and **downloads** them as CSV and XLSX.

---

## 1. What "time worked" means (R3a, settled first)

### 1.1 The definition

> **Time worked on a day = a rough split of the day across a few targets, without the per-minute rules. It is a suggestion until the member approves it.** The minute is only the internal tick.

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
- **The WUI (active-tab minutes).** A minute is recorded when the tab is **visible and focused** (`document.visibilityState === 'visible' && document.hasFocus()`) **and** the member gave input (key, pointer, touch, wheel, scroll) in the last 60 s. A background tab, a tab visible on a second monitor but not focused, a locked phone, a tab left open overnight: **no minute**. The WUI keeps the minutes in a small in-memory buffer, **aggregates them on the device** to (day, target) totals, and sends those every 5 min. The hub never receives a per-minute sequence of what was open. (Read-sync pushes every 5 s, `utils/read-sync.mjs:19`; this is its own timer, not a piggyback.)
- **The recorder is a lazy chunk**, started from the feed pages the way read-sync is (`utils/read-sync.mjs` header: "A lazy chunk started from the feed pages"), never in the initial chunk (027).
- **A member can turn tab minutes off**: "Count my reading time" in their settings (a key in the membership settings jsonb, rdb 0078, no DDL), on by default when owner Q1 = A. Off: the WUI sends no tab minutes and that member's suggestions come from posts and meetings only.

Owner question Q1 (section 13) is whether tab minutes exist at all.

### 1.3 Which target a minute goes to

**Precedence for each minute: meeting > post > tab.**

| the minute had | target |
|---|---|
| inside an accepted meeting (1.4) | the meeting `cal:<event_id>` (or its `topic_id`, 1.4) |
| a post, edit or reaction | that message's topic `t:<task_id>` |
| an active-tab minute | what was open: a topic `t:<task_id>`, an issue (= its topic, section 8), a channel `ch:<name>`, anything else (settings, lists, the calendar page) is `ws` (the workspace) |
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
- **Time it** (owner Q7 = B, section 13; T019): a start/stop timer **in the calendar** (the Hours tab and the day's Working hours dialog), out of the app header. Start picks the target (the 5.3 picker); the running time shows in the header and survives a reload. Stop writes the interval once (`POST /v1/me/hours/timer`): the hub splits it at the member's local midnight (1.6) and adds each day's piece to that day's row for the target (an approved entry, else the open suggestion, else 0), approved, all days or none; a frozen day is 409 `period_frozen`, a day above 1440 minutes is refused, a run over 24 hours is refused. The running timer is kept on the device (localStorage, per workspace and member), never on the hub: nobody, the hub included, sees it until it is stopped (1.7).

### 1.6 Day, time zone, rounding

- A **day** is the member's local day. The zone is the member's chosen zone in this workspace (membership settings `time_zone`, rdb 0078) if set, else the zone the WUI sent with its last tab batch, else the workspace's `hours.tz`. Hub-written post minutes use the same order. A block over midnight splits at midnight.
- **Minutes are stored exactly**; the UI shows `h:mm`. Suggest and show in **quarter hours** (a 098 key `hours.round_minutes`, default `15`); the member may still type any value. A direction needs 0:15 steps, not 0:01.

### 1.7 Privacy of raw signals

- **Only `/v1/me/hours*` serves raw minutes and unapproved suggestions, always filtered `member_id = caller`.** No other route reads `hours_minutes`; a test asserts it (the table name appears only in the hours store file and the hub's post-write upsert).
- Nobody else sees them: not a biz owner, not an admin, not `hours.read`. Others see only **approved** entries and period states (section 6).
- `hours_minutes` is tenant-scoped by RLS (FORCE). RLS separates workspaces, not members: the per-member line is the routes above. `operator_scope` exists for the prune sweep only, and no operator route reads the table. Direct database access by an operator is outside the WUI and outside this spec.
- Raw minutes are deleted **when the day is approved, at the latest 2 days after it closes**; the entries carry the direction. Entries and period rows stay.

---

## 2. Suggestions: how a day is prefilled (R3, R4)

1. The hub computes a (member, day)'s suggestions **on read**, from **one** table plus the calendar: `hours_minutes` by its primary key and the member's meetings by the calendar range index. No job, no cache table.
2. **No suggestion is computed for a frozen day, nor for a day in a returned period** (4.3). In a returned period the worker edits, rejects and adds entries only; the period's raw minutes are already pruned.
3. Once the member approves, edits or rejects a row, it is **an entry** (3.2) and replaces the suggestion for that (day, target). Activity later that day shows as a **delta** on the row only when it reaches the rounding step ("+0:15 since you approved") with its own one-tap accept **✓ +0:20**; an approved number never changes silently.
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
| `day` | date | the day |
| `target` | text | `CHECK (target ~ '^(t\|ch):.{1,200}$' OR target = 'ws')` |
| `minutes` | integer | the counter |
| `src` | text | `post` or `tab` |
| `tz` | text | the IANA zone |

PK `(tenant_id, member_id, day, target)`: a per (member, day, target) counter that the post upsert and the tab batch add to. Precedence is applied per batch. Pruned at freeze and at 45 days.

**`hours_entries`**: what the worker decided, per row. Justified: approval needs state.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | HUM-* |
| `day` | date | the member's local day |
| `target` | text | 1.3 targets plus `cal:<event_id>`: `CHECK (target ~ '^(t\|ch\|dm\|cal):.{1,200}$' OR target = 'ws')` |
| `minutes` | integer | 0..1440 |
| `suggested_minutes` | integer | what the system proposed (0 for an added row); kept in the worker's own view only |
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
- A **delta** (2.3) has its own **✓ +h:mm**, one tap (shown only if it reaches 15 minutes).
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

v1.2 (owner R8, R9): the member's hours live **in the existing calendar**. There is no Hours rail entry and no `/hours` page, but `/hours` in chat is added as a cheap extra (the v1.0 design, kept below only where the dialog reuses it).

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

**Description: the day's discussions, with notes (owner R10).** The dialog's description lists, for the day, **one line per discussion the member took part in** (every row whose target is a topic `t:<task_id>`, recorded by the hub on a post, an edit or a reaction, T005, plus the tab minutes when counted): the topic's subject as a **link** to the topic, and its total time `h:mm` (no block start and end times). Meetings (`cal:`), channels and "other" follow as plain rows. Each line takes a **free-text note** (<= 500 characters):
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
- A row's number opens the stepper in place; the row's name opens the "why" sheet.
- Frozen days carry a lock and no buttons; an approved period says "Final"; a returned one shows the biz owner's note and **Resubmit**.
- No horizontal scroll on the phone (the 106 rule); controls 44..48 px.

### 5.3 Add a row

`+ Add` in the day's Working hours dialog: a target picker (recent topics, issues, channels first; search; an unmatched keyword stays as the row's label under "other") and a minutes stepper (default 0:30). Two taps plus the pick. In-app time is measured; off-app time is added, extended or timed with the header timer (1.5, owner Q7 = B). The picker is one component (`HoursTargetPicker.vue`), shared by `+ Add` and the timer.

### 5.4 The calendar's right side: hours tabs (owner R11)

v1.2: the calendar page gets a **right-side panel with tabs for hours** (desktop, > 820 px: a third column after the year strip and the main view, about 320 px, collapsible from its header; its open / closed state is kept in this browser). The per-day entry stays the day's Working hours line and dialog (5.1, 5.2); the panel holds the period-wide views:

| tab | who | holds | task |
|---|---|---|---|
| **Mine** (default) | every member | the open period's days, newest first: each day's total and state (open mark, approved, frozen lock, Final), the banner "2 days not approved · freezes Wed 00:00 · [Approve 2 days]", **Approve week**, a returned period's note and **Resubmit**; a click on a day opens its Working hours dialog | T011 (read), T013 (approve) |
| **Team** | `hours.read` | the grid below, Approve / Return for `hours.approve` | T015 |
| **Download** | `hours.read` | period picker, CSV / XLSX, Final only (6.2) | T015 on T009 |

A member without `hours.read` sees Mine only (no tab strip). The panel loads with the calendar's lazy chunks; its data is `GET /v1/me/hours` (Mine) and `GET /v1/hours` (Team), fetched when the tab shows.

**Phone (<= 820 px, 390 px):** no third column; the phone calendar's header menu (`calphone-menu`) gains **Hours**, which opens the same tabs as a full-height sheet (the 106 sheet pattern, Back / swipe down closes it): Mine, and Team and Download for `hours.read`. No sideways scroll, controls 44..48 px.

**Team (holders of `hours.read`):** default report = **per period, per target (job, issue, topic), summed over people**; the per-member and per-day views stay one click away for approval. Each member row shows its period state (open / frozen / returned / final) and, for a holder of `hours.approve`, **Approve** and **Return**; the header has **Approve all** and **Return all**. Filters: member, target type, issue. **Download** (its own tab): CSV or XLSX (6.2). On the phone, one card per member with total and Approve / Return.

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
- **CSV** and **XLSX**, the same columns, one line per approved entry: `date, member_id, member_name, target_type, target_id, target_name, issue_key, minutes, hours_decimal, note, period_state, approved_by, approved_at`.
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
| FR-01 | Active minutes and blocks (1.1): N from settings; 3-min floor for tab-only blocks; rule order; suggest and show in quarter hours (1.6) | Planned |
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
| FR-14..FR-40 | v2.0: the business-needs gaps, each citing its BN / U id (section 14; map in section 17; panel in section 18) | Planned |

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

## 14. v2: the business-needs gaps (v2.0)

Source: [business-needs.md](business-needs.md) section 6 (consensus at `2c6c36732`, four seats in `reviews/bn-*.md`, owner answers BN-Q1 = A, BN-Q2 = A, BN-Q3 = A). v2.0 folds the v2 panel (section 18).

**Two sets of owner questions** (v2-claude-2): **BN-Q1..BN-Q3** are the business-needs questions (business-needs section 5); **v1-Q1..v1-Q7** are this spec's v1 questions (section 13). The owner answered v1-Q2 = **B** (msg `54eda621`: "accept the suggestions from the panel , except - q2 b and q7 b"): an open suggestion is approved by the sweep at the freeze. Section 6.6 lists what v1.2 lacks; every requirement below fills one of those gaps and cites its BN or U id. The section 6.6 to requirement map is section 17.

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
| **FR-37** | Hours are **per workspace**. Every v2 object (standard day, plan, jobs, crews, holidays, terminals, the change log) belongs to one workspace, under the same FORCE RLS as section 3.2. Tracking time for one person across several workspaces of the same hub (double counting, a limit across workspaces, reconciling the per-workspace standard days of FR-14, a person-only view of all of them) is **out of scope here**: it is its own new spec (t1 `cee5a73e`, owner msgs `de2cdf88`, `690c4ad1`, `0c3b1bf7`), written separately. | owner `3a121342` |

### 14.2 The standard day and the prefill chain (BN-14, Q3 = A, BN-8, BN-1)

| id | requirement | cites |
|---|---|---|
| **FR-14** | **Standard day, per organisation and per person.** A workspace (= the organisation) has a standard day in minutes: a new registered 098 key `hours.standard_day_minutes` (int, default `480` = 8 h, range `0..1440`; e.g. `450` = 7.5 h), set by a holder of `tenant.settings`. A person may have an **override** (e.g. `240` for a half-day contract), set by their foreman from the crew screen (FR-38) or by a holder of workspace-wide `hours.approve`; the override may be a **weekday pattern** (seven values, e.g. 4 x 480 Monday..Thursday and `0` on Friday), and a weekday at `0` is not a working day for that person (FR-15, FR-29, 5.1 read it). A person's value of `0` on every day means no standard day: the Standard Day (FR-15) is off for them. **Resolution: the person's value wins, else the organisation's.** A person's override carries the date it takes effect; the organisation's value is a 098 scalar and applies from its change forward. A change never rewrites an approved or frozen day: the day record (FR-32) keeps the standard day in force, written at approval. The prefill (FR-17), an absence day (FR-30), the Standard Day (FR-15) and every full-day check (FR-26 break rule, the "full day" mark) use **the person's resolved standard day**. It is hours per day, never an hourly rate (business-needs 6.1). | BN-14, O1, O2, O3 |
| **FR-15** | **The Standard Day (BN-Q3 = A).** A per-member switch "Standard Day", on by default (the workspace may turn the default off with `hours.standard_day_default`, bool, default `true`); the member, their foreman or the office can turn it off for that person, and each change is logged (FR-33). On, a closed working day that has no absence and no plan row is suggested at the person's standard day: the day's tracked activity (sections 1, 2) is **scaled proportionally** across its targets to reach the standard day (largest remainder to whole minutes); with no activity, one row of the standard day goes to the member's default target (the last planned job, else `ws`) and is marked **no activity**. A day whose activity already exceeds the standard day keeps its real minutes (the excess is visible, it feeds FR-28 overtime), it is never cut. **The sweep auto-approves (v1-Q2 = B) only rows with evidence**: activity, a plan row, a clock time or a foreman row. A **no activity** row stays open with the open mark on its Working hours line and counts zero at the freeze unless the worker or the foreman approves it: no paid day without evidence or a tap. Rule 2 pass: the IT person has activity, so their day is split and approved with zero typing. | BN-Q3 = A, BN-1, BN-2 |
| **FR-16** | **The shift plan.** Per (member, day) the plan holds the job (FR-18) and the shift's start and end time; a day may hold up to two rows (two jobs, U3, section 15). A shift that ends after midnight (22:00..06:00) splits at the member's local midnight, as 1.6. Editable by the member's foreman (FR-22) and the office (workspace-wide `hours.approve`), in the plan screen (FR-38). **Repeated from last week by default**: a day with no plan row reads the member's most recent plan row for the same weekday **before that day**, within the last 28 days, at read time (no copy job), skipping a row whose job is `closed` (FR-18) and a row written while the member was in another crew; the foreman's "Copy last week" writes the rows when the week must be fixed. A row the foreman wrote is **explicit**, a read-time repeat is **inherited** (FR-29 tells them apart). It is the planned work, not a calendar event: no `calendar_events` row (as 5.1). | BN-8 |
| **FR-17** | **The prefill chain**, per (member, day). **An entry always beats the chain** (2.3: an approved, edited or rejected row replaces its suggestion). For the rest, first match wins: (1) an absence or holiday row (FR-29, FR-30) for its minutes; a **part-day** absence or holiday takes its minutes and the next step fills the rest of the day; an **explicit** plan row (FR-16) on a holiday beats the holiday; (2) a foreman-entered row (FR-23); (3) the plan (FR-16): the shift's net minutes (start..end minus the break, FR-26) to the planned job; (4) the Standard Day (FR-15); (5) a day with **only a clock in and out** (FR-24): end - start - break to the default target; (6) v1 activity suggestions only (sections 1, 2), when the Standard Day is off. Clock exceptions (FR-24) change the start or end of whatever (2)..(4) produced, and the day's minutes become end - start - break (FR-26). Like v1 (2.1), plan and Standard Day suggestions are computed on read; nothing is stored until approved. Rule 1 pass: the week opens prefilled, the worker confirms. | BN-1, BN-8, BN-14, BN-Q3 = A |

### 14.3 Jobs and the quote (BN-2, BN-15)

| id | requirement | cites |
|---|---|---|
| **FR-18** | **Job, a new target.** A job (`job:<job_id>`) has a name, a site (free text, e.g. an address), an optional linked topic, a **quote in hours** (`quote_minutes`) and a state (`open`, `closed`). Created and closed by the office (workspace-wide `hours.approve`), in the setup screen (FR-38). The target CHECK of `hours_entries` (3.2) widens to `job:`, a constraint redefinition in the 0148 pattern (3.3); `hours_minutes` and its CHECK stay as v1. A site worker's day defaults to their planned job (FR-17); an office member's to tracked activity; the worker changes it only on a day that differed. A post in the job's linked topic is suggested against the job, not the topic: mapped **at read time** from `t:<task_id>`, no extra lookup on the post write path. A closed job is no longer offered in pickers; its rows stay. | BN-2, BN-15 |
| **FR-19** | **No money in hours tracking (owner `5105fdf7`).** Hours tracking has **no rate editor and no rate field**. A person's rate lives in a future **accounting view**, a separate spec (not written; a dependency of 107 v2, out of its scope). Hours tracking only **reads** a rate from it to compare a job's labour cost (approved hours x the person's rate on that day) with the job's quote; a quote in money, if any, lives there too. Until the accounting view exists, a job compares approved hours with `quote_minutes` only. | BN-15, BN-10, O4 |

### 14.4 Roles: the time-accountant, the external accountant (owner O5..O7)

| id | requirement | cites |
|---|---|---|
| **FR-20** | **The time-accountant role.** A new system role `time_accountant` holds `hours.read` and a new permission **`hours.rates`** ("see rates and labour cost; compute approved hours x rate"). Every rate, money amount, labour cost and the BN-15 cost-against-quote comparison is served only to **holders of `hours.rates`**, by route (as 1.7). `hours.rates` is pinned to `time_accountant`: it is in no other default role, the biz owner's included, and the role editor cannot add it to another role. A biz owner who needs rates assigns themself the role, which is logged (FR-33): this is a separation of duties, not a boundary against the biz owner. Workers, foremen and approvers without that role see hours, never money. **Roles combine**: one person may hold, e.g., a foreman's crew leadership (FR-22) and the time-accountant role at once. This needs **several roles per member** (025 section 9, phase 2: `tenant_member_roles`, the authorizer takes the union), not built yet: a dependency of 107 v2. Until the accounting view (FR-19) exists, `hours.rates` has nothing to show; build the hours-only half of FR-20 and FR-21 first. | BN-15, O5, O6 |
| **FR-21** | **The external accountant seat.** A time-accountant may be a foreman (combined roles), an internal accountant, or an **accountant outside the organisation**. The external seat: **invite**: a holder of `members.invite` invites an e-mail with the role `time_accountant` as the membership's **only** role and a **required** end date (`access_until`, rdb 0113, the 072 guest rule R1, A27: scoped, revocable, expiring); **visibility**: read only (`hours.read`, `hours.rates`; no Approve, no Return): the Team and Download tabs and the job cost view, member names as they appear on hours rows; **no** `topics.read` (no WUI socket, no topics, channels, docs, files, roster or calendar events), none of the four permissions every member role holds today (`rbac.go` `withMember`); the WUI opens the calendar's hours panel (5.4) full width with no events: no `/hours` page, but `/hours` in chat is added as a cheap extra, so R8 and R9 stand. Absence types show as "absent" (FR-30). The seat gets no period row (the sweep, 4.2, skips a membership whose only role is `time_accountant`, as it skips agents). **Removal**: a holder of `members.invite` removes the seat, or `access_until` passes; access ends at once; the downloads it made stay in the change log (FR-33). An accountant serving several firms holds one seat per workspace (FR-37). Whether the seat is billed is the billing spec's call, not 107's. | O7, BN-15 |

### 14.5 Crews and the foreman (BN-6, BN-14, BN-5)

| id | requirement | cites |
|---|---|---|
| **FR-22** | **`hours.approve` scoped to a crew.** A crew is a named set of members with one or more foremen. A worker is a member of at most one crew at a time; a foreman may lead several crews. Crews and their foremen are set by the office (workspace-wide `hours.approve`). **Leading a crew is the scope**: a foreman has, **for the members of the crews they lead only**, the hours rights of v1 `hours.read` and `hours.approve` (see approved hours, Approve, Return) plus the v2 crew rights: plan (FR-16), enter and fix (FR-23), set the person's standard day (FR-14), in the crew screen (FR-38). A role grant of `hours.approve` (the office, the biz owner) stays **workspace-wide** and sees every crew. **One second approval**: the foreman's or the office's, either one, not two levels. **No self-approval**: nobody approves or returns their own period; a foreman's own period goes to a workspace-wide holder. A member who changed crew mid-period is approved by the foreman of the crew they are in **when the period freezes**. **Approve crew**: one tap approves every frozen period of the foreman's crews that they may approve (as 4.4 Approve all, crew-scoped), on a phone. A correction after the **worker's** approval and before the freeze needs a reason and is logged with its author (FR-33); after the final approval only an adjustment row applies (FR-40). | BN-6, BN-14 |
| **FR-23** | **Foreman entry with Dispute (BN-Q1 = A).** Before the freeze, a foreman enters or fixes a day for any member of their crew, including members without a login (FR-25). Each such row records its author (`entered_by`) and lands in the worker's week as **proposed** (prefilled, step (2) of FR-17). The worker's Approve week covers it (0 extra taps). **Dispute** (one tap, plus an optional note) marks it **disputed** and puts it in the foreman's list; the foreman fixes it (proposed again) or keeps it with a note. A foreman's fix of a row the worker had approved returns it to proposed. **At the freeze**: a still-proposed row is approved at the foreman's value (v1-Q2 = B; it has evidence, FR-15); a still-disputed row freezes as disputed, and that member's period is approved or returned (4.3) only by a workspace-wide `hours.approve` holder, never by the foreman who is a party to the dispute. **A member without a login** can neither approve nor dispute: the foreman's entry is their first approval, marked so for the approver, and the second approval comes from someone other than that foreman. After the freeze nobody edits minutes; Return (4.3) is the way back. This changes 4.4's "the biz owner never edits a worker's minutes" for the foreman, before the freeze, for their crew. | BN-5, BN-Q1 = A |

### 14.6 Clock exceptions and the shared terminal (BN-1, U2)

| id | requirement | cites |
|---|---|---|
| **FR-24** | **Clock in and out is an exception.** The normal day is confirmed, not clocked (FR-17). **Clock in** / **Clock out** (one tap each, on the phone in the day's Working hours dialog, or on a terminal, FR-25) records a time that replaces the day's start or end: a late start, an early leave, extra hours, or a day with no plan. On a day with two plan rows (U3), Clock in moves the first row's start and Clock out the last row's end. The clock time is the server's time, or the device's time marked `offline` (FR-35), bounded: not later than the sync, not earlier than the device's last sync; a device time outside the bounds, or more than `hours.clock_skew_minutes` (default `10`) from the sync time, is kept and marked for the foreman. **A forgotten clock out** (BN-5's own example): the day ends at the planned end, else start + standard day + break, and the day goes to the foreman as proposed (FR-23). A foreman may set a crew member's clock time (FR-23 rules). The clock sets the day; the v1 header timer (1.5, T019) books a target: a site worker's phone shows only the clock. | BN-1, BN-5 |
| **FR-25** | **Shared terminal identity.** An admin (`tenant.settings`) registers a device as a **terminal** of the workspace: a terminal token held on the device, revocable from the same admin screen (a lost terminal), holding no member's rights. A worker identifies on it **by name or badge first** (a scanned code), **then a PIN** (4..6 digits); a PIN alone never identifies anyone. The PIN is hashed with a hub-held key (pepper), not only a salt. 5 wrong tries lock **that member's** PIN for 15 min, and each terminal is rate-limited. The terminal shows the worker's name, Clock in / Clock out and today's hours, and nothing else; the worker's session ends after the action or after 30 s. Every terminal action writes the change log (FR-33) with the terminal id. A terminal needs a network in v2; offline work is the phone's (FR-35). **A worker without an e-mail or a smartphone** (U2): the foreman or the office creates the member with a name and no e-mail login, and sets the PIN or badge; that member clocks on a terminal or is logged by the foreman (FR-23). Creating a member with no e-mail login is a dependency on the membership code (today a member signs in by e-mail). | BN-1, U2, BN-11 |

### 14.7 Breaks, travel, waiting (BN-3)

| id | requirement | cites |
|---|---|---|
| **FR-26** | **The break rule.** Registered 098 keys `hours.break_after_minutes` (default `360`) and `hours.break_minutes` (default `30`): a day whose start..end span, **after clock exceptions**, exceeds the threshold has the break deducted once, from the day's longest row, unless the worker or foreman marks **No break** on that day (one tap). It applies to days with start and end times (plan, clock); the standard day (FR-14) is already net. A person whose standard day is under the threshold (a half day) never gets the deduction from the prefill. A second, longer tier (several countries add one above ~9 h) is two more scalar keys later, no design change. | BN-3 |
| **FR-27** | **Travel and waiting rows.** An entry gets a **kind**: `work` (default), `travel`, `wait`, `absence`, and **`kind` joins the key**: `hours_entries` PK becomes `(tenant_id, member_id, day, target, kind)`, so travel to job A and work on job A are two rows; an absence row has target `ws` and kind `absence` (its type in `absence_type`, FR-30). The natural-key upsert of S2-4 is unchanged in shape. **+ Travel** and **+ Waiting** in the day's dialog add one row each (one tap), with a default length (`hours.travel_default_minutes`, `hours.wait_default_minutes`, default `30`) and an optional reason (e.g. a weather delay, bn-agy). Travel between two planned jobs on one day (U3) is prefilled from the plan. Only on days it happened; the normal day has none. | BN-3, U3 |

### 14.8 Rate categories and the holiday calendar (BN-4, U5)

| id | requirement | cites |
|---|---|---|
| **FR-28** | **Derived rate categories.** Every approved minute gets its categories **derived, never chosen by the worker**: `evening` and `night` from workspace windows (`hours.evening_window` default `18:00-22:00`, `hours.night_window` default `22:00-06:00`), `weekend` (Saturday, Sunday), `holiday` (FR-29), else `normal`; one of these per minute, precedence holiday > night > weekend > evening > normal. **Times come from the day, stored before they are lost**: at approval (and by the sweep **before** it prunes `hours_minutes`, 1.7) each entry stores its split as `category_minutes`; the day's start and end (FR-32) come from the plan or the clock, or for an activity day from its first and last active minute, take start and end from the plan, else the standard day estimate, never from activity. **Overtime** is a separate flag: minutes past the weekly threshold `hours.overtime_weekly_minutes` (default 5 x the **organisation's** standard day; a person may have an override). Minutes above the person's own weekly standard (FR-14) but under that threshold are flagged **`extra`** (contract top-up, not overtime). A week that spans two periods gets its overtime and `extra` flags when its last day freezes; a frozen period's categories never change. How 107 keeps the times of day is also spec 118's owner question Q1 (msg `5b14c79c`, a `hours_entry_spans` change to 107): `category_minutes` stands until that answer, which may replace it. A category is a label on hours: it carries **no money** (FR-19, FR-20). | BN-4, BN-12 |
| **FR-29** | **The public-holiday calendar.** Per workspace, with an optional **region** per member (membership setting): a list of (region, date, name, optional minutes for a part-day holiday such as 24 Dec), kept by the office in the setup screen (FR-38), entered by hand or imported from a CSV or iCal file. A holiday on a person's working day (FR-14) prefills an absence row of type `holiday` at the person's standard day, or its minutes for a part day (FR-17 step 1); an **explicit** plan row on that day beats it, an inherited one does not (FR-16). Work done on it is category `holiday` (FR-28). It is drawn in the calendar like the Working hours line (5.1), not as a calendar event. | U5, BN-4 |

### 14.9 Absences and the worker type (BN-7, BN-11)

| id | requirement | cites |
|---|---|---|
| **FR-30** | **Absence types (BN-Q2 = A).** A row of kind `absence` with a type from a fixed list: `sick`, `vacation`, `unpaid`, `training`, `holiday`. Whole day = the person's standard day (FR-14; 4 h for a half-day contract), or part day in minutes (FR-17: the rest of the day is filled by the next step). Picked from the day in 2 taps (**Absent** -> type), or entered once as a **date range** by the worker, their foreman or the office; a range covers the person's working days only and never writes into a frozen period (409 `period_frozen`, per day). An absence beats the plan and the Standard Day (FR-17 step 1), and the plan screen (FR-38) shows it over the plan. **The type is health data for `sick`**: the foreman and the external accountant (FR-21) see "absent"; the type goes only to workspace-wide `hours.read` and the payroll export. **No balances in v2**, and leave **requests** (approval before the leave) are out of v2; the worker sees the days taken this year per type (U6, section 15). | BN-7, BN-Q2 = A |
| **FR-31** | **Worker type.** A member is typed `employee` (default), `agency` (with the agency's name) or `subcontractor` (with the company's name), in the membership settings jsonb (no DDL), set by the **office only** (a contract fact, not the foreman's). Members without a login are logged by their foreman (FR-23, FR-25). Reports and the download split by type; subcontractor hours roll up per company for invoice checking and stay **out of the payroll export** (FR-39). | BN-11 |

### 14.10 Start and end times, the change log, retention (BN-12)

| id | requirement | cites |
|---|---|---|
| **FR-32** | **The day record.** Per (member, day) the hub keeps **start, end, break minutes**, the standard day in force and a **source per field** (`plan`, `standard`, `activity`, `clock`, `terminal`, `foreman`, `self`, `absence`, `holiday`). It is written **at approval** and by the sweep (v1-Q2 = B), never on read, matching FR-17. Start and end are prefilled from the plan, else from `hours.day_start` (default `08:00`) + the standard day + the break; **never typed** in the normal case (clock exceptions, FR-24, change them). A `standard` start and end is an estimate, not a measurement: the inspector's export (FR-34) shows each field's source so a derived time is never presented as a recorded one. | BN-12 |
| **FR-33** | **Every change is logged.** Each write to an entry, a day record, a period row, a crew, a plan row, a person's standard day or Standard Day switch, a role assignment of `time_accountant` (and each rate-bearing download, FR-21, and each terminal action, FR-25) writes one change-log row: who (a member, a terminal, or the actor `sweep` for auto-approval, freeze and prune), when, before, after, and why. A reason is **required** for a change after approval (BN-6). The log is append-only, enforced in the database too (the hub role has no UPDATE or DELETE on `hours_changes`); the FR-34 retention sweep is its only deleter. v1's `member_activity` `hours_returned` (3.3) stays as built; a return also writes the change log. | BN-12, BN-6 |
| **FR-34** | **Retention.** A registered 098 key `hours.retention_years` (int, default `5`, range `1..30`), set by `tenant.settings`: the law varies by country, so the workspace sets it. Day records, entries, period rows and the change log are kept that long after their period ends, then deleted by the sweep. (v1's 1.7 pruning of raw minutes at the freeze is unchanged.) **Removing a member keeps their hours rows** for the retention period; only a workspace deletion (the tenant cascade) removes them, and its confirm warns that it destroys the legal working-time record. **The inspector's export**: read-only, per worker and period, CSV and XLSX (6.2's writer), holding start, end, breaks, minutes per day, each field's source (FR-32) and every change; served to `hours.read` (workspace-wide). | BN-12 |

### 14.11 Offline, and the nudge (BN-13, U1)

| id | requirement | cites |
|---|---|---|
| **FR-35** | **Offline approval, minimum scope.** Without a network: the week view, **Approve week**, an absence pick (FR-30) and a clock exception (FR-24). The service worker precaches the hours lazy chunks and the open period's data (today `csi-spl-wui/src/public/sw.js` caches navigations only: a change to it and its tests), and writes are queued in IndexedDB with an operation id (idempotent on replay), the device time and **the version (`updated_at`) of every row the write approves**; they sync on reconnect. **On sync a frozen period wins**: the write is refused (409 `period_frozen`) and the worker sees why. A row changed meanwhile (a foreman edit) shows both values and asks the worker once; it is never overwritten silently. Nothing of this enters the initial chunk (027). Its acceptance test runs on the CI mock bundle (CI has no live socket offline). | BN-13 |
| **FR-36** | **The approve nudge.** One phone notification through Web Push (095): "Your week: 40:00 at Site A · [Approve]". Sent on the period's last working day **30 min after the member's last planned shift ends** (no plan: 17:00 local), and again the day before the freeze if days are still open; never for a fully approved period; quiet hours as 095 section 6.6; a per-member off switch. **Approve week includes today's planned row once its planned end has passed** (a change to 4.1's closed-days rule for plan rows only), so the week in the nudge is the week approved. Tapping it opens the Working hours dialog on its banner (tap 1); **Approve week** (tap 2). A foreman gets "Crew week ready · [Approve crew]" after the freeze; it also covers crew members without a phone (U2). On iPhones Web Push reaches only a web app added to the home screen: onboarding a worker includes that step, or the lock-screen tap does not exist for them. Rule 1 pass: 2 taps from the lock screen. This replaces 11's "no pop-up in v1" for v2. | U1, BN-6 |

### 14.12 Screens, the payroll export, corrections (v2 panel)

Added by the v2 panel (section 18): the draft gave the foreman and the office rights with no screen, and left the payroll file and a correction after approval to later rounds.

| id | requirement | cites |
|---|---|---|
| **FR-38** | **The Crew and Setup tabs.** The calendar's right-side hours panel (5.4; a sheet on the phone, as 5.4) gains two tabs. **Crew**, for a crew leader (their crews) and workspace-wide `hours.approve` (every crew): the list of the people, each with their standard day or weekday pattern (FR-14), Standard Day switch (FR-15), PIN or badge (FR-25), and the **plan** as crew x days with the job and shift per cell, **Copy last week**, and absences drawn over the plan (FR-16, FR-30); **Approve crew** (FR-22) at its top. This is the owner's "the foreman should have access to the list of the people and have the UI for setting up their default hours" (business-needs 6.1). **Setup**, for workspace-wide `hours.approve` and `tenant.settings`: jobs (FR-18), crews and their foremen (FR-22), worker types (FR-31), holidays (FR-29), terminals (FR-25). No new page and no rail entry (R8, R9); both tabs are lazy chunks (027). Phone: controls 44..48 px, no sideways scroll. | BN-14 (owner addendum), BN-8, BN-6 |
| **FR-39** | **The payroll export.** A per-workspace **column map** (rename, order, drop) sets the payroll file's layout; no payroll API. One line per (member, day, kind, category) with its minutes, carrying the FR-28 category and the `overtime` / `extra` flags, the FR-30 absence type and the FR-31 worker type; subcontractor hours are left out. **A month file over weekly freezes**: the export takes a calendar month and holds every frozen or approved day in it, so a weekly period that crosses the month boundary is split at it. CSV and XLSX, 6.2's writer; Final only by default (6.2). | BN-9, BN-4, BN-7, BN-11 |
| **FR-40** | **A correction after approval (U8).** An `approved` period stays final (4.4) and v1 has no unfreeze (v1-Q4 = B). A mistake found after the final approval, or after the payroll export, is an **adjustment row** in the member's next open period: `kind` of the corrected row, the day it corrects, signed minutes, a **required** reason, written by a workspace-wide `hours.approve` holder or the member's foreman, logged (FR-33) and shown in that period's export as an adjustment. A paid period is never rewritten. | U8, BN-6 |

### 14.13 What v2 adds to the data and routes (sketch, for the tasks round)

Not the tasks: the tasks round sizes them. New tables, each in the 3.2 shape (tenant first, FORCE RLS, `tenant_scope`, `operator_scope`): `hours_standard_days` (member overrides with their effective date, FR-14), `hours_plan` (FR-16), `hours_jobs` (FR-18), `hours_crews` and `hours_crew_members` (FR-22), `hours_days` (FR-32), `hours_changes` (FR-33), `hours_holidays` (FR-29), `hours_terminals` (FR-25). `hours_entries` gains `kind` (in its PK, FR-27), `absence_type`, `entered_by`, `reason`, `category_minutes` (FR-28), and states `proposed`, `disputed`; its target CHECK widens to `job:`. Adjustment rows (FR-40) and the payroll column map (FR-39) are sized by the tasks round. `hours_changes` is append-only in the database (FR-33), logging what payroll and trust need: changes after the worker's approval, returns, role and rate events, downloads. New registered keys: `hours.record_clocked_times` (off by default), `hours.standard_day_minutes`, `hours.standard_day_default`, `hours.day_start`, `hours.break_after_minutes`, `hours.break_minutes`, `hours.travel_default_minutes`, `hours.wait_default_minutes`, `hours.evening_window`, `hours.night_window`, `hours.overtime_weekly_minutes`, `hours.clock_skew_minutes`, `hours.retention_years` (for approved period totals per target). Day records and the change log are kept only as long as the law requires (`hours.retention_raw_years`, default period + 1 year). New permission `hours.rates`, pinned to the new role `time_accountant` (FR-20). Routes grow under `/v1/hours/*` (plan, jobs, crews, standard days, holidays, inspector export, payroll export, adjustments) and `/v1/me/hours*` (dispute, clock, absence range); a terminal route takes a terminal token, never a member session.

**Dependencies outside 107**: the accounting view (FR-19, a separate spec, not written); several roles per member (025 section 9, FR-20); a member with no e-mail login (FR-25); cross-workspace tracking (FR-37, its own new spec).

### 14.14 v2 acceptance (the live proof task, as section 9's)

- **Rule 1**: a seeded site worker with a plan for Monday..Friday and no in-app activity opens the nudge on a 390 px phone and approves the week, Friday included after its planned end, in <= 3 taps; the same approval made offline syncs on reconnect, and a foreman edit made meanwhile is shown, not overwritten.
- **Rule 2**: a seeded office member with activity sees each closed day split across their topics at their standard day, and the sweep approves it with zero typing; a no-activity day stays open and counts zero.
- **Crew scope**: a foreman sees and approves only their crew, never their own period; a disputed period goes to a workspace-wide holder.
- **No leak**: rates and labour cost reach only `hours.rates` holders; `sick` reaches neither the foreman nor the external seat; a second workspace reads nothing.
- **Budget**: the Crew, Setup and terminal screens are lazy chunks; `perf-budget.py` stays under 155 KB (027).

---

## 15. v2 candidates, ranked (v2 panel)

Business-needs 6.6 left these for the round to rank. The order below is the v2 panel's (section 18.3): the draft's order, with U8 promoted into v2 and BN-9 first.

| rank | item | decision | why |
|---|---|---|---|
| 1 | **BN-9** payroll column map | **in v2**: FR-39 (column map, a line per category, a month file over weekly freezes, subcontractors left out; no payroll API) | the freeze and both approvals exist to feed payroll; without the categories in the file nothing downstream works |
| 2 | **U3** two sites in one day | **in v2**: up to two plan rows per day (FR-16), **Split** in one tap, travel between them prefilled (FR-27) | Rule 1; common on sites; cheap once the plan exists |
| 3 | **U8** a correction after the payroll export | **in v2**: FR-40, an adjustment row in the next open period | an approved period is final (4.4) and there is no unfreeze (v1-Q4 = B): the first wrong export has no other path |
| 4 | **U6** the worker sees their own numbers | **in v2**: hours this week and month, overtime and `extra`, absence days per type this year, in the Mine tab (5.4) | Rule 1 trust in prefilled hours; read only |
| 5 | **U7** the worker's language | **in v2**: the phone hours UI uses the member's language (`csi-spl-wui/i18n/locales`), icons with short labels; every translation gets the agy language review before it ships (fleet language rule) | Rule 1 for mixed-language crews |
| 6 | **U9** working-time limit warnings | **v2.1**: warn the foreman and the office before a day or week passes the maximum or the minimum rest, from FR-32 start and end | legal risk; it needs recorded, not estimated, times (FR-32 sources) |
| 7 | **U10** who is on site now | **later**: a read view over the plan plus clock exceptions | useful, not Rule 1 |
| 8 | **U4** allowances and expenses | **out**: its own spec (money, receipts); it belongs next to the accounting view | a separate data domain |
| 9 | **U12** equipment and machine hours | **out**: job costing, not people's hours | not hours tracking |
| - | **U11** a leaver's final pay | **decided by the owner: C** (section 16) | |

---

## 16. v2 owner question Q8: decided

**Q8: a leaver's final pay (U11).** A member leaving mid-period needs their hours closed early for the final payslip. v1 has no "freeze now" (v1-Q4 = B, 4.3).

- **A. Close now, per member.** A holder of `hours.approve` (or the member's foreman) closes one member's open period at a chosen last day; the period row ends that day, audited (FR-33). A manual early freeze for one member only.
- **B. No early close.** The leaver's last period freezes on the normal schedule (period end + grace); the final payslip waits up to one period.
- **C. Close on the leave date.** The office sets the member's leave date (the membership's `access_until`, rdb 0113, 072 A27); the sweep freezes that member's period at the leave date + grace, by itself. No new button.

**Status: DECIDED by the owner: C, close on the leave date** (HUM-10, t1 `a28dc5c9`, msg `8afdd796`, verbatim: "c"; relayed by the dispatcher c-002). The office sets the member's leave date (the existing membership end date, `access_until`); that member's period then freezes on the leave date plus the grace time, by itself. No new button; the date change is the audit line. It changes one later task, which the tasks round names.

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
| the foreman's people and default-hours UI (owner addendum to BN-14), the plan screen (BN-8) | FR-38 (v2 panel) |
| candidates: BN-9 | FR-39 (v2 panel) |
| candidates: U8 | FR-40 (v2 panel) |
| candidates: U3, U4, U6, U7, U9, U10, U12 | section 15 (ranked) |
| U11 | section 16, Q8 (decided: C) |

---

## 18. v2 panel and consensus

Folded by the editor (seat v2-claude, c-737) from four seats, each signed against the v2.0-draft at `9260921ef`. Lane dispatch `dispatch-a28dc5c9`.

| seat | agent | harness | review | verdict |
|---|---|---|---|---|
| v2-claude | c-737 | claude | [reviews/v2-claude.md](reviews/v2-claude.md) `6713c5858` | agree with changes: 8 agree, 16 change, 6 missing |
| v2-claude-2 | c-738 | claude | [reviews/v2-claude-2.md](reviews/v2-claude-2.md) `13cb156f3` | agree with changes: 3 agree, 21 change (V2C2-1..4), 5 missing |
| v2-agy | a-779 | agy | [reviews/v2-agy.md](reviews/v2-agy.md) `2cd70a4b4` | agree, all 24 FRs; nothing missing |
| v2-mistral | m-740 | mistral | [reviews/v2-mistral.md](reviews/v2-mistral.md) `c6a275921`, rewritten after the fold as `3a44d1d97` | agree, all 24 FRs; nothing missing (`3a44d1d97`) |

Guard (m- seats have clobbered whole files): `git show --stat` of each of the four commits lists only that seat's own review file (`c6a275921`: 1 file, +78, 0 deletions; the later rewrite `3a44d1d97`: the same file only), and `git log 9260921ef..c6a275921 -- spec.md` is empty, so the fold sits on the reviewed text.

### 18.1 Per FR

The seats in the order v2-claude / v2-claude-2 / v2-agy / v2-mistral. A seat that agreed with the draft did not address the edge a change fixes, so its agreement is not read as opposing that change (the business-needs 6.4 precedent). v2-mistral's first file (`c6a275921`) described other FRs from FR-17 on; its rewrite after the fold (`3a44d1d97`) matches the numbering, with the same verdict: agree with every FR, counted as written.

| FR | claude | claude-2 | agy | mistral | result |
|---|---|---|---|---|---|
| FR-14 | change | agree | agree | agree | **change** |
| FR-15 | change | change | agree | agree | **change** |
| FR-16 | change | change | agree | agree | **change** |
| FR-17 | change | change | agree | agree | **change** |
| FR-18 | agree | change | agree | agree | **change** |
| FR-19 | agree | agree | agree | agree | agree |
| FR-20 | change | change | agree | agree | **change** |
| FR-21 | change | change | agree | agree | **change** |
| FR-22 | change | change | agree | agree | **change** |
| FR-23 | change | change | agree | agree | **change** |
| FR-24 | change | change | agree | agree | **change** |
| FR-25 | change | change | agree | agree | **change** |
| FR-26 | agree | change | agree | agree | **change** |
| FR-27 | change | change | agree | agree | **change** |
| FR-28 | change | change | agree | agree | **change** |
| FR-29 | agree | change | agree | agree | **change** |
| FR-30 | agree | change | agree | agree | **change** |
| FR-31 | agree | change | agree | agree | **change** |
| FR-32 | change | change | agree | agree | **change** |
| FR-33 | change | change | agree | agree | **change** |
| FR-34 | agree | change | agree | agree | **change** |
| FR-35 | change | change | agree | agree | **change** |
| FR-36 | change | change | agree | agree | **change** |
| FR-37 | agree | agree | agree | agree | agree |

Result: **2 agree as drafted (FR-19, FR-37 with one wording change), 22 changed**, plus **FR-38..FR-40 added** (14.12) and the v2 acceptance (14.14). Every change was raised by one or both claude seats and opposed by none.

### 18.2 What v2.0 changed from v2.0-draft

| change | from | where |
|---|---|---|
| A no-activity Standard Day row is never auto-approved: it counts zero at the freeze unless tapped (no paid day without evidence) | V2C2-1; v2-claude (mark it) | FR-15, FR-23 |
| `kind` joins the `hours_entries` key; absence rows target `ws` | V2C2-2; v2-claude | FR-27, 14.13 |
| Rate categories stored per entry (`category_minutes`) at approval, before the prune; overtime across a period boundary set when the week's last day freezes; default threshold 5 x the organisation's day, `extra` for contract top-ups | V2C2-3; v2-claude | FR-28, FR-32 |
| Terminal: name or badge first, then the PIN; lock per member, rate limit per terminal, peppered hash; a terminal needs a network | V2C2-4; v2-claude | FR-25 |
| Standard day: a person's weekday pattern; the organisation's scalar applies forward; the day record keeps the value in force | v2-claude; `0` defined by v2-claude-2 | FR-14 |
| Plan repeat reads before the day, skips closed jobs and other crews; night shifts split at midnight; explicit vs inherited rows | both | FR-16, FR-29 |
| Chain: an entry beats it; part-day absences fill the rest; a clock-only day has a producer | both | FR-17 |
| `hours.rates` pinned to `time_accountant`, not grantable in the role editor; separation of duties; hours-only half built first | both | FR-20 |
| External seat: `access_until` (rdb 0113) required, read only, the calendar's hours panel full width, not a page | both | FR-21 |
| Crew: no self-approval; one second approval by either; crew at the freeze decides; correction wording vs 4.4 | both | FR-22 |
| Dispute: a disputed period goes to a workspace-wide approver; members without a login | both | FR-23 |
| Clock: device-time bounds, two-row days, a forgotten clock out, clock vs header timer | both | FR-24 |
| Break from the longest row, span after clock exceptions | v2-claude-2 | FR-26 |
| `sick` shown as "absent" to the foreman and the external seat; ranges skip frozen days; no leave requests | v2-claude-2 | FR-30 |
| Worker type set by the office only | v2-claude-2 | FR-31, FR-22 |
| Day record: written at approval, a source per field shown to the inspector | both | FR-32, FR-34 |
| Change log append-only in the database, the sweep as an actor | both | FR-33 |
| Member removal keeps hours rows; workspace deletion warns | v2-claude-2 | FR-34 |
| Offline: row versions on queued approvals, `sw.js` precache and IndexedDB, CI mock-bundle test | both | FR-35 |
| Nudge after the last planned shift; Approve week takes today's planned row once it ended; iOS home-screen step; the crew nudge covers U2 | both | FR-36 |
| Crew and Setup tabs (the owner's BN-14 addendum, the plan screen) | both (M1, M2; 3.1) | FR-38 |
| Payroll export: a line per category, a month file over weekly freezes | both (M4; 3.2) | FR-39 |
| U8 adjustment rows in v2 | both, v2-mistral (as a new FR) | FR-40, 15 |
| v2 acceptance per rule, perf budget | v2-claude-2 (3.3, 3.4) | 14.14 |
| BN-Q / v1-Q names; v1-Q2 = B stated | v2-claude-2; v2-claude (M6) | 14 |
| Q8 recorded as the owner's decision C | owner `8afdd796` | 16 |

### 18.3 Disagreements and how they were settled

1. **FR-15, a no-activity day: mark it (v2-claude) vs do not auto-approve it (v2-claude-2).** Under v1-Q2 = B a mark still pays a day nobody worked. Rule 2 does not need it (the IT person has activity). Settled: **not auto-approved, and marked**; v2-claude conceded.
2. **FR-28, the overtime default: the person's weekly pattern (v2-claude) vs 5 x the organisation's day with `extra` (v2-claude-2).** Contract top-up hours of a part-timer are not overtime in most payroll rules. Settled: **v2-claude-2's**; v2-claude conceded, its period-boundary rule kept.
3. **FR-20: not grantable (v2-claude) vs "by default only" (v2-claude-2).** Compatible: pinned to the role, and the biz owner may assign themself the role, logged. Folded both.
4. **FR-25, an offline terminal**: raised as a question by v2-claude only. Settled by the editor: a terminal needs a network in v2 (the phone carries offline, FR-35).
5. **Section 15 ranking.** BN-9 first: 3 seats (v2-mistral's first file ranked FRs; its rewrite puts U9 first and BN-9 second, and names U3, U4, U6, U7, U8, U10 and U12 as other items, e.g. "U6 (absence balances)", so its order is counted only for BN-9 and U9). **U8 into v2**: v2-claude, v2-claude-2 vs v2-agy (v2.1): 2 to 1. **U9**: v2 (v2-claude, v2-mistral) vs v2.1 (v2-claude-2, v2-agy): 2 to 2, settled **v2.1**, the draft's position, since the warnings need recorded times; v2-claude conceded. U3, U6, U7 in v2, U10 later, U4 and U12 out: no seat against.
6. **v2-mistral's first file listed U4, U6..U10 as missing**: they are section 15's candidates, now ranked, and its rewrite says nothing is missing. U8 became FR-40.
7. **Q8 (U11)**: all four seats recommend C (v2-mistral's first file described a manual close with an audit log, option A's mechanism; its rewrite states C plainly). The owner decided **C** (msg `8afdd796`); section 16 states the decision in the owner's terms.

### 18.4 Open owner questions

None in 107 v2: Q8 is decided (C). One question that bears on 107 is the owner's in spec 118: **118 Q1** (msg `5b14c79c`), whether 107 keeps start and end times per entry (`hours_entry_spans`). FR-28's `category_minutes` stands until it is answered (V2C2-3 is the same question). It is referenced here, not asked again.

### 18.5 Signatures on v2.0

Each seat signs the v2.0 sha below on the same lane.

| seat | signed v2.0 | message |
|---|---|---|
| v2-claude (editor) | `964931bdb` | the fold commit |
| v2-claude-2 | not signed: c-738 retired at 08:44Z, before the fold; its review is signed against `9260921ef`, and all four of its findings (V2C2-1..4) are folded | |
| v2-agy | pending: asked on `dispatch-a28dc5c9` at 08:50Z, no reply by 09:25Z | |
| v2-mistral | `964931bdb` | m-740, msg `9a839d50` |

---

## 19. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-10-07 | c-522 (s107-1) | first draft: definition of time worked, signals measured on `aa7523ea`, worker approval, freeze, biz-owner approval, CSV/XLSX, calendar and issue v1/later, owner questions Q1..Q5 |
| 1.0 | 2026-10-07 | c-522 (s107-1) | fold of reviews s107-2, s107-3, s107-4 (section 12.2); unanimous consensus recorded; owner Q1..Q7; `tasks.md` |
| 1.1 | 2026-10-08 | c-566 | owner Q7 = B recorded (13.1): the header timer, 1.5, 5.3, 11; task T019 |
| 1.2 | 2026-10-08 | c-713 | owner R8..R11 (t1 `a28dc5c9`, 13.2): discussion links with a note per line (5.2); the calendar's right-side hours tabs Mine / Team / Download, a sheet on the phone (5.4); no rail entry, no page; a Working hours line on every working day in the calendar opens the event dialog of type Working hours (5, 7, 9, 10, 11); T010 dropped, T011 rewritten, T013..T015 inside the dialog |
| 2.0-draft | 2026-10-10 | c-734 | the business-needs gaps (business-needs.md 6.6, consensus `2c6c36732`): FR-14..FR-37 in section 14 (standard day per organisation and person, the prefill chain from the shift plan, jobs and quotes, no money in hours tracking, the time-accountant role and the external accountant seat, crew scope, foreman entry with Dispute, clock exceptions and the shared terminal, breaks, travel and waiting, derived rate categories, holidays, absences, worker type, start and end times, the change log, retention, offline approval, the nudge, hours per workspace); candidates ranked (15); U11 as open owner Q8 (16); the 6.6 map (17); for the v2 review panel |
| 2.0 | 2026-10-10 | c-737 (v2-claude, editor) | fold of the v2 panel, four seats (section 18): 22 FRs changed (V2C2-1..4: evidence-only auto-approval, `kind` in the entry key, categories stored before the prune, terminal identity), FR-38 Crew and Setup tabs, FR-39 payroll export, FR-40 adjustment rows, v2 acceptance (14.14); section 15 re-ranked (U8 into v2); owner Q8 = C recorded (16) |
| 2.1 | 2026-10-10 | c-837 | owner principle **P0** (msgs `4d6d200c`, `4fd07875`, t1 `6571d5ed`) at the top of section 0; owner rows R12 (`4842ca88`) and R13 (`82efd47b`); FR-01..FR-40 and sections 1..6, 14..17 read against P0, the points that push toward exact tracing listed as owner questions Q9..Q22, and Q23..Q25 (timer placement, keyword-only rows, UI direction) in section 20; no FR text changed |
| 2.1 (fold) | 2026-10-10 | c-837 | owner answer to Q25 (msg `e91fe1b5`): UI directions 1 (Day sketch) and 3 (From what you did); Q9..Q24 still open |
| 2.2 | 2026-10-10 | a-899 | owner answers Q9..Q25 (msgs 8c9b7b56..b04b30bf) folded into sections 1..6, 14..17 and FRs; Q25 includes 4 as extra |

---

## 20. P0 review and the 2026-10-10 owner questions (Q9..Q25)

FR-01..FR-40 and the design sections (1 signals and rounding, 1.7 privacy, 2 suggestions, 3 data, 4 approvals and the freeze, 5 and 6 screens and reports, 14..17) read against P0 (section 0, msgs `4d6d200c`, `4fd07875`). **Nothing here changes an FR yet**: each line names the point, why it reaches past "directional guidelines on where the time is spent", and the recommendation that fits P0. The numbering continues the spec's owner questions (v1 Q1..Q7 in section 13, Q8 in section 16). **A** = the recommendation, **B** = keep the text as written. Answers are folded only when the dispatcher forwards them (`dispatch-6571d5ed`).

### 20.1 What pushes toward exact tracing (Q9..Q22)

| # | cites | pushes toward exact tracing | recommendation that fits P0 (A) |
|---|---|---|---|
| Q9 | 1.6, FR-01, 3.2 `hours_entries.minutes` | **Minute precision**: "Minutes are stored exactly ... No rounding in v1"; suggestions, entries and the Working hours line all show `h:mm` to the minute. | Suggest and show in **quarter hours** (a 098 key `hours.round_minutes`, default `15`); the member may still type any value. A direction needs 0:15 steps, not 0:01. |
| Q10 | 1.1, FR-01, 1.3 | **The minute as the unit of truth**: each wall-clock minute gets one target, deduplicated across tabs and devices, the 3-minute floor, a worked example to the minute. | Keep the minute only as the internal tick; define "time worked" for the member as **a rough split of the day across a few targets**, without the per-minute rules. |
| Q11 | 1.2, FR-02, v1-Q1 | **Reading surveillance**: the WUI records, minute by minute, which topic, channel or DM was open in a focused tab with recent input. | Keep tab minutes but **aggregate on the device** to (day, target) totals before sending; the hub never receives a per-minute sequence of what was open. (Or v1-Q1 = B: no tab minutes at all.) |
| Q12 | 3.2 `hours_minutes`, FR-02, FR-10 | **A per-minute row per person**: PK `(tenant_id, member_id, minute)`, ~500 rows per member per busy day, each with target, source and zone: a timeline of the person's day. | Replace it with a **per (member, day, target) counter** that the post upsert and the tab batch add to; precedence (1.3) is applied per batch. The table stops being a timeline. |
| Q13 | 1.3, FR-03 | **Per-person detail of whom**: a DM target `dm:<peer>` names the person talked to; every channel and topic is its own target. | Fold DMs into **"other"** (`ws`), never `dm:<peer>`; keep topics, issues, jobs and meetings: they are "where the time is spent". |
| Q14 | 1.7, FR-08 | **Raw-signal retention**: raw minutes kept until the period freezes, up to 45 days. | Prune a day's raw signals **when the day is approved, at the latest 2 days after it closes**; the entries carry the direction. |
| Q15 | 5.2 ("why" sheet, description blocks `09:12-10:40`), FR-11 | **Exact time-of-day intervals** per target and per discussion. | Show each line's **total only** (and the discussion links, R10); no block start and end times. |
| Q16 | 2.3, FR-04, 4.1 | **Minute deltas**: "+0:20 since you approved" for any change after an approval. | Show a delta only when it reaches the rounding step (Q9, 15 min). |
| Q17 | 3.2 `suggested_minutes`, 6.2 columns, FR-09 | **The worker measured against the machine**: every exported line carries `suggested_minutes`; reports flag "edited". | Keep `suggested_minutes` in the worker's own view only; **drop it from the Team view and the download**, no "edited" flag. |
| Q18 | 5.4 Team, 6.2 ("one line per approved entry", group by day), FR-09 | **A per-person per-day grid** as the default report. | Default report = **per period, per target (job, issue, topic), summed over people**; the per-member and per-day views stay one click away for approval; day lines in the download on request. |
| Q19 | FR-28, FR-32 (an activity day's start and end "from its first and last active minute, take start and end from the plan, else the standard day estimate, never from activity") | **Activity timestamps kept for years** in the day record and the categories. | For an activity day take start and end from the plan, else `hours.day_start` + the standard day (FR-32's estimate), **never from activity**; first and last active minute are not stored. |
| Q20 | FR-24, FR-25, FR-32, section 15 U9 | **Clocked times to the minute**: server time, device-time bounds, a skew flag, terminal actions with ids, U9 warnings from recorded times. | Keep the clock as the exception FR-24 makes it, and record clocked times only in a workspace whose law requires recorded working time (a 098 switch, off by default); U9 follows that switch. |
| Q21 | FR-33, FR-25 | **A per-action audit**: every write to an entry, day record, plan row, standard day and every terminal action writes a before/after row, the sweep included. | Log what payroll and trust need: **changes after the worker's approval, returns, role and rate events, downloads**; a worker's own edits before approval and the sweep's routine writes are not logged. |
| Q22 | FR-34 | **Five-year retention of the full trail**: day records, entries, period rows and the change log for `hours.retention_years` (default `5`). | Keep the **approved period totals per target** for the retention years; day records and the change log only as long as the workspace's law requires (a companion key, default the period plus one year). |

Read and found to fit P0 (no question): the prefill chain and the Standard Day (FR-14..FR-17: directional suggestions), meetings as accepted spans (1.4, FR-13), jobs and quotes (FR-18), no money in hours (FR-19, FR-20), the external seat (FR-21), crew approval and Dispute (FR-22, FR-23), breaks, travel, holidays and absences as day-level rows (FR-26, FR-27, FR-29, FR-30), worker type (FR-31), offline approval and the nudge (FR-35, FR-36), per-workspace hours (FR-37), the Crew and Setup tabs (FR-38), the payroll export and adjustments (FR-39, FR-40: payroll needs day lines), and the header timer's privacy (1.5: on the device until stopped; its placement is Q23).

### 20.2 Keywords, the timer and the UI direction (R12, R13; Q23..Q25)

These mirror the questions the dispatcher c-002 already put to the owner on `dispatch-6571d5ed`; the dispatcher forwards the answers.

| # | cites | question | A | B | C | recommendation |
|---|---|---|---|---|---|---|
| Q23 | R12, 1.5, 5.3, T019 | Where does the start/stop timer live? | **move it into the calendar**: the Hours tab (5.4) and the day's Working hours dialog (5.2) | both: the calendar and the app header | the app header only (as built, owner v1-Q7 = B) | **A** |
| Q24 | R12, 5.3 (`HoursTargetPicker.vue`), 1.3 targets | A keyword typed while filling the day that matches no issue or topic | **a keyword-only row**: the keyword is kept as the row's label on "other" (`ws`), countable in reports by keyword | no keyword-only rows: the member must pick an issue, topic, channel or job, else the time goes to "other" unlabelled | | **A** (P0: a direction by keyword is enough) |
| Q25 | R13, 5.1, 5.2 | Which UI direction: (1) **Day sketch**: keyword chips in the Working hours line, split by the day's trail, a slider per chip, one Approve; (2) **Paint the calendar**; (3) **From what you did**: prefilled from posts, issues and meetings; (4) **`/hours` in chat** (dispatcher's answer, msg `602daf86`) | 1 + 3, with 4 as a cheap extra | one of 1..4 alone | | **1 + 3, 4 extra** |

**Q9..Q25 decided by the owner** (HUM-10, t1 `6571d5ed`):
- **Q9**: **A** (msg `8c9b7b56`)
- **Q10**: **A** (owner typed "Q. Then, yes", msg `164b1b4a`)
- **Q11**: **A**, only if no performance problem (msg `543cf537`)
- **Q12**: **A**, only if no performance problem (msg `d7f2bbdb`)
- **Q13, Q14**: **A** (msgs `21a5ed18`, `f14c1cac`)
- **Q15**: **A**: each line shows the duration only, no clock times (msg `b04b30bf`)
- **Q16**: **A** (msg `6b245e1c`)
- **Q17, Q18**: **A** (msgs `d99485c4`, `73a7728e`)
- **Q19**: **A** (msg `058d9d38`)
- **Q20, Q21**: **A** (msgs `667ddccf`, `c09896ec`)
- **Q22**: **A** (owner typed "Good 22"; retention = approved period totals per target only, day records + change log only as long as the law requires: a second setting, default period + 1 year, msg `9041739b`)
- **Q23**: **A**: move the timer into the calendar (Hours tab + the day's Working hours dialog), out of the app header (msg `b04b30bf`)
- **Q24**: **A**: an unmatched keyword stays the row's label under "other", countable by keyword in reports (msg `b04b30bf`)
- **Q25**: **A**: UI directions 1 (Day sketch) + 3 (From what you did), with 4 (`/hours` in chat) as a cheap extra (msg `b04b30bf`; v2.1 had folded 1+3 from msg `e91fe1b5`).
****

<!-- version: 2.0.0 · updated: 2026-10-10 -->
