# BN Review (s107-bn-agy)

**BN-1**
Verdict: change
Why: Manual clocking requires daily taps and violates zero typing.
Score: Rule 1: Fail, Rule 2: Fail
Exact change: Prefill a default shift for P1, and implement Q3:A (Standard Day toggle) for P2.

**BN-2**
Verdict: change
Why: Manual booking requires typing and selecting small targets.
Score: Rule 1: Fail, Rule 2: Fail
Exact change: Auto-split standard hours across hub activity (Q3:A) for P2, prefill jobs from shift plans for P1.

**BN-3**
Verdict: missing use case
Why: Standard breaks should auto-deduct to avoid manual entry, but are currently unaddressed.
Score: Rule 1: Fail (if manual), Rule 2: N/A
Exact change: Auto-deduct standard breaks and add exception targets for travel/waiting.

**BN-4**
Verdict: missing use case
Why: Overtime is explicitly excluded from the spec but required for payroll.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: Add categorization of hour types for export without changing the worker UI.

**BN-5**
Verdict: agree
Why: Delegating entry to the foreman achieves zero-friction for the worker.
Score: Rule 1: Pass, Rule 2: N/A
Exact change: Proceed with Q1:A to allow foreman editing.

**BN-6**
Verdict: agree
Why: Standard management workflow independent of worker data entry.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: None.

**BN-7**
Verdict: agree
Why: Essential for complete timesheets, resolved by adding basic non-working target types.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: Proceed with Q2:A to add basic non-working target types.

**BN-8**
Verdict: missing use case
Why: Shift plans are perfect for prefilling hours but are absent in the spec.
Score: Rule 1: Pass, Rule 2: N/A
Exact change: Integrate shift plans to prefill timesheets for P1.

**BN-9**
Verdict: agree
Why: Back-office feature that does not increase entry friction.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: None.

**BN-10**
Verdict: missing use case
Why: Cost per job and overtime trends are needed but excluded.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: Include cost and overtime trends in back-office reporting.

**BN-11**
Verdict: missing use case
Why: Needed for accurate back-office tracking but unsupported in the spec.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: Add support for subcontractor or agency worker roles.

**BN-12**
Verdict: agree
Why: Covered by indefinite retention of frozen periods.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: None.

**BN-13**
Verdict: missing use case
Why: Direct mandate for offline work, but v1 web UI requires a network.
Score: Rule 1: Pass, Rule 2: Pass
Exact change: Implement full offline capability for the hours WUI.

**Missing use cases for a 100-person firm not covered by any BN:**
- Mileage and Expense Tracking: Submitting travel mileage or material expenses alongside timesheets.
- Weather/Delay Logging: Logging downtime reasons (e.g., "rain delay") against a job to explain hours without output.

Signed: business-needs.md sha 5c3f1fe42
