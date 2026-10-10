# Review: Business Needs for Hours Tracking (Mistral Seat)

**Signed: business-needs.md sha 5c3f1fe42**

## Summary
- **Agree**: 6 (BN-2, BN-6, BN-9, BN-10, BN-12, BN-13)
- **Change**: 5 (BN-1, BN-3, BN-5, BN-7, BN-8)
- **Missing**: 2 (BN-4, BN-11)
- **Additional Use Cases**: 2

---

## Per Business Need

| ID  | Verdict | Why                                                                                                                                                                                                 | Rule 1 (3-Tap) | Rule 2 (Zero Typing) | Change Required                                                                                     |
|-----|----------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|----------------|----------------------|------------------------------------------------------------------------------------------------------|
| BN-1 | Change   | Clock in/out is manual. Prefill a default shift (e.g., 8:00-16:00) instead of a timer.                                                                                                              | 3/5            | 5/5                  | Replace timer with prefilled shift rows (e.g., "Shift: 8:00-16:00").                              |
| BN-2 | Agree    | Hours are prefilled and booked to jobs/issues via discussions. The `+ Add` row allows manual booking if needed.                                                                                     | 5/5            | 5/5                  | None.                                                                                               |
| BN-3 | Change   | Breaks, travel, and waiting time are not auto-detected. Add predefined rows for these (e.g., "Break: 0:30") that the worker can approve or adjust.                                                  | 4/5            | 3/5                  | Add predefined rows for "Break," "Travel," and "Waiting."                                     |
| BN-4 | Missing  | Overtime and special rates are not supported. Add a toggle for "Overtime" or "Weekend" in the dialog, with auto-calculated rates.                                                                  | 2/5            | 2/5                  | Add overtime/weekend toggles with auto-calculated rates.                                            |
| BN-5 | Change   | Foremen cannot edit worker hours. Add a "Foreman Mode" where holders of `hours.approve` can edit crew hours.                                                                                        | 3/5            | 5/5                  | Add "Foreman Mode" for `hours.approve` holders to edit crew hours.                                |
| BN-6 | Agree    | The foreman/biz owner approval workflow is already implemented.                                                                                                                                     | 5/5            | 5/5                  | None.                                                                                               |
| BN-7 | Change   | Absences are not tracked. Add predefined rows for "Sick Leave," "Vacation," etc., that the worker can approve.                                                                                     | 4/5            | 4/5                  | Add predefined rows for absences (e.g., "Sick Leave," "Vacation").                             |
| BN-8 | Change   | Shift plans are not integrated. Prefill hours from shift plans (e.g., "Site A: 8:00-16:00") and allow the worker to confirm.                                                                        | 4/5            | 5/5                  | Prefill hours from shift plans (e.g., "Site A: 8:00-16:00").                                      |
| BN-9 | Agree    | Payroll export is already implemented.                                                                                                                                                              | 5/5            | 5/5                  | None.                                                                                               |
| BN-10| Agree    | Reports and cost tracking are already implemented.                                                                                                                                                  | 5/5            | 5/5                  | None.                                                                                               |
| BN-11| Missing  | Subcontractors and agency workers are not supported. Add a "Worker Type" field to distinguish them.                                                                                                | 3/5            | 3/5                  | Add "Worker Type" field (Employee/Subcontractor/Agency).                                          |
| BN-12| Agree    | Legal records are already kept.                                                                                                                                                                     | 5/5            | 5/5                  | None.                                                                                               |
| BN-13| Agree    | Offline support is already implemented.                                                                                                                                                             | 5/5            | 5/5                  | None.                                                                                               |

---

## Missing Use Cases for a 100-Person Firm
1. **Multi-Site Coordination**: Workers split across multiple sites need a way to log hours per site without manual entry.
2. **Equipment Usage Tracking**: Track which equipment (e.g., cranes, tools) was used for each job to allocate costs accurately.