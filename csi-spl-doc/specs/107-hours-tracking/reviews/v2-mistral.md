signed against 9260921ef

# Review: spec 107 v2.0-draft, seat v2-mistral

## FR-14..FR-37: Agree / Change / Missing

| FR | Verdict | Notes |
|---|---|---|
| **FR-14** | Agree | Standard day per organisation and person, with overrides. Aligns with BN-14, O1, O2, O3. |
| **FR-15** | Agree | The Standard Day (Q3 = A) scales activity to the standard day. Zero typing for IT person (Rule 2). |
| **FR-16** | Agree | Shift plan as prefill source (BN-8). Repeats from last week by default. |
| **FR-17** | Agree | Prefill chain (absence > foreman > plan > Standard Day > v1 activity). Rule 1 pass: prefilled, confirms not types. |
| **FR-18** | Agree | Job target with quote (BN-2, BN-15). No money in hours tracking. |
| **FR-19** | Agree | No money in hours tracking (O4). Rates live in accounting view. |
| **FR-20** | Agree | Time-accountant role (O5, O6). Only holders see rates. Roles combine. |
| **FR-21** | Agree | External accountant seat (O7). Invite-only, hours/rates only, no WUI socket. |
| **FR-22** | Agree | `hours.approve` scoped to crew (BN-6, BN-14). Foreman sees crew only. |
| **FR-23** | Agree | Foreman entry with Dispute (BN-5, Q1 = A). Proposed rows, Dispute flow. |
| **FR-24** | Agree | Clock in/out as exception (BN-1). Replaces start/end of plan/Standard Day. |
| **FR-25** | Agree | Shared terminal identity (BN-1, U2). Badge/PIN, no e-mail login. |
| **FR-26** | Agree | Break rule (BN-3). Deducted unless "No break" tapped. |
| **FR-27** | Agree | Travel and waiting rows (BN-3). Prefilled for two jobs (U3). |
| **FR-28** | Agree | Derived rate categories (BN-4). Holiday > night > weekend > evening > normal. No money. |
| **FR-29** | Agree | Holiday calendar (U5). Prefills absence row. Drawn in calendar. |
| **FR-30** | Agree | Absence types (BN-7, Q2 = A). Whole day = standard day. No balances in v2. |
| **FR-31** | Agree | Worker type (BN-11). Subcontractor hours out of payroll export. |
| **FR-32** | Agree | Day record (BN-12). Start, end, break, standard day, source. Never typed. |
| **FR-33** | Agree | Change log (BN-12, BN-6). Required reason after approval. |
| **FR-34** | Agree | Retention (BN-12). `hours.retention_years` (1..30). Inspector export. |
| **FR-35** | Agree | Offline approval (BN-13). Week view, Approve week, absence pick, clock exception. |
| **FR-36** | Agree | Approve nudge (U1). Web Push, 2 taps from lock screen. |
| **FR-37** | Agree | Hours per workspace (O8). Cross-workspace tracking out of scope. |

## Gaps from business-needs 6.6 or owner input
None. All gaps from business-needs 6.6 are addressed by FR-14..FR-37 (section 17 of the spec).

## Section 15: Ranked candidates (BN-9, U3, U4, U6..U10, U12)

| Rank | Candidate | Why |
|---|---|---|
| 1 | **U9** (working-time limit warnings) | Legal risk; cheap after FR-32. |
| 2 | **BN-9** (payroll column map) | Export useless to payroll without categories. |
| 3 | **U6** (absence balances) | Useful for workers, but no legal risk. |
| 4 | **U7** (absence approval flow) | Adds complexity; not critical. |
| 5 | **U8** (absence import) | Nice to have, but not urgent. |
| 6 | **U10** (absence calendar) | Visual, but not critical. |
| 7 | **U4** (absence notes) | Per-day note, not per-line. |
| 8 | **U12** (absence reminders) | Low priority. |
| 9 | **U3** (travel between jobs) | Already handled by FR-27. |

## Section 16, Q8 (U11: closing a leaver's period early)
**Recommendation: C (Close on the leave date).**
- Reuses `access_until` (072 A27).
- No new button.
- The leave-date change is the audit line.
- Keeps Q4 = B ("no manual freeze").