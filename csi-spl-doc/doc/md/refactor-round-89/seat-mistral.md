# Refactor round 89 — panel seat mistral (m-286@<box>)

Issue: SPL-6259 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-89-mistral-panel-seat.md`.

Review target: `csi-spl-doc/doc/md/refactor-round-89-plan.md` on branch
`review/c002-refactor-round-89-planner` at v0.1
**`e6e606d80f75df59b3211574f95eb6110defff88`**.

- `git ls-remote origin refs/heads/review/c002-refactor-round-89-planner` ->
  `e6e606d80f75df59b3211574f95eb6110defff88` (head == the sha the holder relayed,
  msg eeecb2df on dispatch-refactor-r89, 2026-11-22T15:10:37Z).
- `git show e6e606d80 --stat --format='%H %cI %s'` -> one file,
  `csi-spl-doc/doc/md/refactor-round-89-plan.md` +405, subject
  `docs(r89-plan, SPL-6259): refactor round 89 plan v0.1: the spool-install slug copy and the stale sweep's lease.conf reader go, 2 rows`,
  parent `bbc56e5e5`.
- The plan's measured base is `94e5690a2` (committed 2026-11-22T14:47:19Z, matches
  the plan's "origin/master at 2026-11-22T14:47Z"); `git merge-base --is-ancestor
  94e5690a2 origin/master` -> rc 0 (base is on trunk; origin/master at review time
  `04b6048f2`, HEAD of this worktree `94e5690a2`).
- Every file:line cited below was checked with `git show <sha>:<file> | sed -n <N>p`.

**Verdict: PASS on v0.1 `e6e606d80f75df59b3211574f95eb6110defff88`. No W defects.**

## 1. Slug r89 unused since the plan's W

- W: `git log origin/master -1 --format='%h %cI' -E --grep='^docs\(r88-plan'` ->
  `14d41508b 2026-11-22T16:32:03+02:00` — the same W the plan records
  (`Window: W=2026-11-22T16:32:03+02:00`).
- `git log origin/master --since="2026-11-22T16:32:03+02:00" --oneline -E --grep='\(r89-' | wc -l`
  -> **0**; over all history -> **0**.
- `git ls-remote origin | grep -E 'r89-[0-9]{2}|refactor-round-89'` -> only
  `e6e606d80f75df59b3211574f95eb6110defff88  refs/heads/review/c002-refactor-round-89-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r89-[0-9]{2}|refactor-round-89'` ->
  exactly `c002-refactor-round-89-planner.md` and
  `c002-refactor-round-89-mistral-panel-seat.md` (the two expected).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-89`
  -> **0** (the plain name is free on trunk).

## 2. Every row site file:line exists on base and on origin/master

Row paths (6): `orc:src/bash/features/spool-install/steps/claude-memory.inc.sh`,
`.../steps/y18-grok-memory.sh`, `.../steps/y20-agy-memory.sh`,
`orc:src/bash/tests/spl-claude-project-slug.tst.sh`,
`orc:src/bash/run/spl-issue-stale-sweep.func.sh`,
`orc:src/bash/tests/spl-issue-stale-sweep.tst.sh` (`orc:` = `csi-spl-orc/`).

- `git diff --name-only 94e5690a2 origin/master -- <the 6 paths + spl-owner-digest-post.func.sh>`
  -> **empty** at review time (origin/master `04b6048f2`): no drift.
- Cited lines read at `94e5690a2` and re-read at `origin/master`, all **SAME**:
  - `claude-memory.inc.sh:3-5` (header "the claude memory repo and its project slug,
    the one copy"), `:8` (comment), `:9`
    (`spool_install_memory_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }`).
  - `y18-grok-memory.sh:57` and `y20-agy-memory.sh:254`
    (`memdir="$home/.claude/projects/$(spool_install_memory_slug "$repo")/memory"`).
  - `lib/bash/funcs/spl-claude-project-slug.func.sh:10`
    (`spl_claude_project_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }`).
  - `spl-issue-stale-sweep.func.sh:53` (`read -r holder _ ...`), `:54-55`
    (`spl_stale_lease_conf "$root" LEASE_ENV prd` / `LEASE_TENANT ""`), `:71-75`
    (`spl_stale_lease_conf() {` .. `}`), `:76` (blank).
  - `spl-owner-digest-post.func.sh:52-53` (the two `spl_owner_digest_lease_conf` calls),
    `:161-166` (comment + `spl_owner_digest_lease_conf() {` .. `}`).
  - `spl-issue-stale-sweep.tst.sh:35` (fixture `lease.conf` with `LEASE_ENV=dev`,
    `LEASE_TENANT=t1`), `:72-80` (the seams, `source "$FUNC"` at `:74`).
  - `install.sh:194` (`ORC="$(cd "$_here/../../../.." && pwd)"`), `:1100`
    (`y1_mcp_bot "$ORC/src/bash/features/mcp-bot"`);
    `iac:src/terraform/060-gcp-vm-satellite/roles/08_spool_harness/tasks/main.yml:108,136`
    (both run `install.sh` from the repo checkout).
  - Callers of the shared reader: `spl-reflection-gather.func.sh:88-89`,
    `spl-topic-archive-suggest.func.sh:84-85,89,138`, `spl-topic-prio-sync.func.sh:49-50`,
    `spl-zombie-topics.func.sh:65-66,291`; guards `spl-topic-prio-sync.func.sh:36-37`,
    `spl-zombie-topics.func.sh:54-55`; `spl-dispatch-lease.func.sh:2385` (section 7).
- `git grep -n spool_install_memory_slug 94e5690a2` -> the 3 code lines above plus
  the r87 and r88 plan docs only — as the plan's 1.3 says.
- `git grep -n spl_stale_lease_conf 94e5690a2` -> exactly **3 lines** (`:54,:55,:71`).
- `git grep -n spl_owner_digest_lease_conf 94e5690a2 -- csi-spl-orc/src` (tests left out)
  -> the definition `:161-162` and the 5 actions' call lines above — as 1.4 says.
- Slug-rule grep at base (`git grep -nE "s/\[\^A-Za-z0-9\]/-/g|\[\^(A-Za-z0-9|a-zA-Z0-9)\]/-"`
  over `lib`, `src` trees, tests out) -> exactly **7 lines**: the helper `:10`,
  `claude-memory.inc.sh:9`, `spl-dispatch-lease.func.sh:2385`, and the 4
  parameter-expansion forms (`lane-scratch-reap.sh:63`, `lane-test-server-reap.sh:134,163`,
  `spl-session-prune.sh:229`) — as 1.2 (a) says.
- `wc -l` at base: `claude-memory.inc.sh` 20, `spl-claude-project-slug.tst.sh` 43,
  `spl-issue-stale-sweep.func.sh` 152, `spl-issue-stale-sweep.tst.sh` 195,
  helper 10 — as the plan says.
- Commits in the last 24 h on the row paths: `git log origin/master
  --since=2026-11-21T15:30Z -- <the 7 paths>` -> 3, all landed rounds
  (`a42fff43c` r87-02, `90522d802` r88-01, `e2dea23a9` r88-02). Remote branches
  (40 most recent) touching the row paths: `git diff --name-only <merge-base> <b> --
  <paths>` -> **0 hits**.

## 3. Red controls, run on the plan's base in scratch copies

Base scratch copy: `git archive 94e5690a2` into a /tmp scratch dir; head1 = base with
row 01 applied in 1.3's shape, head2 = base with row 02 applied in 1.4's shape,
head1-noguard / head2-noguard = the heads with the `declare -F` line deleted; base-t1 /
base-t2 = base with only the head's test file copied in. Nothing committed, nothing
pushed; every run `SPOOL_TEST=1` (test-lib sets it), as the push user, with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900` each, n=1. No live state
touched (all under /tmp; the stale sweep's `SPOOL_ROOT` is its own `$T/spool` fixture).

Control files hashed (constructed heads, not committed anywhere):
- head1 `spl-claude-project-slug.tst.sh` sha256
  `6c637397aec426a192e02715d1987a90f075a5cc28855908cac12d6c518db75d`
- head2 `spl-issue-stale-sweep.tst.sh` sha256
  `b59d733e4aabc4d2d92654fa7f22d15c5a4577ba48890c57a3639dd7b3baf4d2`
- head1 `claude-memory.inc.sh` sha256
  `df59c15d081b42d2e64f1e79c7da8df5603bb7697ac6037b040b1a6e583d1b83` (21 lines, plan's 20 -> 21)
- head2 `spl-issue-stale-sweep.func.sh` sha256
  `9049b0c74bbc3f35043f1c0f3f9735406507b17871a89bd7409797303deb306c` (147 lines, plan's 152 -> 147)

Runs (rc, last lines):

- **Base green:** slug tst on base -> rc **0**, 4 pass / 0 fail, `ALL PASS` (plan 1.5:
  0/4/0); stale tst on base -> rc **0**, 32 pass / 0 fail, `all passed` (0/32/0).
- **Row 01 red** (head1's tst in base-t1): rc **1**, `2 FAILED`, last lines
  `FAIL: 4. want no copy in the steps, got 'claude-memory.inc.sh '` and
  `FAIL: 4. claude-memory.inc.sh sourced alone: .../claude-memory.inc.sh: line 1: spl_claude_project_slug: command not found`
  — the plan's 1.5 quote.
- **Row 01 green** (head1's tst in head1): rc **0**, 6 pass / 0 fail, `ALL PASS`
  (plan: 0/6/0, case 4 adds 2).
- **Row 01 guard red** (head1-noguard): slug tst rc **1**, `1 FAILED`,
  `FAIL: 4. claude-memory.inc.sh sourced alone: ... spl_claude_project_slug: command not found`;
  `test-y18-grok-memory.sh` rc **1**, `7/13 passed`,
  `FAIL: dry run: .../y18-grok-memory.sh: line 57: spl_claude_project_slug: command not found`
  (also install, late fact, re-run, hand-written, force) — the plan's guard quote.
- **Row 02 red** (head2's tst in base-t2): rc **1**, `3 FAILED`, last lines
  `FAIL: 10. the sweep still reads lease.conf itself: 73: v="$(sed -n ... "$1/dispatch/lease.conf" ...)`
  + `54/55/71: spl_stale_lease_conf ...` and
  `FAIL: 10. LEASE_TENANT is not read through spl_owner_digest_lease_conf`
  (my constructed case 10 splits the plan's first fail line in two, so 3 FAILED where
  the plan quotes 2 — same reason, see N2).
- **Row 02 green** (head2's tst in head2): rc **0**, 35 pass / 0 fail, `all passed`
  (plan: 0/34/0; +1 from the split check, N2).
- **Row 02 guard red** (head2-noguard): rc **1**, `14 FAILED`, case 1
  `FAIL: 1. ended '' rc=1: .../spl-issue-stale-sweep.func.sh: line 54: spl_owner_digest_lease_conf: command not found`,
  `FAIL: 1. writes:` empty — no write, the plan's guard quote.

All controls fail for the plan's reason (the copy still present / the guard missing),
not for an environment reason.

## 4. Equivalence of each row

- The deleted bodies are byte-identical to the shared ones: `diff` of
  `claude-memory.inc.sh:9` (name normalised) vs helper `:10` -> empty; `diff` of
  `spl-issue-stale-sweep.func.sh:72-75` vs `spl-owner-digest-post.func.sh:163-166` ->
  empty (n=1 each, at base).
- 8-path probe, run now, helper vs the inc's copy over a worktree path, `/a b/c_d.e`,
  a non-ASCII string, `/_._`, the empty string, an embedded newline, a leading dash,
  a double slash -> **8 cases, 0 differ**.
- Newline probe (section 7's reason for leaving the parameter-expansion forms out):
  `x=$'/a\nb'`; `printf '%s' "$x" | sed 's/[^A-Za-z0-9]/-/g'` -> `-a\nb` (od shows
  `- a \n b`), `${x//[^A-Za-z0-9]/-}` -> `-a-b` — they genuinely differ, so pointing
  them at the helper would change output; leaving them out is correct.
- The row columns are equal on base and head: row 01 suites on base and head1 all
  rc 0 with identical counts (`test-y18-grok-memory.sh` 13/0, `test-y20-agy-memory.sh`
  68/0 "2 live agy checks not run", `test-agy-rules-always-on.sh` 14/0,
  `spool-install-y18-grok-memory.tst.sh` 13/0, `spool-install-y20-agy-memory.tst.sh`
  68/0); row 02 suites on base and head2 identical (`spl-owner-digest.tst.sh` 45/0,
  `run-eager-files.tst.sh` 14/0, `func-name-unique.tst.sh` 2/0,
  `iac:.../run-lazy-loader.tst.sh` 30/0, `no-literal-paths.tst.sh` 13/2 on BOTH —
  the scratch-copy artifact of N3). `bash-cleancode.tst.sh` on head1 (full archive):
  rc 0, 15/0. `shellcheck -S warning -x` on row 01's 4 files and row 02's 2 files
  (heads): rc 0, no findings.
- The guards sit inside the functions (head diffs), so neither file gains top-level
  code (`run-eager-files.tst.sh` equal on head2). No row changes an exit code, a
  message, a path or a default: row 01 swaps the function name at 2 call sites and
  rewrites a header comment; row 02 swaps the reader at 2 call sites and deletes the
  private copy. Both are one logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after
(reproduced in check 3), a test list, box `either`, vendor `claude`, kind
`simple_coding`, batch 1. Test lists re-grepped at base: row 01 -> the 6 suites of
check 4 plus `orc-shard-weights.txt` (takes `* 10`, needs no line); row 02 ->
`spl-issue-stale-sweep.tst.sh`, `spl-owner-digest.tst.sh`. No mistral coding or
testing row (owner 10-17, t1 b61851fb). R7 (plan section 4): a grok pick or a fresh
claude waiver seat, never a mistral code R7 — compliant. Re-run now:
`BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=<box> reason=every box is at or
above its high mark; ... grok weekly 39%` (the plan recorded `pick=hold` at
2026-11-22T15:05:32Z; both boxes `full` on load either way — see N4). R1: both rows
are batch 1 and their 6 files are distinct (`sort | uniq -d` -> 0), so no file is
shared within the batch. 2 rows, within 5.1's aim 2 / at most 3.

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 paths, comma-separated> --agent m-286`
-> **exit 4**: no live lane lists any row path; 9 live lanes record no files, all on
the other box: c-146, c-495, c-496, c-499, c-806, c-812, c-924, c-927, g-079 (all
`*-rotate` seats except c-495 SPL-6250 gcal, c-496 search type:calendar, c-499
SPL-6242 WUI avatar, c-806 SPL-6182 native auth — their briefs name hub auth/store/
`cmd/spool`, gcal, WUI, search; no row path). The brief's other named lanes
(c-271 SPL-6257 `spawn-agents/lib/lane-issue.inc.sh` + test + docs, c-273 / c-033 /
c-246 step 030 + cnf, c-249 / c-250 contacts + WUI palette, c-252 calendar) record
files and none is a row path (exit 4 proves it). Briefs changed in the last 24 h
(130) naming a row file/function: **8** — the r87-02 / r88 row and reviewer briefs
(landed rounds, 6), the bug-round-38 planner's (r87-02 in its stay-off list) and this
round's planner's; none live. Spawn queue now: `4 queued, 0 placing` (the held spec
154 B16..B11 chain), none naming a row path.

## 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` read directly (114 lines).
  Its refactor-shaped items, re-verified on origin/master: the literal-`/var`
  candidates are served — `git grep -n 'LOGIN_STATE_DIR:-' origin/master --
  spl-watchdog.func.sh spl-lane-rotate.func.sh` -> 0 hits;
  `reverse-tunnel-cron.sh:27` reads `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`;
  the only `/var/` left in the watchdog / boot-restore cron is the `@example` line
  `spl-watchdog.func.sh:76` and the `${SPOOL_ROOT:-/var/spool-hub}` default (the
  owner-decided spool-root exception). `spl-desk-reply.sh:9,19` list all the kinds
  `...|decision|docs` (SPL-6107 N1 served). `10_ci-quality.yml:444-446` now say "only
  about 96 MB of it is left" (p18-02 N1 served). `spl-uplink-probe.func.sh:14-18`
  name the rc 1 config fault (SPL-5828 N1 served). The `spl-lane-mix.func.sh` agy
  words (`:46`, `:392`, `:401`) are still there with SPL-6174 landed
  (`git merge-base --is-ancestor 4d95cd4c3 origin/master` -> rc 0): the plan's 1.2 (c)
  / section 7 account them (the action's output and flag, asserted by its test; the
  fleet rule text still names agy). The `!inserted` loop-fire branch and the `_ppe_keys`
  e2e selector are a test row and a gate-design item, named in the plan's section 7.
  The rest of the file is bug-shaped (review-go retries, placer gaps, token hash,
  e2e flakes, hermetic suites) or secret-class — not refactor rows.
  **No refactor-shaped input is neither served nor accounted for.**
- r88 plan section 7 read on origin/master: every item is carried into r89's section 7
  (dispatch-lease slug, the parameter-expansion forms with the newline probe, the
  secret-class pairs, the agent-id regex, the bug rows, the test rows, the agy words,
  the spec 011 tasks); the one item it left for a later row, `claude-memory.inc.sh:9`,
  is exactly row 01.
- Bug-row scan: no row changes an exit code, a message, a path or a default (check 4).

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-286`,
rc **0** (run before this file was written; re-run after adding it, still rc 0).

## Defects

None (no W1...).

## Notes

- **N1** the lane map exits 4 on all 6 row paths; the 9 unknown-scope lanes are all
  on the other box — same result class as the plan's 2.2 (which saw 9 at 14:58-15:02Z);
  no owner of any row path; the row lanes re-run R3 at spawn.
- **N2** the head control files were constructed per the plan's 1.3/1.4 shape (the
  heads are not committed anywhere); their sha256s are in check 3. My case 4 adds 7
  lines (plan says 43 -> 52, mine 43 -> 50) and my case 10 splits the "still reads
  lease.conf itself" check into two fail lines, so the row-02 red prints 3 FAILED where
  the plan quotes 2 and the green column reads 35 where the plan says 34 — same reason,
  not an environment reason. Run-file line counts match the plan exactly (21 and 147).
- **N3** `no-literal-paths.tst.sh` fails 2 (`STALE baseline: spl-file-erase.func.sh /
  spl-m3-e2e.func.sh has none`) on base AND head2 in my plain `git archive` scratch
  copy (no `.git`); identical on both, so the column's "=" holds. The plan ran in
  detached git worktrees, where it reads 0/15/0. Scratch artifact, not the row.
- **N4** the grok box pick now returns a box (`pick=<box>`, both boxes `full` on load,
  grok weekly 39%); the plan recorded `pick=hold` at 15:05:32Z — either way a grok R7
  seat, or the claude waiver seat if held at placement; never mistral.
- **N5** origin/master moved to `04b6048f2` during the review; `git diff --name-only
  94e5690a2 origin/master -- <the 7 row files>` is empty, so every site stands.
