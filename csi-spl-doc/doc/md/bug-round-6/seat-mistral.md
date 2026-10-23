# Bug Round 6: Mistral Reviewer Verdict

**Row 01**: `b06-01-orc-dispatch-lag-grace`

## Verdict: Agree
The row describes a real defect. The evidence:

1. **Defect**: Confirmed.
   - The file at `50743edbb` defaults `DISPATCH_LAG_GRACE` to 30 min (line 40 in `csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh`).
   - The red control (checking for `DISPATCH_LAG_GRACE=30`) passes, meaning the defect is present.
   - The baseline measurement (n=48) shows **23% of runs exceed 30 min**, and **p90 is 34 min**. The 30-minute grace is shorter than a normal deploy.

2. **Lane**: `csi-spl-orc`.
   - The file `csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh` is owned by `csi-spl-orc`.

3. **Sites**: Only the default value in `spl-dispatch-deploy-lag.func.sh:40`.
   - No other references to `DISPATCH_LAG_GRACE` in the file or the repo at `50743edbb`.

4. **Red control**: Fails to fail (passes), confirming the defect.

5. **Default (60 min)**: Sound.
   - **23% of runs exceed 30 min**, and **p90 is 34 min**. A 60-minute grace is conservative but safe: it avoids false GAP fires while still catching truly broken deploys (none observed in the last 48 runs).

## Not a bug

- **(b)**: Confirmed. The `placed: <id>` note goes to the ask's `.from`, not the dispatcher. The hub row stores no enqueuer, and re-enqueueing a placed ask is refused. This is by design.
- **(c)**: Confirmed. Round 5 rows 01 and 02 (the R7 review-line check) are landed on `50743edbb`. No open defects.

## Evidence
- **Red control**: `grep -n "DISPATCH_LAG_GRACE" /tmp/m-278-scratch/01/csi-spl-orc/src/bash/run/spl-dispatch-deploy-lag.func.sh` -> line 40: `local grace="${DISPATCH_LAG_GRACE:-30}"`.
- **Baseline**: `gh run list --workflow 20_hub-build-deploy.yml --status success -L 100` (n=48, p50=23.6, p90=34.0, 11 exceed 30 min, 0 exceed 60 min).
- **(b)**: `git show 50743edbb:csi-spl-orc/src/bash/run/spl-spawn-placed.func.sh | sed -n '2,8p;29p'` and `git show 50743edbb:csi-spl-orc/src/bash/run/spl-spawn-queue.func.sh | sed -n '116,134p'`.
- **(c)**: `git log --oneline 35a8a111d..50743edbb -- csi-spl-orc/src/bash/run/spl-review-line-check.func.sh`.

## Session log
- **Path**: The session log under `<HARNESS_USER>/.vibe/logs/session/unified/` (this session).