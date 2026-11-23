# Refactor round 92 — panel seat mistral (m-650@<box>)

Issue: SPL-6306 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-92-mistral-panel-seat.md`.

Review target: `csi-spl-doc/doc/md/refactor-round-92-plan.md` on branch
`review/c002-refactor-round-92-planner` at v0.1
**`eba675d07b465f14a91740219e2da78bd2b3fdcc`**.

- `git ls-remote origin refs/heads/review/c002-refactor-round-92-planner` ->
  `eba675d07b465f14a91740219e2da78bd2b3fdcc` (head == the v0.1 sha; the commit subject
  names it: `docs(r92-plan, SPL-6306): refactor round 92 plan v0.1 for the panel: ...`,
  committed 2026-11-23T14:37:38+02:00 by the planner c-648).
- `git show eba675d07 --stat --format='%H %cI %s'` -> one file,
  `csi-spl-doc/doc/md/refactor-round-92-plan.md` +407, parent `bce008e61`;
  `git log -1 --no-mailmap --format='%ae %ce' eba675d07` -> the repo-canonical address
  for both author and committer (the CLAUDE.md "Commits:" line), body carries no AI
  trailer.
- The plan's measured base is `7024772b1` (`origin/master` at 2026-11-23T12:24Z).
  `origin/master` moved to `bce008e61` (the r91 close record) during this review:
  `git diff --stat 7024772b1 origin/master` -> only `csi-spl-doc/doc/md/refactor-round-91-plan.md`
  (+29 -3), so every base read of the row paths is also the trunk read
  (`git diff --name-only 7024772b1 origin/master -- <the 6 row paths>` -> empty).
- Every file:line cited below was checked with `git show <sha>:<file> | sed -n <N>p`.
- All control runs were in detached **git worktrees** of `7024772b1`
  (`git worktree add --detach` under /var/tmp/r92-review, removed after this review),
  as the push user, `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset,
  `timeout 900` each, n=1. Nothing committed, nothing pushed from those trees.

**Verdict: PASS on v0.1 `eba675d07b465f14a91740219e2da78bd2b3fdcc`. No W defects.**

## 1. Slug r92 unused since the plan's W

- W: the plan records `Window: W=2026-11-23T08:56:59+02:00`, read once at round open
  from `git log origin/master -1 --format=%cI -E --grep='^docs\\(r91-plan'` ->
  `b31854815 2026-11-23T08:56:59+02:00` (verified: `git log -1 --format='%h %cI %s'
  b31854815` prints exactly that). The later r91 close record `bce008e61`
  (2026-11-23T14:28:53+02:00) is now the newest `docs(r91-plan` commit
  (`git log origin/master -1 --format='%h %cI %s' -E --grep='^docs\\(r91-plan'` ->
  `bce008e61 ...`), but rulebook 5.3 says the recorded W stands ("every later read of
  the round uses that recorded date"), and the holder's 12:35:30Z note said the same.
  `git merge-base --is-ancestor b31854815 7024772b1` -> rc 0.
- `git log origin/master --since="$W" --oneline -E --grep='\\(r92-' | wc -l` ->
  **0**; over all history -> **0**.
- `git ls-remote origin | grep -E 'r92-[0-9]{2}|refactor-round-92'` -> only
  `eba675d07b465f14a91740219e2da78bd2b3fdcc  refs/heads/review/c002-refactor-round-92-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r92-[0-9]{2}|refactor-round-92'` ->
  exactly `c002-refactor-round-92-planner.md` and
  `c002-refactor-round-92-mistral-panel-seat.md` (the two expected).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-92`
  -> **0** (the plain name is free on trunk).

## 2. Every row site file:line exists on base and on origin/master

Row paths (4) plus the two keepers (6): `orc:src/bash/run/spl-search-speed-probe.func.sh`,
`orc:src/bash/tests/search-speed-probe.tst.sh`,
`iac:src/bash/run/box-go-switch.func.sh`,
`iac:src/bash/tests/box-go-switch.tst.sh`,
`orc:src/bash/run/spl-search-doc-probe.func.sh`, `iac:src/bash/run/box-pkg-install.func.sh`
(`orc:` = `csi-spl-orc/`, `iac:` = `csi-spl-iac/`), all read at `7024772b1`:

- Row 01 — speed probe func `:25` (the call `spl_search_speed_probe_check "$tenant"
  "$n" "$terms" || return 1`), `:41-48` (comment `:41-42`, def `:43`, body `:44` ENV
  refusal, `:45` TENANT_ID refusal, `:46` PROBE_N, `:47` PROBE_TERMS, `:48` `}`);
  doc probe func `:47-52` (comment `:47-48`, def `:49`, body `:50-51`);
  calendar probe func `:25-26` (the r91-02 guard and call); speed probe tst `:109`
  (`chk` sources the real file alone and calls the check directly). All match 1.3.
- Row 02 — go-switch func `:43` (the guarded `spl_box_name` load), `:45-55` (comment
  `:45`, `_bgs_sudo` `:46-49`, blank, comment `:50`, `_bgs_q` `:51-54`, blank),
  calls `:114-116`, `:123-125` (`_bgs_q`), `:151`, `:161-164`, `:213-225` (`_bgs_sudo`),
  `:233` (`do_box_go_switch`), `:240` (`local GS_ROOT=...`); pkg-install func `:41`
  (the same guarded `spl_box_name` load, its only top-level code), `:43-52`
  (`_bpi_sudo` `:44-47`, `_bpi_q` `:49-52`); go-switch tst `:24` (`FUNC` default),
  `:108`, `:175`, `:218` (source the real file alone); pkg-install tst `:235`,
  `:244-245` (match `_bpi_journal` / `_bpi_send` / `_bpi_real` in its own red copies,
  not the two helpers); the terraform role default
  `iac:src/terraform/060-gcp-vm-satellite/roles/02_os_binaries/defaults/main.yml:3`
  (names `do_box_go_switch`). All match 1.4.
- `diff` of speed probe `:44-45` vs doc probe `:50-51` -> **empty** (byte-identical
  ENV / TENANT_ID refusal, n=1); `diff` of pkg `:43-52` vs go-switch `:45-54` with
  `_bgs_` read as `_bpi_` -> **empty** (byte-identical helper block, n=1).
- `git grep -cE '_bgs_(q|sudo)\b' 7024772b1 -- csi-spl-iac/src/bash/run/box-go-switch.func.sh`
  -> **17** (2 definitions, 2 comments, 13 calls) — as 1.4 says.
- `git grep -nE '\b_b(gs|pi)_(q|sudo)\(\)' 7024772b1 -- ':!*.md'` -> exactly **4**
  definitions (go-switch `:46,:51`; pkg `:44,:49`); no test names either.
- `git grep -nE 'spl_search_(speed|doc)_probe_check' 7024772b1 -- ':!*.md'` -> the
  def/call/comment lines of the three probe files plus the calendar probe tst's
  one-copy check (`:145-148`) — as 1.3 says.
- Line counts at base: speed func 48, speed tst 118, go-switch func 255, go-switch
  tst 225 — as the plan's heads claim (49 / 130 / 246 / 236).
- R2 test-name greps: `git grep -lE 'spl-search-speed-probe|search-speed-probe|spl_search_speed_probe_check' 7024772b1 -- ':!*.md'`
  -> `search-speed-probe.tst.sh` and `orc-shard-weights.txt`; `git grep -lE
  'box-go-switch|do_box_go_switch|_bgs_|_bpi_(q|sudo)' 7024772b1 -- ':!*.md'` ->
  `box-go-switch.func.sh`, `box-go-switch.tst.sh`, `box-pkg-install.func.sh` (the
  keeper's definitions) and the terraform `main.yml:3` comment — as the plan says.
- Drift: `git diff --name-only 7024772b1 origin/master -- <the 6 paths>` -> **empty**;
  `git diff --stat 7024772b1 origin/master` -> only `refactor-round-91-plan.md`.
  Every site stands on trunk.
- Section-7 spot reads at base: `spl-lane-mix.func.sh` agy words at `:46,:136,:138,:392,:401,:402`
  (6 lines; its tst `:16,:471,:475,:476,:477` = 5 lines, case 8 at `:471-477` asserts the
  printed output); the fleet pin `<!-- fleet-pin language-rule-final: agy -->` at
  `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/20-spawn-an-agent.md:38`;
  `ndf_link` `net-dns-fast-failover.func.sh:71-75` and `ndp_link`
  `net-dns-pin-and-mask.func.sh:49-53` (4-line bodies, identical but for the name);
  the red-copy controls `net-dns-fast-failover.tst.sh:194-202` (`sed ... > "$T/red.func.sh"`)
  and `net-dns-pin-and-mask.tst.sh:157-168` (`red1..3.func.sh`).

## 3. Red controls, run on the plan's base in git worktrees

Heads constructed per the plan's 1.3 / 1.4 shape in detached worktrees of `7024772b1`
(under /var/tmp/r92-review, removed after this review): "base" unmodified, "head1" =
base with row 01 applied, "head2" = base with row 02 applied, "base-t1" / "base-t2" =
base with only the head's test file copied in, "head1-noguard" / "head2-noguard" = the
heads with the `declare -F` line deleted. Nothing committed, nothing pushed; every run
`SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900`, n=1, as the
push user. No live state touched: all fixtures live under each test's own mktemp `$T`
(`SPOOL_TEST=1` makes the spool guard refuse the live root), the speed probe's only
network is a stub hub on 127.0.0.1 with an ephemeral port killed by its trap, and the
go-switch test sandboxes `/usr/local` and `/etc` under `GO_SWITCH_ROOT` with stubs on
`PATH`.

Control files hashed (constructed heads):

- head1 `spl-search-speed-probe.func.sh` sha256
  `d04f753ff29a074a4c86a2074a0ba28a9f0b251faf4d5b6ca650c8752347f526` (49 lines)
- head1 `search-speed-probe.tst.sh` sha256
  `343b06f5e4fe00418a1d313ba0647618c3b11a82a6ddc46e5b1ddbf50c753b0a` (134 lines)
- head2 `box-go-switch.func.sh` sha256
  `b2c84b00aa77fc34ab88a822fc9c5016636a1a5e708fbc0813781159be0832b7` (246 lines)
- head2 `box-go-switch.tst.sh` sha256
  `457d5f455a9adfaa2de17b15d70c20c7b7f9728cc0ed4f13ceb98dd22cfe3774` (237 lines)

Runs (rc, pass/fail line counts, last line; pass = `grep -ciE '^ *(ok|pass)'`,
fail = `grep -ciE '^ *(not ok|fail)'`):

- **Base column** (all rc **0**, 0 fail): `search-speed-probe.tst.sh` 12
  (plan 1.5: 0/12/0); `spl-search-doc-probe.tst.sh` 6; `spl-search-calendar-probe.tst.sh`
  7; `box-go-switch.tst.sh` 11; `box-pkg-install.tst.sh` 18; `no-box-path-source.tst.sh`
  10; `no-literal-paths.tst.sh` 15; `func-name-unique.tst.sh` 2; `run-lazy-loader.tst.sh`
  30; `bash-cleancode.tst.sh` 15; `run-eager-files.tst.sh` 14 — the plan's table exactly.
- **Row 01 red** (head1's tst in base-t1): rc **1**, 13 pass / 1 fail, last line
  `search-speed-probe: 1 failure(s)`, FAIL line:
  `FAIL: own ENV / TENANT_ID check left, or no call of spl_search_doc_probe_check: 44:  [[ "${ENV:-}" == dev || ...`
  — the plan's 1.5 quote verbatim.
- **Row 01 green** (head1's tst on head1): rc **0**, 14 pass / 0 fail, last
  `search-speed-probe: 0 failure(s)` (plan: 0/13/0; my check carries 2 pass lines where
  the plan's carries 1 — see N1).
- **Row 01 guard red** (head1-noguard): rc **1**, 12 pass / 2 fail, last
  `search-speed-probe: 2 failure(s)`; FAIL lines `FAIL: a well-formed call was refused`
  and `FAIL: the FATAL lines changed: [] []` (the `spl_search_doc_probe_check: command
  not found` goes to stderr; the FATAL-text half is what fails) — 2 fails as the plan
  says, for the plan's reason.
- **Row 02 red** (head2's tst in base-t2): rc **1**, 11 pass / 1 fail, last
  `box-go-switch: 1 failure(s)`, FAIL line
  `FAIL: 7. own sudo / quote helper left, or no call of _bpi_q: 45:# _bgs_sudo <cmd...>: run as root, through sudo unless already root`
  — the plan's 1.5 quote verbatim.
- **Row 02 green** (head2's tst on head2): rc **0**, 12 pass / 0 fail, last
  `box-go-switch: 0 failure(s)` (plan: 0/12/0).
- **Row 02 guard red** (head2-noguard): rc **1**, 7 pass / 5 fail, last
  `box-go-switch: 5 failure(s)`; FAIL lines `1. plain directory`, `2. symlink`,
  `5. DRY_RUN unset`, `5. DRY_RUN=1` (the `_bpi_sudo: command not found` cases) plus my
  case 7's guard half — the plan counts 4 (its case 7 does not check the guard line);
  same root cause, see N1.
- **Heads' other suites** (all rc 0, 0 fail, equal to base): head1 — doc probe 6,
  calendar probe 7, run-eager-files 14, no-literal-paths 15, func-name-unique 2,
  run-lazy-loader 30, bash-cleancode 15, box-go-switch 11; head2 — box-pkg-install 18,
  no-box-path-source 10, run-eager-files 14, no-literal-paths 15, func-name-unique 2,
  run-lazy-loader 30, bash-cleancode 15, search-speed-probe 12.
- `shellcheck -S warning -x` (0.10.0) on each row's two files, base and both heads:
  rc **0**, no findings (n=1 each, 12 runs).

Every control fails for the plan's reason (the own copy still present / the guard
missing), not for an environment reason, and none touches live state.

## 4. Equivalence of each row

- The deleted bodies are byte-identical to the shared ones (check 2: both `diff`s
  empty at base), and the changed call sites pass the same arguments: row 01's new
  `spl_search_doc_probe_check "$1"` passes the tenant exactly as the deleted TENANT_ID
  line read it (the ENV line reads `${ENV:-}` in both copies); row 02's 13 call lines
  are renamed `_bgs_` -> `_bpi_` with identical arguments (head2 diff shows only the
  rename).
- The column (check 3) is equal on base and both heads but for the added checks; the
  speed probe's knobs checks pass on base and head1, and my added FATAL-text check
  proves `chk stg t1 5 archive` / `chk prd T1 5 archive` print
  `FATAL ENV must be dev or prd, got 'stg'` / `FATAL TENANT_ID must be a tenant slug, got 'T1'`
  word for word on head1 — the refusal messages and return codes are unchanged.
- Row 02's test log on head2 vs base: `diff` -> `11a12 > PASS: 7. one copy: ...` only
  (n=1) — the plan's "11a12" claim verbatim; output, exit codes, paths and defaults
  unchanged.
- The controls catch a difference: the red controls fail while the own copy is present
  (RED on base, GREEN on the head); the guard controls fail when the `declare -F` line
  is deleted. The guards sit inside the calling function/check (head1 `:45` inside
  `spl_search_speed_probe_check`, head2 `:231` inside `do_box_go_switch` after the
  `local`), so neither file gains top-level code (`run-eager-files.tst.sh` equal on all
  trees). No row changes an exit code, a message, a path or a default: each row is ONE
  logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced
in check 3), a test list (the 1.5 column plus `shellcheck` and
`cd csi-spl-iac && ./run -a do_check_pre_push`), box `either`, vendor `claude`, kind
`simple_coding`, batch 1. No mistral coding or testing row (owner 10-17, t1 b61851fb).
R7 (plan section 4): a grok pick or the claude waiver seat, never a mistral code R7 —
compliant. Re-run now: `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` ->
`pick=<box> reason=<box> is the first box in order below its low mark (69% < 70%)`,
grok weekly 63-64% on both boxes — a grok R7 seat per row still holds (the plan recorded
a pick at 12:32:24Z too). R1: the two rows' 4 files are distinct
(`sort | uniq -d` -> empty), so no file is shared within batch 1. 2 rows, within 5.1's
aim 2 / at most 3; 5.3's numbering r92 with the plain plan name free on trunk (check 1).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 paths, comma-separated> --agent m-650`
-> **exit 4**: no live lane lists any of the 6 paths; 9 live lanes record no files
(all `unknown:`, all on the other box: the `*-rotate` seats c-029, c-041, c-086, c-146,
c-924, c-927, the blog lane c-102 (SPL-6302), the bug round 41 planner c-136, and the
language-rule drift lane c-151). The brief's named lanes at 12:2xZ — SPL-6301 c-626
(costs vendor share / prefix route) and costs month range c-624 (both on this box:
their briefs name no row file, `grep -lE '<row patterns>'` over their lifetime briefs ->
no hits), blog SPL-6302 c-102 and bug round 41 c-136 (both in the `unknown:` list) —
touch none of the row files: exit 4 proves no live lane lists them, and their scopes
are costs/blog/planner, not orc or iac run files.
Spawn queue now (`./run -a do_spl_spawn_queue`): `0 queued, 0 placing`; share line
refactor 2 of 15 known live lanes, 13% (band 10-20%: ok). Briefs changed in the last
24 h naming a row file or function -> **2**: `c002-r91-02-orc-search-probe-check.md`
(landed `85f0e60fc`, names the speed probe as off limits) and
`c002-bug-round-41-mistral-panel-seat.md` (names the r92 rows only inside its R3
cross-check instruction, not as its scope). Remote branches with head in the last
24 h: **11**, `git diff --name-only <merge-base> <b> -- <the 6 paths>` -> **0 hits**.
Commits in the last 24 h on the 6 paths on master -> **0**.

## 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` read directly (114 lines).
  Its refactor-shaped items, re-verified on `origin/master`: the literal `/var` paths
  are served — `git grep -n 'LOGIN_STATE_DIR:-' origin/master -- spl-watchdog.func.sh
  spl-lane-rotate.func.sh` -> 0 hits; `reverse-tunnel-cron.sh:27` reads
  `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`;
  `git grep -c spool_install_memory_slug origin/master -- csi-spl-orc` -> 0;
  `spl-desk-reply.sh:9` lists all the kinds incl. `decision|docs` (SPL-6107 N1 served).
  The `spl-lane-mix.func.sh` agy words (r91 panel N4) are accounted in the plan's
  section 7 as not a refactor row — verified: `:138` and `:402` are printed output and
  `:401` the flag value, asserted by `spl-lane-mix.tst.sh:471-477` (case 8), and the
  fleet pin at `20-spawn-an-agent.md:38` still names agy; a live lane (c-151) works the
  drift. The `_ppe_keys` e2e selector is a gate-design input and the `!inserted`
  loop-fire branch a test row (accounted in r90/r91 1.2 (c), carried by the plan's
  1.2 (c)). The rest of the file is bug-shaped, test-shaped, secret-class or process —
  not refactor rows. **No refactor-shaped input is neither served nor accounted for.**
- r91 plan section 7 read on `origin/master`: its items are carried into r92's section 7
  ("unchanged since W, its reason there"); verified `git diff --name-only b31854815
  7024772b1` touches none of the section-7 paths (only the r91 row files themselves:
  `spl-search-calendar-probe.*`, `tf-import-existing.*`). The `TENANT_ID must be a
  tenant slug` count on base is 20 (r91 said 21 on `1b49782a0`; r91-02 removed the
  calendar probe's copy) — consistent.
- `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor`
  -> 0 (1.2 (d)).
- Bug-row scan: no row changes an exit code, a message, a path or a default (check 4).

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of <this worktree>`,
rc **0** (run before this file was written; re-run after adding it, still rc 0).

## Defects

None (no W1...).

## Notes

- **N1** the head control files were constructed per the plan's 1.3 / 1.4 shape (the
  heads are not committed anywhere); their sha256s are in check 3. My constructed test
  files differ in line count from the plan's heads (speed tst 134 vs the plan's 130,
  go-switch tst 237 vs 236; the func files match exactly: 49 / 246), head1's pass count
  is 14 vs the plan's 13 (my check carries two pass lines where the plan's carries one),
  and head2-noguard shows 5 fail lines vs the plan's 4 (my case 7 also checks the
  `declare -F` line's presence). Every red/guard control fails with the plan's exact
  quoted line and every other count matches the plan's 1.5 exactly. Same reason, not an
  environment reason.
- **N2** `origin/master` moved `7024772b1` -> `bce008e61` (the r91 close record) during
  the review; `git diff --name-only 7024772b1 origin/master -- <the 6 paths>` is empty,
  so every site stands.
- **N3** the lane map now exits 4 with 9 unknown-scope lanes (the plan saw 7, incl.
  c-102 and c-136 which are still there, plus c-151 the language-rule drift lane); the
  queue is now empty (the plan saw 1 queued); 11 remote branches have heads in the last
  24 h (the plan saw 12), 0 hits on the row paths either way; 2 briefs name row files
  (the plan saw 1) — the b41 panel seat brief cross-references the r92 rows in its R3
  instruction only. The row lanes re-run R3 at spawn.
- **N4** the recorded `Window: W=` comes from `b31854815` (read once at round open, per
  rulebook 5.3); the r91 close record `bce008e61` landed after that read and does not
  move it. Slug checks since W: 0 commits, 0 branches besides the planner's, 2 briefs.
- **N5** the grok box pick now returns a box (`pick=<box> ... 69% < 70%`, grok weekly
  63-64% on both boxes), as it did at the plan's 12:32:24Z read — either way a grok R7
  seat per row, or the claude waiver seat if the pick holds at placement; never mistral.
