# 107 Hours tracking: Business Needs

**Status**: consensus in section 6 (four seats, owner answers 1A 2A 3A, new BN-14 and BN-15).

## 1. Personas and the User Experience

**Persona 1: The Site Worker**
- **Environment**: Working on a construction site or in a metal workshop; often away from a screen, hands might be dirty, connectivity may be poor or non-existent.
- **Rule 1 (The 3-Tap Rule)**: The normal week must be approved on a phone in <= 3 taps. Hours must be prefilled so the worker confirms instead of typing. Targets must be big, only exceptions need work, and it must work offline.

**Persona 2: The Busy IT Person**
- **Environment**: Working in the office or remotely on a desktop/laptop, overwhelmed with work, always online.
- **Rule 2 (Zero Typing)**: Needs a standing "accept my standard day" (e.g., 8 hours). The system must automatically track issues, discussions, and the kind of work they have been doing, splitting those standard hours across them automatically. It must be straight and visible in the system with zero typing.

## 2. The Firm and Context

- **Size and Type**: Up to 100 people; typically a construction firm or metal workshop, including back-office and IT staff.
- **Roles**:
  - **Worker (Persona 1)**: On site or in the shop.
  - **IT / Office (Persona 2)**: Handles tech, administration, invoicing, and payslips.
  - **Foreman / Shift Lead**: Manages a crew on site or in the shop.
  - **Owner / Manager**: Oversees operations, costs, and reporting.

## 3. Business Needs (Scored against the Personas)

| ID | Need | Role | Cadence | Alignment with Personas (P1/P2) |
|---|---|---|---|---|
| BN-1 | Clock in and out at the start and end of the day, on a phone on site or a shared terminal in the shop. | worker | daily | **P1**: A timer requires daily taps; prefilling a default shift is better. **P2**: Wants a standing "accept my standard day" without manual clocking. |
| BN-2 | Book hours to a job, site or work order, so each job's labour cost is known. | worker, foreman | daily | **P1**: Needs "big targets" on phone. **P2**: Needs automatic tracking and splitting across issues/work kinds. |
| BN-3 | Record breaks, travel time between sites, and waiting time separately. | worker | daily | **P1**: Friction if manual; should be handled by exceptions. **P2**: N/A or auto-deducted from the standard day. |
| BN-4 | Track overtime, evening, night, weekend and holiday hours, each paid at its own rate. | payroll | daily, paid monthly | Handled by payroll/system based on approved hours; keeps both worker UIs simple. |
| BN-5 | A foreman records or fixes hours for a whole crew, e.g. when a worker forgot to clock out. | foreman | daily | **P1**: Foremen handling exceptions removes worker friction completely. **P2**: N/A. |
| BN-6 | The foreman approves the week's hours; a correction after approval needs a reason. | foreman | weekly | Management side, independent of P1's <= 3 taps or P2's zero typing. |
| BN-7 | Manage absences: sick leave, vacation, unpaid leave, training, with balances. | worker, office | as needed | Must be easy to pick from a list (P1) or auto-filled as an exception to the standard day (P2). |
| BN-8 | Manage shift plans, and who is on which site tomorrow. | foreman, office | weekly | **P1**: Prefilling from shift plans would achieve the "prefilled, confirms not types" goal perfectly. |
| BN-9 | Lock the pay period, then export it to the payroll system (file or API). | payroll | monthly | Back-office task; does not impact P1 or P2 UIs. |
| BN-10 | Generate reports: hours and labour cost per job against the quote, per person, and overtime trends. | owner, office | weekly, monthly | Back-office task; does not impact P1 or P2 UIs. |
| BN-11 | Track subcontractors and agency workers apart from employees. | office | monthly | Back-office task; does not impact P1 or P2 UIs. |
| BN-12 | Maintain a legal record of working time kept for years, shown to an inspector. | office | on request | Back-office task; does not impact P1 or P2 UIs. |
| BN-13 | Work without a network on site; hours sync later. | worker | daily | **P1**: Direct mandate ("works offline"). **P2**: Usually online, but beneficial. |

## 4. Map to Spec 107 v1.2

| ID | Status | Notes |
|---|---|---|
| BN-1 | Partly | Spec 107 has a start/stop timer in the header (T019) but no shift-style clock-in or shared terminal support. P2's "accept my standard day" is a gap. |
| BN-2 | Partly | Hours go to a topic, issue, or channel, but there is no specific job/site with a quote. P2's automatic split of standard hours based on tracked activity is a gap (v1 only suggests actual tracked minutes). |
| BN-3 | Gap | No dedicated handling for breaks, travel, or waiting time. Gaps just drop out of activity blocks. |
| BN-4 | Gap | Overtime and special rates are explicitly excluded. |
| BN-5 | Gap | Each member records and edits their own hours. The foreman cannot edit them, only approve or return them. |
| BN-6 | Covered | The worker approves first, then the biz owner/foreman approves, followed by a freeze. |
| BN-7 | Gap | Absences, leave, and balances are explicitly excluded from v1. |
| BN-8 | Gap | The calendar holds events/meetings, not shift plans or site schedules. |
| BN-9 | Partly | Periods freeze automatically and can be exported as CSV/XLSX; no payroll-system-specific API/format. |
| BN-10 | Partly | The Team table and export provide per-target totals and per-person hours, but cost and overtime trends are excluded. |
| BN-11 | Gap | Subcontractors and agency workers are not supported distinctly from employees. |
| BN-12 | Partly | Frozen periods are kept indefinitely, but there is no explicit retention or compliance rule built-in. |
| BN-13 | Gap | The web UI requires a network to load the calendar and sync hours. Full offline capability is not supported in v1. |

## 5. Open Questions

**Q1: Foremen editing worker hours (BN-5)**
In a construction setting, workers often do not log their own hours; the foreman does it for the whole crew. Spec 107 v1 prevents managers from editing worker timesheets.
- A. Allow foremen (holders of `hours.approve`) to log and edit hours for their crew directly.
- B. Stick to the current design: the worker must log and edit their own hours; the foreman can only approve or return them.
- **Recommendation:** A. In these industries, delegating data entry to the foreman is a core need and fits Persona 1's goal of zero friction.

**Q2: Leave and absences (BN-7)**
Tracking working hours usually requires tracking why someone is not working, to complete the timesheet.
- A. Add basic non-working target types (Sick, Vacation, Unpaid) so workers can log absences, without building a full leave balance system.
- B. Keep absences out of v1; the firm will track them in a separate HR system.
- **Recommendation:** A. It keeps the weekly timesheet complete and accurate for payroll export.

**Q3: The IT Persona's Standard Day (BN-1, BN-2)**
Persona 2 needs a standing 8-hour day that is automatically tracked and split across issues, with zero typing.
- A. Add a "Standard Day" toggle for members that automatically scales their tracked hub activity proportionally to reach 8 hours, requiring zero manual entry.
- B. Rely on the existing system (which only suggests exact tracked minutes) and require them to manually top up to 8 hours.
- **Recommendation:** A. It satisfies the busy IT persona's requirement for zero typing and automatic issue splitting.

## 6. Consensus

Folded by the editor (seat bn-claude) from four seats, each signed against this file at `5c3f1fe42`: [bn-agy](reviews/bn-agy.md) (`c84d86f82`), [bn-mistral](reviews/bn-mistral.md) (`c7c5d1c12`), [bn-claude](reviews/bn-claude.md) (`bcd3d453c`), [bn-claude-2](reviews/bn-claude-2.md) (`4edf78105`). Lane dispatch `dispatch-a28dc5c9`.

### 6.1 The owner's answers

The owner answered "1a,2a,3a", and added: "the standard amount per hour should be configurable both for the whole organization and on a per-person basis", "the foreman should have access to the list of the people and have the UI for setting up their default hours".

- **Q1 = A**: a foreman logs and fixes hours for their crew (BN-5).
- **Q2 = A**: basic absence types, no balances in v1 (BN-7).
- **Q3 = A**: a standing "Standard Day" per member, split automatically across tracked activity (BN-1, BN-2).
- **New BN-14** (6.3): default hours per day, set for the whole workspace and per person.

Read as **hours per day**, not an hourly pay rate (the dispatcher's reading, flagged to the owner). A pay or cost rate is BN-15 (6.3).

### 6.2 The key finding (all four seats)

Spec 107 v1 prefills hours only from in-app activity: posts, tab minutes, meetings. A site worker has almost none, so their suggested week is empty and Rule 1 cannot be met. **The site worker's prefill comes from the shift plan (BN-8), then the person's default hours (BN-14), and the foreman fills the gaps (BN-5).** That makes BN-8 the precondition of Rule 1, not a planning extra. Every seat changed or promoted BN-8.

### 6.3 Per BN: the agreed text

Seat verdicts in the order agy / mistral / claude / claude-2. "Missing" in bn-agy and bn-mistral mostly means "spec 107 does not cover it", not "the need is wrong"; the editor reads those as agreement with the need.

| ID | Seats | Consensus | Agreed text or change |
|---|---|---|---|
| BN-1 | change / change / change / change | **change** | Each worker's normal day is prefilled from the shift plan (BN-8), else the person's default hours (BN-14), else the Standard Day (Q3 = A), and the week is confirmed in one tap. Clock in and out is an **exception** (late start, early leave, extra hours, no plan for that day), on a phone or on a shared shop terminal where the worker identifies with a badge or PIN. Rule 1 pass (open, Approve week); Rule 2 pass. |
| BN-2 | change / agree / change / change | **change** | The day's default target is the site or job the worker is planned on (BN-8) for a site worker, and tracked activity (Q3 = A) for an office member; the worker changes it only when the day differed. A **job** carries its site and its quoted labour (BN-15). Rule 1 pass; Rule 2 pass. |
| BN-3 | missing / change / change / change | **change** | Breaks are deducted by a workspace rule (e.g. 30 min once a day exceeds 6 h) unless the worker marks "no break". Travel and waiting are exception rows added only on the days they happened, one tap each, with a default length and an optional reason (e.g. weather delay); travel between two planned sites is prefilled from the plan. Rule 1 pass; Rule 2 pass. |
| BN-4 | missing / missing / agree / agree | **agree, plus one sentence** | The rate category of every approved minute (overtime, evening, night, weekend, holiday) is **derived** from the time of day, the weekday, a weekly threshold and the public-holiday calendar (U5), and is never chosen by the worker. It needs start and end times (BN-12). Rule 1 pass; Rule 2 pass. |
| BN-5 | agree / change / agree / change | **change (Q1 = A)** | A foreman enters or fixes a day for any member of their crew, including members without an account. Every such row records who entered it. It lands in the worker's week prefilled, with a one-tap **Dispute** (plus a note) that returns it to the foreman before the freeze. The worker's Approve week covers it. Rule 1 pass (0 taps for the worker). |
| BN-6 | agree / agree / change / change | **change** | The foreman approves **their own crew's** week on a phone (Approve crew, one tap); the office or the owner keeps the workspace-wide grant and sees every crew. A correction after approval needs a reason and is logged with its author. |
| BN-7 | agree / change / change / agree | **change (Q2 = A)** | v1: an absence (sick, vacation, unpaid, training, public holiday) is a whole-day or part-day row picked from a short list (2 taps), or entered once as a date range by the worker or the office. An absence day counts the person's default hours (BN-14). **No balances in v1.** Rule 1 pass; Rule 2 pass (an absence replaces the Standard Day). |
| BN-8 | missing / change / change / change | **change, promoted** | The plan says who works on which site or job and which shift, per day, repeated from last week by default and editable by the foreman or the office. **It is the prefill for every worker without in-app activity.** Rule 1 pass (it is what makes <= 3 taps possible). |
| BN-9 | agree / agree / agree / agree | **agree, plus one sentence** | The export carries the BN-4 rate categories, the BN-7 absence codes and the BN-11 worker type as columns, mapped to the payroll system's format by a per-workspace column map. Subcontractor hours stay out of the payroll export. |
| BN-10 | missing / agree / missing / agree | **agree, depends on BN-15** | Unchanged. Labour cost against the quote is computed from approved hours x the cost rate against the job's quote (BN-15). |
| BN-11 | missing / missing / agree / change | **change** | A member is typed employee, agency or subcontractor (with the agency or company). Members without an account are logged by their foreman (BN-5). Subcontractor hours roll up per company for invoice checking and stay out of the payroll export (BN-9). |
| BN-12 | agree / agree / change / change | **change** | Keep, per worker per day, start and end times, break minutes and every change (who, when, why), for a retention period the workspace sets in years; read-only and exportable per worker and period for an inspector. Start and end are prefilled from the plan or the default hours, never typed. |
| BN-13 | missing / agree / agree / agree | **agree, scoped** | Minimum offline scope: the week view, Approve week, an absence pick and a clock exception work without a network and sync later. On sync a frozen period wins and the worker sees why; a foreman edit made meanwhile shows both values and asks the worker once. |
| **BN-14** | owner, new | **added** | **Default hours per day**, set for the whole workspace (by an admin) and per person (by the foreman, from the list of their crew, in a screen for each person's default; the crew scope is BN-6's). The person's value beats the workspace's. A day's prefill takes the plan's shift (BN-8) first, then the person's default; the Standard Day (Q3 = A) and an absence day (BN-7) count this number. Hours per day, not an hourly pay rate. Rule 1 pass; Rule 2 pass. Scored by the editor: all four seats landed before the owner's input. |
| **BN-15** | claude, claude-2 (under BN-10), agy (under BN-10) | **added** | A cost rate per person or per role, with the date it starts, and a quoted labour budget per job (hours or money). Reports compare approved hours x rate against the quote while the job is running. Back office; Rule 1 and Rule 2 n/a. |

### 6.4 Disagreements and how they were settled

1. **BN-2: agree (mistral) vs change (three seats).** bn-mistral says hours are "booked to jobs/issues via discussions". A site worker has no discussions, and spec 107 has no job target. Settled: **change**, 3 to 1.
2. **BN-4: worker toggles (mistral) vs derived rates (claude, claude-2).** bn-mistral proposed an "Overtime" or "Weekend" toggle in the worker's dialog. That adds a tap for Persona 1 and typing for Persona 2. Settled: **rates are derived, never chosen**. bn-agy's "categorise hour types for export without changing the worker UI" is the same position.
3. **BN-6: agree (agy, mistral) vs crew scope (claude, claude-2).** The agreeing seats did not address a firm with several foremen, and nobody argued that a foreman should approve other crews. Spec 107 grants `hours.approve` workspace-wide. Settled: **change, crew scope**. The owner's BN-14 ("the list of the people") needs the same crew scope.
4. **BN-7: balances.** The BN says "with balances", Q2 = A says without. Settled by the owner: **no balances in v1**; the text now says so.
5. **BN-10, BN-12, BN-13: "already implemented" (mistral) vs section 4.** bn-mistral calls cost reports, the legal record and offline work done. Section 4 marks BN-13 as a gap and BN-10 and BN-12 as only partly covered. These are facts against the reviewed file, not unclear verdicts, so the editor did not ask the seat. Settled against section 4: BN-10 depends on BN-15, BN-12 **change** (start and end times are missing, retention is unset), BN-13 agree with a scoped minimum. bn-agy's BN-12 "covered by indefinite retention" is settled the same way: keeping rows is not keeping the record a working-time law asks for.
6. **BN-5: agree vs change.** All four seats accept Q1 = A. The split is only whether the worker keeps a say. Owner requirement R4 ("the workers should approve them") stays true with a one-tap Dispute and Approve week covering foreman rows. Settled: **change** as worded in 6.3.
7. **Section 4 counts 7 Gap rows, not 8** (bn-claude-2: BN-3, 4, 5, 7, 8, 11, 13). Noted. This file's text never states the count, so nothing changes here.

### 6.5 Added use cases

| # | Use case | Seats | Rule |
|---|---|---|---|
| U1 | **The nudge that starts the 3 taps**: one phone notification ("Your week: 40:00 at Site A · [Approve]") lands tap 1 on the approve screen. Spec 107 v1 has no pop-up or push. | claude-2 | 1 |
| U2 | **A worker with no e-mail or no smartphone**: the foreman or the office creates the account; the worker signs in on a shared terminal with a badge or PIN, or the foreman logs for them (BN-5). | claude, claude-2 | 1 |
| U3 | **Two sites in one day**: split the planned day between two jobs in one tap, with the travel between them (BN-3). | claude, mistral | 1 |
| U4 | **Allowances and expenses tied to hours**: per diem, meals, mileage, own vehicle, tools, material expenses. | claude, agy | 1 |
| U5 | **A public-holiday calendar per workspace and region**: it prefills holidays as absences and drives holiday rates (BN-4). | claude, claude-2 | 1, 2 |
| U6 | **The worker sees their own numbers**: hours this week and month, overtime, absence days taken. | claude | 1 |
| U7 | **The worker's language**: a plain phone UI in the worker's own language, icons with short labels. Translated text gets the fleet's language review before it ships. | claude, claude-2 | 1 |
| U8 | **A correction after the payroll export** goes into the next open period as an adjustment row with a reason; a paid period is never rewritten. | claude, claude-2 | n/a |
| U9 | **Working-time limit warnings**: the foreman and the office are warned before a day or week passes the maximum hours or the minimum rest. | claude, claude-2 | n/a |
| U10 | **Who is on site right now**: today's headcount per site for the foreman and the safety officer, from the plan plus clock exceptions. | claude-2 | n/a |
| U11 | **A leaver's final pay**: close one member's period early for the final payslip. Spec 107 has no "freeze now" (its owner Q4), so this needs an owner call. | claude-2 | n/a |
| U12 | **Equipment and machine hours** booked to a job alongside the crew's hours, for job costing. One seat; the v2 round decides if it belongs in hours tracking. | mistral | n/a |

bn-agy's "weather or delay logging" is folded into BN-3 (a reason on a waiting row).

### 6.6 What goes to the 107 v2 gap-spec round

Spec 107 v1.2 lacks all of these, each needed by the agreed text above: the shift plan as the prefill source (BN-8), default hours per day (BN-14) and the Standard Day (Q3 = A); exception clock in and out and a shared terminal identity (BN-1, U2); a job target with a quote (BN-2, BN-15); the break rule and travel and waiting rows (BN-3); derived rate categories and a holiday calendar (BN-4, U5); foreman entry with Dispute (BN-5); `hours.approve` scoped to a crew (BN-6, BN-14); absence types (BN-7); worker type (BN-11); start and end times and retention (BN-12); offline approval (BN-13); the approve nudge (U1). The payroll column map (BN-9) and U3, U4, U6..U12 are candidates the round ranks; U11 needs an owner call first.
