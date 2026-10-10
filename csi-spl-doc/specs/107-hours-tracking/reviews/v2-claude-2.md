signed against 9260921ef

# 107 Hours tracking: v2 review, seat v2-claude-2

**Seat**: v2-claude-2 (claude, c-738) · **Reviewed**: `csi-spl-doc/specs/107-hours-tracking/spec.md` v2.0-draft at `9260921ef`, sections 14..17 (FR-14..FR-37), against [business-needs.md](../business-needs.md) section 6 (consensus `2c6c36732`) and the owner input in table 14.0. Sections 1..13 read for context.
**Date**: 2026-10-10 · **Lane**: `dispatch-a28dc5c9` · **Editor**: c-737

**Verdict: agree with changes.** The draft covers every 6.6 item (section 17 map checked line by line). Four findings change behaviour or the data model and should be folded before the tasks round: **V2C2-1** (phantom paid days), **V2C2-2** (the `hours_entries` key), **V2C2-3** (rate categories lose their times at the freeze), **V2C2-4** (terminal PIN guessing).

Naming note, used below: the draft has two sets of owner questions with the same names. "Q1..Q3" in FR-15/17/23/30 are the **business-needs** questions; "owner Q2 = B (13.1)" in FR-15 is the **spec's** v1 question. I write **BN-Q1..BN-Q3** and **v1-Q2**; I ask the editor to do the same in the spec.

## 1. Key findings

| id | FR | finding | change |
|---|---|---|---|
| **V2C2-1** | FR-15, FR-17, 4.2 | **Phantom paid days.** FR-15 suggests a full standard day on a closed working day with **no activity** (one row to the default target), and FR-15 itself says v1-Q2 = B auto-approves open suggestions at the freeze. Together: a member who was off and logged nothing (a forgotten absence, a site worker who never opened the app, a day of illness) gets 8:00 approved and exported with no evidence and no human tap. | The sweep auto-approves (v1-Q2 = B) only rows backed by evidence: activity, a plan row, a clock time, a foreman row. A zero-activity Standard Day row stays open, shows on the Working hours line with the open mark, and counts zero at the freeze unless the worker or foreman approves it. Rule 2 still passes: the IT person has activity. |
| **V2C2-2** | FR-27, FR-30, 3.2 | **The entry key collides.** `hours_entries` PK is `(tenant_id, member_id, day, target)` (3.2). FR-27 adds `kind` (`work`, `travel`, `wait`, `absence`) but not to the key: travel to job A and work on job A on the same day are one row; an absence row has no defined target and would collide with the "other" `ws` row. | Put `kind` in the PK, `(tenant_id, member_id, day, target, kind)`; give an absence the target `ws` with `kind = absence`. One migration line, and the natural-key upsert of S2-4 keeps working. |
| **V2C2-3** | FR-28, FR-32, 1.7 | **Rate categories need times that are deleted.** An entry is minutes per (day, target), with no time of day; the only per-minute times are `hours_minutes`, pruned **at the freeze** (1.7). FR-28 categories are derived after approval, so for an activity day they fall back to `hours.day_start`: an IT person's evening work is labelled `normal`. With two jobs (U3) the day's start..end cannot say which job's minutes were evening. | Store the category split on the entry when it is approved (or by the sweep before the prune): `category_minutes` per entry, plus the overtime flag at period close. For activity days take FR-32 start and end from the first and last active minute, captured before the prune. |
| **V2C2-4** | FR-25 | **PIN guessing on a shared terminal.** "5 wrong tries lock that PIN" does not work if the worker is identified by the PIN alone: a wrong PIN belongs to no one, so nothing locks, and with 100 workers a 4-digit guess hits someone 1 time in 100. A 4..6 digit hash is also brute-forced offline in seconds. | Badge or name first, then the PIN; lock per member after 5 tries **and** rate-limit per terminal; hash the PIN with a hub-held key (pepper), not a plain salted hash. |

## 2. Per requirement

| FR | verdict | one line |
|---|---|---|
| FR-14 | **agree** | Matches BN-14 and O1..O3 (`450`, `240` examples, person beats organisation, effective dates). Say what `0` means (range `0..1440`): "no standard day, Standard Day off for this person", or forbid it. |
| FR-15 | **change** | V2C2-1. Also "the member, their foreman or the office can turn it off": add FR-33 logging, since it changes what is paid. |
| FR-16 | **change** | "The most recent plan row for the same weekday within the last 28 days" must be **before that day**, else a future row rewrites a past day's inherited plan; skip `closed` jobs when inheriting. **Missing**: a night shift whose end is on the next day (start 22:00, end 06:00): say it splits at local midnight like 1.6. |
| FR-17 | **change** | State that an **entry always beats the chain** (2.3: an approved row replaces its suggestion); add a step for a day that has **only a clock in and out** (FR-24 "a day with no plan" with the Standard Day off has no producer); say how a clock exception changes a Standard Day's minutes (end - start - break, FR-26). An explicit plan row on a holiday must beat step (1), see FR-29. |
| FR-18 | **change** | Map "a post in the job's linked topic counts for the job" **at read time**, from `t:<task_id>`; `hours_minutes` and its target CHECK stay as v1 (one less write-path lookup per post). The `hours_entries` CHECK widening is a constraint redefinition, the 0148 pattern (3.3). |
| FR-19 | **agree** | O4 as written. With the accounting view unwritten, everything money-related in FR-20/FR-21 has nothing to show; see the ranking (section 4). |
| FR-20 | **change** | "Only holders of the time-accountant role see rates" is not what RBAC enforces: a biz owner can grant `hours.rates` to any role through the role editor (6.1). Write "only holders of `hours.rates`, which only `time_accountant` holds by default". It is a separation of duties, not a boundary against the biz owner (who can assign themself the role): say so. Depends on 025 section 9 phase 2, not built (`git grep -l tenant_member_roles origin/master -- csi-spl-api \| wc -l` -> 0). |
| FR-21 | **change** | The "hours-only shell" is a new WUI surface, while v1.2 (R8, R9) put hours inside the calendar with "no `/hours` page": name it (the calendar's 5.4 panel, full width, no events) so it does not reopen R8. Member names plus hours go to someone outside the organisation: `access_until` (072 A27, built: `git grep -l access_until origin/master -- 'csi-spl-rdb/*.sql' 'csi-spl-api/*.go' \| wc -l` -> 22) should be **required** for this seat, not optional. An accountant serving several firms holds one seat per workspace: consistent with FR-37. |
| FR-22 | **change** | Three gaps: (a) **no self-approval**: a foreman who is a member of their own crew cannot approve their own period, the office does; (b) say whether the foreman's approval and the office's are **one** second approval (either one) or two levels; I read BN-6 as one, by either; (c) which foreman approves after a crew change mid-period: the crew at the freeze. "A correction after approval needs a reason" contradicts 4.4 ("approved, final"): say it means after the **worker's** approval, before the freeze; after the final approval only U8 applies. |
| FR-23 | **change** | Say what a **proposed** row is at the freeze: under v1-Q2 = B it is approved at the foreman's value (it has evidence, V2C2-1). A member with no login (FR-25) can never approve or dispute: their rows are foreman-approved at the freeze, and the approver sees them marked so. |
| FR-24 | **change** | **Missing**: a forgotten clock out (BN-5's own example). Rule: the day ends at the planned end, else start + standard day + break, and the row goes to the foreman as proposed. Say how the clock relates to the v1 header timer (1.5, T019): the timer books a target, the clock sets the day; a site worker's phone shows only the clock. |
| FR-25 | **change** | V2C2-4. Also: the terminal token lives on the device; a lost terminal is revoked from the same admin screen, and every terminal action writes FR-33 with the terminal id. |
| FR-26 | **change** | Say which row loses the break on a two-job day (U3): the longest row. The threshold compares the span **after** clock exceptions. |
| FR-27 | **change** | V2C2-2. Otherwise agree: one tap each, default lengths, reason optional, prefilled between two planned jobs. |
| FR-28 | **change** | V2C2-3. The overtime default "5 x the person's standard day" makes a half-day worker's hour 21 overtime; most payroll rules call that extra contract hours, not overtime. Default to 5 x the **organisation's** standard day, with a per-person override; flag minutes above the person's contract but below that line as `extra`. Labels only, no money (agree). |
| FR-29 | **change** | An **explicit** plan row (written by the foreman) on a holiday beats the holiday prefill; an inherited one (FR-16 read-time repeat) does not. Otherwise the holiday shift a foreman planned is prefilled as an absence. |
| FR-30 | **change** | The type `sick` is health data: the foreman and the external accountant (FR-21) see "absent"; the type goes only to the workspace-wide `hours.read` and the payroll export. A date range never writes into a frozen period (409, per day) and covers working days only. Say explicitly that leave **requests** (approval before the leave) are out of v2. |
| FR-31 | **change** | Worker type is a contract fact: set by the office only, not the foreman. Agree with the rest (no DDL, split in reports, subcontractors out of payroll). |
| FR-32 | **change** | A legal record must not present derived times as recorded ones. Keep `source` per field and show it in the inspector export; for `standard`, start and end are an estimate unless activity (V2C2-3) or a clock gives them. Add `absence` and `holiday` to the source list. |
| FR-33 | **change** | "Append-only for every route": enforce it in the database too (no UPDATE or DELETE for the hub role, a trigger, or both), except the FR-34 retention sweep. Log the sweep's own writes (auto-approval, freeze, prune) with the actor `sweep`. |
| FR-34 | **change** | Removing a member must not delete their hours rows inside the retention period (today only the tenant FK cascades: say it stays so). A workspace deletion (tenant cascade) destroys the legal record: name that as the workspace owner's act and warn in its confirm. |
| FR-35 | **change** | The service worker today caches navigations only and leaves the rest to HTTP: `git show origin/master:csi-spl-wui/src/public/sw.js \| grep -n '/api/\*\* is never cached'` -> line 24. FR-35 needs the worker to precache the hours chunks and the queue in IndexedDB, both named as a change to `sw.js` and its tests. A device-time clock marked `offline` is shown to the foreman when it differs from the sync time by more than a set limit. |
| FR-36 | **change** | Web Push on iOS reaches only a home-screen-installed web app: the 2-tap claim holds there and on Android, not in an iOS browser tab. A worker without a phone (U2) gets no nudge: the foreman's crew nudge covers them. Agree with timing, quiet hours (095 6.6) and the off switch. |
| FR-37 | **agree** | Per workspace, cross-workspace in its own spec. Specs 118 and 119 are not on master yet (`git ls-tree -d origin/master csi-spl-doc/specs/ \| grep -cE '/11[89]-'` -> 0); against the briefed scope I see no contradiction. |

## 3. Missing from 6.6 and the owner's addenda

1. **Where the v2 screens live.** The owner's addendum (business-needs 6.1: "the foreman should have access to the list of the people and have the UI for setting up their default hours") has no screen in the draft, nor do the plan editor, crews, jobs, holidays and terminals. v1.2 puts hours inside the calendar (5.4). Proposal: a **Crew** tab in the 5.4 panel for a foreman (people, standard day, plan, Approve crew) and a **Setup** tab for the office (jobs, crews, holidays, terminals), a sheet on the phone as 5.4 does.
2. **A monthly payroll export over weekly freezes.** BN-9 is monthly; the freeze is weekly by default; 6.2 is "periods only" and 11 excludes free from..to ranges. Payroll needs "every period ending in this month" (or a split at the month boundary) as one file.
3. **v2 acceptance.** v1 has an acceptance scenario (9); v2 has none. Add one per rule: Rule 1, a site worker with a plan and no app activity approves the week in <= 3 taps on a 390 px phone, offline, and it syncs; Rule 2, an IT person with activity sees a standard day split across topics with zero typing; plus a no-leak test that rates reach only `hours.rates`.
4. **The perf budget for v2**: the new screens (Crew, Setup, terminal) load as lazy chunks; acceptance runs `perf-budget.py` (027) as v1 does.
5. **U7 language**: FR text promises nothing about translated labels; the ranked item must carry the fleet language rule (agy review before shipping).

## 4. Section 15, my ranking

| rank | item | where | why |
|---|---|---|---|
| 1 | **BN-9** payroll column map, with the monthly export of section 3 item 2 | **v2** | payroll is why the firm pays for hours tracking; without categories and a month file the export is unused |
| 2 | **U3** two sites in one day | **v2** | Rule 1, cheap on top of FR-16 |
| 3 | **U8** correction after the payroll export | **v2**, not v2.1 | the first export that is wrong has no path today: an approved period is final (4.4) and v1 has no unfreeze (Q4 = B) |
| 4 | **U6** the worker sees their own numbers | **v2** | trust in prefilled hours, read only |
| 5 | **U7** the worker's language | **v2** | Rule 1 for mixed crews; agy review gate |
| 6 | **U9** working-time limit warnings | v2.1 | needs FR-32 times that are recorded, not derived (FR-32 above) |
| 7 | **U10** who is on site now | later | useful, not Rule 1 |
| 8 | **U4** allowances and expenses | out | money: next to the accounting view |
| 9 | **U12** equipment hours | out | job costing, not people's hours |

Also a build-order note: FR-20 and FR-21's money parts (`hours.rates`, the cost view) have nothing to read until the accounting view (FR-19) exists; build the roles' hours-only half first.

## 5. Q8 (U11), the owner's call

I would recommend **C** (close on the leave date via `access_until`), because it needs no new button and the leave date is itself audited; with v1-Q2 = B the leaver's open days are approved at leave date + grace, so losing access on the leave date loses no hours (subject to V2C2-1).
