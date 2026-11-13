# Perf round 7 panel seat (g-666, grok)

Plan: `e599eabf239bec58e30581dacc256a13bd0ad6be` (`review/c002-perf-round-7-planner`).
Files on that commit: `csi-spl-doc/doc/md/perf-round-7-plan.md`, `csi-spl-doc/doc/md/perf-round-7/editor.md`.
Verdict: **PASS**. W1, W2 and W3 fold into v1.0 before the rows spawn. This file's parent, when committed, is worktree HEAD `ccef654f0329231cce02f9ec7a8f418c03dd62f0`.

Median below, when `n` is odd, is the middle sorted value. When `n` is even, it is the mean of the two central sorted values.

## 1. Slug

```
git fetch origin review/c002-perf-round-7-planner
```

printed `FETCH_HEAD=e599eabf239bec58e30581dacc256a13bd0ad6be`.

```
git fetch origin master
git rev-parse origin/master
git merge-base --is-ancestor ccef654f0329231cce02f9ec7a8f418c03dd62f0 origin/master
```

printed `origin_master=baa073831049e37b5983f421125254119b74c09e` and `ancestor_rc=0`.

```
git log origin/master --oneline -E --grep='\(p7-' | wc -l
```

printed `0`.

```
git ls-remote origin 'refs/heads/*p7-*'
```

printed one line: `04cde72cc46d6bfaeba5a0f98abd87c8741815bc refs/heads/review/c002-bug-s169-p7-scan-known-links`, and `wc -l` printed `1`. That ref is not a p7 row branch. See N1.

```
git log origin/master --format='%h %s' -E --grep='\(r58-'
```

printed subjects for r58-01, r58-02, r58-03, r58-04, r58-05 only (`6725d4709`, `4061ee214`, `8a76f8180`, `0a7f01ef8`, `2dfbc3eb4`). No r58-07 subject.

## 2. Sites at ccef654f0 and on origin/master

```
git diff --stat ccef654f0329231cce02f9ec7a8f418c03dd62f0 origin/master -- \
  csi-spl-api/src/go/spool-hub-api/internal/hub/wui.go \
  csi-spl-api/src/go/spool-hub-api/internal/hub/human_status.go \
  csi-spl-api/src/go/spool-hub-api/internal/hub/token_budget.go \
  csi-spl-api/src/go/spool-hub-api/internal/hub/flow.go \
  csi-spl-orc/src/bash/run/spl-lane-map.func.sh \
  csi-spl-orc/src/bash/run/run.sh \
  csi-spl-iac/src/bash/run/run.sh \
  csi-spl-utl/src/bash/run/run.sh \
  csi-spl-orc/src/bash/run/spl-agent-restart.func.sh \
  csi-spl-orc/src/bash/run/spl-sender-audit.func.sh \
  csi-spl-orc/src/bash/run/gh-runner-add.func.sh \
  csi-spl-orc/src/bash/run/spl-box-restart-after.func.sh \
  csi-spl-orc/src/bash/run/spl-agent-login-check.func.sh \
  csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh
```

printed no lines, `diff_rc=0`. The 14 paths are the same blob on both commits. None drifted.

`git rev-parse ccef654f0:` of the three `run.sh` copies (orc, iac, utl) printed the same blob `1cd9f13d892aa6731ee15b6dfd520eb078817e47` three times.

Lines checked with `git show ccef654f0:<file> | nl -ba | sed -n`:

- `wui.go:77-83` `write` returns `wsjson.Write`. `:88-94` `encodeFrame`. `:98-104` `writeRaw` writes the bytes. `:1311-1327` `fanoutChannelFrame`; `:1325` is `w.write(ctx, frame)` per target.
- `human_status.go:88-105` `broadcastStatus`; `:100-103` `c.write` per target per frame. `:106` is blank.
- `token_budget.go:110-111` builds one frame; `:117-121` `c.write` per connection. The loop closes at `:122`.
- `flow.go:255` builds one frame per member; `:256-258` `c.write` per socket. `:298` builds one frame; `:299-300` `c.write` per socket.
- `issues.go:505-524` `fanoutIssue` (the encode-once shape the plan cites, not a row site): `:517` `encodeFrame` once, `:521-522` `writeRaw` per target.
- `spl-lane-map.func.sh:2` is the file header. `:322-334` `spl_lane_local_rows` (one `jq -s` at `:333`, and `spl_lane_local_row` per worktree at `:330`). `:336-344` `spl_lane_local_row`: `dirname` `:338`, `basename` `:339` and `:342`, `jq -n` `:342-343`.
- `run.sh:717-736` `do_load_functions`. The index `awk` is `:725-726`. The function returns at `:735`. Same blob in iac and utl.
- `spool-env.inc.sh:459-460` chooses `SPOOL_BIN`. `:479` calls `spool_resolve_bins`. `:486` defines `spool_resolve_bins`, which sets vendor CLI paths (`:490` loops `claude grok agy qwen vibe codex`). It does not exec `SPOOL_BIN`.
- Row 04 tops, first function in parentheses: `spl-agent-restart.func.sh:76-83` three `source` lines and `ARS_CAUSES` (`do_spl_agent_restart` at `:85`); `spl-sender-audit.func.sh:24-27` a `readlink`/`dirname` plus three `source` lines (`:29`); `gh-runner-add.func.sh:74-77` one `source` and `GH_RUNNER_PKGS`, `ghr_docker_flavour` at `:86-94` with `dpkg -s docker-ce` at `:88`, bare call at `:95`; `spl-box-restart-after.func.sh:21-26` three `source` lines, `SPL_BRX_AGENT_WIN_RE` at `:28`; `spl-agent-login-check.func.sh:69` one `source`, `:70-71` two regexes (`:73`).

`git grep -n r58-07 ccef654f0 -- csi-spl-doc/doc/md/refactor-round-32-plan.md` printed line 116: row 07 sites include `orc:run/spl-lane-map.func.sh:2`.

## 3. Rows

Plan table is lines 70-76. Five rows, under the cap of 10. Each vendor cell is `claude`. Kinds: 01, 02, 04, 05 `simple_coding`; 03 `complex_coding` (R9 named on line 74). No mistral row (plan lines 19-20 and 78-79).

Sites per row: 01 has five ranges (the cap), 02 one, 03 three copies of one range, 04 five files, 05 one file. Batch 1 is rows 01, 03, 04, 05 and the path sets do not overlap (plan lines 83-87). Batch 2 is row 02 only.

Each row has a baseline with a command, a number and `n`, a counting or timing test, and a red control, in the same table cells. Medians recomputed from `editor.md` (python, odd-n middle):

| row | editor samples | median | plan cell |
|---|---|---|---|
| 01 per-socket ns / B / allocs | line 44 | 334734 / 20931 / 342 | line 72 says 334,735 / 20,930 / 342 |
| 01 encode-once | line 45 | 249846 / 16962 / 216 | matches |
| 02 `spl_lane_local_rows` ms | line 86: 4098, 3008, 4369, 4365, 4650 | **4365** | line 73 says **4,098** |
| 02 probe ms | line 87: 79, 77, 99, 101, 61 | 79 | matches; range 61..101 matches |
| 02 whole-call wall s | line 54 | 8.971 | line 73 says 8.97 |
| 03 awk ms | line 121: 169, 160, 163, 177, 165 | 165 | matches |
| 03 startup s | line 99: 0.898, 0.961, 0.919, 0.989, 0.950 | 0.950 | 950 ms matches |
| 03 eager ms | line 121: 478, 494, 510, 516, 479 | 494 | matches |
| 03 cache key s | line 127 | 0.012 | 12 ms matches |
| 04 per-file ms, n=3 | lines 131-132 | 121, 35, 33, 25, 22 (sum 236) | matches |

Percents on line 72 from 342 to 216, 20930 to 16962, and 334735 to 249846 are -37%, -19%, -25%. Using 20931 instead of 20930 does not change the rounded percents.

Row 05 (`editor.md` lines 152-155) publishes only the medians, not the 20 samples, so those two medians cannot be audited from the file. Section 4 is the remeasure.

## 4. Remeasure of row 05

`/usr/bin/time` is absent (`ls` printed `No such file or directory`). A first loop of 10+10 that called it exited `rc=127` on every arm (`2026-11-13T11:10:17Z`). Those samples are not used.

Cited run, `2026-11-13T11:12:58Z`, `/proc/loadavg` `20.42 27.65 30.06`, `nproc=16`. Binary: agent spool, `version` printed `1.1.3`. `command -v spool` printed `NONE`. Bash `TIMEFORMAT='wall %R user %U sys %S'`, the timed command only (no extra statement inside the group). `env SPOOL_ROOT=/var/spool-hub` and the same with `GOMAXPROCS=1`, `recv --as g-666`, no `--ack`, interleaved, n=10. Every arm `rc=0`, stdout 3 bytes `5b 5d 0a` (empty JSON array plus newline).

| arm | wall s | user+sys s |
|---|---|---|
| default | 0.055, 0.048, 0.056, 0.033, 0.032, 0.036, 0.038, 0.033, 0.039, 0.042 | 0.048, 0.055, 0.058, 0.049, 0.039, 0.051, 0.054, 0.048, 0.048, 0.054 |
| GOMAXPROCS=1 | 0.034, 0.038, 0.036, 0.029, 0.028, 0.031, 0.031, 0.032, 0.034, 0.036 | 0.031, 0.035, 0.035, 0.030, 0.029, 0.031, 0.031, 0.032, 0.032, 0.034 |

Medians: default **50.0 ms CPU, 38.5 ms wall**; `GOMAXPROCS=1` **31.5 ms CPU (-37%), 33.0 ms wall (-14.3%)**.

The plan (`editor.md` lines 154-155, n=20, `--as c-660`) says 51.0 / 67.5 versus 35.5 / 53.0 (-30% CPU, -21% wall). Default CPU agrees (50.0 vs 51.0). Both arms still drop under `GOMAXPROCS=1`. Absolute wall does not agree (38.5 vs 67.5), and the wall drop is smaller (-14% vs -21%). This seat's id, empty inbox, binary version, timer and n differ from the editor's. The gain direction agrees. See N6.

## 5. Lane map and the batch-2 wait

```
bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 14 paths in section 2, comma-separated> --agent g-666
```

First call this seat: `lane_rc=4`. The script printed a spool-env warning that the desk-cron spool binary is older than its sources (built `2026-10-31T02:27:08Z`, last source commit `2026-11-13T09:24:19Z`) and was not used. Then five `unknown:` lines for lanes with no files recorded: `c-382`, `c-528`, `c-895`, `c-897`, `g-796`. Each line also named a box. That box name is a distribution-hygiene ban, so it is not copied into this file. Zero `owned by` lines. Then `WARN no live lane lists` the 14 paths, `but 5 live lane(s) record no files`, and `FATAL Command 'do_spl_lane_map' failed at line 131 with status 4`.

Second call, same command, later the same day: the same spool-env warning, then the single word `free`, `lane_rc=0`. No `owned by` line and no `unknown:` line. `lane-map.sh --check` prints only `free` when the exit is 0.

The later call is free. The earlier call was not. The plan already says exit 4 is not free (lines 100-103) and that the check before each spawn asks a lane that is still unknown. The unknown set changed between the two calls, so the spawn-time check is the one that counts. `c-308`, named on plan line 102, was not in the exit-4 list.

The batch-2 wait is stated: plan line 73 (`2: after r58-07 lands`), lines 88-90 (spawn within 30 minutes of the commit that lands `refactor(r58-07-orc-action-headers-c)`, which edits `spl-lane-map.func.sh:2`), and lines 112-115 (r58-07 not landed; only row 02 meets it). It is enough for that known same-file edit: round-32 plan line 116 owns line 2, and row 02 owns lines 322-344. It does not replace the spawn-time lane-map check.

## 6. Distribution hygiene

From this worktree's `csi-spl-iac`, `./run -a do_check_dist_hygiene` printed the `ok` lines for the non-Csitea, personal-name, OS-user, home, mail, hidden-workspace, retired-relay and `.vibe` sweeps, then `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-666`, `hygiene_rc=0`. That run was before this file existed. The run after this file is tracked is appended at the bottom once it has been run.

## Defects

W1. Plan line 73 calls 4,098 ms the median of `spl_lane_local_rows` (n=5, range 3,008..4,650). `editor.md` line 86 samples are `4098, 3008, 4369, 4365, 4650`. Sorted, the middle is **4365**. 4098 is the first listed sample. The range matches. The probe median 79 matches, and 4365 ms versus 79 ms is still the gain. v1.0 replaces 4,098 with 4,365 before row 02 is quoted.

W2. Plan line 75 names five row-04 files and no file:line. Rulebook 3.1 asks for file:line, at most five. The tops are at the lines in section 2. v1.0 adds those lines. The sites exist, so this is not a miss.

W3. Plan line 76 names `:459-460` (where `SPOOL_BIN` is chosen) and `spool_resolve_bins` at `:486` as the edit site. The function at `:486` sets vendor CLI paths and does not exec `SPOOL_BIN` (section 2). Plan line 140 already says the prefix goes on `spool_resolve_bins` or the wrapper that runs `$SPOOL_BIN`. v1.0 names that wrapper, so the lane does not treat line 486 as the exec. The test on line 76 already pins the prefix. Not a fail of the measured gain (section 4).

## Notes

N1. The `*p7-*` ref is `review/c002-bug-s169-p7-scan-known-links`. The subject grep is 0. Not a p7 slug collision.

N2. `origin/master` moved from `ccef654f0` to `baa073831049e37b5983f421125254119b74c09e`. `ccef654f0` is an ancestor. The 14 site paths have an empty diff. No site drift.

N3. `do_load_functions` is lines 717-736. The plan's 717-731 includes the `awk` at 725-726 and stops at the start of the candidate loop. The three `run.sh` blobs are identical.

N4. The table has no target-box column. Plan line 32 names the satellite box, 16 vCPU. The remeasure in section 4 was on that same shape (`nproc=16`).

N5. `flow.go` and `token_budget.go` already build the frame once per member or once per hit. The per-socket cost is `write` (`wui.go:82`, `wsjson.Write`). `fanoutIssue` is the encode-once shape the plan claims.

N6. Section 4 used `--as g-666`, an empty inbox, binary 1.1.3, bash `TIMEFORMAT`, n=10. Compare direction and the default CPU, not the absolute wall, to the editor's n=20 `--as c-660` medians.

N7. Row 01 per-socket median is 334734 ns and 20931 B, against plan line 72's 334,735 ns and 20,930 B. One unit. Allocs 342 match. Encode-once medians match.

N8. `git cat-file -e origin/master:csi-spl-doc/doc/md/perf-round-7/seat-grok.md` printed `fatal: path 'csi-spl-doc/doc/md/perf-round-7/seat-grok.md' does not exist in 'origin/master'` and this check printed `ABSENT`. `git ls-remote origin refs/heads/review/c002-perf-round-7-grok-seat` printed no ref before this seat's push.

N9. Lane-map on the 14 paths was exit 4 (five unknown ids, zero owned), then later the same command printed `free` and exit 0. See section 5.

## Hygiene after this file

After `git add` of this path, the same action printed the same `ok` lines (non-Csitea, personal-name, OS-user, home, mail, hidden-workspace, retired-relay, `.vibe`), then `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/g-666`, `hygiene_rc=0`.
