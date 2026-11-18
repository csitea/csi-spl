# Bug-fix round 14 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5855 (this plan).  
Discussion: t1 #spool-hub-bugs `0698c329-8de4-4364-8c48-a6cd324f075f` ("Bug round 14", opener msg b6f69d26, opened by c-002@sat 2026-11-18T02:38:35Z; its discussion issue is SPL-5854). Requested by c-001 spawn-share 26f26c67: bug 5% of the live lanes (1 of 18, band 20-30%), no bug row queued. Round 13 ([bug-round-13-plan.md](bug-round-13-plan.md) v1.0, 2 rows) is served: b13-01 5ebf6314b and b13-02 087f33ea0 are on `origin/master`, both ACCEPTED.  
Round focus: two defects live on `origin/master` today. Row 01 comes from the holder's candidate list (SPL-5825's R7 notes W2 and N1): section 7 of the nightly reflection gather names a wip issue "stalled, last commit none" when commits name its key in their body only, and it prints an empty section, with no `(not read` line, when its judge fails. Row 02 comes from this box's cron logs: a pid that exits between its `/proc` stat read and its cmdline read makes the lane rotation print `/proc/<pid>/cmdline: No such file or directory` to the cron log (730 lines in `lane-rotate`'s log, 4 of them after b13-01 landed). The cause is that the `2>/dev/null` comes after the `<` redirection that fails. The same line is in `spl-rotate-lib.func.sh`.  
Round size: at most 10 items (rulebook 1.1); this round has 2.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md) (round size, push caps, bands, R1-R16), linked here, not copied.  
Model: [bug-round-13-plan.md](bug-round-13-plan.md) (same shape, same 5 sources).

**Status: v1.0** (signed by the panel: m-538@<box2> mistral PASS on v0.2 `8a9dc6392`, msg 472c199f, no W items). v1.0 folds in its N1 (bash names `spl-rotate-lib.func.sh`'s error by the function's first line, 813; the statement is at `:823`) and N3 (the CI window moved since). No row's defect, site or red control changes. v0.2 folded in the <box2> answers to the editor's asks 2 to 4 (c-001@<box2> msg d46c8f08, forwarded by the holder c-002@sat, msg 39787558): the b14 slug is unused there, `spl_private_has_tokens` has no line since 2026-11-15, and gc-<box2> names no defect.  
Editor: **c-279@sat** (claude, `specs_and_docs`).  
Panel: asked of the dispatch holder (section 8).

**One sha:** every count below is measured on **`087f33ea0`** (`origin/master`, committed 2026-11-18T01:59:04Z), on sat, between 02:40Z and 02:47Z on 2026-11-18. n=1 per command unless stated.

---

## 1. How to read this

- One row = one defect = one lane, at the sites named and nowhere else. Each row has a **red control** that fails on `087f33ea0` and passes after the fix (section 3.2).
- **Paths** are repo-relative. Line numbers are as of `087f33ea0`.
- **Box:** the preferred box. The placer may move a row (no pin).
- **Vendor:** `do_spl_lane_mix` by kind, then the owner rules and R14. Both rows are bash tooling (`simple_coding`). The lane mix picks claude (02:46:42Z: `pick=claude ... kind simple_coding: main claude, backup agy`). The bug rows of rounds 10 to 13 all went to claude, so R14 agrees. Mistral writes no code.
- **Subject** (R6 reads it): `fix(b14-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** rulebook 2.7.4 (box-free form in the commit body).

---

## 2. Where the rows come from (measured on `087f33ea0`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports in t1 and csitea since round 13 was planned** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-18T00:00:06Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (02:43:54Z) | t1 12, all 12 `[spool-probe]`; no other workspace has a human message | **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (02:41Z) | 100 runs 2026-11-17T08:19:25Z .. 2026-11-18T01:59:35Z: 66 success, 29 cancelled, 5 failure. Every timeout headroom line `ok` (highest p90: 56 %) | 5 failed runs, 4 first-red sightings over 2 jobs, all already in round 13. Round 12 fixed `TestAgentRunPresenceFrames` (41d35321) and wui e2e 2/8 "no Email row" x2 (fd9e5a27, 013cb71b). `TestDemoPostQuotaPerDay` (68cd3332) and wui e2e 2/8 `4j Shift+O opens the issue` (013cb71b) are still one sighting each. Every failed job is green again on `087f33ea` (run 44219928387). The panel's later read gave 65 / 27 / 5 / 3 running as the window moved, with the same 5 failed runs (panel N3). **0 rows** (section 5). |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 087f33ea0 -- "$d" \| wc -l; done` | api 197, wui 17, orc 10, iac 21, utl 0; `csi-spl-wui/tests/e2e/ci-skip.txt` 4 entries | The same counts as round 13 on `344be1c04`. No new skip. **0 rows.** |
| **4. Box cron logs and GC notes, last 24 h** | sat: the editor's scan of the 39 `/var/csi/csi-spl/*/cron.{out,log}` files changed in the last 24 h. First for `unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|No such file or directory`, then for `FATAL\|ERROR`. Each line is keyed by the last timestamp above it and counted per distinct line after 2026-11-17T02:45Z. Then `spool tail --task gc-sat` | 3 distinct defect-shaped lines; 12 distinct FATAL/ERROR lines over 5 crons. Re-keyed with an awk that skips the `spool-env` WARN line (it carries a build timestamp): 91 `cmdline` lines and 6 `operand expected` lines in the window | **1 row (02):** `lane-rotate/cron.log` has 730 lines `spl-lane-rotate.func.sh: line <n>: /proc/<pid>/cmdline: No such file or directory` on 38 days, the first keyed 2026-10-12T01:53Z; 88 keyed 2026-11-17 and 4 keyed 2026-11-18. 80 are at `line 602`, and 4 are at `line 607`, the same statement after b13-01 moved it. `dispatch-rotate/cron.out` has 1 from `spl-rotate-lib.func.sh`. The other lines go to section 5 (b13-01's `operand expected`, 6 lines, all before b13-01 reached the box checkout; a `gh` i/o timeout; one `git fetch` failure) and section 6 (box-update, env-order). `issue-close-landed`'s `spl_private_has_tokens: command not found` has 0 lines in sat's log; round 13 counted 180 on <box2>, and on <box2> (c-001 msg d46c8f08) it is still 180, the last in the 2026-11-15T19:00:39Z tick, none since. gc-sat's notes since 00:20Z (census, share, one close) name no defect, and neither does gc-<box2> 20261118T0230Z (17 agents, 0 restarted, 0 close asked; d46c8f08). |
| **5. Open defect issues, round 13's leftovers, the holder's candidate list** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select number, status, assignee, left(title,90) from issues where tenant_id='t1' and deleted_at is null and archived_at is null and status in ('eval','todo','wip','blocked','onhold','qas') and kind='issue' and ('bug' = any(labels) or title ~* '(bug:\|broken\|does not\|not work\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|flake)') order by number desc" ./run -a do_spl_db_query` (02:44:04Z); round 13 sections 4 to 6; the R7 notes of b13-01 (c-252, in 5ebf6314b's body) and b13-02 (c-257: FAIL msg d75a2369, PASS in 087f33ea0's body); `/var/spool-hub/dispatch/c002-next-round-candidates.md`, each claim re-read on `087f33ea0` | 27 issues matched; 9 candidate notes in the list | Open defect issues are owned by lanes, programs or the desk (section 6). SPL-5825 W2 and N1 **reproduce (row 01)**. The other notes are measured in section 4 (not a bug, or a test gap with no failing behaviour) or section 6 (owned elsewhere). **1 row.** |

In the commands of this table, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 3. The 2 rows

| # | defect | evidence | sites file:line | red control (fails on `087f33ea0`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b14-01-orc-reflection-stalled-body-keys)` | Section 7 of the nightly reflection gather (`spl_reflection_stalled`, SPL-5825) lists every wip issue that no live lane, no live ask and no commit of the last 72 h names. It reads the commits through `spl_reflection_subjects`, which logs `%cI%x09%s`: subjects only. A key named only in a commit body (`Refs: SPL-n`, a review note, a `Closes:` in a docs commit) is not seen, so the issue is listed as stalled with `(last commit none)`, which is false. Second, `spl_reflection_stalled` calls `spl_reflection_stalled_judge` (python) and ignores its exit status. When python fails, the section prints nothing: no issue line, no `(none)` and no `(not read: ...)` line, although every other unread source of the section prints one. | (1) SPL-5825's R7, c-386@<box2> msg a6d810ef on 32da3b6ea, W2: "func.sh:217 reads subjects only; 110 SPL keys in 72 h appear only in a body/trailer". Re-measured on `087f33ea0` (02:46:37Z): `git log origin/master --since='72 hours ago'` with `--format=%s` and with `--format=%b`, each piped to `grep -oE 'SPL-[0-9]+' \| sort -u`, then `comm -13` -> **68** keys in a body only; 230 body lines start with `Closes: SPL-` or `Refs: SPL-`. (2) The same review, N1: "func.sh:194 ignores the judge's rc; TypeError gives an empty section 7 with no '(not read' marker". (3) The red control below on `087f33ea0`: case A prints `- SPL-7: named in a body only (last commit none)`, case B prints nothing. | `csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh:250-252` (`spl_reflection_subjects`, the `%s` format), `:270-276` and `:287` (the judge reads `subjects.tsv` and matches its keys), `:228` (the judge's call, its rc ignored); test `csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh` (beside case 16, `:362`); doc `csi-spl-doc/specs/166-orchestrator-daily-rhythm/spec.md:305` (row B8: "no `origin/master` commit subject of the last 72 h names") | The editor's script `rc01.sh` (section 3.2). It makes a one-commit git repo (subject `docs(orc): a change`, body `Refs: SPL-7`, `refs/remotes/origin/master` on it) and sources the func file. It stubs `spl_reflection_wip_read` (one wip issue SPL-7), `spl_reflection_lanes_read` (`{"hub":"ok","lanes":[]}`) and `spl_reflection_asks_read` (`{"hub":"ok","asks":[]}`), then runs `REFLECTION_REPO=<repo> spl_reflection_stalled "$(date +%s)" /dev/null`. Case A runs it as is. Case B puts a `python3` stub that exits 1 first on PATH. On `087f33ea0`: `A: - SPL-7: named in a body only (last commit none) rc=0` and `B: rc=0` (no line). PASS requires case A to print `(none)` (the body names SPL-7 inside the 72 h) and case B to print one `(not read: ...)` line naming the judge. Case 16 and the whole suite stay green. | Read the whole message: `spl_reflection_subjects` prints the subject and body of each commit as one record, and the judge matches a key in either. The record format is the lane's choice, but a body line must not split a record. A body-only mention's date counts like a subject's. When `spl_reflection_stalled_judge` exits non-zero, print one `(not read: the judge failed: <its last stderr line>)` line, as the other sources do (`spl_reflection_why`). Keep the 72 h window, the lane and ask matching, and the key regex as they are. Docs: spec 166 row B8 in the same commit: "commit subject" becomes "commit message (subject or body)", and the judge failure becomes one more `(not read: ...)` source. | sat | claude | a cross-vendor seat if one places (agy or grok); else the claude waiver seat, as for rounds 11 to 13 (c-001 ruling 5fb1bdab; b13-02's line cites waiver 1a7c70da). The holder decides at placement | simple_coding | 1 |
| 02 `fix(b14-02-orc-rotate-gone-pid-cmdline-stderr)` | Two readers of `<proc>/<pid>/cmdline` put `2>/dev/null` after the `<` redirection: `cl="$(tr '\0\n\r' '   ' < "$root/$d/cmdline" 2>/dev/null \|\| true)"` in `spl_lane_rotate_child_match`, and `{ IFS= read ...; } < "$1/cmdline" 2>/dev/null \|\| true` in `spl_rotate_cli`. Bash applies redirections left to right. When the pid exits between the stat read and this read, the `<` fails first, and its error goes to the caller's stderr (the cron log) before the `2>/dev/null` takes effect. The value read is empty either way, so the scan's verdict does not change; the defect is the stderr line. It is noise in every cron scan (this round's source 4 included), and it looks like the race b13-01 fixed. | (1) sat `/var/csi/csi-spl/lane-rotate/cron.log`: 730 lines `/opt/csi/csi-spl/csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh: line <n>: /proc/<pid>/cmdline: No such file or directory`, the first keyed 2026-10-12T01:53Z, on 38 days, 88 of them keyed 2026-11-17. 80 are at `line 602`, and 4 are at `line 607`, the same statement after b13-01 (5ebf6314b) moved it. `/var/csi/csi-spl/dispatch-rotate/cron.out` has 1 from `spl-rotate-lib.func.sh` (the dispatch rotation reads `spl_rotate_cli`). (2) The red control below on `087f33ea0`: 2 lines. | `csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh:607` (`spl_lane_rotate_child_match`, `:590-615`); `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh:823` (`spl_rotate_cli`, `:813-827`); test `csi-spl-orc/src/bash/tests/lane-rotate.tst.sh` (a new case after 33) | The editor's script `rc02.sh` (section 3.2). It makes a sandbox proc root with one child `4242` of `4241` that has a `stat` file and no `cmdline`, and sources `spl-rotate-lib.func.sh` and `spl-lane-rotate.func.sh`. It runs `LEASE_PROC_ROOT=<root> spl_lane_rotate_child_match 4241 "pnpm\|go test" all` and `ROTATE_KIND=grok spl_rotate_cli <root>/4242 node` with stderr to a file, then counts `cmdline: No such file` in it. On `087f33ea0`: `A rc=0 B rc=1 stderr cmdline lines: 2` (`spl-lane-rotate.func.sh: line 607: $T/proc/4242/cmdline: No such file or directory`, and `spl-rotate-lib.func.sh: line 813: ...`; bash names the lib's error by the first line of `spl_rotate_cli`, `:813`, while the statement is at `:823`, panel N1). PASS requires 0 such lines with the same rc values (A 0, B 1). The rotate suites stay green (test column below). | At both sites, put the stderr redirection before the input redirection, or test that the file is readable first (e.g. `tr ... 2>/dev/null < "$f"`, or `{ ...; } 2>/dev/null < "$f"`). Nothing else changes: the empty value and the return codes stay as they are. The lane, dispatch and role rotations share both files, so the test column is every suite that sources either: `git grep -l -e spl-rotate-lib -e spl-lane-rotate.func -- '*tests/*'` (orc suites and spawn-agents tests on `087f33ea0`, among them `lane-rotate.tst.sh`, `lane-rotate-role-seats.tst.sh`, `dispatch-rotate.tst.sh` and `orch-rotate.tst.sh`). Docs: `Docs: none (a gone pid's read error no longer reaches the cron log; no rule changes)`. | sat | claude | as row 01 | simple_coding | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02. Their file sets are disjoint:
  - row 01: `csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh`, `csi-spl-orc/src/bash/tests/spl-reflection-gather.tst.sh`, `csi-spl-doc/specs/166-orchestrator-daily-rhythm/spec.md`;
  - row 02: `csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh`, `csi-spl-orc/src/bash/run/spl-rotate-lib.func.sh`, `csi-spl-orc/src/bash/tests/lane-rotate.tst.sh`.
- **Off limits:** every live lane's files, among them p15-01 (c-261@sat, perf round 15, the `in_orc` run set). Neither row edits a file a live lane lists (below).
- **Waits (R3):** none. The last lanes on these files have landed: 9d358eee6 (SPL-5829) last changed `spl-reflection-gather.func.sh`, 5ebf6314b (b13-01) last changed `spl-lane-rotate.func.sh`, and 221418819 (SPL-5737) last changed `spl-rotate-lib.func.sh`. Some briefs on this box name these files: `c003-reflection-gather-stalled-wip-issues`, `c002-bug-reflection-issue-links-backlog-topic`, `c001-bug-reflection-brief-mode-0600`, `c002-b13-01-orc-lane-rotate-age-of-a-gone-pid` and their reviewer seats. They all belong to landed work: SPL-5825, 5829, 5826 and 5848 are on `origin/master`.
- **How the files were checked (2026-11-18, from sat):**
  - 02:45:24Z `lane-map.sh --check csi-spl-doc/doc/md/bug-round-14-plan.md,<the row files above, the spec 166 file excepted> --agent c-279` -> exit 4. No live lane lists these files. 13 lanes on <box2> record no files: c-054 and c-714 (blog drafts), c-060, c-528, c-669, c-924 and c-927 (csitea topic seats), c-366 (an Outlook calendar import), c-390 (the GCP costs fetch), c-468 and c-469 (spec 169 T13 / T15), c-545 (a workspace watch seat) and c-570 (the box CPU overload measure). c-570's brief (`c002-64ca-t9-cpu-overload-measure.md`, spec 175) names none of the row files (`grep -nE 'lane-rotate\|rotate-lib\|reflection'` -> no line). By their brief titles, none of the others works on the reflection gather or the rotation. The orchestrator re-runs the check before each spawn (R3) and asks an exit-4 lane first.
  - 02:41:13Z `lane-map.sh` (all boxes): 27 live rows; the one live bug lane is c-570@<box2> (above).
  - 02:45:40Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 0 rows.
- **Slug b14 is unused as a round id** (02:41:03Z, sat): `git log origin/master -E --grep='\bb14-[0-9]{2}-'` -> empty; `git log origin/master --grep='(b14-'` -> empty; `git ls-remote origin | grep -E 'b14-[0-9]{2}|bug-round-14'` -> empty; `grep -rlE '(^|[^0-9a-f])b14-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs` (5885 files), `/var/spool-hub/asks` (8786) and `/var/spool-hub/spawn-remote/briefs` (199) -> 0 files. Spec 154's `s154-b14` rows are another id. On <box2> (c-001 msg d46c8f08, ~02:5xZ) the same grep over 3311 briefs, 8825 asks and 2957 spawn-remote briefs -> 0 files.

### 3.2 Red controls run on `087f33ea0`

| row | command (repo untouched) | output on `087f33ea0` | output with the fix | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh <repo root>`: the one-commit repo, the three stubs, `spl_reflection_stalled` twice (A as is, B with a failing `python3` first on PATH) | `A: - SPL-7: named in a body only (last commit none) rc=0`; `B: rc=0` | `A: (none) rc=0`; `B: (not read: ... judge ...) rc=0` | editor c-279 |
| 02 | `bash rc02.sh <repo root>`: the sandbox proc root, `spl_lane_rotate_child_match 4241 ... all` and `ROTATE_KIND=grok spl_rotate_cli <root>/4242 node` | `A rc=0 B rc=1 stderr cmdline lines: 2` | `A rc=0 B rc=1 stderr cmdline lines: 0` | editor c-279 |

Both scripts are in the editor's scratch dir on sat and go to each row lane with its brief; the row lane turns them into suite cases.

---

## 4. Measured and not a bug

| candidate | command | result | why not a row |
|---|---|---|---|
| SPL-5825 W1: an ask whose brief carries `Issue: SPL-x` does not hide SPL-x from section 7 (the asks are matched by summary, topic and placement) | `jq 'del(.history)' /var/spool-hub/asks/3f05c219-2fb0-4fb6-b221-1586271624be.json` (this round's planner ask) | The ask record has no brief text and no issue key: its fields are `ask_id, role, kind, from, to, topic, summary, deadline_at, discussion, state, acked_by, closed_by, reason, ...`. | Matching a key the ask does not hold needs a new source (the brief file, or a key field on the ask), not a fix of the match. A feature for the ask book. |
| SPL-5825 N2: a failed fetch leaves section 7 judged on the last fetched `origin/master` | `spl-reflection-gather.func.sh:340-341` | Section 2 of the same file prints `(fetch failed: <ref> as of the last fetch)`. | The file already says so. Optional for row 01, not a defect. |
| SPL-5825 N3: the hub answers `ok` with `lanes: []`, so every wip issue is listed | `spl-reflection-gather.func.sh:220` | An empty fleet with a hub `ok` is a valid answer under the reader's contract. No failing run was found. | No failure reproduced. |
| SPL-5825 N4: no cap on section 7 (a remote brief over the 64 KiB hub message cap) | the reviewer's estimate, "~440 more lines" | Not reached today. | No failure. |
| SPL-5824 W1, N1, N2: `spl_desk_live_hop` (`csi-spl-orc/lib/bash/funcs/spl-desk-moved.func.sh:151-153`) does not forward `SPOOL_LANDED_REPOS_FILE`, `SPOOL_WORKSPACE_REPOS_MAP`, `SPOOL_GO_ASK_OK` and some tuning knobs; the hop in `do_spl_lane_issue` (`spl-lane-issue.func.sh:142`) does | read on `087f33ea0` | The reviewer: "Only an explicit override is lost". The hopped run loads the box env itself, and no caller sets `SPOOL_GO_ASK_OK`. | No failing behaviour on the default path. |
| SPL-5828 r60-06 N1: `spl-uplink-probe.func.sh:14-15` says "The probe exits 0 even with the link down" | `grep -n 'return 1' csi-spl-orc/src/bash/run/spl-uplink-probe.func.sh` | The `return 1` lines (`:58`, `:60`, `:65`, `:80`, `:196`) are config faults (no dir, a bad box id or command), not a link down. | The sentence is true as written. |
| SPL-5828 N2: in a clone outside `<base>/<org>/<app>` the derived dir moves with the tree | the reviewer | By design of `spl_run_paths`. | Not a defect. |
| r34 row 01 N1, N2: `channels.no_fallback` and `m.from_id LIKE 'HUM-%'` in `internal/store/fallback_postgres.go:83-86` are not covered by a test | the reviewer (17f86543): with the plant dropped, the pg tests stay green | A coverage gap. | No failing behaviour (the brief's rule): input for a test round. |
| SPL-5850 N1: an AltGr letter (Polish AltGr+N, `key` 'ń', `code` `KeyN`) now picks a kind through the `code` fallback (`csi-spl-wui/src/utils/kind-picker-keys.ts:45-50`, `msg-shortcuts.mjs:94-99`) | read on `087f33ea0` | The reviewer marks it "unchecked in a browser". `KindKeyEvent` carries no AltGraph state, and a Cyrillic letter on `KeyT` is meant to pick (SPL-5836 R7 W1). Which way an AltGr letter should go is a product choice. | Not reproduced in a browser; a decision, not a defect. |
| b12-02 R7 N4: `do_tf_apply_target`, `do_tf_destroy`, `do_tf_destroy_target` and `do_tf_destroy_local_step_bucket` drop terraform's exit status | read on `087f33ea0`, not run: each sets `set -e` before the pipeline, `./run` sets `set -u -o pipefail` (`csi-spl-iac/src/bash/run/run.sh:762`), and it calls the action plainly (`execute_step`, `:587`) | By that reading, a failing terraform under `./run` fails the pipeline and exits the run non-zero. The rc is lost only when the function is called outside `./run` without `pipefail`. | Not a defect on the path that is used (read, not run). |
| b12-02 R7 N2, N3: `terraform init` / `output` without `-input=false`; `do_tf_log_open`'s `${1:?}` exits the shell | read | Every caller passes the path; terraform runs in the tf-runner container, not on a terminal. | No failing run. |
| b13-02 R7 N2 (a sent blocker whose `failed.keys` append fails is sent again) and N4 (a hand run beside the cron) | 087f33ea0's body: "N2, N4 not changed" | N2 needs a full disk; N4 is the race `inherit.pending` already has. | Edge cases with no failing run. |
| desk-cron `bin/spool` older than its sources | every orc cron line | As in rounds 12 and 13. | As before. |

---

## 5. Not reproduced, or not code

| candidate | command | result |
|---|---|---|
| `lane-rotate` `line 174: ((: -: syntax error: operand expected` (b13-01) | the cron scan of section 2, source 4 | 6 lines in the scan window, the last keyed 2026-11-17T18:58:25Z, before b13-01 (5ebf6314b, 2026-11-18T01:36:42Z) reached the box checkout (`git -C <box checkout> merge-base --is-ancestor 5ebf6314b HEAD` -> yes now). None since. |
| `TestDemoPostQuotaPerDay` (68cd3332), wui e2e 2/8 `4j Shift+O opens the issue` (013cb71b) | `do_report_ci_gate` above | Still 1 sighting each in 100 runs, below the R11 flake bar (a lane on the 3rd). Watch. |
| Network and GitHub answers in the sat crons: `restore-drill-red-note` `gh run list failed: ... i/o timeout` (1), `issue-close-landed` `git fetch origin/master failed` (1) | the cron scan of section 2, source 4 | Once each in 24 h. |
| `issue-close-landed` `spl_private_has_tokens: command not found` (rounds 12 and 13, section 5) | `grep -c spl_private_has_tokens /var/csi/csi-spl/issue-close-landed/cron.log` on sat -> 0 | None on sat. On <box2> (c-001 msg d46c8f08): 180, all `spl-cloud-cnf.func.sh: line 68: spl_private_has_tokens: command not found`, the last in the 2026-11-15T19:00:39Z..19:01:02Z tick; the newest tick (2026-11-18T02:50:12Z) is rc=0. Read as a gap fixed since; not bisected. Still on watch. |

---

## 6. Owned elsewhere (R3)

| item | owner | status |
|---|---|---|
| `box-update` `FATAL Command 'do_spl_box_update' failed` (2 in sat's log in 24 h) | SPL-5847, c-001's bug lane (round 13 section 6, ask 078d9541) | `wip`. |
| `env-order` `ENV_ORDER UNKNOWN: 6 row(s) could not be read` (terraform steps 058 to 061 read `error` or `pending`), exit 2 | the infra steps (owner's go for any plan or apply) | Status 2 is the action's UNKNOWN verdict by design; the rows are terraform state, not this round's code. |
| r34 row 05 R7 N3: literal `/var` paths at `spl-watchdog.func.sh:72`, `:1311` and `spl-lane-rotate.func.sh:112` | the next refactor round's planner (the candidate list says so) | A refactor, not a defect. Row 02 does not touch `:112`. |
| Event type SPL-5751 (`vue: insertBefore`, n=6) | owner's event-log order, t1 955ab0bd (F9) | As in rounds 12 and 13. |
| SPL-5609, 5411, 5396, 5368, 5254, 5232, 5104, 4994, 4934 | dispatch desk (c-002), `wip` / `onhold` | Placed by the holder. |
| SPL-5386, 5217, 5180 | review and move threads with their own owners | Not defects of the code. |
| SPL-4120, SPL-4416, SPL-4224, SPL-4849 | the release transfer tool, another repository | As in round 13. |
| SPL-3811 (`e2e-shard-pack:139` flake), SPL-1046 (dropped Go errors) | `qas` with c-296; backlog 07 | Held by their owners. |
| SPL-455, SPL-450, SPL-435, SPL-342 | spec 011 and spec 007 gates | Labelled `bug`, not defects. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 (defect fixes, red controls run on `087f33ea0`) |
| vendor | claude 2 (the lane mix picks claude; R14) |
| R7 | a cross-vendor seat if one places, else the claude waiver seat; both rows |
| box (preferred) | sat 2 |
| batches | 1 (disjoint, no wait) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-279@sat (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-0698c329`, with at least one non-claude seat (round 13's panel was a mistral doc seat, m-235@sat).
- **Asked of the holder with the plan, answered (c-001@<box2> msg d46c8f08, forwarded as msg 39787558):** the b14 slug has 0 hits on <box2>; `spl_private_has_tokens` has no line since 2026-11-15; gc-<box2> names no defect. v0.2 folds the answers in.
- **Review history:**
  - 2026-11-18 02:51Z: the editor pushed v0.1 (`e0862a1c8`) to `review/c002-bug-round-14-planner` and sent the result to the holder c-002@sat (msg 6b25f9dd).
  - 2026-11-18: the holder queued a mistral panel seat (ask 3fcc3eee, `c002-bug-round-14-mistral-panel-seat`, msg b0b73140) and forwarded the <box2> answers (msg 39787558). v0.2 folds them in.
  - 2026-11-18: the editor pushed v0.2 (`8a9dc6392`); the holder pointed the seat at it (msg 7ab8fb17), placed as m-538@<box2> (c-001 479c4a6c).
  - 2026-11-18: panel m-538@<box2> (mistral) PASS on v0.2 `8a9dc6392` (msg 472c199f), no W items. It re-ran rc01 and rc02 RED on a clone of `087f33ea0`, every cited site on `087f33ea0` and `origin/master` (0 drift), the slug check (0 hits), the skip counts, the CI report, the body-only key count and `lane-map.sh --check` (exit 4, no owning lane). Its notes: N1 the lib's printed line (folded in); N2 the sat cron counts are not re-measurable from <box2>, whose own lane-rotate log has 539 lines of the same shape; N3 the CI window moved (folded in); N4 the b13 ACCEPTED messages are on sat's task, the shas verified; N5 v0.2 vs v0.1 is the plan file only; N6 the `\|` escapes reproduce with a plain `|`.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-279@sat | **v1.0** |
| Panel | m-538@<box2> (mistral) | **PASS** on `8a9dc6392` (msg 472c199f; seat file `csi-spl-doc/doc/md/bug-round-14/seat-mistral.md` on `review/c002-bug-round-14-mistral-seat`, `6a765c01e`) |
