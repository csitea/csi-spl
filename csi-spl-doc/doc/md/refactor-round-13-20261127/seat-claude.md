# Refactoring round 13 (2026-11-27) - panel seat claude

Seat: `c-867` (claude), placement `hand-sat-c002-refactor-round-13-claude-panel-seat`,
same-vendor panel under waiver `1a7c70da` (plan section 9). Issue: SPL-6710.

**Read:** plan `csi-spl-doc/doc/md/refactor-round-13-20261127-plan.md` v0.1 at
**`2d15031a07213af4d855fb07e4c3ed179b03a334`** (`git ls-remote origin
refs/heads/review/c002-refactor-round-13-planner` -> `2d15031a0...`, the sha the
dispatch holder relayed in msg `5ee554e7`; plan file sha256 `e48d7080...6cfc6`, 870 lines).
Base of the plan: `d030289673d10a4ad4caad945382d05e0f474c27`. `origin/master` at review
time: `bad8f0f05`.

## Verdict: FAIL on `2d15031a0` (one defect, W1; everything else reproduces)

Both rows are sound refactors: every site, sha256, numstat, suite count, both red
controls and the 3 mutations I re-ran reproduce exactly on my own scratch clones of
`d03028967`. The plan cannot be signed as written for one reason only: the id `r13` is
not free by rulebook 5.3 for row 02's review branch, and v0.1 leaves the fix undecided
(W1). Fold W1 into v1.0 and I expect to sign it.

All runs: 2026-11-28T00:2xZ-01:0xZ, n=1 per command, as the seat's own OS user, in
scratch clones (`git clone --shared` of this worktree, checkout `d03028967`): `base`,
`head1` = base + the plan's 1.3 diff, `head2` = base + the 1.4 diff, `rc1` / `rc2` = base +
the head's test file. The diffs were cut from the plan file with
`awk '/^```diff/{n++;f=1;next} /^```/{f=0} f{print > "head" n ".diff"}'` and applied
with `git apply` (both applied clean). Suites ran with `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and
`SPOOL_AGENT_ID` unset, stdin `/dev/null`; pass / fail lines counted as the plan's 1.5
does.

## 1. Slug r13 since W

- `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r12-(plan|close)'` ->
  `bbef684985632e26c022c50af4b4f81d665640f6 2026-11-27T20:38:00+02:00 docs(r12-plan, SPL-6696): ...`:
  the plan's `W` (line 10) matches.
- `git log origin/master --since="2026-11-27T20:38:00+02:00" --oneline -E --grep='\(r13-' | wc -l`
  -> `0`.
- `git ls-remote origin | grep -E 'r13-[0-9]{2}|refactor-round-13'` -> 3:
  `2d15031a0 refs/heads/review/c002-refactor-round-13-planner`,
  `6cc7f2cbb refs/heads/review/r13-02`,
  `90887bc0c refs/heads/wip/c-596-c002-r13-01-wui-decompose-message-card`. Nothing else
  (this seat's branch did not exist yet). See W1 for `review/r13-02`.
- `ls -la /var/spool-hub/dispatch/briefs | grep -E 'r13|refactor-round-13'` -> the 2
  expected briefs (`hand-sat-c002-refactor-round-13-planner.md`, this seat's; both
  `Nov 28 01:31`) and the 20 old-cycle leftovers the plan lists at 1.1 lines 101-115
  (19 dated `Nov 18 12:51` plus `.c002-r13-07-restart2.md.bak-2125` `Oct 18 00:22`). The
  names match the plan's list one for one; nothing else.

## 2. Sites exist on the base and still on `origin/master`

- `git diff --name-only d03028967 origin/master -- <the 5 row files, spl-uplink-probe.func.sh, both .tst.sh siblings, spl-peer-restart.func.sh, spl-rotate-lib.func.sh> | wc -l`
  -> `0` (origin/master `bad8f0f05`, 3 commits past base, none on these paths).
- Each cited line, `git show d03028967:<file> | sed -n <N>p`:
  - ext-api `:65` the lazy `source` of `spl-uplink-probe.func.sh`; `:72` and `:98` the
    inline `TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T'`; `:74`, `:80`, `:124`, `:135`
    `ext_api_ms` calls; `:99` `ext_api_trim "$file" "$cut"`; `:109` `ext_api_ms()`;
    `:142` `ext_api_trim() {`; `:152` `}`; `:16-18` the "in its format" header; 157 lines.
  - uplink `:89` `spl_uplink_iso()`; `:95` `spl_uplink_ms()`; `:184` `spl_uplink_trim() {`;
    `:194` `}`.
  - add-op `:41` (`... dry=1 raw a`), `:44-45` (`local -a ids=()`, `declare -A seen=()`),
    `:67` box check, `:76` `agents="${ids[*]}"`; 268 lines. remove-op `:3-4` "the operator
    mirror", `:30-32`, `:39` box check, `:48`, `:62-63` (`for a in $4` count); 145 lines.
    Tests: remove-op tst 137 lines (`:13` header item 4, `:136` the PASS footer); ext-api
    tst 207 lines (`:16` header item 12, `:204` the `=====` footer line).
- Twins: `diff` of ext-api `:142-152` against uplink `:184-194` with the names masked ->
  rc 0; `:109` against `:95` -> rc 0; add-op `:67-76` against remove-op `:39-48` -> rc 0.
  uplink defines only functions at top level (`grep` of non-indented, non-comment
  lines -> 11 function heads, no command).

## 3. Red controls

- sha256 of the control files (`sha256sum`):
  `external-api-health.tst.sh` (head1) `d28b6e398393220d1ea62c0c371583125d7115049598f690c251a3f72d54df60`;
  `channel-agent-remove-op.tst.sh` (head2) `a34c5a00909b2fec972d8096947e863a65cf1cf531ee807e0366dfa44f26132b`.
  Edited action files: `ffff32c79361` (ext-api), `0886cb641acc` (add-op), `76627571f91b`
  (remove-op). All 5 equal the plan's 1.3 / 1.4 values; `git diff --numstat` equals the
  plan's (+13 -29, +11 -0, +24 -13, +6 -15, +41 -0).
- **rc1** (head1's test on base): rc **1**, pass 13, fail 1; the fail line
  `FAIL: 13. one copy (own=[72:  ts="$(TZ=UTC printf '%(%Y-%m-%dT%H:%M:%SZ)T' "$now")"`;
  last line `==========================================` (the suite's own footer; its exit is
  `[[ "$fails" -eq 0 ]]`). head1: rc 0, 14 / 0. base: rc 0, 13 / 0.
- **rc2** (head2's test on base): rc **1**, pass 22, fail 7 lines; last line
  `FAIL: 6 assertion(s) in channel-agent-remove-op.tst.sh`; the fails: 4 x
  `_spl_channel_agent_ids: command not found` (`5. dedupe/box-wui/empty/human`), `5. host`,
  `5. remove_op own=[39: ...`. Both `5. remove_op alone` checks pass on base. head2: rc 0,
  29 / 0. base: rc 0, 21 / 0.
- Both fail for the reason the plan gives (the one-copy greps and the helper's absence),
  not an environment reason.
- Live state: none touched. ext-api tst: `T=$(mktemp -d)` + `trap 'rm -rf "$T"' EXIT`
  (`:31-32`), stub getent / tcp / tls (`:37-57`), `EXTERNAL_API_DIR` under `$T`. remove-op
  tst: `mktemp -d` + trap (`:22`), `HOME="$T/home"`, `PATH="$T/stub:$PATH"` with stub
  `gcloud`, `psql` and the other cloud bins (`:30-60`); the new section 5 runs under the
  same `HOME` / `PATH` / `SPOOL_BOX_ENV="$T/box.env"`.

## 4. Equivalence

- **Row 01.** The three helpers are byte-identical to the copies they replace (2.), so
  the TSV line, stdout, WARN lines, the trim rule and the exit codes stay the same. The
  only change in what runs: `spl-uplink-probe.func.sh` is now sourced also when
  `EXTERNAL_API_DIR` is set. That file defines functions only, and no utl or iac file
  defines a `spl_uplink_*` or `do_spl_uplink_probe` of its own
  (`git grep -nE '^(spl_uplink_[a-z_]+|do_spl_uplink_probe)\(\)' d03028967 -- csi-spl-utl csi-spl-iac`
  -> no output). One degraded-tree difference: N1. Control: case 13 catches a copy that
  comes back (m1c in the plan); m1a (I re-ran it: the source line deleted) -> rc 1,
  10 / 4.
- **Row 02.** The helper's 10 lines equal the removed ones with `$agents` read through
  the nameref `_cai_ids`. Same FATAL texts, same order (the call sits where the block
  stood), same first-seen dedupe, `ids[*]` joined under the same IFS. The helper's last
  command is an assignment (rc 0). `BASH_SOURCE[0]` inside a function is the file that
  defined it (the add-op file, same dir as remove-op), so the `spool-env.inc.sh` path is
  the same. Sourcing `spool-env.inc.sh` one call deeper: its top-level assignments
  (col 0) are `SPL_ROLE_SEAT_RX SPOOL_AGENT_ID_NEW_RX SPOOL_AGENT_ID_RX SPOOL_BOX_ENV_KEYS SPOOL_CLI_ENV SPOOL_ID_RE SPOOL_LEGACY_ID_UNTIL SPOOL_MODEL_RX SPOOL_PARTICIPANT_RX SPOOL_SPAWN_KINDS _SPOOL_ENV_LIB_DIR`.
  None of them is named like a helper or caller local (`box a ids seen _cai_ids agents
  tenant ch dry raw allowdef`), so they stay global as before. The add-op file has no
  top-level command (awk scan outside function bodies -> no output). `for _ in $4` keeps
  the same count and word splitting. Controls re-run: m2b (lazy source deleted) -> rc 1,
  26 / 3; m2d (remove-op's own box check put back) -> rc 1, 27 / 2. Both match plan 1.5.
- Neither row changes an exit code, a message, a path or a default on the normal tree:
  no bug row hidden in either.

## 5. Rows: R2, tests, vendor, kind, batch, R7, R1

- Each row has a control that fails today and passes after (3.), a test list, vendor
  claude, kind `simple_coding`, batch 1 (plan section 2, lines 657-658). There is no
  mistral row; R7 is the claude waiver seat while agy cannot sit, never mistral (section 4,
  lines 754-760).
- R1: row 01 edits the 2 `csi-spl-utl/` files, row 02 the 3 `csi-spl-orc/` files; no
  shared file.
- Suites re-run (rc / pass / fail): `spl-uplink-probe.tst.sh` base 0/22/0, head1 0/22/0;
  `channel-agent-add-op.tst.sh` base 0/42/0, head2 0/42/0; `bash-cleancode.tst.sh` 0/15/0,
  `func-name-unique.tst.sh` 0/2/0, `run-eager-files.tst.sh` 0/14/0 and
  `no-box-path-source.tst.sh` 0/10/0, each on base, head1 and head2 alike. shellcheck
  0.10.0 `-S warning -x` on the 2 head1 files rc 0, on the 3 head2 files rc 0;
  `csi-spl-iac/src/bash/scripts/sigpipe-lint.sh` rc 0 on each head's files. I did not
  re-run the other 11 suites of the plan's 1.5 table.

## 6. R3

- `lane-map.sh --check <the 5 row files> --agent c-867` at 2026-11-28T00:52:26Z: **exit 4**,
  `WARN no live lane lists <paths>, but 29 live lane(s) record no files`: 0 owned, 29
  `unknown:` lines, the same count as the plan's read at 23:47:57Z (line 696).
- Remote branches with a commit in the last 48 h (147 after a fresh fetch): `git diff
  --name-only $(git merge-base origin/master <b>) <b> -- <the 5 files>` -> 0 hits.
- Briefs modified in the last 48 h naming `external-api-health|spl-uplink-probe|spl-channel-agent-(add|remove)-op|channel-agent-remove-op\.tst`
  -> 1: `hand-sat-c002-refactor-round-13-planner.md` (the planner's). No live or queued
  lane touches a row file. I did not re-read the spawn queue.

## 7. Inputs accounted for

- r12 section 7's two items deferred to r13 by name (r12 plan lines 177-180, 947-948):
  the uplink / ext-api pair is row 01. The `spl_peer_pids` / `spl_rotate_pids` pair is
  still deferred (plan line 838). `diff` of `spl-peer-restart.func.sh:102-120` against
  `spl-rotate-lib.func.sh:832-850` shows only the name line and the matcher line (`8c8`)
  differ. The brief `c001-s179-b5-paused-seats-free.md:20` names
  `spl-rotate-lib.func.sh` ("the `Open takes`"), so the R3 deferral holds.
- r12's other section 7 items: the plan says they are unchanged. Spot check:
  `shellcheck -S warning` on base -> `orphan-process-reap.func.sh:208:21 ... [SC2071]` and
  `cloud-sql-backup-verify.func.sh:125:18 ... [SC2155]` are still there, so the utl
  `*_SEND_CMD` families stay locked behind that bug ask, as r12 N5 said.
- Candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, now **196**
  lines, mtime 02:04:06 box time; the plan read 183 lines at 01:28:11). Refactor-shaped
  items: line 1 (served: the plan's `git grep` -> `0`, re-run), 25 / 48 / 76 / 104 / 115
  (plan: served on `3308d118f`; line 76 re-checked: `spl-desk-reply.sh` usage names the
  kinds, landed `3174e591a refactor(r81-01-...)`), 113 and 125 (section 7). Line 133
  (r96-01 N1, `spl-unanswered-sweep.func.sh:196` `send_to_peers_on`): served,
  `git grep -n send_to_peers_on d03028967 -- <file>` -> no output. The plan does not name
  it; see N3. The 13 lines added after the plan's read (SPL-6698 L4 N1-N6, SPL-6699 H2
  N1-N3) are test gaps and bug notes, not refactor-shaped.
- I found no refactor-shaped input that the plan neither serves nor accounts for.

## 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` on a clone at the plan sha
  `2d15031a0` -> `INFO distribution-hygiene: clean over the tracked tree of <scratch>/plan`,
  rc 0. Also rc 0 on this worktree at `bad8f0f05`.

## Defects

- **W1 (lines 96-97, 116, 775-789): `review/r13-02` exists on origin, so the id is not
  free for row 02, and v0.1 does not decide the fix.** Rulebook 5.3: "An id is free when
  ... `git ls-remote origin 'refs/heads/review/<id>-*' ...` prints nothing". It prints
  `6cc7f2cbb refs/heads/review/r13-02` (and the `wip/` head; the prune keeps both as
  before-window, but only `review/r13-02` collides). Row 02's lane would push its
  reviewed sha to `review/r13-02`. That push is not a fast-forward of `6cc7f2cbb`
  (`git merge-base --is-ancestor 6cc7f2cbb origin/master` -> rc 1), so it is refused and
  no lane may force it. Line 116 says "No other r13 head ... exists for this cycle", but
  that is not the 5.3 test. Lines 786-789 give two options to the holder and leave both
  open ("the second form is unproven end to end"). A signed plan must be executable as
  written. v1.0 should pick one:
  - (a) number row 02 **`r13-03`**:
    `git ls-remote origin 'refs/heads/review/r13-03*' 'refs/heads/review/r13-01*' | wc -l`
    -> `0`, so both `review/r13-01` and `review/r13-03` are free. Nothing in the rulebook
    asks for consecutive row numbers (I believe this, unchecked against every section).
  - (b) the holder removes the old head first, named in the plan with its proof. The old
    head's change is on master: `git log origin/master --oneline
    --grep='r13-02-wui-test-sfc-script-ratchet'` -> `fbdac7c39 test(r13-02-wui-test-sfc-script-ratchet, SPL-2079): ...`
    (same subject as `6cc7f2cbb`, a rebased copy; `git cherry` reads `+`, so the patch ids
    differ). Removing it loses no unlanded subject, but it is a remote delete, so it is the
    holder's call.

## Notes

- **N1 (1.3, diff line 221):** head1's
  `declare -F spl_uplink_trim >/dev/null || source ".../spl-uplink-probe.func.sh"` has no
  failure branch. On base with `EXTERNAL_API_DIR` set, the action needed no orc tree. On
  head1 a missing orc file gives `spl_uplink_iso: command not found` and an empty stamp
  instead of a clean refusal. Not reachable in the mono-repo (the file is tracked), so it
  is not a behaviour change on the shipped tree. v1.0 may add `|| { do_log "FATAL ..."; return 1; }`
  or say it accepts this.
- **N2 (line 778):** the R4 slug check before placement uses
  `--grep='r13-01-'` (no `-E`, no `\(`) and names row 01 only. 1.1 (line 85) already uses
  5.3's form: use `-E --grep='\(r13-'` for both rows.
- **N3 (1.2 (c), line 147):** the candidates file grew from 183 to 196 lines after the
  plan's read. The new lines are not refactor-shaped (7.), and line 133 (r96-01 N1) is
  served. v1.0 may restate the read with its line count.
- **N4:** m1d (the `TZ=UTC` mutation) is box-dependent, as the plan says (line 632). The
  row lane should show it on a box whose zone is not UTC, or say that it could not.
- **N5:** I did not run `cd csi-spl-iac && ./run -a do_check_pre_push` on either head, and
  neither did the planner (line 606). That stays with the row lanes.

## Signature

| plan sha | verdict | seat |
|---|---|---|
| `2d15031a07213af4d855fb07e4c3ed179b03a334` (v0.1) | FAIL (W1) | `c-867` claude |
