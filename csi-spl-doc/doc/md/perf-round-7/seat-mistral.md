# Perf round 7: mistral panel seat (m-669@sat)

Verdict on `e599eabf239bec58e30581dacc256a13bd0ad6be` (branch
`review/c002-perf-round-7-planner`): **PASS** — defects W1-W2 below are for the
editor to fold into v1.0; none changes a measured gain, a site or the batch
structure.

Fetch proof: `git fetch origin review/c002-perf-round-7-planner && git
rev-parse FETCH_HEAD` -> `e599eabf239bec58e30581dacc256a13bd0ad6be`.

Seat: m-669@sat, mistral, plan review only (a doc review; mistral code reviews
are paused, owner 10-30 cf7a7ee5). Everything below was read from the tree at
that sha (`git show e599eabf2:<file> | sed -n '<N>p'`), never from the author's
pastes. Box sat, 2026-11-13; 1-minute load read beside the re-measure:
`cat /proc/loadavg` -> `22.60 24.00 27.02` before and after check 4.

## Check 1: slug p7 unused

- `git log origin/master --oneline -E --grep='\(p7-' | wc -l` -> `0`
- `git ls-remote origin 'refs/heads/*p7-*' | wc -l` -> `1`; the one match is
  `refs/heads/review/c002-bug-s169-p7-scan-known-links` (04cde72c), subject
  `fix(api, SPL-5010): spec 169 P7 lists the mentions Q4 leaves in place...` —
  "P7" there is spec 169 part 7, not a round slug.
- stricter round-slug patterns: `git ls-remote origin 'refs/heads/*p7-[0-9][0-9]*' | wc -l`
  -> `0`; `git log origin/master --oneline -E --grep='\(p7-[0-9]' | wc -l` -> `0`.

Round slug p7 is unused.

## Check 2: each row's sites exist at `ccef654f0` and still on origin/master

origin/master has moved past the measured sha: `git log --oneline
ccef654f0..origin/master | wc -l` -> `11` (origin/master = `baa073831`;
`git merge-base --is-ancestor ccef654f0 origin/master` -> exit 0). For every
site below I ran `git show <sha>:<file> | sed -n '<a>,<b>p'` at both
`ccef654f0` and `origin/master` and diffed the two dumps: identical except the
header line, so **no cited site drifted**. `hub/` =
`csi-spl-api/src/go/spool-hub-api/internal/hub/`.

- Row 01 (plan line 72): `hub/wui.go:1311-1327` = `func (s *Server)
  fanoutChannelFrame(...)` with the per-socket `w.write(ctx, frame)` at
  `wui.go:1325`; `hub/human_status.go:88-106` = `broadcastStatus`, per socket
  per frame `c.write(ctx, &frames[i])` at `human_status.go:102` (function ends
  at :105); `hub/token_budget.go:110-121`, per-conn `c.write` at
  `token_budget.go:118`; `hub/flow.go:255-258` (`c.write` at :257) and
  `hub/flow.go:298-300` (`c.write` at :300). Reference encode-once path:
  `hub/issues.go:505` = `func (s *Server) fanoutIssue(...)`.
- Row 02 (plan line 73): `csi-spl-orc/src/bash/run/spl-lane-map.func.sh:322-344`
  = `spl_lane_local_rows` (one `jq -s -c '.'` at :333) and `spl_lane_local_row`
  (`dirname` at :338, `basename` at :339, one `jq -n` per worktree at :342).
- Row 03 (plan line 74): `do_load_functions` at
  `csi-spl-orc/src/bash/run/run.sh:717-731` — the `find|sort|xargs awk` index
  pass at :725-726, the eager `source` loop at :727-730 — byte-identical at
  the same lines in `csi-spl-iac/src/bash/run/run.sh` and
  `csi-spl-utl/src/bash/run/run.sh`.
- Row 04 (plan line 75): top-level non-comment lines at `ccef654f0`:
  `run/spl-agent-restart.func.sh:76-83` (3 `source` + `ARS_CAUSES`),
  `run/spl-sender-audit.func.sh:24-27` (`readlink`/`dirname` + 3 `source`),
  `run/gh-runner-add.func.sh:74-77` and :95 (`source`, `GH_RUNNER_PKGS`, the
  `ghr_docker_flavour` call), `run/spl-box-restart-after.func.sh:21-28` (3
  `source` + `SPL_BRX_AGENT_WIN_RE`), `run/spl-agent-login-check.func.sh:69-71`
  (`source` + 2 regex constants).
- Row 05 (plan line 76): `csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh:459-460`
  (`SPOOL_BIN` resolve) and :486 (`spool_resolve_bins()`).
- Section 2/6 cites: `internal/store/release_note_postgres.go:200` and :223
  (count subqueries), `csi-spl-wui/src/components/TenantDropBox.vue:70`
  (`v-show="listOpen && shownRows.length > 0"`),
  `csi-spl-api/src/bash/tests/hub-pg.tst.sh:52-53` (`pg_ctl -o`) and :58-60
  (`docker run`), `csi-spl-orc/lib/bash/funcs/spl-box-workspace.func.sh:27-36`
  (`yq eval-all` merge). See N2 for `hub-live-stack.sh`.

## Check 3: row shape (rulebook 3.1, 4.1/C2, R1, R14, owner 10-17)

Read the table at plan lines 71-76 and section 3.1 (line 81):

- Sites per row: 01 = 5, 02 = 1, 03 = 3 (the byte-identical `run.sh` copies),
  04 = 5, 05 = 1 — all at most 5.
- Baseline with command + number + n: every row names one (01: `go test
  ./internal/hub -bench P7 -benchmem -count=5`, 342 allocs/op, 20,930 B/op,
  334,735 ns/op, n=5; 02: rows-alone claim n=5 plus the whole
  `lane-map.sh --check` 8.97 s wall n=5; 03: 165 ms of a 950 ms startup, n=5;
  04: per-file medians n=3 summing to 236 ms of the 494 ms eager phase n=5;
  05: 51.0 ms CPU / 67.5 ms wall, n=20 interleaved).
- Counting or timing test with a red control (4.1, C2): every row names its
  test and the plant that turns it RED (01: `testing.AllocsPerRun` over 10
  sockets fails on today's per-socket `write`; 02: `jq` PATH shim counts 40
  calls today, at most 1 after; 03: dropping the cache read makes the second
  start count 1 `awk`; 04: re-adding one top-level `source` reads eager; 05:
  a globally exported `GOMAXPROCS=1` is seen by a `go` child).
- Vendor / kind / batch: every row is `claude / <kind>` (plan line 78: "Rows
  01-05 are claude"), batch 1 for 01/03/04/05, batch 2 for 02. No mistral
  coding or testing row.
- Batches disjoint (R1): batch-1 files are the hub Go files + a new bench
  test; the three `run.sh` copies + `run-lazy-loader.tst.sh`; five
  `run/*.func.sh` + a new `run-eager-files.tst.sh`; `spool-env.inc.sh` + a
  spawn-agents test. Batch 2 is `spl-lane-map.func.sh` + the lane-map suite.
  No path appears in two rows.
- Medians cross-checked against the raw runs in `perf-round-7/editor.md`:
  row 01 (editor.md:44-45) per-socket median of 337351, 361911, 334734,
  322043, 292877 = 334,734 ns (plan: 334,735), allocs median 342, B median
  20,931 (plan: 20,930); encode-once median 249,846 ns / 216 allocs / 16,962 B;
  the plan's -37% / -19% / -25% recompute to -36.8% / -19.0% / -25.3%. Row 03
  (editor.md:99,121,127): startup median of 0.898..0.989 = 0.950 s, awk median
  of 169,160,163,177,165 = 165 ms, cache-key median 0.012 s, eager median
  494 ms — all match the plan. Row 04 (editor.md:131): medians 121/35/33/25/22
  = 236 ms — match. Row 02: see W1.

## Check 4: re-measure of row 05 (read-only, no prd write)

`SPOOL_ROOT=/var/spool-hub ~/.local/bin/spool recv --as m-669` (the installed
spool CLI, run as the agent user; no `--ack`), 10 rounds interleaved default /
`GOMAXPROCS=1`, bash
`TIMEFORMAT='%R %U %S'`, load 22.60 (`cat /proc/loadavg`) before and after:

- default: wall median **43.5 ms**, CPU (user+sys) median **49.0 ms** (n=10)
- `GOMAXPROCS=1`: wall median **32.0 ms** (-26%), CPU median **33.5 ms** (-32%) (n=10)

The editor's numbers on `ccef654f0` (n=20, editor.md section 2.4): 67.5 ms
wall / 51.0 ms CPU default -> 53.0 / 35.5 with `GOMAXPROCS=1` (-21% / -30%).
Direction and relative gain **agree** (one P is faster on wall and CPU);
absolute wall differs — my inbox is smaller than c-660's and the box load was
22 vs 16.

## Check 5: R3 lane map on the rows' paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check <the 14 row paths, comma-separated> --agent m-669` -> exit `0`,
output `free` (no `owned by`, no `unknown:` lines). The editor's 09:43Z
reading was exit 4 with 16 `unknown:` lanes (plan section 3.2, line 92); my
reading now is exit 0 — either way, no row path is owned by a live lane.

Batch-2 wait on r58-07: stated at plan line 73 (batch cell) and section 3.1
(line 81) — row 02 spawns within 30 minutes (R16) of the commit that lands
r58-07. r58-07 is not landed: `git log origin/master --oneline -E
--grep='\(r58-07' | wc -l` -> `0` (r58-01..05 landed). The wait is stated and
matches the R16 SLA, and serializing row 02 after r58-07 is correct because
r58-07 edits `spl-lane-map.func.sh:2` (R1/R3).

## Check 6: distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> exit 0, last line
`INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-669` (every part `ok` or `allowed` with its cnf-key
reason).

## Defects

- **W1** — plan line 73 (row 02 baseline): "**4,098 ms (median, n=5;
  3,008..4,650)**". The median of the editor's five runs (editor.md line 86:
  4098, 3008, 4369, 4365, 4650) is **4,365 ms**; 4,098 is the first run. The
  range and the gain (probe 79 ms median, editor.md line 87) are unaffected.
- **W2** — plan lines 71-76 (table header line 71): rulebook 3.1 asks the
  action table to carry a target box; the p7 table has no `box` column (p6's
  did: `perf-round-6-plan.md` line 108). The rows were measured on sat; the
  spawn decides the box (R4).

## Notes

- **N1**: the brief's literal `git ls-remote origin 'refs/heads/*p7-*' | wc -l`
  prints `1` (the s169-P7 review branch), not 0; the strict round-slug
  patterns print 0 (check 1).
- **N2**: plan section 6 cites `hub-live-stack.sh:59` without its directory;
  the file is `csi-spl-api/src/bash/hub-live-stack.sh` (not under `tests/`),
  and its line 59 is the `docker run` line. The `tests/` prefix applies to
  `hub-pg.tst.sh` only.
- **N3**: `human_status.go:88-106` — the function ends at :105, :106 is blank;
  the range still resolves.
- **N4**: my lane-map reading (exit 0, `free`) differs from the editor's 09:43Z
  exit 4; both agree no row path is owned. The R3 re-check before each spawn
  still applies (plan section 3.2).

Signed: m-669@sat (mistral), 2026-11-13, plan sha
`e599eabf239bec58e30581dacc256a13bd0ad6be`, verdict PASS.

---

## v1.0 sign-off: `d47de8b8f5a7cfba95a6ea05bc943604871680b1`

Verdict on v1.0 (branch `review/c002-perf-round-7-planner`, fast-forward from
`e599eabf2`): **PASS**, no new defect. Fetch proof: `git fetch origin
review/c002-perf-round-7-planner && git rev-parse FETCH_HEAD` ->
`d47de8b8f5a7cfba95a6ea05bc943604871680b1`; `git diff --stat
e599eabf2..d47de8b8f` -> 2 files changed, 54 insertions(+), 19 deletions(-)
(plan + editor.md only).

Checks re-run on `d47de8b8f` (2026-11-13 ~11:36Z-11:40Z):

1. Slug, fresh master (`baa073831`): `git log origin/master --oneline -E
   --grep='\(p7-' | wc -l` -> `0`; `git ls-remote origin 'refs/heads/*p7-[0-9][0-9]*' | wc -l`
   -> `0`.
2. Changed sites, each read with `git show <sha>:<file> | sed -n '<N>p'` at
   both `ccef654f0` and `origin/master`, byte-identical:
   - row 05 (plan line 76): `scripts/spool-send.sh:533` =
     `out="$(SPOOL_ROOT="$SPOOL_ROOT" SPOOL_NOTIFY_CMD=off "$SPOOL_BIN" "${args[@]}")"`;
     `scripts/asks.sh:66` = `timeout "${ASKS_CLAIM_TIMEOUT:-15}" "$SPOOL_BIN" claim "$@"`;
     the excluded long-running exec `scripts/spool-harness.sh:194` =
     `setsid "$SPOOL_BIN" hub-run ...`; `lib/spool-env.inc.sh:459-460` assigns
     `SPOOL_BIN`, and `spool_resolve_bins` (:486) sets only the vendor CLI path
     vars — `grep -nE 'SPOOL_BIN"?\s+(send|recv|tail|claim|hub-run)'` over the
     file -> no match, so `SPOOL_BIN` is never executed in `spool-env.inc.sh`
     (the plan's "`spool_resolve_bins` execs nothing" holds).
   - row 04 (plan line 75) new line cites: `gh-runner-add.func.sh:86-95`
     (`ghr_docker_flavour()` defined at :86, `dpkg -s docker-ce` at :88, called
     bare at :95), `spl-agent-restart.func.sh:76-83`,
     `spl-sender-audit.func.sh:24-27`, `spl-box-restart-after.func.sh:21-28`,
     `spl-agent-login-check.func.sh:69-71`.
   - row 01 (plan line 72): `human_status.go:88-105` (function ends at :105).
3. Row shape: table header (plan line 70) now carries the `box` column (W2
   folded; every row `sat`); row 02 baseline (line 73) now **4,365 ms median**
   (W1 folded; the middle of editor.md:86's sorted 3008, 4098, 4365, 4369,
   4650); row 05 baseline (line 76) matches editor.md:186-197 (section 2.8):
   default 69.5 ms wall / 75.0 ms CPU, `GOMAXPROCS=1` 64.0 / 59.0, n=20 —
   recomputed -8% wall ((69.5-64)/69.5 = 7.9%), -21% CPU ((75-59)/75 = 21.3%).
   Still at most 5 sites per row, a test + red control per row, all rows
   claude, batches disjoint; section 3.1 (line 81) now lists row 05's three
   files (`spool-env.inc.sh`, `spool-send.sh`, `asks.sh`).
4. Re-measure of the changed row 05 on `spool send`, on my own scratch
   `SPOOL_ROOT` with `SPOOL_NOTIFY_CMD=off`, exactly as `spool-send.sh:533`
   runs it (`SPOOL_ROOT=<scratch> SPOOL_NOTIFY_CMD=off ~/.local/bin/spool send
   --from c-998 --to c-999 --kind msg --body probe`), n=10 interleaved, load
   72.43 (`cat /proc/loadavg` before and after): default **77.5 ms wall /
   51.5 ms CPU** median, `GOMAXPROCS=1` **56.5 ms wall (-27%) / 36.0 ms CPU
   (-30%)** median. Direction agrees with the editor's n=20 at load 23.0 (one
   P faster on wall and CPU); my CPU gain is larger, wall noisier under load 72.
5. R3: `lane-map.sh --check <all 16 row paths, incl. spool-send.sh and
   asks.sh> --agent m-669` -> exit `0`, output `free`.
6. Consensus (plan lines 208-214): `git ls-remote origin
   'refs/heads/review/c002-perf-round-7-grok-seat'` ->
   `d0f89fcdfe67d452a54b4ef1506efec8db6cbec5`, as the table claims; my seat
   branch `review/c002-perf-round-7-mistral-seat` = `0ee0871b8`.

Notes:

- **N5**: editor.md 2.8's `spool send` baseline was measured at 11:27Z, after
  the 09:26Z fetch of `ccef654f0`; the two exec sites are byte-identical at
  `ccef654f0` and `origin/master` `baa073831`, so the number applies to both.
- **N6**: the fsync A/B is honestly reported as not finished (editor.md
  section 2.7 result, plan section 6) and carried to round 8 — no invented
  number.

Signed: m-669@sat (mistral), 2026-11-13, v1.0 sha
`d47de8b8f5a7cfba95a6ea05bc943604871680b1`, verdict PASS.
