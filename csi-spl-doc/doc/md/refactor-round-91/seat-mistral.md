# Refactor round 91 — panel seat mistral (m-548@<box>)

Issue: SPL-6282 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-91-mistral-panel-seat.md`.

Review target: `csi-spl-doc/doc/md/refactor-round-91-plan.md` on branch
`review/c002-refactor-round-91-planner` at v0.1
**`3eb6298f8d4f0b46cb24a0e5fa10bce1f032cb3e`**.

- `git ls-remote origin refs/heads/review/c002-refactor-round-91-planner` ->
  `3eb6298f8d4f0b46cb24a0e5fa10bce1f032cb3e` (head == the v0.1 sha; the commit subject
  names it: `docs(r91-plan, SPL-6282): refactor round 91 plan v0.1 for the panel: ...`,
  committed 2026-11-23T08:15:50+02:00 by the planner c-547).
- `git show 3eb6298f8 --stat --format='%H %cI %s'` -> one file,
  `csi-spl-doc/doc/md/refactor-round-91-plan.md` +369, parent `1b49782a0`, author and
  committer the repo-canonical address, no AI trailer.
- The plan's measured base is `1b49782a0` (`origin/master` at 2026-11-23T06:06Z);
  `git merge-base --is-ancestor 1b49782a0 origin/master` -> rc 0; origin/master was
  still `1b49782a0` at the end of this review (re-fetched 2026-11-23T06:25Z), so base ==
  trunk and every base read is also the trunk read.
- Every file:line cited below was checked with `git show <sha>:<file> | sed -n <N>p`.
- All control runs were in detached **git worktrees** of `1b49782a0`
  (`git worktree add --detach` under /var/tmp/r91-review, removed after this review),
  as the push user, `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset,
  `timeout 900` each, n=1. Nothing committed, nothing pushed from those trees.

**Verdict: PASS on v0.1 `3eb6298f8d4f0b46cb24a0e5fa10bce1f032cb3e`. No W defects.**

## 1. Slug r91 unused since the plan's W

- W: `git log origin/master -1 --format='%h %cI' -E --grep='^docs\(r90-plan'` ->
  `447095af7 2026-11-22T21:43:20+02:00` — the same W the plan records
  (`Window: W=2026-11-22T21:43:20+02:00`).
- `git log origin/master --since="$W" --oneline -E --grep='\(r91-' | wc -l` ->
  **0**; over all history -> **0**.
- `git ls-remote origin | grep -E 'r91-[0-9]{2}|refactor-round-91'` -> only
  `3eb6298f8d4f0b46cb24a0e5fa10bce1f032cb3e  refs/heads/review/c002-refactor-round-91-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r91-[0-9]{2}|refactor-round-91'` ->
  exactly `c002-refactor-round-91-planner.md` and
  `c002-refactor-round-91-mistral-panel-seat.md` (the two expected).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-91`
  -> **0** (the plain name is free on trunk).

## 2. Every row site file:line exists on base and on origin/master

Row paths (4) plus the two keepers (6): `orc:src/bash/run/tf-import-existing.func.sh`,
`orc:src/bash/tests/tf-import-existing.tst.sh`,
`orc:src/bash/run/spl-search-calendar-probe.func.sh`,
`orc:src/bash/tests/spl-search-calendar-probe.tst.sh`,
`orc:src/bash/run/tf-plan-ref.func.sh`, `orc:src/bash/run/spl-search-doc-probe.func.sh`
(`orc:` = `csi-spl-orc/`).

- Every cited line read at `1b49782a0` with `git show <sha>:<file> | sed -n <N>p`:
  row 01 — import func `:54-55` (the two `_tf_import_oap` calls), `:104` blank,
  `:105-107` comment, `:108-111` the 4-line `_tf_import_oap` (body `:109-110`);
  plan-ref `:57-58` (calls), `:117-122` (comment + `_tf_plan_ref_oap`, body `:120-121`);
  import tst `:100` (sources the real file alone), `:157` (`verdict` helper);
  row 02 — cal probe func `:25` (the check call), `:46` blank, `:47-48` comment,
  `:49-52` the 4-line `spl_search_calendar_probe_check` (body `:50-51`);
  doc probe func `:25`, `:47-52` (body `:50-51`); cal probe tst `:127-131` (`chk`).
  All match the plan's 1.3 / 1.4 text. Section-7 sites also read: `ndf_link` at
  `orc:.../net-dns-fast-failover.func.sh:71`, `ndp_link` at
  `orc:.../net-dns-pin-and-mask.func.sh:49`, `ghr_in` `gh-runner-add.func.sh:112`,
  `ghrm_in` `gh-runner-remove.func.sh:43`, `oss_runner_in` `oss-runners-move.func.sh:40`,
  `spl_asks_dur` `spl-asks-tick.func.sh:479`, `spl_fleet_dur`
  `spl-dispatch-lease.func.sh:1731`, `spl_search_speed_probe_check`
  `spl-search-speed-probe.func.sh:43`, the `LEASE_ORCH` sed
  `spl-vendor-terms-check.func.sh:32`, `_spl_rebox_copy` / `_spl_rebox_verify`
  `spl-desk-rebox.func.sh:128,232`, the red-copy controls
  `net-dns-pin-and-mask.tst.sh:157-168` and `gh-runner-add.tst.sh:247-252`.
- origin/master at review end (re-fetched 2026-11-23T06:25Z) is still `1b49782a0` ==
  the plan's base, so every base read is the trunk read;
  `git diff --name-only 1b49782a0 origin/master -- <the 6 paths>` -> **empty**.
- `git grep -nE '_tf_import_oap|_tf_plan_ref_oap' 1b49782a0 -- ':!*.md'` -> **8 lines**
  (import `:54,:55,:105,:108`; plan-ref `:57,:58,:117,:119`) — as 1.3 says; no test
  names either.
- `git grep -n 'do_resolve_oap "\$1"; echo' 1b49782a0 -- ':!*.md'` -> exactly **2 lines**
  (import `:109`, plan-ref `:120`) — as 1.3 says.
- `git grep -nE 'spl_search_(calendar|doc)_probe_check' 1b49782a0 -- ':!*.md'` -> 6
  lines (the 4 call/def lines `:25,:49` of each file plus the 2 comment lines `:47`);
  no test names either — as 1.4 says (its "4 lines" counts the call/def lines).
- `git grep -n 'TENANT_ID must be a tenant slug' 1b49782a0 -- csi-spl-orc/src/bash/run |
  wc -l` -> **21** — as section 7 says.
- `diff` of import `:109,110` vs plan-ref `:120,121` -> **empty** (byte-identical
  resolver bodies, n=1); `diff` of cal probe `:50,51` vs doc probe `:50,51` ->
  **empty** (byte-identical knobs-check bodies, n=1).
- Line counts at base: import func 111, import tst 163, cal probe func 52, cal probe
  tst 142 — as the plan says (heads 104 / 173 / 46 / 151).
- `git grep -nE '^[a-z_]+\(\)' 1b49782a0 -- tf-plan-ref.func.sh` -> only
  `do_tf_plan_ref` and `_tf_plan_ref_*`; `-- spl-search-doc-probe.func.sh` -> only
  `do_spl_search_doc_probe` and `spl_search_doc_probe_check`. The import tst stubs
  `do_log` (and `docker` on `PATH`); the cal probe tst's `chk` stubs `do_log`,
  `spl_dry_run`, `do_require_bin`, `do_spl_cloud_cnf`, `spl_cnf_api_fqdn` — none of them
  is defined in the keeper, so each guard's `source` replaces none, as 1.3 / 1.4 say.
- Section 7's ndf/ndp bodies: `diff` of `net-dns-fast-failover.func.sh:71-75` vs
  `net-dns-pin-and-mask.func.sh:49-53` (names masked) -> **empty**; the pin-and-mask
  tst's red controls at `:157-168` write red copies to `$T` — as section 7 says.
  `spl-search-speed-probe.func.sh:43-48` = row 02's body plus 2 more checks — as
  section 7 says.

## 3. Red controls, run on the plan's base in git worktrees

Heads constructed per the plan's 1.3 / 1.4 shape in detached worktrees of `1b49782a0`
(under /var/tmp/r91-review, removed after this review): "base" unmodified, "head1" =
base with row 01 applied, "head2" = base with row 02 applied, "base-t1" / "base-t2" =
base with only the head's test file copied in, "head1-noguard" / "head2-noguard" = the
heads with the `declare -F` line deleted. Nothing committed, nothing pushed; every run
`SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900`, n=1, as the
push user. No live state touched: all fixtures live under each test's own mktemp `$T`
(its own spool root; `SPOOL_TEST=1` makes the spool guard refuse the live root), and
the cal probe test's only network is a stub hub on 127.0.0.1 with an ephemeral port,
killed by its trap.

Control files hashed (constructed heads):

- head1 `tf-import-existing.func.sh` sha256
  `1fac8d3b10df44e72dd8bfa24946cdea38c83d2317af549c46ef23412b6e86d6` (104 lines)
- head1 `tf-import-existing.tst.sh` sha256
  `f73cb0d4e9f21039f269b8e830203994017d5ae320045882a5babdc528fb8fa5` (172 lines)
- head2 `spl-search-calendar-probe.func.sh` sha256
  `7ed07763b8adaf2b81dd8de4363907cdee30eaf8c249ff4592f9de9c70308d34` (46 lines)
- head2 `spl-search-calendar-probe.tst.sh` sha256
  `f58e487828e4f42c8e27a89921bc1bbd233e595190e9bdf30edb8f3280fa8205` (150 lines)

Runs (rc, pass/fail line counts, last line; pass = `grep -ciE '^ *(ok|pass)'`,
fail = `grep -ciE '^ *(not ok|fail)'`):

- **Base column** (all rc **0**, 0 fail): `tf-import-existing.tst.sh` 29 pass
  (plan 1.5: 0/29/0); `tf-plan-ref.tst.sh` 47 (0/47/0); `spl-search-calendar-probe.tst.sh`
  6 (0/6/0); `spl-search-doc-probe.tst.sh` 6 (0/6/0); `search-speed-probe.tst.sh` 12
  (0/12/0); `run-eager-files.tst.sh` 14; `no-literal-paths.tst.sh` 15;
  `func-name-unique.tst.sh` 2; `iac:run-lazy-loader.tst.sh` 30; `iac:bash-cleancode.tst.sh`
  15 — the plan's table exactly.
- **Row 01 red** (head1's tst in base-t1): rc **1**, 29 pass / 2 fail, last line
  `--- 2 failure(s)`, FAIL lines:
  `FAIL: 12. own ORG/APP resolver left: 108:_tf_import_oap() {` and
  `FAIL: 12. no _tf_plan_ref_oap ORG call` — the plan's 1.5 quote verbatim.
- **Row 01 green** (head1's tst on head1): rc **0**, 31 pass / 0 fail, last
  `--- 0 failure(s)` (plan: 0/30/0; my case 12 carries 2 pass lines where the plan's
  carries 1 — see N1).
- **Row 01 guard red** (head1-noguard): rc **1**, 23 pass / 8 fail, last
  `--- 8 failure(s)`; first FAILs:
  `FAIL: 040-cloud-sql-postgres dev: rc=1 .../tf-import-existing.func.sh: line 54: _tf_plan_ref_oap: command not found`
  (and the prd twin) — the plan's guard quote verbatim, 8 fail lines as the plan says.
- **Row 02 red** (head2's tst in base-t2): rc **1**, last line `FAILED: 1`, FAIL line
  `FAIL: own knobs check left, or no call of spl_search_doc_probe_check: 49:spl_search_calendar_probe_check() {`
  — the plan's 1.5 quote verbatim.
- **Row 02 green** (head2's tst on head2): rc **0**, 7 pass / 0 fail, last
  `PASS: all` (plan: 0/7/0).
- **Row 02 guard red** (head2-noguard): rc **1**, last line `FAILED: 1`, FAIL line
  `FAIL: the action's knobs: [.../spl-search-calendar-probe.func.sh: line 25: spl_search_doc_probe_check: command not found] ...`
  — the plan's guard quote verbatim.
- **Heads' other suites** (all rc 0, 0 fail, equal to base): head1 `tf-plan-ref` 47,
  `run-eager-files` 14, `no-literal-paths` 15, `func-name-unique` 2, `run-lazy-loader`
  30, `bash-cleancode` 15; head2 `spl-search-doc-probe` 6, `search-speed-probe` 12,
  and the same five gates 14/15/2/30/15.
- `shellcheck -S warning -x` on each row's two files, base and both heads: rc **0**,
  no findings (n=1 each, 12 runs).

Every control fails for the plan's reason (the own copy still present / the guard
missing), not for an environment reason, and none touches live state.

## 4. Equivalence of each row

- The deleted bodies are byte-identical to the shared ones (check 2: both `diff`s
  empty at base), and the changed call sites pass the same arguments: row 01's
  `:54-55` call `_tf_plan_ref_oap ORG|APP "$root" "$orc_dir"` exactly as the deleted
  `_tf_import_oap` was called; row 02's `:25` calls `spl_search_doc_probe_check
  "$tenant"` exactly as the deleted check was called.
- The column (check 3) is equal on base and both heads but for the added cases, and
  case 6 of the import tst asserts `ORG=csi APP=spl` on every exec — green on head1,
  so the resolution is unchanged; the cal probe's knobs check asserts the exact
  `FATAL ENV must be dev or prd` / `FATAL TENANT_ID must be a tenant slug` messages and
  the dry-run line — green on head2, so the refusal messages and return codes are
  unchanged.
- The controls catch a difference: case 12 / the new check fail while the own copy is
  present (RED on base, GREEN on the head); the guard controls fail when the
  `declare -F` line is deleted; case 6 pins the resolved ORG/APP; the knobs check pins
  the refusal text.
- The guards sit inside the calling functions (head diffs), so neither file gains
  top-level code (`run-eager-files.tst.sh` equal on all trees). No row changes an exit
  code, a message, a path or a default: both rows swap a call for the byte-identical
  body. Each row is ONE logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after (reproduced
in check 3), a test list (the 1.5 column plus `shellcheck` and
`cd csi-spl-iac && ./run -a do_check_pre_push`), box `either`, vendor `claude`, kind
`simple_coding`, batch 1. No mistral coding or testing row (owner 10-17, t1 b61851fb).
R7 (plan section 4): a grok pick or the claude waiver seat, never a mistral code R7 —
compliant. Re-run now: `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` ->
`pick=<box> reason=<box> is the first box in order below its low mark (17% < 70%)`, grok
weekly 57-58% on both boxes — a grok R7 seat per row (the plan recorded a pick at
06:11:50Z too). R1: the two rows' 4 files are distinct (`sort | uniq -d` -> empty), so
no file is shared within batch 1. 2 rows, within 5.1's aim 2 / at most 3; 5.3's
numbering r91 with the plain plan name free on trunk (check 1).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 paths, comma-separated> --agent m-548`
-> **exit 4**: no live lane lists any of the 6 paths; 4 live lanes record no files
(all `unknown:`, all `*-rotate` seats on the other box: c-146@<box>, c-499@<box>,
c-924@<box>, c-927@<box>). The brief's named lanes at 06:0xZ — spec 154 B18 c-473@<box>
(contacts sync, hub + WUI), B12 c-540@<box> (help `people.md`), B11 a-942@<box> (i18n
locale files), SPL-6242 c-499@<box> (WUI avatar) — touch none of the row files: exit 4
proves no live lane lists them, and their scopes are hub/WUI/docs, not orc run files.
Spawn queue now (`./run -a do_spl_spawn_queue`, 06:2xZ): `0 queued, 0 placing`; share
line refactor 2 of 7 known live lanes, 28% (band 10-20%: OVER). Briefs changed in the
last 24 h naming a row file or function (`find ... -mmin -1440 | xargs grep -lE
'tf-import-existing|tf-plan-ref|_tf_import_oap|_tf_plan_ref_oap|spl-search-calendar-probe|spl-search-doc-probe|spl_search_(calendar|doc)_probe_check'`)
-> **0**. Remote branches with head in the last 24 h: **17**,
`git diff --name-only <merge-base> <b> -- <the 6 paths>` -> **0 hits**. Commits in the
last 24 h on the 6 paths on master -> **1**: `1ce4797b6` (SPL-6251, the calendar probe
itself, landed). One stale branch, `review/search-qto-docs` (head 2026-10-25), touches
`spl-search-doc-probe.func.sh` against its month-old merge-base, but no live lane owns
it (exit 4) and its head is not in the last 24 h — see N3.

## 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` read directly (114 lines,
  the same count r90 read at 16:5xZ). Its refactor-shaped items, re-verified on
  origin/master: the literal `/var` paths are served —
  `git grep -n 'LOGIN_STATE_DIR:-' origin/master -- spl-watchdog.func.sh spl-lane-rotate.func.sh`
  -> 0 hits; `reverse-tunnel-cron.sh:27` reads
  `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`; the agent-boot-restore
  dir is `$SPL_VAR_APP_DIR/agent-boot-restore`
  (`spl-agent-boot-restore-install-cron.func.sh:31`). `spl-desk-reply.sh:9` lists all
  the kinds incl. `decision|docs` (SPL-6107 N1 served).
  `git grep -c spool_install_memory_slug origin/master -- csi-spl-orc` -> 0 (r90 1.2 (a)
  "served"). `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor`
  -> 0 (1.2 (d)). The `_ppe_keys` e2e selector is a gate-design input and the
  `!inserted` loop-fire branch a test row (candidates file, b37 entry; r90 1.2 (c)) —
  accounted, not this round's. The `spl-lane-mix.func.sh` agy words are still on master
  (`:46,:136,:138,:392,:401,:402`) and the candidates file calls for a row "once
  SPL-6174 lands" (SPL-6174 landed `986ddca84`); the plan accounts them via r90
  section 7's "behaviour and a rule decision", carried by r91 section 7's last row —
  see N4. The rest of the file is bug-shaped, test-shaped, secret-class or process —
  not refactor rows. **No refactor-shaped input is neither served nor accounted for.**
- r90 plan section 7 read on origin/master: its items are carried into r91's section 7
  (last row, "unchanged since W, its reason there"); the two rows' inputs (1.2 (a)) are
  re-verified above.
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
  files differ in line count from the plan's heads (import tst 172 vs the plan's 173,
  cal probe tst 150 vs 151; the func files match exactly: 104 / 46), and head1's pass
  count is 31 vs the plan's 30 because my case 12 carries two pass lines where the
  plan's carries one — every red/guard control fails with the plan's exact quoted line
  and every other count matches the plan's 1.5 exactly. Same reason, not an
  environment reason.
- **N2** origin/master stayed at `1b49782a0` (== the plan's base) through the whole
  review (re-fetched at 06:25Z); `git diff --name-only 1b49782a0 origin/master -- <the
  6 paths>` is empty, so every site stands.
- **N3** the lane map now exits 4 with 4 unknown-scope lanes (all `*-rotate` on the other box;
  the plan saw 5 incl. a-942 at 06:13Z); the queue is now empty (the plan saw 1 queued);
  17 remote branches have heads in the last 24 h (the plan saw 10), 0 hits on the row
  paths either way. One stale branch `review/search-qto-docs` (head 2026-10-25) touches
  `spl-search-doc-probe.func.sh` against its old merge-base; no live lane owns it. The
  row lanes re-run R3 at spawn.
- **N4** the `spl-lane-mix.func.sh` agy words (`needs_agy_review`, "agy has the final
  word") are still on master at `:46,:136,:138,:392,:401,:402`, and the candidates
  file (SPL-6174 follow-up, 2026-11-21 10:3xZ) calls for a refactor/doc row "once
  SPL-6174 lands" — SPL-6174 landed `986ddca84`. The plan accounts the item only via
  r90 section 7's "behaviour and a rule decision"; a doc/rule item, not a pure
  refactor row, so the accounting is defensible, but the next planner should pick it
  up explicitly.
- **N5** the grok box pick now returns a box (`pick=<box> ... 17% < 70%`, grok weekly
  57-58% on both boxes), as it did at the plan's 06:11:50Z read — either way a grok R7
  seat per row, or the claude waiver seat if the pick holds at placement; never
  mistral.
