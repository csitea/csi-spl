# 107 Hours tracking: suggested, approved, frozen

**Feature ID**: `107-hours-tracking` · **Milestone**: M3 · **Status**: v0.1 draft (seat s107-1), awaiting reviews s107-2..4
**Created**: 2026-10-07 · **Drafter / folder**: c-522 (seat s107-1) · **Topic**: t1 `ef217164-daaa-43bb-8343-f55ddb2f53a8` · lane dispatch `dispatch-ef217164`
**Authority**: this file for behaviour; `tasks.md` (written at the v1.0 fold) for what is built. Docs only: this spec builds nothing (`../README.md` §2.4). Status vocabulary: `../README.md` §2.3; every FR below is **Planned**.

Builds on, and does not change:
- [089 the Calendar section](../089-calendar-section/spec.md), [097 full editing](../097-calendar-full-editing/spec.md), [106 the phone calendar](../106-calendar-phone-rewrite/spec.md): read-only source of meetings (section 7).
- [039 issues](../039-spool-issues/spec.md): an issue's discussion is an ordinary topic on `issues.task_id` (section 8).
- [025 tenant RBAC](../025-spool-tenant-rbac/spec.md): roles and permissions; two new permissions (section 6).
- [098 tenant settings jsonb](../098-tenant-settings-jsonb/spec.md): the workspace's hours settings.
- [043 mobile WUI](../043-spool-wui-mobile/spec.md): the phone stack (level 1/2/3, Back).
- [027 performance](../027-spool-performance/spec.md): the 155 KB initial chunk; the Hours page loads lazily.

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
| R7 | `e7197854` | "biz owners should be able to approve the hours and download them in csv , xls etc." | 4.3, 6 |

R4 and R7 are requirements, not options: hours are **prefilled** from suggestions, the **worker approves** them, a **freeze** locks a period (**weekly by default, configurable**), the **biz owner approves** them a second time and **downloads** them as CSV and XLSX.

---

## 1. What "time worked" means (R3a, settled first)

### 1.1 The definition

> **Time worked on a day = the member's active minutes in the workspace, joined into blocks, plus the meetings they attended. It is a suggestion until the member approves it.**

1. **An active minute** is a wall-clock minute in which the member did at least one *counted action* (1.2) in this workspace.
2. **A block** joins active minutes whose gap is **at most N minutes** (N = the idle cutoff, default **10**). The bridged gap counts as worked: it is the reading and thinking between two actions.
3. **A gap longer than N ends the block.** Nothing of that gap counts, and the block gets no "idle tail": it ends at the end of its last active minute.
4. **A lone active minute** (no neighbour within N) is a 1-minute block. Blocks shorter than **3 minutes** are dropped from suggestions (a glance at the phone is not work).
5. **Each minute belongs to exactly one target** (1.3). A minute is never counted twice, also not across two tabs or two devices: the minute is the unit, not the device.
6. **The result is a suggestion.** Nothing counts until the member approves it (section 4).

Worked example (N = 10): posts at 09:00, 09:04; reading 09:05..09:20; nothing until 09:45; a post at 09:46. Blocks: 09:00..09:21 (21 min, the 09:00..09:04 gap is bridged) and 09:46..09:47 (1 min, under the floor, dropped). Suggested: 0:21.

### 1.2 Counted actions: which signals exist today, and which are reliable

Measured on trunk `aa7523ea` (2026-10-07); each line cites how.

| signal | stored today? | reliable for a past day? | in v1 |
|---|---|---|---|
| **posts and replies** (`messages`: `from_box = box-wui`, `from_id` = HUM-*, `ts`, `task_id`, `channel`) | yes, durable; index `messages_from (tenant_id, from_box, from_id, ts)` (rdb 0001) | **yes**, while the row lives: retention default 720 h (`grep -n 720 internal/store/retention.go` -> `CommittedRetention = 720 * time.Hour`) | **counted** |
| **message edits, reactions** (`edited_at`, rdb 0026; `message_reactions.created_at`, rdb 0037) | yes, durable | yes | **counted** |
| **issue field edits** (`issues.updated_by/updated_at`, rdb 0047) | only the LAST edit per issue, no history | no | not counted (8, I3) |
| **reading** (`read_marks.updated_at`, rdb 0098) | one row per (member, key), **overwritten** on every sync (`PRIMARY KEY (tenant_id, member_id, mark_key)`) | **no**: the past is gone | not usable as-is |
| **online / presence** (`humanOnline`, `internal/hub/channels.go:399`) | **in memory**, per hub instance, never written | **no** | not usable |
| **typing** | no hub signal (`grep -rli typing internal/hub/*.go \| grep -v _test \| wc -l` -> 0) | no | not usable |
| **sign-in / sign-out** (`member_activity`, rdb 0091) | yes, durable | a session, not work | not counted |
| **calendar events** (`calendar_events` + `calendar_guests.response`, rdb 0125/0139) | yes, durable | yes, but it is the *plan*, not the work | **counted as meetings** (1.4) |

So today the hub can prove *what you wrote*, not *what you read*, and reading is most of the work in a chat tool. That gap is closed by **one** new, small signal:

- **Active-tab minute (new, v1).** While a WUI tab is **visible** and the member gave **input** (key, pointer, touch, scroll) in the last 60 s, the WUI records the minute and the target that was open. It sends the list in one small batch every 5 min and when the tab is hidden (the moments read-sync already pushes, `utils/read-sync.mjs`). A background tab, a locked phone, a tab left open overnight: **no input -> no minute**.

Owner question Q1 (section 13) is whether to collect it at all.

### 1.3 Which target a minute goes to

| the minute had | target |
|---|---|
| a post, edit or reaction | that message's topic `t:<task_id>` |
| an active-tab minute | what was open: a topic `t:<task_id>`, an issue (= its topic, section 8), a channel `ch:<name>`, a DM `dm:<peer>`; anything else (settings, lists, the calendar page) is `ws` (the workspace) |
| both, different targets | the post wins (the stronger proof) |
| a bridged gap minute | the target of the minute before the gap |

A day's suggestions are **one row per target**, sorted by minutes. Targets under 5 minutes in the day fold into one `ws` row ("other"), so a day is 3..6 rows, not 40.

### 1.4 Meetings (calendar)

A timed (not all-day), `confirmed` calendar event of this workspace where the member is the **creator or a guest who answered `yes`** suggests its own row: target `cal:<event_id>`, minutes = the event's length. Active minutes inside the event's span go to the meeting, not to a topic (no double count). An event whose `topic_id` is set suggests against that topic instead. Not counted: all-day, `cancelled`, a guest answer of `no`, `maybe` or none.

### 1.5 Time outside the app

Calls, an editor, a whiteboard: the hub cannot see them and v1 **does not guess**. The member adds them, without a form:
- **Extend** a suggested row by one tap: `+15`.
- **Add** a row (5.3): pick a target, set minutes.

### 1.6 Day, time zone, rounding

- A **day** is the member's local day in the browser's time zone (sent with each batch). A block over midnight splits at midnight.
- **Minutes are stored exactly**; the UI shows `h:mm`. Rounding (15 min) is an export option, never a stored value.

### 1.7 Privacy of raw signals

- Active minutes and blocks are visible **only to the member** ("why this number": tap a row, see `09:12-10:40`).
- **Nobody else** reads them: not a biz owner, not an admin, not an operator view in the WUI. Others see only **approved** entries (section 6).
- Raw minutes are deleted **when their period freezes**, and in any case after 45 days. The entries stay.

---

## 2. Suggestions: how a day is prefilled (R3, R4)

1. The hub computes a (member, day)'s suggestions **on read**, from 1.2's signals: no job, no cache table; one indexed read each for posts (`messages_from`), minutes (the new table's primary key) and events (the calendar range index).
2. Once the member approves, edits or rejects a row, it is **an entry** (3.2) and replaces the suggestion for that (day, target). Activity later that day shows as a **delta** on the row ("+0:20 since you approved"); an approved number never changes silently.
3. **Prefilled** means the Hours page opens with every day of the period filled; the member never starts from an empty grid.

---

## 3. Data: what is new and why (R1)

### 3.1 Reused

| need | reused |
|---|---|
| posts, edits, reactions | `messages`, `message_reactions` (read only) |
| meetings | `calendar_events`, `calendar_guests` (read only) |
| issues | `issues.task_id`, key and title (read only) |
| workspace settings | `tenants.settings` jsonb, key `hours` (098) |
| who sees whose hours | RBAC (rdb 0021, `internal/rbac/rbac.go` `Defaults`): two new permission rows |
| audit of a return or an unfreeze | `member_activity` kinds `hours.return`, `hours.unfreeze` (rdb 0091) |
| names of topics, issues, channels, members | the existing view, issue and roster reads |
| reminder | the existing pop-up path |

### 3.2 New: three tables, each FORCE RLS

All three in the 0098 shape: `tenant_id` first, `ENABLE` + `FORCE ROW LEVEL SECURITY`, `tenant_scope` with the `NULLIF(current_setting('app.tenant_id', true), '')` guard, `operator_scope`. One migration, next free number.

**`hours_minutes`**: the new signal (1.2). Justified: without it reading counts zero.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | HUM-* |
| `minute` | timestamptz | truncated to the minute |
| `target` | text | `t:` / `ch:` / `dm:` / `ws`, CHECK like `read_marks.mark_key` |
| `tz` | text | IANA zone the browser sent |

PK `(tenant_id, member_id, minute)`: two tabs or devices write the same row (the first target wins). A busy day is ~500 rows per member; pruned at freeze and at 45 days.

**`hours_entries`**: what the worker decided. Justified: approval needs state.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `entry_id` | uuid | PK with tenant |
| `member_id` | text | HUM-* |
| `day` | date | the member's local day |
| `target` | text | 1.3 targets plus `cal:<event_id>` |
| `minutes` | integer | 0..1440 |
| `suggested_minutes` | integer | what the system proposed (0 for an added row); reports show "edited" |
| `state` | text | `approved` or `rejected` |
| `note` | text | optional, <= 500 |
| `updated_at`, `updated_by` | | |

Unique `(tenant_id, member_id, day, target)`; a day's total is refused above 1440 minutes.

**`hours_signoffs`**: the biz owner's decision per member and period (4.3). Justified: the second approval needs state, and it is per member, not per row.

| column | type | note |
|---|---|---|
| `tenant_id` | text | FK tenants, cascade |
| `member_id` | text | whose hours |
| `period_start`, `period_end` | date | the frozen period |
| `state` | text | `approved` or `returned` |
| `minutes` | integer | the total that was approved (a later change shows as a difference) |
| `note` | text | required for `returned` |
| `decided_by`, `decided_at` | | the biz owner |

PK `(tenant_id, member_id, period_start)`.

**Not new**: no periods table. The freeze is a **watermark**, `tenants.settings.hours.frozen_through` (a date): every day `<=` it is frozen (4.2).

---

## 4. Two approvals and the freeze (R4, R7)

The life of a member's period:

```
 open (prefilled) ──worker approves rows──► open ──freeze──► frozen ──biz owner──► signed off
                                                               │                     (final)
                                                               └── biz owner returns ─► reopened for that member
                                                                    (note)               │ worker fixes, approves
                                                                                         └──► frozen again
```

### 4.1 First approval: the worker

- **Approve a day**: one tap writes an `approved` entry for each suggested row of that day.
- **Approve the period**: one tap approves every day of the visible period that still has open suggestions.
- **Edit**: change minutes (stepper ±15, or type), change the target, add a note: the row is `approved` with the new number.
- **Reject**: the row becomes `rejected` (counts 0); Undo for 10 s, and changeable until the freeze.
- Everything stays editable **until the freeze**.

### 4.2 The period and the freeze

| setting (`tenants.settings.hours`) | default | who sets it |
|---|---|---|
| `period` | `week` (Mon..Sun) | `tenant.settings` (biz owner, admin) |
| allowed values | `week`, `two_weeks`, `month` | |
| `freeze_grace_days` | `2` (a week freezes Wednesday 00:00) | same |
| `idle_minutes` (N, 1.1) | `10`, range 5..30 | same |
| `tz` | the workspace time zone, for the freeze moment | same |
| `frozen_through` | moved forward by the hub | the hub; moved back only by unfreeze (4.4) |

- **The freeze is automatic**: at `period end + freeze_grace_days`, the hub's existing sweep moves `frozen_through` to the period's last day. "Freeze now" (`tenant.settings`) does the same early.
- **After the freeze** the worker cannot change the period. It now waits for the biz owner.
- **Unapproved suggestions at the freeze** count **zero** and disappear (owner question Q2: A zero, B auto-approved).
- **Changing `period`** takes effect from the next period that is not frozen; a frozen period keeps its bounds.
- **Reminder**: one pop-up the day before a freeze, to members with open suggestions in it ("2 days not approved, freezes tomorrow").
- The calendar's `kind = 'freeze'` (a deploy freeze, rdb 0125) is a different thing; the hours freeze never writes a calendar event.

### 4.3 Second approval: the biz owner (R7)

- The biz owner approves **frozen** periods, per member: the Team tab (5.4) lists each member's frozen, not-yet-signed-off period with its total.
- **Approve** (one tap per member, or **Approve all** for the period): writes an `approved` signoff. The period is now **final** for that member.
- **Return** (with a required note): writes a `returned` signoff and **reopens that member's period for that member only**, despite the watermark. The worker sees the note on top of the period, fixes, and approves again ("Resubmit"); the period is then frozen again for them and back in the biz owner's list. A `member_activity` row `hours.return` records it.
- The biz owner never edits a worker's minutes: they approve or return. This keeps "the worker approves their hours" true.
- Before the freeze the biz owner sees the worker's approved rows (to watch progress) but cannot sign off.

### 4.4 Unfreeze

Rarely needed now that a return reopens one member. A holder of `tenant.settings` can still move `frozen_through` back for the whole workspace (a wrong period setting, a mass correction), with a reason; it writes `member_activity` `hours.unfreeze` and voids the signoffs of the reopened period. Owner question Q4.

---

## 5. Screens: one page, phone and desktop (R2)

### 5.1 Where

One new rail item **Hours** (`/hours`), placed by the existing rail order (rdb 0133). Justified: approving needs a place, and putting it in the calendar page would change 089/106 files, which this spec must not. The page loads lazily (027).

### 5.2 Mine (the default tab)

```
 Hours                         Week 41  < >      [Approve week]
 ─────────────────────────────────────────────────────────────
 Mon 6 Oct     6:40 suggested                    [Approve day]
   <PREFIX>-212 Calendar phone rewrite  2:10   +15  ✕
   #<channel>                           1:35   +15  ✕
   Meeting: weekly sync                 1:00   +15  ✕
   other                                0:55   +15  ✕
 Tue 7 Oct     5:15  ✓ approved
 ...
 Week  31:05 suggested · 18:20 approved · freezes Wed 15 Oct
```

- **Common case, desktop**: open Hours -> **Approve week**: 2 clicks.
- **Common case, phone**: tap Hours in the rail -> **Approve day** on today's card: 2 taps. Day cards stack newest first; **Approve week** is the sticky bottom button.
- A row's number opens the stepper in place; the row's name opens the "why" sheet (1.7).
- Frozen days carry a lock and no buttons; a signed-off period says "Final"; a returned one shows the biz owner's note and **Resubmit**.
- No horizontal scroll on the phone (the 106 rule); controls 44..48 px.

### 5.3 Add a row

`+ Add` under a day: a target picker (recent topics, issues, channels first; search) and a minutes stepper (default 0:30). Two taps plus the pick. This is also the answer to "timer": **no timer in v1**; in-app time is measured, off-app time is added or extended (1.5).

### 5.4 Team (holders of `hours.read`)

Members x days of the period, approved minutes per cell, totals per row and column, a per-target breakdown on tap. Each member row carries the period state (open / frozen / returned / final) and, for a holder of `hours.approve`, **Approve** and **Return**; the header has **Approve all**. Filters: member, target type, issue, epic. **Download**: CSV or XLSX (6.2).

---

## 6. Who sees what, reports, download (R7)

### 6.1 Visibility

| who | sees | can |
|---|---|---|
| the member | own suggestions, raw minutes, entries, signoffs | approve, edit, reject, add, resubmit |
| **`hours.read`** (new; default `biz_owner`) | every member's **approved** entries and signoff states | Team view, download |
| **`hours.approve`** (new; default `biz_owner`) | as `hours.read` | approve or return a frozen period |
| `tenant.settings` (biz owner, admin) | | set period, grace, N; freeze now; unfreeze |
| everyone else | nothing of others | |

Admins and product owners get neither new permission by default (owner question Q5); a biz owner can grant them through the existing role editor. No one but the member sees raw minutes or unapproved suggestions. Tenant isolation is RLS with FORCE (3.2); a cross-workspace test is part of the store task.

### 6.2 Reports and download

- A period, or any from..to range; grouped by member, target (topic / issue / channel / meeting / other) or day.
- **CSV** and **XLSX**, the same columns, one line per approved entry: `date, member_id, member_name, target_type, target_id, target_name, issue_key, minutes, hours_decimal, suggested_minutes, note, period_state, signed_off_by, signed_off_at`. XLSX adds a total row and a second sheet with totals per member.
- Options: **final only** (signed-off periods; the default), and **round to 15 min** per line.
- XLSX is written by the hub with Go's standard `archive/zip` and `encoding/xml` (a one-sheet OOXML file is a small zip): no new dependency. Other formats (ODS, PDF) are **not in v1**: XLSX opens in every spreadsheet program.
- Rejected rows and open suggestions never appear.

### 6.3 Routes (new; existing auth and `X-Spool-Tenant`)

| route | who | what |
|---|---|---|
| `PUT /v1/me/hours/minutes` | member | the WUI's active-minute batch (<= 60 rows) |
| `GET /v1/me/hours?from=&to=` | member | days with suggestions, entries, freeze and signoff state |
| `PUT /v1/me/hours` | member | approve / edit / reject / add / resubmit, a batch; a frozen day is 409 `period_frozen` (unless returned) |
| `GET /v1/hours?from=&to=&member=&target=` | `hours.read` | approved entries and signoffs |
| `GET /v1/hours/export?from=&to=&format=csv\|xlsx&final=&round=` | `hours.read` | the download |
| `PUT /v1/hours/signoffs` | `hours.approve` | approve or return members' frozen periods, a batch |
| `POST /v1/hours/freeze` | `tenant.settings` | freeze now / unfreeze (reason) |

Settings are written through the existing tenant settings route (098).

---

## 7. Calendar (R5): v1 and later

**v1** (reads only; no 089/097/106 file changes):
- Meetings become suggestions (1.4).
- An entry with target `cal:<event_id>` shows the event's title in Hours and the download.

**Later** (hooks the calendar would need; later tasks for a calendar lane):
- **C1** an Hours lane in the desktop Day / Week view (089 / 097): approved hours per day, read from `GET /v1/me/hours`.
- **C2** the same lane in the phone Day view (106 `CalendarPhone*`).
- **C3** "Log this" in the event pop-over / peek: one tap approves the meeting's suggestion.
- **C4** the freeze date as a month-view marker (not a calendar event).

---

## 8. Issues (R6): v1 and later

An issue's discussion is a topic on `issues.task_id` (`internal/store/issues.go`: "The discussion is an ordinary topic on the issue's task_id"). So:

**v1** (no issue code change):
- Hours on an issue = hours on its topic: posts in it and active minutes with the issue open are suggested against it.
- Hours and the download show the issue key and title for a target whose topic is an issue's.
- `+ Add` picks an issue by key or title.
- The Team tab filters and groups by issue and by epic (the issue's level-1 parent).

**Later** (hooks for an issues lane):
- **I1** the issue's right pane shows "Booked 12:30" (approved entries on its topic), from `GET /v1/hours?target=t:<task_id>`.
- **I2** booked hours next to the `level` estimate on the issue list.
- **I3** issue field edits as activity: needs an issue-history table first (`issues` keeps only the last edit).

---

## 9. Requirements

| id | requirement | status |
|---|---|---|
| FR-01 | Active minutes and blocks (1.1): N from settings, 3-min floor | Planned |
| FR-02 | Signals of 1.2: posts, edits, reactions, active-tab minutes, meetings | Planned |
| FR-03 | One target per minute (1.3); small targets fold to "other" | Planned |
| FR-04 | Suggestions on read; approved rows never change silently (2) | Planned |
| FR-05 | Worker: approve day / period in one tap; edit, reject, add (4.1, 5.3) | Planned |
| FR-06 | Period, automatic freeze, grace, freeze now, unfreeze with audit (4.2, 4.4) | Planned |
| FR-07 | Biz owner: approve or return a frozen member period; return reopens that member only (4.3) | Planned |
| FR-08 | Raw minutes visible only to the member; pruned at freeze / 45 days (1.7) | Planned |
| FR-09 | `hours.read`, `hours.approve`; Team view; CSV and XLSX (6) | Planned |
| FR-10 | Three tables FORCE RLS; cross-tenant test (3.2, 6.1) | Planned |
| FR-11 | Phone: 2 taps for the common case, no sideways scroll, 44..48 px controls (5.2) | Planned |
| FR-12 | Meetings suggested (7 v1); issues via their topics (8 v1) | Planned |

**Acceptance**: a seeded member with posts, active minutes and a meeting on Monday opens Hours at 390 px and at 1440 px and sees Monday prefilled with the fixture's rows; approves the week in 2 taps; after the freeze sweep the week is read-only and its open suggestions are gone; the biz owner returns it with a note, the member resubmits, the biz owner approves; the biz owner's CSV and XLSX hold exactly the approved lines with `period_state = final`; a second workspace's biz owner reads none of them.

---

## 10. Phone and desktop

One page, two layouts at 820 px (043). Desktop: the period as day cards (Mine) and a grid (Team). Phone: the same cards in the mobile stack (level 2), Back returns to the rail; the Team grid becomes one card per member with its total and Approve / Return.

---

## 11. Not in v1

- A start/stop **timer**.
- **Money**: rates, invoices, overtime, leave and holidays.
- **Agents' hours** (roster ids), box or agent runtime as cost.
- The biz owner editing a worker's minutes (approve or return only).
- Cross-workspace totals for a member in several workspaces.
- ODS, PDF or other formats beyond CSV and XLSX; e-mail delivery of exports; e-mail reminders.
- Calendar hooks C1..C4, issue hooks I1..I3.
- Activity outside the WUI (the `spool` CLI, git, an editor).
- Editing raw minutes (the member edits entries, not signals).

---

## 12. Panel (R0)

Seats: s107-1 c-522 (claude, drafter and folder), s107-2 (agy), s107-3 (claude), s107-4 (claude). Each review lands as `reviews/s107-N.md` beside this file; v1.0 folds them here with what was agreed, what changed, and what is left for the owner.

Questions for the reviewers, besides anything they find:
1. Is the active-tab minute (1.2) the right single new signal, and "input in the last 60 s" the right test?
2. N = 10 and the 3-minute floor: right defaults?
3. Is "return reopens that member only" (4.3) simpler than a workspace unfreeze, and does it keep the freeze meaningful?
4. Is a rail item + one page the smallest UI, or can Hours live inside an existing page without touching 089/106?
5. Three tables: can any be dropped (e.g. signoffs into `tenants.settings`, or entries carrying the signoff)?

---

## 13. Questions for the owner (A/B, recommendation first)

| # | question | A (recommended) | B |
|---|---|---|---|
| Q1 | Collect the active-tab minute? | **A**: yes, visible tab + input; reading counts | B: no new tracking; suggestions from posts and meetings only (reading counts zero, numbers come out low) |
| Q2 | Suggestions the worker did not approve by the freeze | **A**: count zero ("nothing counts until accepted") | B: auto-approved at the freeze |
| Q3 | Idle cutoff N | **A**: one value per workspace (default 10 min) | B: each member sets their own |
| Q4 | Workspace-wide unfreeze | **A**: biz owner / admin, with a reason in the audit log; per-member corrections go through Return | B: none; Return is the only way back |
| Q5 | Who sees and approves team hours | **A**: biz owner only by default, grantable to other roles | B: biz owner and admin by default |

---

## 14. Version log

| version | date | by | what |
|---|---|---|---|
| 0.1 | 2026-10-07 | c-522 (s107-1) | first draft: definition of time worked, signals measured on `aa7523ea`, worker approval, freeze, biz-owner approval, CSV/XLSX, calendar and issue v1/later, owner questions Q1..Q5 |

<!-- version: 0.1.0 · updated: 2026-10-07 · last-edit: 2026-10-07T21:20:00Z -->
