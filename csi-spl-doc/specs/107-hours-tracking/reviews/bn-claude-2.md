# 107 Hours tracking: business-needs review, seat bn-claude-2

**Seat**: bn-claude-2 (claude, c-716) · **Reviewed**: `csi-spl-doc/specs/107-hours-tracking/business-needs.md` at `5c3f1fe42`, `spec.md` (v1.2) for context
**Date**: 2026-10-10 · **Lane**: `dispatch-a28dc5c9` · **Proceeds on**: Q1 = A, Q2 = A, Q3 = A (the doc's recommendations)

**Verdict: 5 agree, 8 change, 0 missing; +6 use cases.**

The two rules, as business-needs.md section 1 defines them, are the yardstick:

- **Rule 1 (site worker)**: the normal week is approved on a phone in <= 3 taps, prefilled, big targets, only exceptions need work, offline.
- **Rule 2 (IT person)**: a standing "accept my standard day", activity split automatically, zero typing.

Score key: **pass** = the need as written can meet the rule; **fail** = it cannot as written; **n/a** = the persona never touches it. A score after "->" is the score once the proposed change is made.

One observation on the doc itself: section 4 marks **7** rows `Gap` (BN-3, 4, 5, 7, 8, 11, 13), `grep -c '| Gap |' business-needs.md` -> 7; a summary saying "8 gaps" counts one `Partly` row as a gap.

---

## 1. Per business need

### BN-1 Clock in and out
- **change**: daily clock-in/out is two taps a day, ten a week; it cannot meet Rule 1, and it is manual work that Rule 2 rules out.
- Rule 1: **fail** -> pass · Rule 2: **fail** -> pass
- Exact change: "The day is prefilled from the worker's planned shift (BN-8) or standard day (Q3 = A) and confirmed weekly. Clock-in/out is an **exception path**: a shared shop terminal, or a worker with no plan for that day."

### BN-2 Book hours to a job, site or work order
- **change**: right need, but a daily job pick is a tap per day; the job must come prefilled, and a "job" needs a quote to serve BN-10.
- Rule 1: **fail** as written (a pick per day) -> pass · Rule 2: pass (Q3 = A split)
- Exact change: "The default target of each day is the site or job the worker is planned on (BN-8); the worker changes it only on a day that differed. A job carries its quoted hours, so BN-10 can compare." Add a `job` target type next to topic / issue / channel.

### BN-3 Breaks, travel, waiting time
- **change**: recording them separately by hand breaks both rules; most of it is a firm rule, not an entry.
- Rule 1: **fail** -> pass · Rule 2: pass (auto-deducted)
- Exact change: "The statutory break is deducted automatically by a firm rule (e.g. 30 min once a day exceeds 6 h). Travel and waiting are exception rows the worker or foreman adds only on days they occurred; travel between two planned sites is prefilled from the plan."

### BN-4 Overtime, evening, night, weekend, holiday rates
- **agree**: computed from approved hours, never entered; neither persona sees it.
- Rule 1: n/a (pass) · Rule 2: n/a (pass)
- No change to the need. The implementing spec needs a firm rate calendar (public holidays, night window, weekly threshold) kept by the office.

### BN-5 Foreman records or fixes hours for a crew
- **change**: agree with Q1 = A, but it collides with owner requirement R4 ("the workers should approve them"), and an edit by someone else needs a trace.
- Rule 1: pass (0 taps when the foreman enters) · Rule 2: n/a
- Exact change: "A foreman (`hours.approve` scoped to their crew) can enter or fix a crew member's day. Every such row records who entered it. The worker sees it with a one-tap **Dispute**; undisputed rows count as the worker's approval at the freeze." This keeps R4 true without adding taps.

### BN-6 Foreman approves the week; a post-approval correction needs a reason
- **change**: in spec 107 `hours.approve` is workspace-wide; a 100-person firm has several foremen, each approving only their crew.
- Rule 1: n/a · Rule 2: n/a
- Exact change: "The foreman approves **their crew's** week on a phone (Approve all for the crew, one tap). `hours.approve` can be scoped to a crew; the owner/office keeps the workspace-wide grant." Correction-with-reason stays as written.

### BN-7 Absences with balances
- **agree** with Q2 = A (absence target types, no balance engine in v1).
- Rule 1: pass (an absence is an exception: day -> Sick, 2 taps) · Rule 2: pass (an absence replaces the standard day, no typing)
- No change to the need. For the spec: a planned vacation is entered once as a date range by the worker or office, not day by day.

### BN-8 Shift plans, who is on which site tomorrow
- **change**: this is the **source** of the prefill that BN-1, BN-2 and BN-3 need for Rule 1; it should be ranked a prerequisite, not a peer.
- Rule 1: pass (it is what makes 3 taps possible) · Rule 2: n/a
- Exact change: "Promote BN-8 to the prefill source of Rule 1. Minimum: a crew-to-site assignment per day, repeated from last week by default, editable by the foreman or office."

### BN-9 Lock the pay period, export to payroll
- **agree**: spec 107's freeze plus CSV/XLSX covers the lock; the payroll format is a mapping.
- Rule 1: n/a · Rule 2: n/a
- No change to the need. The export must carry the BN-4 rate categories and the BN-7 absence codes as columns.

### BN-10 Reports: cost per job against quote, per person, overtime trends
- **agree**: back office; depends on BN-2 carrying the job's quote and a cost rate per person or grade.
- Rule 1: n/a · Rule 2: n/a
- No change to the need.

### BN-11 Subcontractors and agency workers apart from employees
- **change**: the need does not say what is tracked: a subcontractor usually invoices per company, an agency worker often has no account or phone.
- Rule 1: **fail** for a worker without an account -> pass · Rule 2: n/a
- Exact change: "A member is typed employee / agency / subcontractor. Agency workers without an account are logged by their foreman (BN-5). Subcontractor hours roll up per company for invoice checking and are left out of the payroll export (BN-9)."

### BN-12 Legal record of working time, kept for years
- **change**: working-time records usually need **start and end times and breaks per day**, plus who changed what; spec 107 stores minutes per (day, target) only, and "for years" needs a stated retention.
- Rule 1: pass if start/end come from the plan (BN-8) · Rule 2: pass if derived from the standard day
- Exact change: "Keep, per worker per day, start, end, break minutes and every change with author, time and reason, for a firm-configured number of years; export it per worker and period for an inspector." Start/end are prefilled, never typed.

### BN-13 Work offline, sync later
- **agree**: a direct Rule 1 mandate.
- Rule 1: pass (required) · Rule 2: n/a
- No change to the need. For the spec: the week view and **Approve** must work offline (cached app, queued write); on sync a frozen period wins and the worker sees why.

---

## 2. Use cases a 100-person firm needs that no BN covers

1. **The nudge that starts the 3 taps.** A site worker never opens a calendar, and spec 107 v1 has no pop-up or push (spec 5.1, 11). Rule 1 needs one phone notification ("Your week: 40:00 at Site A · [Approve]") so tap 1 lands on the approve screen.
2. **Who is on site right now.** The foreman and safety officer need today's headcount per site (evacuation, site register), read from the plan plus clock exceptions.
3. **A leaver's final pay.** Someone leaving mid-period needs their period closed early for the final payslip; spec 107 has no "freeze now" (owner Q4).
4. **A correction after payroll ran.** A correction to an exported, frozen period must flow into the next pay run as an adjustment line, not rewrite the exported period.
5. **Working-time limit warnings.** The foreman and office are warned before a worker breaks the daily rest or the weekly maximum, rather than finding it in the BN-12 record afterwards.
6. **The worker's language.** Site crews are often multilingual; the worker's approve screen must be in the worker's language.

Signed: business-needs.md sha 5c3f1fe42
