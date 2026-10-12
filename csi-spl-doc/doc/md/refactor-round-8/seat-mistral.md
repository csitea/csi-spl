# Refactor round 8 - mistral seat (m-033, PC)

Verdicts on `origin/master` (mapped sha `6165cfc71`), n=1 per count. The plan's commands and n are in section 2.

| #  | Verdict               | Command / Note                                                                                     |
|----|-----------------------|----------------------------------------------------------------------------------------------------|
| 01 | **Agree with changes** | The plan states: "orc-suite and hub-suite stop only once no job outside them is still running". The measurement shows 0 of 32 shards stopped, which contradicts the plan's claim. The fix must ensure the suites stop **only when no other job is running**. |
| 02 | Agree                 | `grep -cE '=== [A-Za-z0-9._-]+\\.tst\\.sh'` on the logs of cancelled shards: 1236 of 5288 verdicts printed. The fix prints all finished files on stop. |
| 03 | Agree                 | `gh run list --workflow 10_ci-quality.yml --limit 13 --json headBranch --jq 'map(select(.headBranch != "master")) | length'`: 3 of 13 runs were branches. The fix reads `master` only. |
| 04 | Agree                 | `awk` over all `.sh` files: 294 one-liners, 270 unmeasured functions. The fix measures one-liners correctly. |
| 05 | Agree                 | `spool_notify_poke`: 110 lines, `_ppl_run_one`: 109 lines. The fix splits them under 80.          |
| 06 | Agree                 | `test-strip-two-envs.sh`: 9 sleeps, `test-strip-two-way.sh`: 2 sleeps. The fix replaces them with bounded polls. |
| 07 | Agree                 | `useMove`: 182 lines. The fix splits it under 80.                                                  |
| 08 | Agree                 | `useScrollAnchor`: 208 lines. The fix splits it under 80.                                          |
| 09 | Agree                 | `go tool cover -func`: 42 functions at 0% in `cmd/spool`. The fix raises coverage.                 |
| 10 | Agree                 | `git ls-remote`: 15 `review/r8-*` or `wip/*r8*` branches. The fix prunes them after the retro.      |

Signed: plan sha 7508d04c3