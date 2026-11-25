# Refactor round 99 - panel seat claude (c-396)

Seat: c-396, claude, cross-vendor panel seat of rulebook 3.2 (the planner a-482 is agy).
Brief: placement `c002-refactor-round-99-claude-panel-seat`, issue SPL-6469.

**Plan read:** `csi-spl-doc/doc/md/refactor-round-99-plan.md` v0.1 on
`review/c002-refactor-round-99-planner` at
**`e6845b2573d87460f3737559ef6c08e79759a117`** (`git ls-remote` at the start of the review and
again at 09:11Z: unchanged). Plan file sha256
`f30ec9a1e00ff0e3e266e1e3cbaeeaa6b5c0c9383e700d4f78fee04303e20394`.
Plan base: `f2cb19298`. origin/master when this file was written: `18b6725e6`.

## Verdict: FAIL on e6845b25

Row 01 is sound and its controls reproduce byte for byte. Row 02 is a correct refactor
as written, but its tests do not guard the one thing that differs per caller. Two plausible
wrong implementations of the row's own shape pass every test the plan lists for it (W1, W2).
The fix is small: add two assertions (below). Everything else in the plan reproduced.

## Defects

- **W1 (plan 1.4 lines 340-343, 427-452; section 2 row 02 line 549).** No test sets
  `PFL_WUI_URL` / `PFL_EMAIL` (nor `PF_WUI_URL` / `PF_EMAIL`). The only per-caller wiring
  row 02 introduces is which override vars each action hands to `spl_pf_env`. Mutation m2
  (head2 with first-load-net calling `spl_pf_env "$tenant" "${PF_WUI_URL:-}" "${PF_EMAIL:-}" ...`)
  passes all three perf suites: `spl-wui-perf-flow-events.tst.sh` rc 0 fail 0,
  `spl-wui-perf-first-load.tst.sh` rc 0 fail 0, `spl-wui-perf-first-load-net.tst.sh` rc 0
  fail 0 (n=1). Today a first-load-net run with `PFL_WUI_URL` set uses it; after m2 it would
  be silently ignored. That is a behaviour change no listed test catches.
  Fix: in row 02's tests, run each of the three actions through the existing stub-node
  harness with its override pair set (e.g. `PFL_WUI_URL=https://o.example.test PFL_EMAIL=o@example.test`)
  and assert `BASE=https://o.example.test` and `EMAIL=o@example.test` in the stub log. The
  first-load-net case needs either `spl-wui-perf-first-load-net.tst.sh` added to row 02's Files
  (the plan's 2.1 and 5 list it as NOT touched) or the check placed in
  `spl-wui-perf-first-load.tst.sh` section 4, beside the existing first-load-net lazy check.
- **W2 (plan 1.4 lines 342, 454-456; row 02 line 549).** The `"first-load"` label for
  first-load-net is asserted only via a direct `spl_pf_env ... first-load` call (section 4,
  `env script`), never through the action. Mutation m3 (head2 with first-load-net omitting
  the 5th argument, so it would print `FATAL no timing e2e at ...` where base prints
  `FATAL no first-load e2e at ...`) passes all three perf suites, rc 0 fail 0 each (n=1).
  That is a message change no listed test catches. Fix: one check that runs
  `do_spl_wui_perf_first_load_net` with the timing script absent from `APP_PATH` and asserts
  `FATAL no first-load e2e at`, plus the same for flow-events / first-load asserting
  `FATAL no timing e2e at`.

## Notes

- **N1 (plan 1.1 lines 89-90).** "over all history -> **0**" does not reproduce:
  `git log origin/master --oneline -E --grep='\(r99-' | wc -l` -> 1 (`0e918d4b9`,
  2026-10-15, `ci(r10-10-...)`: its body quotes `refactor(r99-01-x)` as test case 8 text).
  It is no r99 slug, and the windowed count the rule asks for is 0, so the slug is free.
- **N2 (plan 1.1 lines 93-95).** On this box `ls /var/spool-hub/dispatch/briefs | grep -E 'r99-[0-9]{2}|refactor-round-99'`
  -> nothing. The panel brief is at `/var/spool-hub/spawn-remote/briefs/1f1e525c-836d-4d30-92bc-ee3b289e943d.md`;
  the planner's brief is on sat, where it was placed. Not re-checked on sat.
- **N3 (plan 1.2 (c)).** `/var/spool-hub/dispatch/c002-next-round-candidates.md` does not
  exist on this seat's box (`wc -l` -> No such file). The candidates check is NOT RUN here: the file is on
  the dispatcher's box (sat).
- **N4 (plan 2.2 lines 591-598).** The lane map changed between the plan's read and mine:
  exit 4 both times, but 8 `unknown:` lanes at 09:08Z (all `@sat`: a-482, a-486, a-492,
  a-494, c-074, c-296, c-298, c-458) vs the plan's 14 at 08:38Z. 0 remote branches committed
  in the last 24 h touch the 9 paths. The holder re-reads at placement as R3 says.
- **N5 (row 02 shape).** The lazy `declare -F spl_pf_env || source ...` guard adds a
  capability that base lacks. Standalone-sourcing first-load or first-load-net fails on base with
  `spl_pf_validate: command not found` (rc2b's reason). Under `./run` nothing changes:
  the run.sh index awk on the heads emits `spl_pf_env() { _rl_load 722 spl_pf_env "$@"; }` and
  `_spl_human_require_order() { _rl_load 431 _spl_human_require_order "$@"; }`. The row's lazy
  checks prove the new path; equivalence rests on the `./run` path, which the existing suites do
  not drive (they source every `.func.sh` eagerly). Acceptable, worth one sentence in the row brief.
- **N6 (row 01).** `_spl_calendar_require_actor` (`spl-calendar-event-add.func.sh:196-200`
  on f2cb19298) is not a third copy. It accepts `{3,}` digits and legacy ids, and `ORDERED_BY`
  is optional there, with a different FATAL. Keeping it out is right (r98 section 7 said the same).

## Checks (each: command, then what it printed)

### 1. Slug r99 free since W

- `W=2026-11-25T09:01:01+02:00`; `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r98-plan'`
  -> `f0df3782b1ab594201c22a55967cf9c7744c6718 2026-11-25T09:01:01+02:00 docs(r98-plan, SPL-6457): ...`. W matches.
- `git log origin/master --since="$W" --oneline -E --grep='\(r99-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r99-[0-9]{2}|refactor-round-99'` -> only
  `e6845b25... refs/heads/review/c002-refactor-round-99-planner` (this seat's branch did not exist yet).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r99-[0-9]{2}|refactor-round-99'` -> nothing (N2).

### 2. Sites on base and on origin/master

`git show f2cb19298:<file> | sed -n <N>p` for every cited line printed the plan's text:
`spl-human-link.func.sh:74` (`# _spl_human_link_body: ...`), `:83-84` (the 2 checks);
`spl-human-email-add.func.sh:70` (`_SPL_HUMAN_EMAIL_MASK_JQ=...`), `:103-104` (the same 2
checks); `spl-human-link.tst.sh:79` and `spl-human-email-add.tst.sh:88` (the `ALL PASS`
lines); `spl-wui-perf-flow-events.func.sh:36-48` (the 13-line block), `:69`
(`spl_pf_validate() {`), `:76` (`}`); `spl-wui-perf-first-load.func.sh:35`
(`spl_pf_validate ... || return 1`), `:38-50`; `spl-wui-perf-first-load-net.func.sh:36`,
`:39-51` (`PFL_` and `first-load e2e`); `spl-wui-perf-flow-events.tst.sh:69`,
`spl-wui-perf-first-load.tst.sh:71` (the `OK ...` lines); `spl-wui-perf-report.func.sh:69-75`.
Line counts on base: 88, 108, 79, 88, 76, 68, 76, 69, 71 as the plan says.
`diff -u <(... email-add :103-104) <(... link :83-84)` -> no hunk, rc 0.
`git grep -c '_spl_human_require_order\|spl_pf_env\|SPL_PF_' f2cb19298 | wc -l` -> 0.
Drift: `git diff --name-only f2cb19298 origin/master -- <the 10 row/test files>` -> empty,
on origin/master `c9dd02117` and again on `18b6725e6`.

### 3. Red and guard controls

Trees: `git archive f2cb19298` into a scratch dir ("base"); head1 / head2 built from the
plan's verbatim blocks (plan lines 219-226, 233-244, 251-262, 372-392, 399-424, 431-451)
in 1.3 / 1.4's positions. Every rebuilt file matched the plan's 12-char sha256 and its `+/-` counts:
`c7392841cb5e 96 +10-2`, `bc27dae0a4af 109 +3-2`, `8861cb134fce 92 +13-0`,
`54af08d7ff54 101 +13-0`, `4c554e0add30 87 +24-13`, `7983dab7a90e 59 +4-13`,
`5e82d6661aaf 67 +4-13`, `006fd4af56b1 96 +27-0`, `c1416b2d9ada 93 +22-0`.
Run as `SPOOL_TEST=1 bash src/bash/tests/<t> </dev/null` with `SPOOL_BOX_TAG`/`SPOOL_AGENT_ID`
unset, n=1. The control file and its full sha256, then rc, pass/fail lines and the last line:

| control | file sha256 | rc | pass / fail | last line, reason |
|---|---|---|---|---|
| rc1a | `spl-human-link.tst.sh` `8861cb134fcee8ec1d1da0fe3debefcd53895b721e9215ecf3a966efcccefb90` | 1 | 20 / 6 | `FAILED: 5`; 4x `_spl_human_require_order: command not found` (rc 127) + `5. link one copy` |
| rc1b | `spl-human-email-add.tst.sh` `54af08d7ff54af1da2b6f7194135001c1f2cb53b9dd6018a812622985815f6f1` | 1 | 22 / 2 | `FAILED: 1`; `6. one copy add: own=[103: ...]` |
| gc1 | head1 `spl-human-email-add.func.sh` minus the guard `ffaadbb5684563ba5c30d6ef11a70a758901b61d7ae51de68d886822ad148a08` | 1 | 22 / 2 | `FAILED: 1`; `6. lazy add: ... line 104: _spl_human_require_order: command not found` |
| rc2a | `spl-wui-perf-flow-events.tst.sh` `006fd4af56b1b434a7c1d64b1f261d5d6d9537c0ac2b659321c094c58a99d240` | 1 | 29 / 6 | `FAIL spl-wui-perf-flow-events: 5 check(s)`; `spl_pf_env: command not found` x4 + `flow one copy` |
| rc2b | `spl-wui-perf-first-load.tst.sh` `c1416b2d9ada18b58cd4b32e0601f319651ce2ccbbab902f24486f4b4449ea23` | 1 | 33 / 5 | `FAIL spl-wui-perf-first-load: 4 check(s)`; one copy `own=[46:` / `own=[47:`, lazy `line 35` / `line 36: spl_pf_validate: command not found` |
| gc2a | head2 `spl-wui-perf-first-load.func.sh` minus the guard `b7220dee3a39c5302c41c127ba70a97068343736a54536e6c783290a1b65e75f` | 1 | 36 / 2 | `FAIL spl-wui-perf-first-load: 1 check(s)`; `lazy first-load ... line 36: spl_pf_validate: command not found` |
| gc2b | head2 `spl-wui-perf-first-load-net.func.sh` minus the guard `49b38c5523a15f174c3ab9d0ea97fa0f67a09b86879cdc838b6392e4e0ac10c4` | 1 | 36 / 2 | `FAIL spl-wui-perf-first-load: 1 check(s)`; `lazy first-load-net ... line 37: spl_pf_validate: command not found` |

Each fails for the plan's reason (missing helper / own copy / missing guard), not an
environment reason. On the heads: link 0/25/0, email-add 0/23/0, flow-events 0/35/0,
first-load 0/38/0. None touches live state: the suites run in their own `$T` temp dir with
stubbed `node`/`gcloud`/`curl`/`docker` and a stub `do_spl_cloud_cnf`
(`spl-wui-perf-first-load-net.tst.sh:20-37` read), and the new hunks call no `./run`, hub or GCP.

### 4. Equivalence

- **Row 01:** keeps behaviour. Same two regexes and FATAL strings, same order (after
  HUMAN_ID and EMAIL / LINKED_HUMAN_ID), same `return 1`, and no exit code, path or default
  changes. `spl-human-link.func.sh` is function-only, so the lazy source has no side effect.
  Under `./run` the email-add file stays eager as on base (`_rl_eager+=` in both). The
  control catches a difference: mutation m1 (swapped `"$agent" "$ordby"` in both callers) ->
  link rc 1 fail 7, email-add rc 1 fail 7 (`FAIL: 1. dry: ... got: 'c-308'`).
- **Row 02:** the code as written keeps behaviour. The same origin, email fallback, `pw-human`,
  script, Chrome checks and messages, in the same order. `st` is not read after the block in any of
  the 3 actions (base lines 50-65 / 52-67 / 53-68 read). The only new state is five
  unexported globals. The control catches a changed password text (m4: all 3 suites rc 1,
  `FAIL: no pw text`) but **not** a wrong override pair (m2) or a dropped label (m3): W1, W2.
- Shared gates, base / head1 / head2, rc and pass lines all equal: `no-box-path-source` 0/10,
  `action-header-tags` 0/6, `param-required` 0/17, `run-lazy-loader` 0/30, `bash-cleancode` 0/15
  (iac); `run-eager-files` 0/14, `no-literal-paths` 0/15, `func-name-unique` 0/2 (orc);
  `spl-wui-perf-first-load-net.tst.sh` 0/39 base and head2.
  `shellcheck -S warning -x` (0.10.0) on the 9 files in each tree -> rc 0 for all 27.
  `do_sec_shellcheck`: NOT RUN by this seat.

### 5. Row form (R1, R2, R7)

Both rows: a control that fails on the parent and passes on the head (check 3), a test list,
vendor claude, kind `simple_coding`, batch 1. No mistral row. R7 is an agy seat, and the
claude waiver backup is limited to ruling `dc84300a`, never mistral (plan section 4, lines
654-665, 700-703). R1: the file sets of rows 01 and 02 are disjoint (2.1). R2 column:
`git grep -lE '<basenames>|<the 14 functions the 5 site files define>' f2cb19298 -- '*.tst.sh' '*test-*.sh' '*/tests/*'`
-> the 5 row suites plus `orc-shard-weights.txt` (a weights list) and the 3
`csi-spl-wui/tests/e2e/perf-*.timing.mjs` (they only name the action in a comment; the row
does not change them). The 30-char comment strings within +/-3 lines of each site, `git grep -lF`
over tests -> 0 hits for all 7 strings.

### 6. R3

`lane-map.sh --check <the 9 paths> --agent c-396` at 2026-11-25T09:08:05Z -> **exit 4**, no
live lane lists any of the 9 paths, 8 `unknown:` lanes (N4). Remote branches with a commit in
the last 24 h: 29, `git diff --name-only $(git merge-base origin/master <b>) <b> -- <9 paths>`
-> 0 hits. `git log origin/master --since='24 hours ago' -- <9 paths> | wc -l` -> 0.
`do_spl_spawn_queue` at 09:08:20Z -> 9 queued, 0 placing. By slug, none is a refactor
lane on these paths. Unlanded r98-02 (plan 2.2): not re-read by this seat.

### 7. Inputs

r98 section 7 (on origin/master) against r99 section 7: every r98 item is served (row 01 =
the human-account guards, which r98 named "candidate for a separate small human-actor helper
in r99+") or carried forward (the utl `_chs_send`/`_rrc_send` and sweep scripts, the `_holder`
trio, the lane-handover files, `sec-*` / `check_tools`, the gh parsers, `peer/seats` /
`LEASE_*` / prose, Go/TS, the round-95 WUI item, the 10 Bash groups). The candidates file was
NOT RUN (N3). Neither row changes an exit code, message, path or default as specified; W1/W2
are about catching such a change, not about the plan making one.

### 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean`, rc 0,
on this worktree (`c9dd02117`) and on a scratch copy of the plan's tree (`git archive e6845b257`).

## Re-review: v0.2 at 853b9368f3f58e9b6a175796121c94e4a0674dcd - PASS

**Verdict: PASS on 853b9368.** `git ls-remote origin refs/heads/review/c002-refactor-round-99-planner`
-> `853b9368f3f58e9b6a175796121c94e4a0674dcd` (parent `e6845b257`, the only commit between them).
Plan file sha256 `f3f3782dcaaeab89834c6e92f1fa09787b4e08248be46c05258fd09c78d929c0`.
`git diff --stat e6845b257 853b9368f` -> only `refactor-round-99-plan.md` (+171 -71).

- **W1, W2 folded and effective.** Row 01's blocks and the `spl_pf_env` helper block are
  byte-identical to v0.1 (`diff` of plan lines 219-226 / 228-235, 233-244 / 242-253,
  251-262 / 260-271, 372-392 / 392-412 -> same). head1 and head2 were rebuilt from v0.2's verbatim
  blocks, and all 9 files match its sha256 prefixes and counts: `c7392841cb5e`, `bc27dae0a4af`,
  `8861cb134fce`, `54af08d7ff54`, `4c554e0add30`, `7983dab7a90e`, `5e82d6661aaf`,
  `739e49914c92 102 +33-0`, `c19274f92900 116 +45-0`.
- Row 02 suites on v0.2 head2 (n=1, `SPOOL_TEST=1`): flow-events rc 0 / 37 pass / 0 fail,
  first-load 0 / 42 / 0, first-load-net 0 / 39 / 0, as the plan says.
- Controls on v0.2: rc2a rc 1, 31 / 6 (`spl_pf_env: command not found`); rc2b rc 1, 37 / 5
  (one copy `own=[46:` / `own=[47:`, lazy `spl_pf_validate: command not found`); gc2a rc 1,
  40 / 2 (`lazy first-load`); gc2b rc 1, 40 / 2 (`lazy first-load-net`). The plan's numbers match.
- Mutations, each a 1-line change of head2 (`diff -r` -> 1 line each), each RED:
  m2 (first-load-net passes `PF_*`) -> first-load.tst rc 1, `FAIL: 4. first-load-net overrides`;
  m3 (first-load-net drops `"first-load"`) -> first-load.tst rc 1, `FAIL: 4. first-load-net script label: ... FATAL no timing e2e at`;
  m2_fl (first-load passes `"" ""`) -> rc 1 `first-load overrides`; m3_fl (first-load passes
  `"first-load"`) -> rc 1 `first-load script label`; m2_flow -> flow-events.tst rc 1 `flow overrides`;
  m3_flow -> flow-events.tst rc 1 `flow script label`. m2 and m3 still pass flow-events.tst and
  first-load-net.tst (rc 0). That is expected: the catching checks live in first-load.tst, which is in row 02's test list.
- The new hunks reach no live state: `grep -E 'SPOOL_ROOT|/var/|gcloud|\./run|curl|\$HOME'` over plan
  lines 419-450 and 457-500 -> 0 lines. They reuse each suite's own `in_orc` (base `:29`), stub
  `node`, `$T` temp dir and stub `do_spl_cloud_cnf`.
- Shared gates on v0.2 head2: no-box-path-source 0/10, action-header-tags 0/6,
  param-required 0/17, run-lazy-loader 0/30, bash-cleancode 0/15, run-eager-files 0/14,
  no-literal-paths 0/15, func-name-unique 0/2 (all equal to base). `shellcheck -S warning -x`
  on the 5 row-02 files -> rc 0 each. Row 01 is unchanged from v0.1 (sha256 equal), so its
  results above stand.
- **N1, N4, N5, N6 folded** (plan 1.1, 2.2, 1.3, 1.4, section 5). N2 and N3 are recorded as
  reads on the planner's box; this seat did not re-check them there.
- Drift: `git diff --name-only f2cb19298 origin/master -- <10 row/test files>` on `208e5f757`
  at 09:37Z -> empty. Slug: `git log origin/master --since="$W" --oneline -E --grep='\(r99-' | wc -l` -> 0.
- `do_sec_shellcheck`: still NOT RUN by this seat (the plan reports it rc 0).
