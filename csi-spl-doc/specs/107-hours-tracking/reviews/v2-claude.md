signed against 9260921ef

# 107 Hours tracking: v2 review, seat v2-claude

**Reviews**: [spec.md](../spec.md) v2.0-draft at `9260921ef`, sections 14..17 (FR-14..FR-37), against [business-needs.md](../business-needs.md) section 6 (consensus `2c6c36732`) and the owner input in table 14.0. Sections 1..13 read for context only. · **Seat**: v2-claude (c-737, also the panel's editor) · **Date**: 2026-10-10 · **Lane dispatch**: `dispatch-a28dc5c9`

**Verdict: agree with changes.** The draft covers every 6.6 item (section 17 maps all of them) and follows the owner's O1..O8 faithfully: hours per day, not a rate; no money in hours tracking; a time-accountant role that combines with others. Most changes below are edge rules a build would otherwise invent on its own. Three findings matter more than the rest:

1. **The nudge's week is not approvable in its 2 taps** (FR-36 against 4.1): sent Friday 14:00, its "40:00" includes today, but **Approve week** approves closed days only, so the tap leaves Friday open.
2. **The owner's foreman screen is missing** (BN-14 addendum: "the UI for setting up their default hours"): FR-14 and FR-22 give the foreman the right, but no screen in section 5 or 14 holds it. The plan (FR-16) has no screen either.
3. **After approval nothing can change at all**: v1 Return works on `frozen` only, and `approved` is final (4.4). With a payroll export in v2 (section 15, BN-9), U8 (a correction after the export) is needed in v2, not v2.1.

Tally: **8 agree, 16 change** of 24 FRs; **6 missing** (section 2).

---

## 1. Per FR

| FR | verdict | one line |
|---|---|---|
| FR-14 | change | (a) The workspace value is a 098 **scalar** key, which cannot carry "the date it takes effect": say the workspace value applies from the change forward, and protect past days by the FR-32 day record's "standard day in force", written at approval. (b) O2 and O3 also need a **per-weekday pattern** for a person (e.g. 4 x 8 h Mon..Thu, Friday off), not only one number: the "working day" of FR-15, FR-29 and 5.1 then reads the pattern. |
| FR-15 | change | Under owner Q2 = B the sweep approves open suggestions, so a member who never opens the app gets the full standard day approved every week, including on days they did not work. Mark a standard-day row with **no activity behind it** ("no activity") in the Team view and the download so the approver sees it; keep it auto-approved (Rule 2). |
| FR-16 | change | The 28-day repeat must skip a row whose job is `closed` (FR-18) and a member who has left the foreman's crew since; otherwise a finished site keeps prefilling. |
| FR-17 | change | "First match wins" breaks a **part-day** absence (FR-30): a 4 h doctor's visit would make the whole day 4 h. Say a part-day absence or holiday takes its minutes and the next step (foreman, plan, Standard Day) fills the rest of the day. |
| FR-18 | agree | A job target with `quote_minutes`; the linked-topic rule keeps office posts on the job. |
| FR-19 | agree | Matches O4; with no accounting view yet, hours against `quote_minutes` is enough for BN-10's first use. |
| FR-20 | change | Say "holders of `hours.rates`", and make `hours.rates` **not grantable through the role editor** (6.1: a biz owner can add permissions to any role), else "only the time-accountant role sees rates" is one editor click away from false. |
| FR-21 | change | `access_until` already exists (`ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| grep access_until` -> `0113_membership_access_until.sql`): cite rdb 0113 and drop it from the dependency list. Also state the seat is read-only: no Approve, no Return. |
| FR-22 | change | Two rules missing: (a) **no self-approval**: a foreman never approves or returns their own period, a workspace-wide holder does; (b) a member who changes crew mid-period is approved by the foreman of the crew they are in **when the period freezes**. |
| FR-23 | change | (a) A period with a still-**disputed** row is approved or returned only by a workspace-wide `hours.approve` holder, never by the crew foreman who is a party to the dispute. (b) For a member **without a login** nobody can approve first or dispute: say the foreman's entry is the first approval, and the second approval must then come from someone other than that foreman. |
| FR-24 | change | Bound the device time of an offline clock: not later than the sync, not earlier than the device's last sync; outside the bounds the server keeps the time but marks it for the foreman. On a day with two plan rows (U3), Clock in moves the first row's start, Clock out the last row's end. |
| FR-25 | change | A PIN alone must not identify the worker: 4..6 digits across up to 100 people collide and can be enumerated. The worker picks their name (or scans the badge), then enters the PIN; the lockout is per member. Say whether a terminal queues offline like FR-35 or needs a network. |
| FR-26 | agree | Workspace break rule with **No break**. Optional later: a second tier (several countries add a longer break above ~9 h); two more scalar keys, no design change. |
| FR-27 | change | `hours_entries` is keyed by target (`grep -n 'PRIMARY KEY (tenant_id, member_id, day' csi-spl-rdb/src/sql/postgres/spool-hub/0151_hours.sql` -> `56: PRIMARY KEY (tenant_id, member_id, day, target)`): a travel row to job X collides with the work row on job X. Give `kind` a place in the key, or give travel, wait and absence their own target forms (`travel`, `wait`, `abs:<type>`); say which in 14.12. |
| FR-28 | change | (a) Derive categories from the day record (FR-32 start, end, break), which every approved day has, instead of "minutes without times start at `hours.day_start`" (office rows have no times once raw minutes are pruned at the freeze). (b) The weekly overtime threshold spans periods under `two_weeks` / `month` and across a period boundary: compute it when the week's last day freezes and never change a frozen period's categories. (c) The default "5 x standard day" is wrong for a 4-day pattern (FR-14 b): use the sum of the person's weekly pattern. |
| FR-29 | agree | Per-workspace calendar with a member region, CSV or iCal import. Part-day holidays (e.g. a half day on 24 Dec) fall out of the FR-17 change. |
| FR-30 | agree | Fixed list, no balances, date range by the worker, foreman or office. The plan view (missing item M2) should show an absence over the plan, so "who is on which site tomorrow" (BN-8) stays true. |
| FR-31 | agree | Worker type in the membership jsonb, no DDL; subcontractor hours out of the payroll export. |
| FR-32 | change | Say **when** the day record is written: at approval and by the sweep (Q2 = B), not on read, matching FR-17's "nothing is stored until approved". Add `terminal`, `absence` and `holiday` to the source list; an inspector must see that a `standard` start and end are planned, not measured. |
| FR-33 | change | "Append-only for every route" plus FR-34's deletion: say the retention sweep is the only deleter. Say whether v1's `member_activity` `hours_returned` (3.3) stays or moves into `hours_changes`. |
| FR-34 | agree | Workspace-set years, default 5; the inspector's export reuses 6.2's writer. |
| FR-35 | change | A queued **Approve week** must carry the version (`updated_at`) of every row it approves; on sync a row changed meanwhile (a foreman edit) is the "both values, ask once" case, not a silent overwrite. The acceptance test for it must run on the CI mock bundle: CI has no live socket offline. |
| FR-36 | change | (a) Friday 14:00 is today, not a closed day (4.1): either send after the last planned shift's end (else Monday 08:00, before the freeze), or let **Approve week** include today's planned row once the shift's end has passed. (b) On iPhones Web Push reaches only a web app added to the home screen: onboarding a site worker must include that step, or Rule 1's lock-screen tap does not exist for them. |
| FR-37 | agree | Per workspace, cross-workspace deferred. Wording: "different standard days per workspace" is already true here (FR-14 is a per-workspace key); the new spec only reconciles them. |

---

## 2. Missing from 6.6 or the owner's addenda

| # | what | from | where it belongs |
|---|---|---|---|
| M1 | **The foreman's crew screen**: the list of the crew with each person's standard day (and FR-14 b pattern), Standard Day switch, worker type and PIN or badge, editable on a phone. The owner asked for exactly this UI. A **Crew** tab beside Mine / Team / Download (5.4), for crew leaders and workspace-wide `hours.approve`. | owner addendum to BN-14 (business-needs 6.1) | new FR in 14.5 |
| M2 | **The plan screen**: crew x days, the job and shift per cell, **Copy last week**, absences shown over the plan. FR-16 defines the data only. | BN-8 ("who is on which site tomorrow") | FR-16, or with M1 |
| M3 | **A correction after approval**: today an `approved` period is final and Return works on `frozen` only (4.3, 4.4), so a mistake found after payroll has no path. U8's adjustment row (next open period, with a reason, logged by FR-33) belongs in v2 together with the payroll export. | BN-6 ("a correction after approval needs a reason"), U8 | section 15, rank 2 below |
| M4 | **Export rows per category**: 6.2's export is one line per approved entry, but FR-28 categories are per minute, so one entry can span normal and evening. The payroll file needs a line per (member, day, category, kind) with its minutes. | BN-9, BN-4 | section 15 rank 1 (BN-9) |
| M5 | **Approve week for a site worker on the last day** (finding 1): today's planned shift is approvable once its end has passed. | Rule 1, U1 | FR-36 or 4.1 |
| M6 | **Q2 = B is not stated in 13.1**: the owner's msg `54eda621` says "q2 b and q7 b" (`grep -n 'q2 b' spec.md` -> line 542), 13.1 lists only Q7, and 4.2 still reads as if Q2 were open; FR-15 relies on Q2 = B. A one-line fix outside 14..17, for the fold. | owner `54eda621` | 13.1, 4.2 |

Out of scope, checked for contradictions only: specs 118 (cross-workspace hours) and 119 (the personal realm) are not on origin/master (`git ls-tree --name-only origin/master csi-spl-doc/specs/ | grep -cE '/11[89]-'` -> 0 at `a55071d53`). FR-37 defers to the first and says nothing the second could contradict. An external accountant serving several firms (FR-21) holds one membership per workspace, which 118 should take as given.

---

## 3. Section 15, ranked by this seat

| rank | item | this seat | the draft's rank | why the change |
|---|---|---|---|---|
| 1 | **BN-9** payroll column map | in v2, with M4 | 2 | the freeze and both approvals exist to feed payroll; without the categories in the file nothing downstream works |
| 2 | **U8** correction after the export | **in v2** | 6 (v2.1) | M3: once payroll reads the file, an approved period that can never change is a blocker on day one |
| 3 | **U3** two sites in one day | in v2 | 1 | Rule 1; cheap once the plan exists |
| 4 | **U6** the worker's own numbers | in v2 | 3 | trust in prefilled hours; read only |
| 5 | **U9** working-time limit warnings | **in v2** | 5 (v2.1) | FR-32 already holds start, end and breaks; the check is a read over it, and the legal risk starts with the first planned week |
| 6 | **U7** the worker's language | in v2 | 4 | the WUI already has `csi-spl-wui/i18n/locales`; the work is the strings and the agy review |
| 7 | **U10** who is on site now | later | 7 | a read view over the plan plus clock exceptions |
| 8 | **U4** allowances and expenses | out | 8 | money; next to the accounting view |
| 9 | **U12** equipment hours | out | 9 | job costing, not people's hours |

---

## 4. Q8 (U11), the owner's call

This seat would recommend **C** (close on the leave date): `access_until` already exists (rdb 0113), and it keeps Q4 = B's "no manual freeze". The leaver must approve their last days before `access_until` ends their sign-in; after that, the foreman's entry (FR-23) covers them. **The owner decides; U11 stays OPEN.**
