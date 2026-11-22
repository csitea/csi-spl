# Refactor round 90 — panel seat mistral (m-326@<box>)

Issue: SPL-6265 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-90-mistral-panel-seat.md`.

Review target: `csi-spl-doc/doc/md/refactor-round-90-plan.md` on branch
`review/c002-refactor-round-90-planner` at v0.1
**`418f6e69c043b2bcb41d4d86b30e23f2ef44e868`**.

- `git ls-remote origin refs/heads/review/c002-refactor-round-90-planner` ->
  `418f6e69c043b2bcb41d4d86b30e23f2ef44e868` (head == the sha the holder relayed,
  msg on dispatch-refactor-r90, 2026-11-22T17:24:27Z).
- `git show 418f6e69c --stat --format='%H %cI %s'` -> one file,
  `csi-spl-doc/doc/md/refactor-round-90-plan.md` +408, parent `748282860`, subject
  `docs(r90-plan, SPL-6265): refactor round 90 plan v0.1, 2 rows, for the panel`;
  author and committer the repo-canonical address, no AI trailer.
- The plan's measured base is `748282860` (`origin/master` at 2026-11-22T16:55Z);
  `git merge-base --is-ancestor 748282860 origin/master` -> rc 0 (base on trunk;
  origin/master at review time `e270fc5d7`, HEAD of this worktree `748282860`).
- Every file:line cited below was checked with `git show <sha>:<file> | sed -n <N>p`.
- All control runs were in detached **git worktrees** of `748282860`
  (`git worktree add --detach`, under /var/tmp, removed after this review), as the
  push user, `SPOOL_TEST=1` (test-lib sets it), `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID`
  unset, `timeout 900` each, n=1. Not a `git archive` copy: r89 panel N3 was an
  artifact of one.

**Verdict: PASS on v0.1 `418f6e69c043b2bcb41d4d86b30e23f2ef44e868`. No W defects.**

## 1. Slug r90 unused since the plan's W

- W: `git log origin/master -1 --format='%h %cI' -E --grep='^docs\(r89-plan'` ->
  `b49a192ff 2026-11-22T18:18:54+02:00` — the same W the plan records
  (`Window: W=2026-11-22T18:18:54+02:00`).
- `git log origin/master --since="$W" --oneline -E --grep='\(r90-' | wc -l` ->
  **0**; over all history -> **0**.
- `git ls-remote origin | grep -E 'r90-[0-9]{2}|refactor-round-90'` -> only
  `418f6e69c043b2bcb41d4d86b30e23f2ef44e868  refs/heads/review/c002-refactor-round-90-planner`
  (the planner's; this seat's review branch is pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r90-[0-9]{2}|refactor-round-90'` ->
  exactly `c002-refactor-round-90-planner.md` and
  `c002-refactor-round-90-mistral-panel-seat.md` (the two expected).
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-90`
  -> **0** (the plain name is free on trunk).

## 2. Every row site file:line exists on base and on origin/master

Row paths (6): `orc:src/bash/run/spl-push-orphan-check.func.sh`,
`orc:src/bash/run/spl-agent-login-check.func.sh`,
`orc:src/bash/tests/spl-push-orphan-check.tst.sh`,
`orc:src/bash/tests/spl-agent-login-check.tst.sh`,
`orc:src/bash/run/spl-issue-owner-question-diss.func.sh`,
`orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh` (`orc:` = `csi-spl-orc/`).

- 53 cited file:lines (the row sites of 1.3 / 1.4, the reader
  `spl-owner-digest-post.func.sh:162-166`, the callers and sourcers
  `spl-claude-login-mode.func.sh:44,199`, `spl-agent-login-proof.func.sh:39`,
  `spl-dispatch-lease.func.sh:2727`, `spl-watchdog.func.sh:86`, the brc copy
  `spl-issue-blocker-rca-close.func.sh:140,153,155-158`, the not-in-row bodies
  `spl-issue-discard-stale.func.sh:211`, `spl-issue-stale-sweep.func.sh:140`, and
  every section-7 site: `spl-vendor-terms-check.func.sh:32`,
  `scripts/cron-no-stack.sh:58`, `scripts/reliability-check-cron.sh:72`,
  `scripts/topic-status-card.sh:83`, `spl-cost-labels-translate.func.sh:325`,
  `spl-pool-ctl.func.sh:93`, `iac:.../net-dns-fast-failover.func.sh:71`,
  `iac:.../net-dns-pin-and-mask.func.sh:49`, plus the `_po_to` / `_lc_alert_to`
  ranges `spl-push-orphan-check.func.sh:168,175,182,185-190`,
  `spl-agent-login-check.func.sh:496,514,521,523-528`) each read at `748282860`
  and re-read at `origin/master` with `git show <sha>:<file> | sed -n <N>p`:
  **SAME=53 DRIFT=0**.
- `git diff --name-only 748282860 origin/master -- <the 6 row paths +
  spl-owner-digest-post.func.sh + spl-issue-blocker-rca-close.func.sh>` ->
  **empty** at review time (origin/master `e270fc5d7`): no drift.
- Line counts at base: push-orphan func 190, login-check func 528, push-orphan tst
  200, login-check tst 444, oq-diss func 168, oq-diss tst 77 — as the plan says
  (heads 191 / 529 / 215 / 452 / 162 / 89).
- `git grep -n spl_owner_digest_lease_conf 748282860` -> the definition `:162` and
  the call lines of 6 actions (owner-digest-post, stale-sweep, reflection-gather,
  topic-archive-suggest, topic-prio-sync, zombie-topics) — as 1.3 says.
- `git grep -nE 'spl_issue_oq_one|spl_issue_brc_one' 748282860` -> exactly **6
  lines** (brc `:140,:153,:154`; oq `:150,:163,:164`) — as 1.4 says.
- `git grep -nE 'dispatch/lease\.conf' 748282860` over orc / iac / utl, tests and
  docs out, lines with `sed -n` -> **12** — as 1.2 (a) says.
- `git grep -nE "sed -n ['\"]s/\^LEASE_ORCH=//p" 748282860` -> 3 run files
  (`spl-agent-login-check.func.sh:525`, `spl-push-orphan-check.func.sh:187`,
  `spl-vendor-terms-check.func.sh:32`) + 2 standalone scripts
  (`scripts/cron-no-stack.sh:58`, `scripts/reliability-check-cron.sh:72`) — as
  1.2 (a) says.
- `diff <(git show 748282860:.../spl-issue-blocker-rca-close.func.sh | sed -n
  '155,158p') <(git show 748282860:.../spl-issue-owner-question-diss.func.sh |
  sed -n '165,168p')` -> **empty** (byte-identical bodies, n=1) — as 1.4 says.
- `git grep -nE '^[a-z_]+\(\)' 748282860 -- spl-owner-digest-post.func.sh` ->
  only `do_spl_owner_digest_post` and `spl_owner_digest_{run,render,box,lease_conf}`;
  `-- spl-issue-blocker-rca-close.func.sh` -> only
  `do_spl_issue_blocker_rca_close`, `spl_issue_brc_*`, `_spl_issue_brc_query`.
  Neither file stubs a function of the two row tests (the oq tst stubs
  `spl_issue_oq_read`, `spl_desk_issue_once`, `spl_desk_issue_run`), so each
  guard's `source` replaces none — as 1.3 / 1.4 say.

## 3. Red controls, run on the plan's base in git worktrees

Heads constructed per the plan's 1.3 / 1.4 shape in detached worktrees of
`748282860` (not committed anywhere): "base" unmodified, "head1" = base with row
01 applied, "head2" = base with row 02 applied, "base-t1" / "base-t2" = base with
only the head's test file copied in, "head1-noguard-po" / "head1-noguard-lc" /
"head2-noguard" = the heads with the `declare -F` line deleted. Nothing committed,
nothing pushed; every run `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID`
unset, `timeout 900`, n=1. No live state touched: all fixtures live under the
test's own mktemp `$T` (its own spool root), and `SPOOL_TEST=1` makes the spool
guard refuse the live root.

Control files hashed (constructed heads):

- head1 `spl-push-orphan-check.func.sh` sha256
  `a4773ab38a66e845d9c4b3a4791a98119a6e32e793a399ad8ac36cfc79b97dc2` (191 lines)
- head1 `spl-agent-login-check.func.sh` sha256
  `cd7587ff7be2cefa4e062fd4ef6ead7e151573fc76aef9817974d385a9207bc6` (529 lines)
- head1 `spl-push-orphan-check.tst.sh` sha256
  `54d93032a46ee80b99c1e37ff6468440f79e8bb452187ee229582bc550665c05` (214 lines)
- head1 `spl-agent-login-check.tst.sh` sha256
  `9e18e07cabd7f78c8b08eba7214c4f1cf8a63d73332ea3fc65d3f9ebd6b80b51` (450 lines)
- head2 `spl-issue-owner-question-diss.func.sh` sha256
  `9dac57025d63b89b1e3d77f3071e6470dcf0a3ee9b176674d00b3d65d34ebded` (162 lines)
- head2 `spl-issue-owner-question-diss.tst.sh` sha256
  `bb6ab8e14408c4f401fb835b84f4c83e0dbb651f11a92990b7be75a9b1349f46` (89 lines)

Runs (rc, pass/fail line counts, last lines):

- **Base green:** push-orphan tst on base -> rc **0**, 26 pass / 0 fail,
  `spl-push-orphan-check: 0 failure(s)` (plan 1.5: 0/26/0); login-check tst on
  base -> rc **0**, 57 / 0, `spl-agent-login-check: 0 failed` (0/57/0); oq-diss
  tst on base -> rc **0**, 9 / 0, `ALL PASS` (0/9/0).
- **Row 01 red** (head1's push-orphan tst in base-t1): rc **1**, 27 pass / 1 fail,
  `FAIL: 12. own LEASE_ORCH reader left: .../spl-push-orphan-check.func.sh:187:
  o="$(sed -n 's/^LEASE_ORCH=//p' "$SPOOL_ROOT/dispatch/lease.conf" ...`, last line
  `spl-push-orphan-check: 1 failure(s)` — the plan's 1.5 quote. The second half
  of case 12 (`--from c-007`) passes on base too: it pins the behaviour, it is not
  the red control.
- **Row 01 green** (head1's tst on head1): rc **0**, 28 / 0 (plan: 0/28/0, case 12
  adds 2); head1's login-check tst on head1 -> rc **0**, 58 / 0 (plan: 0/58/0,
  case 23 adds 1).
- **Row 01 guard red** (head1-noguard-po): push-orphan tst rc **1**, 1 fail,
  `FAIL: 12. --from c-007 (.../spl-push-orphan-check.func.sh: line 187:
  spl_owner_digest_lease_conf: command not found ...)`; (head1-noguard-lc):
  login-check tst rc **1**, 1 fail, `FAIL: 23. _lc_alert_from sourced alone
  (.../spl-agent-login-check.func.sh: line 525: spl_owner_digest_lease_conf:
  command not found ...)` — the plan's guard quotes.
- **Row 02 red** (head2's oq tst in base-t2): rc **1**, 10 pass / 1 fail,
  `FAIL: r90-02: own copy left: 150:    if spl_issue_oq_one "$key" "$why"; then`,
  last line `1 FAILED` — the plan's 1.5 quote.
- **Row 02 green** (head2's tst on head2): rc **0**, 11 / 0, `ALL PASS` (plan:
  0/11/0).
- **Row 02 guard red** (head2-noguard): rc **1**, 1 fail,
  `FAIL: r90-02: sourced-alone run (rc=1): INFO 5 candidates: KEEP=2 MOVE=2
  SKIP=1 ...` — no diss write, the plan's guard quote.

All controls fail for the plan's reason (the own copy still present / the guard
missing), not for an environment reason.

## 4. Equivalence of each row

- The deleted bodies are byte-identical to the shared ones: `diff` of
  `spl-issue-blocker-rca-close.func.sh:155-158` vs
  `spl-issue-owner-question-diss.func.sh:165-168` -> empty (n=1, at base).
- The `-n` probe (1.3's reason the reader is safe at the two row-01 sites, and
  section 7's reason `spl-vendor-terms-check.func.sh:32` stays out): with
  `LEASE_ORCH=-n` in a fixture lease.conf,
  `spl_owner_digest_lease_conf <root> LEASE_ORCH ""` prints `[]` (the reader's
  `echo` eats `-n`), the inline `sed` captures `[-n]` — they differ — but
  `[[ "-n" =~ ^${SPOOL_AGENT_ID_RX}$ ]]` is NO match, so both row-01 sites fall
  back to `spl_role_seat 1` on base and head alike. The third run file has no id
  check after its read, so pointing it at the reader would change its output:
  leaving it out is correct.
- The column (1.5) re-run now in the git worktrees, base / head1 / head2, all
  rc 0 with identical counts, matching the plan's table exactly:
  `spl-claude-login-mode` 17, `spl-agent-login-proof` 16, `wd-login-snapshot` 14,
  `spl-claude-project-slug` 6, `spl-owner-digest` 45, `spl-issue-stale-sweep` 34,
  `spl-issue-blocker-rca-close` 18, `run-eager-files` 14, `no-literal-paths` 15,
  `func-name-unique` 2, `iac:run-lazy-loader` 30, `iac:bash-cleancode` 15 —
  0 fail everywhere. `no-literal-paths.tst.sh` reads 15/0 in a git worktree
  (r89 panel N3's STALE lines were the `git archive` artifact, as the plan's 1.2
  (b) says).
- `shellcheck -S warning -x` on the 6 row files: rc **0**, no findings, on base,
  head1 and head2 (n=1 each).
- The guards sit inside the functions (head diffs), so neither file gains
  top-level code (`run-eager-files.tst.sh` equal on all three trees). No row
  changes an exit code, a message, a path or a default: row 01 swaps the reader
  at 2 call sites (both regex-guarded, the `-n` probe above); row 02 swaps the
  call at `:150` for the byte-identical body. Both are one logical refactor.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both section-2 rows carry a red control that fails today and passes after
(reproduced in check 3), a test list (the 1.5 column plus `shellcheck` and
`cd csi-spl-iac && ./run -a do_check_pre_push`), box `either`, vendor `claude`,
kind `simple_coding`, batch 1. No mistral coding or testing row (owner 10-17, t1
b61851fb). R7 (plan section 4): a grok pick or the claude waiver seat, never a
mistral code R7 — compliant. Re-run now:
`BOX_PICK_KIND=grok ./run -a do_spl_box_pick` -> `pick=<box> reason=<box> is the
first box in order below its low mark (57% < 70%)`, grok weekly 43% on both
boxes (the plan recorded a pick at 2026-11-22T17:17Z too — see N4). R1: both rows
are batch 1 and their 6 files are distinct (`sort | uniq -d` -> 0), so no file is
shared within the batch. 2 rows, within 5.1's aim 2 / at most 3; 5.3's numbering
r90 with the plain plan name free on trunk (check 1).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 paths, comma-separated> --agent m-326`
-> **exit 4**: no live lane lists any row path; 7 live lanes record no files, all
on the other box: c-146, c-496 (search type:calendar), c-499 (SPL-6242 WUI
avatar), c-593 (the hub wake-off relay flake), c-812, c-924, c-927 (all
`*-rotate` seats). The brief's other named lanes (SPL-6182 c-806 hub auth /
store / `cmd/spool`, spec 154 B8 c-249 and B16 c-293 contacts) record
files and none is a row path (exit 4 proves it). Spawn queue now
(`./run -a do_spl_spawn_queue`): `5 queued, 0 placing`, all held spec 154 rows
(B17/B18/B12/B11/B16b), none naming a row path; share line refactor 2 of 11
known live lanes, 18% (band 10-20%: ok). Briefs changed in the last 24 h (140
most recent) naming a row file/function: **3** — the r88-01 row, the r88-01
reviewer's and the r88-02 rotate briefs (a landed round); none live. Remote
branches with commits in the last 24 h: **40**, `git diff --name-only
<merge-base> <b> -- <the 8 paths>` -> **0 hits**. Commits in the last 24 h on the
8 paths: **1**, `90522d802` (r88-01, landed).

## 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` read directly (114
  lines). Its refactor-shaped items, re-verified on origin/master: the literal
  `/var` candidates are served — `git grep -n 'LOGIN_STATE_DIR:-' origin/master
  -- spl-watchdog.func.sh spl-lane-rotate.func.sh` -> 0 hits;
  `reverse-tunnel-cron.sh:27` reads
  `${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}`; the
  agent-boot-restore dir is `$SPL_VAR_APP_DIR/agent-boot-restore`
  (`spl-agent-boot-restore-install-cron.func.sh:31,53`). `spl-desk-reply.sh:9`
  lists all the kinds incl. `decision|docs` (SPL-6107 N1 served).
  `10_ci-quality.yml:445` says "only about 96 MB of it is left" (p18-02 N1
  served). `spl-uplink-probe.func.sh:15` names the rc 1 config fault (SPL-5828
  N1 served). The `spl-lane-mix.func.sh` agy words and flag, the `_ppe_keys` e2e
  selector and the `!inserted` loop-fire branch are accounted in the plan's
  section 7 (behaviour / a gate-design item / a test row). The rest of the file
  is bug-shaped, test-shaped or secret-class — not refactor rows.
  **No refactor-shaped input is neither served nor accounted for.**
- r89 plan section 7 read on origin/master: the inline `LEASE_ORCH` reads are
  exactly row 01 (the 3 run files; the third stays out for the `-n` reason, check
  4), the `spl_issue_brc_one` / `spl_issue_oq_one` pair is exactly row 02, and
  every other item stays out for its r89 reason, carried into r90's section 7.
- Bug-row scan: no row changes an exit code, a message, a path or a default
  (check 4).

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> all `ok`,
`INFO distribution-hygiene: clean over the tracked tree of <this worktree>`,
rc **0** (run before this file was written; re-run after adding it, still rc 0).

## Defects

None (no W1...).

## Notes

- **N1** the head control files were constructed per the plan's 1.3 / 1.4 shape
  (the heads are not committed anywhere); their sha256s are in check 3. My
  constructed test files differ in line count from the plan's heads (push-orphan
  tst 214 vs the plan's 215, login-check tst 450 vs 452; oq tst 89 = the plan's
  89; the func files match exactly: 191 / 529 / 162), but every pass count
  matches the plan's 1.5 exactly (28, 58, 11) and every red/guard control fails
  with the plan's quoted line — same reason, not an environment reason.
- **N2** origin/master moved to `e270fc5d7` during the review; `git diff
  --name-only 748282860 origin/master -- <the 8 row paths>` is empty and all 53
  cited lines read SAME, so every site stands.
- **N3** the lane map now exits 4 with 7 unknown-scope lanes (the plan saw 9 at
  17:15Z), all on the other box; 40 remote branches had commits in the last 24 h
  (the plan saw 18), 0 hits on the row paths either way. No owner of any row
  path; the row lanes re-run R3 at spawn.
- **N4** the grok box pick returns a box now (`pick=<box>`, grok weekly 43% on both
  boxes), as it did at the plan's 17:17Z read — either way a grok R7 seat per row,
  or the claude waiver seat if the pick holds at placement; never mistral.
