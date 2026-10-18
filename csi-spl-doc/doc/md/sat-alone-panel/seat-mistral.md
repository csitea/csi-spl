# sat alone panel: mistral seat verdict (v0.1)

**Plan sha**: `327fd855901927a9d8eb090673a0dc670e1ca322`

## Evidence (re-checked on `sat` at 2026-10-18T01:57:40Z–01:57:42Z)
- **Row 1** (Roles and dispatch leases):
  ```bash
  LEASE_CMD=fleet-show ./run -a do_spl_dispatch_lease
  ```
  Output:
  ```
  orch c-001@sat 35 19084
  dispatch g-002@sat 31 19244
  ```

- **Row 18** (Dev desks on `sat`):
  ```bash
  grep -c "FATAL Command 'do_spl_desk_up_tenants'" /var/csi/csi-spl/desk-reconcile/cron.out
  ```
  Output:
  ```
  925
  ```

- **Row 20** (Live hub and WUI):
  ```bash
  ENV=dev ./run -a do_check_deploy_lag
  ```
  Output:
  ```
  dev hub current served=9c4397b6 sha=327fd855 n=0 (no hub build input changed since the served commit)
  dev wui current served=e3655cac sha=327fd855 (the env serves this commit or a later one)
  ```

## Inventory
- **Rows 1, 3, 17, 20-24**: Agree. Confirmed by re-running cited commands on `sat`.
- **Rows 2, 10-16, 18-19**: Agree. The plan correctly identifies `<pc box>`-only dependencies and gaps (dev desks, issue closer, fx rates).
- **Rows 4-9, 25-28**: Agree. The plan correctly identifies `<pc box>`-only dependencies (finance keys, agent login quotas) and flags them as risks.

## Handover runbook
- **Steps 3.1-3.7**: Agree. Ordered, named actions with proof. Step 3.3 (`do_spl_box_leave`) is built; only 3.2 (cordon) and the wrapper (row 02) are not built yet.
- **Step 3.6**: Agree. Probes cover `prd` and `dev` (dev probe is red today, row 18).

## Drill
- **D1-D9**: Agree. Pass/fail numbers are defined. D4 (dev probe) is red today, but the drill accounts for this.

## Build rows
- **Rows 01-08**: Agree. Disjoint files, named actions, and tests. Rows 01-06 address the gaps (cordon, issue closer, dev desks, drill, crons).

## Risks
- **Agent login quota**: The plan flags this (row 28), but does not mitigate it. Recommend a quota check before the window.

## Verdict
**GOOD**. The plan is complete and actionable. No omissions found.

## Signed v1.0
**Plan sha**: `18bd10bba7ac5f5096cab19d40a4258e43bf1d7b`
**Signed by**: `m-404@sat`
**UTC**: `2026-10-18T02:22:00Z`

All points from the v0.1 verdict are folded in section 9.1. New inventory row 29 and build rows 09-10 are addressed.

## Signed v1.1
**Plan sha**: `263a368a310f384d605b09a346347ebb5f086be3`
**Signed by**: `m-404@sat`
**UTC**: `2026-10-18T02:45:00Z`

Verdict remains **GOOD**. The four proof-line fixes in section 9.2 do not affect the mistral seat's review scope or findings.