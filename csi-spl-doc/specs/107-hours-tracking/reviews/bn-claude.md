# 107 Hours tracking: business-needs review, seat bn-claude

**Reviews**: [business-needs.md](../business-needs.md) at `5c3f1fe42` (13 BNs, two personas, 3 open questions), with [spec.md](../spec.md) v1.2 for context · **Seat**: bn-claude (c-715) · **Date**: 2026-10-10
**Lane dispatch**: `dispatch-a28dc5c9` · **Assumes**: Q1 = A, Q2 = A, Q3 = A (the file's recommendations), unless the owner answers otherwise.

**Verdict: agree with changes.** The two rules are the right yardstick, and the 13 BNs are the right list for a 100-person construction firm or metal workshop. One finding matters more than the rest: **spec 107 v1 prefills hours only from in-app activity (posts, tab minutes, meetings), and a site worker has almost none.** For Persona 1 the suggestion is empty, so the v1 engine cannot meet Rule 1 at all. A site worker's prefill has to come from the shift plan (BN-8) or from the foreman (BN-5). BN-8 is therefore not a weekly back-office extra but the precondition of Rule 1. Section 1 scores each BN, section 2 lists the use cases no BN covers.

**Score key.** Rule 1 (site worker: the normal week on a phone in <= 3 taps, prefilled, big targets, offline) and Rule 2 (IT person: zero typing, a standing standard day split automatically), both from business-needs.md section 1. Each BN is scored as written: **pass**, **at risk** (passes only with the change given), **fail**, or **n/a** (that persona never touches it).

---

## 1. Per BN

| ID | Verdict | Why (one line) | Rule 1 | Rule 2 |
|---|---|---|---|---|
| BN-1 | change | A daily clock in and out is 10 taps a week; the normal day should be confirmed, not clocked. | fail | fail |
| BN-2 | change | Picking a job every day breaks Rule 1; the job must come prefilled from the plan. | at risk | at risk |
| BN-3 | change | Breaks are a rule, not an entry; only travel and waiting are exceptions. | at risk | pass |
| BN-4 | agree | Rates are computed from approved hours; nobody types an overtime number. | pass | pass |
| BN-5 | agree | Q1 = A is the main way site hours get in; the worker still needs a say. | pass | n/a |
| BN-6 | change | Spec 107 grants approval workspace-wide to the biz owner; a foreman approves their own crew only. | n/a | n/a |
| BN-7 | change | The BN says "with balances", Q2 = A says without: split it explicitly. | pass | at risk |
| BN-8 | change | It is the prefill source for Persona 1, not a planning extra. | at risk | n/a |
| BN-9 | agree | Freeze plus biz-owner approval is the lock; the payroll format is a mapping. | n/a | n/a |
| BN-10 | missing use case | Labour cost against the quote needs cost rates and quotes that no BN records. | n/a | n/a |
| BN-11 | agree | A worker type on the member is enough; most of their hours come in via BN-5. | n/a | n/a |
| BN-12 | change | A legal working-time record usually needs start and end times plus an audit of corrections, not daily totals. | n/a | n/a |
| BN-13 | agree | Rule 1 says "works offline" outright; scope it to the three taps. | at risk | n/a |

Tally: **5 agree, 7 change, 1 missing use case; +8 use cases** (section 2).

### 1.1 The exact changes

**BN-1 (change).** Replace the Need text with:
> Each worker's normal day is prefilled from the shift plan (BN-8) or the standard day (Q3) and confirmed for the whole week in one tap. Clock in and out is an **exception** (late start, early leave, extra hours), on a phone or on a shared terminal in the shop where the worker identifies with a badge or PIN.

Rule 1 then passes: open, Approve week, done (2 taps). Rule 2 passes with Q3 = A. The shared terminal needs an identity that is not an e-mail login (section 2, U1).

**BN-2 (change).** Add to the Need text:
> The job or site is prefilled from the shift plan for a worker and from tracked activity for an office member; the worker changes it only when the day differed. Each job carries its site and its quote (BN-10).

Spec 107's targets (topic, issue, channel) have no job or site entity; a job is either a new target type or a topic tagged as a job. That choice belongs to the v2 gap spec, not here.

**BN-3 (change).** Replace the Need text with:
> Breaks are deducted by a workspace rule (e.g. 30 min after 6 h) unless the worker marks "no break". Travel between sites and waiting time are exception rows, one tap each from the day ("+ Travel", "+ Waiting"), with a default length the worker can adjust.

Rule 1: the normal day needs zero break taps. Rule 2: the standard day already excludes the break.

**BN-4 (agree).** Add one sentence: the rate category of every approved minute is derived from the time of day, the weekday and the public-holiday calendar (section 2, U5), never chosen by the worker. Without start and end times (BN-12) evening and night rates cannot be derived, so BN-4 depends on BN-12's change.

**BN-5 (agree, with Q1 = A).** Add to the Need text:
> A row entered by the foreman shows its author; it lands in the worker's week prefilled, and the worker's Approve week covers it. A worker who disagrees taps "Not right" and adds a note; the row goes back to the foreman before the freeze.

Spec 107 section 4.4 says "the biz owner never edits a worker's minutes"; Q1 = A reverses that for the foreman, before the freeze only. After the freeze the existing Return path stays the only way back.

**BN-6 (change).** Replace "The foreman approves the week's hours" with:
> The foreman approves the week's hours **for their own crew**, on a phone in <= 3 taps ("Approve crew"); the office or the owner approves the rest and sees every crew. A correction after approval needs a reason and is logged with its author.

Spec 107 grants `hours.approve` workspace-wide (section 6.1); a crew scope is a v2 gap. The foreman is also a phone user on site, so Rule 1 applies to the foreman too.

**BN-7 (change, with Q2 = A).** Replace "with balances" with:
> v1: an absence (sick, vacation, unpaid, training, public holiday) is a whole-day or part-day row picked from a short list (2 taps). Balances (vacation days left) are a later step; until then the worker sees the count of days taken this year.

Rule 2: an office member's all-day calendar event of a registered absence kind should become the absence row by itself (zero typing); today spec 107 does not count all-day events at all (section 1.4), so this is a v2 gap.

**BN-8 (change).** Raise its weight and add to the Need text:
> The plan says who works on which site or job and which shift, for tomorrow and the week. **It is the prefill for every worker without in-app activity**: a planned day becomes that worker's suggested day.

Without it Persona 1 sees empty days and every week costs typing; this is the single largest gap against Rule 1.

**BN-9 (agree).** Add: the export columns map to a configurable payroll format (a column map per workspace), and an export is offered as final only for a period whose every member is approved.

**BN-10 (missing use case).** Add a new need, BN-14:
> Record a cost rate per person or per role (with the date it starts), and a quoted labour budget per job (hours or money). Reports compare approved hours x rate against the quote while the job is running, not only at the end.

Without it BN-10's "labour cost against the quote" has no numbers to compute from.

**BN-11 (agree).** Add: a member carries a worker type (employee, subcontractor, agency) and, for agency workers, the agency; reports and the export split by it. Most subcontractors will not have an account, so their hours come in via the foreman (BN-5).

**BN-12 (change).** Replace the Need text with:
> Keep a working-time record per person and day, with start and end times, breaks, and every correction (who, when, why), for a retention period the workspace sets (in years), read-only and exportable for an inspector.

Spec 107 stores minutes per target per day; it has no start and end times, and its frozen periods are "kept indefinitely" with no retention setting. The law that applies varies by country; the BN should name what the record must hold, not one country's rule.

**BN-13 (agree).** Add the minimum offline scope: the week view, Approve week, an absence pick and a clock exception work without a network and sync later; a conflict with a foreman's edit made meanwhile shows both values and asks the worker once.

---

## 2. Use cases a 100-person firm needs that no BN covers

| # | Use case | Why it matters | Rule |
|---|---|---|---|
| U1 | **A worker with no e-mail or no smartphone.** The foreman or the office creates the account; the worker signs in on a shared terminal with a badge or PIN. | Many site workers and most agency staff have no work e-mail; BN-1's shared terminal needs an identity. | 1 |
| U2 | **Working-time limits.** Warn the foreman and the worker before a day or week goes past the maximum hours, or below the minimum rest between shifts. | Breaking these is a legal risk for the firm, and the warning is cheap once BN-12 records start and end times. | n/a |
| U3 | **Two sites in one day.** Split the planned day between two jobs in one tap ("Split"), with the travel between them (BN-3). | Common in construction; without it a worker types two rows. | 1 |
| U4 | **Allowances and expenses tied to hours**: per diem, meals, mileage, own-vehicle use, tool allowance. | Payroll needs them with the hours (BN-9); a separate system means a second entry per day. | 1 |
| U5 | **A public-holiday calendar per workspace (and region).** It prefills the holiday as an absence and drives holiday rates (BN-4). | Without it every holiday is typed by hand or paid at the wrong rate. | 1, 2 |
| U6 | **The worker sees their own numbers**: hours this week and month, overtime, absence days taken. | It removes most "how many hours do I have" calls to the office and builds trust in prefilled hours. | 1 |
| U7 | **A plain, multilingual phone UI for site staff**: icons with short labels, large targets, the worker's own language. | Mixed-language crews are common; Rule 1's "big targets" is not enough if the label is not understood. Translated text gets the fleet's language review before it ships. | 1 |
| U8 | **A correction after the payroll export.** A late fix goes into the next open period as an adjustment row with a reason, instead of reopening a paid period. | Spec 107 has Return before the final approval only; a paid period must stay paid. | n/a |

Signed: business-needs.md sha 5c3f1fe42
