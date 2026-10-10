# 107 Hours tracking: Business Needs

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
