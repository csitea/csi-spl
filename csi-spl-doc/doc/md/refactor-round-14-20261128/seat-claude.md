# Refactor round 14 (2026-11-28) - claude panel seat verdict (c-917@sat)

Seat: **c-917@sat** (claude), the panel seat
`hand-sat-c002-refactor-round-14-claude-panel-seat` of
`csi-spl-doc/doc/md/refactor-round-14-20261128-plan.md` (on the review branch).
Issue SPL-6723. Same-vendor panel under waiver `1a7c70da` (agy out of quota,
grok out, mistral on no review). A doc review of the plan only; no row code
written.

**Plan sha read: `75d0f5fff2f2e12eba42372ffb8c2dce1ef0d3dd`** (v0.1), the head
of `review/c002-refactor-round-14-planner`
(`git ls-remote origin refs/heads/review/c002-refactor-round-14-planner` ->
`75d0f5fff2f2e12eba42372ffb8c2dce1ef0d3dd`), one commit over the plan's base
`774876d90` (`git diff --stat origin/master...75d0f5fff` -> the plan file only,
826 lines). `origin/master` at review time: `0e6f561e4`.

## Verdict: **PASS** on `75d0f5fff2f2e12eba42372ffb8c2dce1ef0d3dd`

No defect (W none). Six notes (N1-N6) for the editor's v1.0; none blocks a row.

Every number below I ran myself, n=1, 2026-11-28T04:2x-04:3xZ, in scratch
clones of `774876d90` (`git clone --shared`, then `git checkout --detach`):
"base" unchanged, "head1" and "head2" = base + the plan's 1.3 / 1.4 diff
(extracted from the plan file, applied with `git apply`, both rc 0), each red
control in its own copy. The suites ran with `SPOOL_TEST=1`, `SPOOL_BOX_TAG`,
`SPOOL_AGENT_ID` and `AGENT_ID` unset, stdin `/dev/null`, a short `TMPDIR`
(`mktemp -d`).

## 1. Slug r14 unused since `W=2026-11-28T03:34:51+02:00`

- W itself: `git log origin/master --format='%H %cI %s' | grep -E '^[0-9a-f]+ \S+ docs\(r13-(plan|close)' | head -3`
  -> `1e730d6e2... 2026-11-28T03:34:51+02:00 docs(r13-plan, SPL-6710): refactor round 13 plan v1.0 as signed, panel PASS recorded`,
  then `7fe900332` and `0d04a240b` with the same date. Matches plan 1.1.
- `git log origin/master --since="$W" --oneline -E --grep='\(r14-' | wc -l` -> **0**.
- `git ls-remote origin | grep -E 'r14-[0-9]{2}|refactor-round-14-2026'` -> nothing
  (rc 1). `git ls-remote origin | grep refactor-round-14` -> only
  `review/c002-refactor-round-14-planner` (`75d0f5fff`); my own seat branch did
  not exist yet. No other r14 head.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r14-[0-9]{2}|refactor-round-14-2026'`
  -> the 9 old-cycle row briefs `c002-r14-01`..`08` and `c003-r14-09-bash-small-run-do-log.md`.
  The wider `ls -la --time-style=full-iso | grep -E 'r14|round-14'` -> 20 entries:
  the planner's and this seat's `hand-sat-...` briefs (2026-11-28 05:36:23 and
  05:37:12 box time) and 18 more, all mtime 2026-11-18 12:51:2x (before W): the
  9 above, `c002-r14-seat-claude.md`, `c002-r14-seat-mistral.md`,
  `c002-refactor-r13-retro-r14-plan.md`, `c003-refactor-r14-retro-r15-plan.md`,
  `c002-wui-err-r14-journal-coalesce.md`, `c001-perf-round-14-planner.md`,
  `c002-bug-round-14-planner.md`, `c002-bug-round-14-mistral-panel-seat.md`,
  `c002-perf-round-14-mistral-panel-seat.md`. Exactly the plan's 1.1 list;
  nothing else.

## 2. Sites exist on the base and on origin/master

`git show 774876d90:<file> | sed -n <N>p` for every cited site, output read:

| site | line(s) read on `774876d90` |
|---|---|
| `spool-mirror.py:89-92` | `HERE = ...`, `sys.path.insert(0, os.path.join(HERE, "..", "lib"))`, `from spool_redact import redact`, `import spool_discussion as sd` |
| `spool-mirror.py:497-511` | `def desk_root(home):` .. `return r.stdout.strip() if r.returncode == 0 else ""`, 2 blank lines |
| `spool-mirror.py:516` | `root = desk_root(os.path.expanduser("~"))` |
| `agent-mirror-check.py:34-38` | `import re`, `import subprocess`, `import sys`, blank, `HOOK_RE = ...` |
| `agent-mirror-check.py:137-151` | the same `def desk_root(home):` body, 2 blank lines |
| `agent-mirror-check.py:155` | `root = desk_root(` |
| `desk-root-readers.tst.sh:9-11`, `:84` | the `0b.` header comment; the `0b. spool_box_kv is defined once` check |
| `agent-caps.mjs:16` | `import { OPERATOR_MOCK_KEY, OPERATOR_WS_ID_RE } from './operator-console.mjs'` |
| `agent-caps.mjs:94-108` | `function capsError(...)` .. `}`, blank, `function browserStore()` .. `}` |
| `agent-caps.mjs:125-126`, `:154`, `:156` | the 4 `throw capsError(...)` calls |
| `operator-console.mjs:121-136` | `function opError(...)` .. `}`, the "Byte-identical twin" comment (`:130`), `function browserStore()` .. `}` |
| `operator-console.d.ts:35` | `export function replaceOperatorWorkspace(...)` (insertion point) |
| `agent-caps.test.mjs:97` | blank line before `const s = runsInUnitSuite(...)` (insertion point) |

- `diff` of `spool-mirror.py:497-509` against `agent-mirror-check.py:137-149` -> identical.
- `diff` of `agent-caps.mjs:95-101` / `:103-108` against `operator-console.mjs:122-128` / `:131-136` -> identical, both.
- Line counts on base (`wc -l`): 1318, 273, 217, 163, 216, 41, 105: as plan 1.3 / 1.4.
- Drift: `git diff --name-only 774876d90 0e6f561e4 -- <the 8 row files> csi-spl-orc/src/bash/features/spawn-agents/lib/`
  -> **empty** (4 commits on master since the base, none on a row file or `lib/`).
- Head shapes: `git diff --numstat` of head1 -> `19 0`, `5 15`, `1 15`, `3 0`
  (+28 -30); head2 -> `2 0`, `5 21`, `11 3`, `10 0` (+28 -24). The 8 `sha256sum | cut -c1-12`
  values: `a7cdf5fcd894`, `7bb858044ecb`, `0fe9bf7cf00b`, `8d2c03ea4ac9`,
  `a4ea0ef4832c`, `f583065b1266`, `fcdbd02e5c0c`, `5f34aefd973b`: all equal plan 1.3 / 1.4.

## 3. Red controls

- **rc1**: `sha256sum` of head1's `csi-spl-orc/src/bash/tests/desk-root-readers.tst.sh`
  -> `8d2c03ea4ac950069baa85c80125c5ed87951d18d8099e5736f3978f3056d6b0`. Copied
  onto base, run: `1 FAILED`, `rc=1`, 41 PASS lines, the one FAIL
  `0c. desk_root is defined once, in lib/spool_desk_root.py (want '.../lib/spool_desk_root.py', got '.../scripts/spool-mirror.py ...`.
  The same file on head1: `ALL PASS`, rc 0, 42 PASS. Base's own file: `ALL PASS`, rc 0, 41.
  It fails for the reason the plan gives (the grep finds the copies under
  `scripts/`), not for an environment reason. Live state: its header
  (`:22`) says "Nothing outside $T is read or written; no hub; tmux only on a
  private socket", and its runner (`:57-58`) sets `HOME`, `SPOOL_ROOT="$T/spool"`,
  `SPOOL_TEST=1` and `SPOOL_TMUX_SOCKET="$T/..."`: it touches none.
- **rc2**: `sha256sum` of head2's `csi-spl-wui/tests/unit/agent-caps.test.mjs`
  -> `5f34aefd973bb99d1ebb9f458fea18c867d7c45292f836c3dfe5e45bae684156`. Copied
  onto base, `node tests/unit/agent-caps.test.mjs` (node v20.19.2): `2 failure(s)`,
  `rc=1`, 29 OK, the FAILs `one copy: agent-caps.mjs defines no error or store helper of its own`
  and `…and imports opError and browserStore from operator-console.mjs, which exports each once`.
  head2: `All agent-caps checks passed.`, rc 0, 31 OK; base: rc 0, 29 OK. It fails
  for the reason given (the source text holds the copies). Live state: it reads
  source files with `readFileSync` and drives the mock with its own store; no
  `fetch`, `spawn`, `exec` or `localStorage` in the new lines
  (`grep -nE 'writeFile|fetch\(|spawn|exec|localStorage|http'` -> only the comment at `:98`).
- One mutation spot-checked: **m1d** (spool-mirror `import spool_desk_root` and
  `spool_desk_root.desk_root(...)` at `:502`) -> `test-spool-discussion-mirror.sh: 188 passed, 4 failed`,
  rc 1, the 4 FAILs C17 / C18 as plan 1.5 says. m1a-m1c, m2a-m2d: NOT RUN by me.

## 4. Equivalence

- **Row 01.** The moved body is the same statements. The only text change is the
  path: `join(dirname(realpath(<script>)), "..", "lib", "desk-root.inc.sh")`
  becomes `join(dirname(realpath(<lib>/spool_desk_root.py)), "desk-root.inc.sh")`.
  Both name the same file. `desk-root.inc.sh` resolves itself with
  `readlink -f "${BASH_SOURCE[0]}"` (`:59-61`), so a different but equivalent
  argv string does not change what it does. Same `bash` argv, the same 20 s
  timeout, the same `""` on `OSError`, `SubprocessError` or rc != 0. The name
  `desk_root` stays module-level in both scripts, so the test stub at
  `test-spool-discussion-mirror.sh:419` still reaches it (m1d proves the
  control catches the other form). `lib/` holds `lane_console.py`,
  `spool_discussion.py` and `spool_redact.py` (`git ls-tree`), so no stdlib
  name is shadowed by the new `sys.path` entry. Both scripts are only run
  in-tree (`spl-agent-mirror-check.func.sh:20` from `$PROJ_PATH`, the hook
  from the checkout: `git grep` of the callers), where `lib/` is there. Run on
  base and head1: `test-agent-mirror-check.sh` 14/0, `test-spool-mirror.sh` 118/0,
  `test-spool-discussion-mirror.sh` 192/0, rc 0 each, equal. `py_compile` rc 0;
  ruff 0.16.9 `check --isolated --select E9,F,S102,S113,S301,S307,S506,S602,S604,S605`
  -> `All checks passed!`; `ruff format --isolated --check` -> `3 files already formatted`.
  The 21 other suites of 1.5: NOT RUN by me.
- **Row 02.** The two folded helpers are byte-identical (section 2), so the
  thrown Error (message `detail || token`, `status`, `token`, `detail`,
  `permission`) and the default store do not change. Only the name `capsError`
  goes. No new import edge (`agent-caps.mjs:16` already imports
  `./operator-console.mjs`; the lazy client loads `agent-caps.mjs` with
  `await import('./agent-caps.mjs')`, `spool-client-lazy.mjs:2461`). `git grep -nE '\b(opError|browserStore)\b'`
  outside the two files -> only the local, unexported `browserStore` of
  `fleet-load.mjs:515` and `vendor-keys.mjs:101` and the new test lines, so the
  two new auto-import names collide with nothing. On base and head2:
  `operator-console` 40/0, `monitoring-tokens` 29/0, `topic-loops` 30/0,
  `util-docs` 5/0, `swallow-reasons` 20/0, rc 0 each, equal; `unused-exports`
  `3612` -> `3614 exports in 596 files, 30 unused, all listed in ALLOW (33 <= cap 33)`;
  `mjs-shims-exist` `all 1083 declared names exist in 102 modules` on both (it
  reads `src/types/mjs-shims.d.ts`, which declares neither module). NOT RUN by me
  (no `node_modules`, installs forbidden): `cleancode.test.mjs`,
  `pnpm run typecheck`, the e2e files.
- Would the controls catch a difference? Row 01: yes for the body (m1a: sections
  8 / 9) and for the import form (m1d). Row 02: the one-copy checks catch a copy
  coming back (m2a), and the existing mock checks catch a lost `permission`
  (m2b, plan). A default store that changes is caught by no unit suite (m2c,
  plan 1.5 `:598-600`): N3.

## 5. Row form (R2, R1, R7, vendor)

- Each row has a control that fails on base and passes on its head (section 3),
  a test list (plan section 2 `:620-621`), vendor claude, kind `simple_coding`,
  batch 1. No mistral row; neither row writes tests on mistral.
- R7 for both rows: the claude waiver seat (`1a7c70da`) while agy cannot sit,
  re-checked at placement, never mistral (plan section 4 `:704-710`, briefs `:749`, `:770`).
- R1: row 01's files are all under `csi-spl-orc/`, row 02's under
  `csi-spl-wui/`, so the batch shares no file.

## 6. R3, lane map

`bash .../lane-map.sh --check <the 4 row 01 files>,<P/lib/desk-root.inc.sh>,<the 4 row 02 files> --agent c-917`
at 2026-11-28T04:32:52Z -> **exit 4**. No live lane lists a row path. 21 lanes,
all on the other box, record no files: 16 `-rotate` seats, `c-285` (SPL-6707
tf), `c-287` (s184 W1), `c-298` (s184 L5), `c-303` (s184 H3), `c-995` (blog
draft). `grep -cE 'agent-caps|operator-console|capsError|opError|browserStore|spool-mirror\.py|agent-mirror-check|desk_root|desk-root|spool_desk_root'`
on the briefs of c-285, c-287, c-298, c-303 and c-995 -> 0 each. No row file is
touched by a live or queued lane the plan names, or by one I found. `c-298` and
`c-303` are new since the planner's read (N2).

## 7. Inputs accounted for

- r13 section 7's `/proc` PID-scan twin (`spl_peer_pids` at `spl-peer-restart.func.sh:102`,
  `spl_rotate_pids` at `spl-rotate-lib.func.sh:832`, `git grep` on base): accounted
  for, deferred a third time on R3 (plan `:790`). The L5 brief
  (`c002-s184-l5-rotation-restart-rekind.md:19`) names both files, so the
  reason holds (N2).
- Candidates file (221 lines): the refactor-shaped lines 1, 25, 48, 76, 104,
  113, 115 and 125 are accounted for by r13 1.2 (c), which the plan carries.
  Line 133 (r96-01 N1, `send_to_peers_on` in `spl-unanswered-sweep.func.sh:196`)
  is named in neither plan. It was served by r97-01: `git grep -n send_to_peers_on 774876d90 -- csi-spl-orc`
  -> only the two tests that ban it, and `git log -S send_to_peers_on` -> `2924c633f refactor(r97-01-...)`.
  Lines 184-221: bug, test or design notes, none a refactor. That is the plan's 1.2 (c).
- r13-03 R7 N1-N4 (65cc7198): accounted for, plan `:794`. I did not read the message myself.
- r13-01 R7 N1-N4 (abf29eef): only recorded by the candidates file's label, and
  unread by the planner (plan `:133-136`, `:795`). I could not read them either.
  `grep -rlF abf29eef /var/spool-hub` -> only relays and references, not the
  message. `git log -1 --format=%B 07b483e33` holds the review line and the
  waiver line, not the notes: N1.
- Behaviour: neither row changes an exit code, a message, a path or a default
  (section 4). These are refactor rows, not bug rows. The one edge is N4.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` in a clone at `75d0f5fff`
-> rc 0, `INFO distribution-hygiene: clean over the tracked tree`.

## Defects

None.

## Notes

- **N1** (plan `:133-136`, `:795`): the r13-01 R7 notes are recorded only by
  their label. Before v1.0, ask c-241 on the other box, or that box's holder, to
  relay msg abf29eef. Then classify N1-N4 yourself. If one is refactor-shaped,
  it becomes the first row of r15, not a 3rd row here.
- **N2** (plan `:115-120`, `:651-655`, `:790`): ask `cf5e8b46` (s184 L5) is no
  longer queued. It is live as `c-298` on the other box (lane map 04:32:52Z), and
  `c-303` (s184 H3) is new too. Update both reads in v1.0. The deferral of the
  `/proc` twin then holds on a live lane, not a queued one.
- **N3** (plan `:598-600`, briefs `:762-763`): m2c, a default store that changes,
  is caught by no unit suite. The mock path does use the default
  (`spool-client-lazy.mjs:2464` calls `mockOperatorPutAgentCaps(id, body)`
  without a store). The brief's ask, "say which e2e catches it, or that none
  does", is right. Keep it as a required field of the row's result.
- **N4** (head1 `agent-mirror-check.py:40-43`): the import moves to load time.
  In a tree without `lib/spool_desk_root.py`, the script would stop with an
  ImportError instead of finding no desk. This cannot happen in-tree, so it is
  not a behaviour change of the repo. The r14-01 brief could ask the
  post-land `--help` smoke run (`:751-753`) to cover `agent-mirror-check.py` too.
- **N5** (head2 `operator-console.mjs:121-124`, plan `:458-459`): the new doc
  says "as spool-client.mjs reads one". `spool-client.mjs:260-264` builds an
  Error of the same shape; it does not read the mock's. Better: "the same shape
  spool-client.mjs builds". This is a C5 wording point for the row lane.
- **N6** (plan `:535-536`, `:548-554`): 2 of row 01's 24 suites are red on base
  in the planner's harness, and I did not re-run them. The r14-01 lane must show
  `test-install.sh` and `agent-mcp.tst.sh` green in its real worktree, or the same
  check names red on its parent. Otherwise C4 has no evidence for them.

## Brief note (not about the plan)

The seat brief names the r13 plan as `refactor-round-14-20261128-plan.md (on
origin/master)`, for the format and the r13 left-out section. That file is not
on master. I read the r13 plan, `refactor-round-13-20261127-plan.md`, section 7.

## State (for a rotation)

v0.1 verdict written and pushed to `review/c002-refactor-round-14-claude-seat`.
Next: wait for the editor's v1.0 sha, re-check it, and sign it in this file
(a second commit on the same branch), then report in the same form.
