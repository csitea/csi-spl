# Review: s107 v2 panel, seat v2-mistral

**Signed against 9260921ef** (spec v2.0-draft).

## FR-14..FR-37: Agree/Change/Missing

| FR | Verdict | Notes |
|---|---|---|
| **FR-14** | Agree | Default hours per day (workspace + per-person) is essential for Rule 1/2. |
| **FR-15** | Agree | Standard Day toggle for IT persona (zero typing) is critical. |
| **FR-16** | Agree | Shift plan as prefill is the only way to meet Rule 1 for site workers. |
| **FR-17** | Agree | Exception clock in/out is necessary for shared terminals and offline work. |
| **FR-18** | Agree | Job target with quote enables cost tracking and aligns with BN-2. |
| **FR-19** | Agree | Money stays out of hours tracking; rates belong in accounting. |
| **FR-20** | Agree | Multiple roles per member enable crew-scoped `hours.approve`. |
| **FR-21** | Agree | `access_until` for guests/subcontractors is a must. |
| **FR-22** | Agree | Break rule reduces manual entry for site workers. |
| **FR-23** | Agree | Travel/waiting rows handle exceptions without friction. |
| **FR-24** | Agree | Foreman entry with Dispute balances delegation and worker control. |
| **FR-25** | Agree | Crew-scoped `hours.approve` is the only scalable way to handle multiple foremen. |
| **FR-26** | Agree | Absence types (no balances) keep timesheets complete for payroll. |
| **FR-27** | Agree | Worker type (employee/agency/subcontractor) is needed for BN-11. |
| **FR-28** | Agree | Derived rate categories keep the worker UI simple and auditable. |
| **FR-29** | Agree | Holidays as absences and rate drivers are non-negotiable for payroll. |
| **FR-30** | Agree | Leave as absence types (no balances) is the minimal viable solution. |
| **FR-31** | Agree | Start/end times and retention are legal requirements (BN-12). |
| **FR-32** | Agree | Offline approval is mandatory for site workers (BN-13). |
| **FR-33** | Agree | Approve nudge (push notification) is the only way to meet Rule 1’s "<= 3 taps". |
| **FR-34** | Agree | Shared terminal identity enables workers without smartphones. |
| **FR-35** | Agree | Two sites in one day is a common scenario for site workers. |
| **FR-36** | Agree | Push nudge (Web Push) is critical for timely approvals. |
| **FR-37** | Agree | Payroll column map ensures export compatibility. |

## Omissions from Business-Needs.md Section 6.6 or Owner Addenda

- **U4 (Allowances/expenses)**: Missing from FR-14..FR-37. Should be added as **FR-38** (Allowances/expenses tied to hours).
- **U6 (Worker’s own numbers)**: Missing. Should be added as **FR-39** (Worker dashboard for hours/overtime/absences).
- **U7 (Worker’s language)**: Missing. Should be added as **FR-40** (Plain phone UI in worker’s language, icons + short labels).
- **U8 (Correction after payroll)**: Missing. Should be added as **FR-41** (Adjustment rows for corrections in the next open period).
- **U9 (Working-time limit warnings)**: Missing. Should be added as **FR-42** (Warnings for foreman/office before exceeding max hours/min rest).
- **U10 (Who is on site)**: Missing. Should be added as **FR-43** (Today’s headcount per site from plan + clock exceptions).

## Section 15 Ranking (Priority for v2)

1. **FR-16** (Shift plan as prefill) – Enables Rule 1 ("<= 3 taps").
2. **FR-14** (Default hours per day) – Prefill for site workers and Standard Day.
3. **FR-25** (Crew-scoped `hours.approve`) – Scalable approval for multiple foremen.
4. **FR-33** (Approve nudge) – Critical for timely approvals (Rule 1).
5. **FR-32** (Offline approval) – Mandatory for site workers (BN-13).
6. **FR-24** (Foreman entry with Dispute) – Delegation + worker control.
7. **FR-28** (Derived rate categories) – Keeps worker UI simple.
8. **FR-26** (Absence types) – Completes timesheets for payroll.
9. **FR-18** (Job target with quote) – Enables cost tracking (BN-2).
10. **FR-31** (Start/end times and retention) – Legal requirement (BN-12).
11. **FR-29** (Holidays) – Drives holiday rates and absences.
12. **FR-37** (Payroll column map) – Ensures export compatibility.
13. **FR-22** (Break rule) – Reduces manual entry.
14. **FR-23** (Travel/waiting rows) – Handles exceptions.
15. **FR-17** (Exception clock in/out) – Shared terminals and offline.
16. **FR-34** (Shared terminal identity) – Workers without smartphones.
17. **FR-35** (Two sites in one day) – Common scenario.
18. **FR-36** (Push nudge) – Timely reminders.
19. **FR-27** (Worker type) – Subcontractor tracking.
20. **FR-20** (Multiple roles per member) – Crew-scoped permissions.
21. **FR-21** (Guest `access_until`) – Subcontractor/agency workers.
22. **FR-19** (Money stays out) – Rates in accounting.
23. **FR-15** (Standard Day toggle) – IT persona’s zero typing.
24. **FR-38** (Allowances/expenses) – Tied to hours.
25. **FR-39** (Worker dashboard) – Visibility for workers.
26. **FR-40** (Worker’s language) – Localization.
27. **FR-41** (Correction after payroll) – Adjustment rows.
28. **FR-42** (Working-time limit warnings) – Compliance.
29. **FR-43** (Who is on site) – Safety/foreman tool.

## Section 16 Q8 (U11): Closing a Leaver’s Period Early

**Agree with the owner’s decision (Option C)**: Close the period on the leave date.
- **Rationale**: The owner decided (msg 8afdd796) that a leaver’s final pay must not wait for the next freeze. The biz owner closes the period on the leave date, with an audit log (who, when, why). This aligns with BN-9 (payroll export) and U8 (corrections after payroll).