# Refactor round 86 — panel seat mistral (m-035@<box>)

Issue: SPL-6209 (epic SPL-2402). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/m-035/lifetime/brief.md` (spawn-remote copy
`b0b89afc-da61-4632-b219-22c5015bd4ca.md`).

Review target: `csi-spl-doc/doc/md/refactor-round-86-plan.md` on branch
`review/c002-refactor-round-86-planner` at the sha the dispatch holder named in its
spool note (msg `6ace7930-3bed-41bc-aba7-cb26f50a6f34`, task `dispatch-refactor-r86`,
from c-002@sat, relayed via the hub): **`8dc0ce940b09b83efa03a2684048446c07fa938f`**.

- `git ls-remote origin | grep -E 'r86-[0-9]{2}|refactor-round-86'` ->
  `8dc0ce940b09b83efa03a2684048446c07fa938f  refs/heads/review/c002-refactor-round-86-planner`
  (head == the named sha; `git log origin/master..<branch>` -> exactly 1 commit,
  `git diff --stat origin/master <branch>` -> 1 file, `refactor-round-86-plan.md` +383).
- The plan's measured base is `f074057b5de9f69836e5c820908f0c6b54e8b6e0`; `origin/master`
  at review time (2026-11-21T21:3xZ, after a fresh `git fetch origin master`) is the same
  sha, so `git diff --name-only f074057b5 origin/master -- <the 7 row paths>` -> **empty**.
- Every file:line cited below was checked with `git show f074057b5:<file> | sed -n <N>p`.

**Verdict: PASS on `8dc0ce940b09b83efa03a2684048446c07fa938f`. No W defects.**

## 1. Slug r86 unused since the plan's W

- Plan's `Window: W=2026-11-21T18:21:36+01:00`. `git log origin/master -1 --format=%cI
  -E --grep='^docs\(r85-plan'` now reads `6a68f693862aaf30ebee37a8e04dfd6642ebb664`
  (2026-11-21T20:26:13+01:00, the r85 close record, landed after the round opened — the
  plan records W as read at open, `d519dd8e5`; both dates give the same results below).
- `git log origin/master --since="2026-11-21T18:21:36+01:00" --oneline -E --grep='\(r86-' | wc -l`
  -> **0**; with `--since="2026-11-21T20:26:13+01:00"` -> **0**; over all history -> **0**.
- `git ls-remote origin | grep -E 'r86-[0-9]{2}|refactor-round-86'` -> only
  `refs/heads/review/c002-refactor-round-86-planner` (the planner's; my review branch is
  pushed after this read). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r86-[0-9]{2}|refactor-round-86'` -> no match;
  `grep -rlE 'r86-[0-9]{2}|refactor-round-86' /var/spool-hub/dispatch/briefs
  /var/spool-hub/spawn-remote/briefs` -> exactly 2 files, both in `spawn-remote/briefs`:
  `b0b89afc-...md` (this seat's brief) and `c77e6d85-...md` (the planner's). Expected.
- `git ls-tree --name-only f074057b5 csi-spl-doc/doc/md/ | grep -c refactor-round-86` -> **0**
  (the plain name is free on trunk).
- `git log origin/master --since="$W" --oneline -- <the 7 row paths>` -> **0** commits.

## 2. Every row site file:line exists on base and on origin/master

Row paths (7): `orc:src/bash/scripts/rotate-cron.inc.sh` (new),
`orc:src/bash/scripts/orch-rotate-cron.sh`, `orc:src/bash/scripts/dispatch-rotate-cron.sh`,
`orc:src/bash/tests/orch-rotate.tst.sh`, `orc:src/bash/tests/dispatch-rotate.tst.sh`,
`api:internal/hubclient/agent_drop.go`, `api:internal/cleancode/cleancode_test.go`
(`orc:` = `csi-spl-orc`, `api:` = `csi-spl-api/src/go/spool-hub-api`).

- `git cat-file -e f074057b5:csi-spl-orc/src/bash/scripts/rotate-cron.inc.sh` -> rc 128,
  "does not exist" — expected, the row creates it.
- `git diff --name-only f074057b5 origin/master -- <the 7 paths>` -> **empty** (origin/master
  == f074057b5 at review time): no drift.
- Cited lines read at `f074057b5` with `git show <sha>:<file> | sed -n <N>p`:
  - `orch-rotate-cron.sh:7-8` header PATH sentence; `:15-17` PATH block
    (`PATH="/usr/local/sbin:...${PATH:+:$PATH}"`, `ROTATE_CRON_PATH_EXTRA`, `export PATH`);
    `:20-30` `say()` + `check_tools()` over `$ROTATE_CRON_TOOLS` (rc 3 on missing);
    `:39-48` `SELF`/`ORC`, `check_tools || exit $?`, the `--check-tools` OK line, the
    `*-wt/*` case with `ROTATE_ALLOW_WORKTREE` refusal (exit 2), the `[ -x "$ORC/run" ]` check.
  - `dispatch-rotate-cron.sh:10-11` header; `:19-21` PATH block; `:24-34` `say`/`check_tools`;
    `:44-53` the same gate. All present, same text as the orch counterparts (see check 4).
  - `orch-rotate.tst.sh:29-30` header item 10; `:911` `cp "$PROJ_ROOT/.../orch-rotate-cron.sh"
    "$SRC/..."`; `:942` the missing-tool case (exit 3, `no-such-tool-x`).
  - `dispatch-rotate.tst.sh:603` the `cp` of the dispatch wrapper.
  - `agent_drop.go:7` `"strconv"` import; `:193-205` `ParseDropAfter` doc comment + 8-line body
    (`strings.TrimSpace`, `""` -> 0, `strconv.Atoi` -> minutes, else `time.ParseDuration`).
  - `cleancode_test.go:43-46` the `folded` list (`var folded = ...{` at :43, two entries
    :44-45, close `}` at :46).
  - Also read: `queue_health.go:58-69` `ParseMinutes` (body :60-69 byte-identical to
    `agent_drop.go:196-205`); callers `cmd/spool/hub.go:1200` (`ParseDropAfter`), `:1215`,
    `:1218` (`ParseMinutes`); tests `agent_drop_test.go:69-78` (`TestParseDropAfter`),
    `queue_health_test.go:164-173` (`TestParseMinutes`).
- R2 site greps at `f074057b5`: `git grep -lE
  'orch-rotate-cron|dispatch-rotate-cron|ROTATE_CRON_TOOLS|ROTATE_ALLOW_WORKTREE' --
  csi-spl-orc/src/bash/tests` -> `dispatch-rotate.tst.sh`, `orch-rotate.tst.sh`,
  `peer-restart.tst.sh`; `git grep -lE 'ParseDropAfter|ParseMinutes' --
  csi-spl-api/src/go/spool-hub-api | grep _test` -> `agent_drop_test.go`,
  `queue_health_test.go`. Matches the plan.

## 3. Red controls, run on the plan's base in scratch copies

Control files read and hashed at `f074057b5`:
- `git show f074057b5:csi-spl-orc/src/bash/tests/orch-rotate.tst.sh | sha256sum` ->
  `8ac1c2f5fecaea7c86a718cc28fadf43e524e224a48c100b538a61a843673428`
- `git show f074057b5:csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go | sha256sum`
  -> `f1e367a6afb0b318ce0bb57d8e41a7caa82f629a63f40e9c39ba63f6009b07b7`

Scratch copies: `git archive f074057b5 | tar -x -C /tmp/r86-base01` (and `...02`),
`git init` + one commit each. Nothing committed to any shared repo; both copies live in
/tmp only.

**Row 02 (Go cleancode gate).** In `/tmp/r86-base02/csi-spl-api/src/go/spool-hub-api`:
- Base, unmodified: `go test ./internal/cleancode/ -run TestCleanCodeGate` ->
  `ok  github.com/csitea/csi-spl/spool-hub-api/internal/cleancode  2.239s`, rc **0** (green).
- Red: added the plan's `folded` entry after `cleancode_test.go:45`
  (`{"return time.Duration(m) * time.Minute, nil", "internal/hubclient/queue_health.go",
  "a cnf minutes-or-duration value is read by hubclient.ParseMinutes (r86-02)"},`),
  parent's `agent_drop.go` untouched:
  `go test ./internal/cleancode/ -run TestCleanCodeGate` ->
  `--- FAIL: TestCleanCodeGate (1.10s)` /
  `cleancode_test.go:105: internal/hubclient/agent_drop.go: "return time.Duration(m) * time.Minute, nil" is back outside internal/hubclient/queue_health.go: a cnf minutes-or-duration value is read by hubclient.ParseMinutes (r86-02)` /
  last line `FAIL`, rc **1**. Byte-identical to the plan's 1.5 quote. It fails for the
  plan's reason (the pattern sits outside its home), not for an environment reason.
- `go test ./internal/hubclient/ -run 'TestParseDropAfter|TestParseMinutes' -v` on base ->
  `--- PASS: TestParseDropAfter`, `--- PASS: TestParseMinutes`, `ok ... 0.083s`, rc 0.
- Live state: none — `go test` ran in the /tmp scratch copy only.

**Row 01 (head's `orch-rotate.tst.sh` on the parent).** In `/tmp/r86-base01`, the base
test file was given the head's two edits only: the `cp` of `rotate-cron.inc.sh` after
`:911` and the new case after `:942`
(`grep -lE '^(say|check_tools|rotate_cron_orc)\(\) *\{'` over the three files in the
sandbox, want `rotate-cron.inc.sh `). The parent has no inc, so the `cp` fails there too,
as the plan notes. Run: `cd /tmp/r86-base01 && SPOOL_TEST=1 bash
csi-spl-orc/src/bash/tests/orch-rotate.tst.sh` -> rc **1**, **195 PASS, 1 FAIL**, last
line `orch-rotate: 1 failure(s)`; the FAIL is
`FAIL: 10. defined once (want 'rotate-cron.inc.sh ', got 'orch-rotate-cron.sh ')`
(the plan's run had both wrappers in its sandbox and got both names; this sandbox copies
only `orch-rotate-cron.sh` at :911 — same reason either way: the functions are defined in
the wrapper, not once in the inc). Fails for the plan's reason, not an environment reason.
- Live state: none — the suite runs in `T=$(mktemp -d)` with `SPOOL_TEST=1`, a fake
  `/proc` (`LEASE_PROC_ROOT="$T/proc"`), stub `tmux`/`spawn`/`./run`/`kill` under
  `$T/bin` first on PATH, `FAKE_CRONTAB="$T/crontab"` (test file lines 114, 313-315, 914).

## 4. Equivalence of each row

- **r86-01:** `diff` of the cited blocks between the two wrappers at `f074057b5`:
  `sed -n '15,17p' orch-rotate-cron.sh` vs `sed -n '19,21p' dispatch-rotate-cron.sh` ->
  IDENTICAL (PATH block); `:20-30` vs `:24-34` -> IDENTICAL (`say` + `check_tools`);
  `:39-48` vs `:44-53` -> IDENTICAL (SELF/ORC, `check_tools || exit $?`, `--check-tools`
  line, `*-wt/*` + `ROTATE_ALLOW_WORKTREE` refusal exit 2, `[ -x "$ORC/run" ]` exit 2).
  `wc -l`: orch 53, dispatch 62 — as the plan says. The wrappers differ only in header,
  the `ROTATE_CRON_TOOLS` default (`:18` `jq tmux flock timeout getent` vs `:22`
  `python3 jq tmux flock git`), arguments, messages and `./run` lines — all of which the
  row keeps in the wrapper. Moving the identical blocks into one sourced inc keeps output,
  exit codes, paths and defaults; the gate's `return 2` becomes `rotate_cron_orc || exit $?`
  -> exit 2, same as base. The control (the new defined-once case + the 22-case probe +
  the red control above) catches a difference.
- **r86-02:** `ParseDropAfter` (`agent_drop.go:196-205`) and `ParseMinutes`
  (`queue_health.go:60-69`) have the same signature and a byte-identical 8-line body at
  `f074057b5`. Making the former `return ParseMinutes(s)` keeps every return value and
  error; `TestParseDropAfter` (green on base, above) then proves the one-line call. The
  `folded` gate entry (red above) catches the pattern reappearing outside
  `queue_health.go`. The exact pattern `return time.Duration(m) * time.Minute, nil` is in
  exactly two non-test files at base (`git grep -n ... -- csi-spl-api/src/go/spool-hub-api`
  -> `agent_drop.go:202`, `queue_health.go:66`); `store/issue_history_test.go:20` carries
  `t0.Add(time.Duration(m) * time.Minute)` and does not match the full pattern — as the
  plan says.

## 5. Row fields (R2, tests, vendor, kind, batch, R7)

Both rows in the section-2 table carry: a red control that fails today and passes after
(R2, reproduced in check 3), a test list, box `either`, vendor `claude`, kind
`simple_coding`, batch 1. No mistral coding or testing row (owner 10-17, t1 b61851fb).
R7 (plan section 4): grok pick or a fresh claude waiver seat, never a mistral code R7 —
compliant. R1: batch 1's two rows share no file (row 01: 5 orc files; row 02: 2 api files;
`git diff --name-only` between the sets is empty by construction — disjoint paths).

## 6. R3: lane map on the row paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check <the 7 row paths, comma-separated> --agent m-035` -> **exit 4**:
`unknown: c-809@sat c-809-c002-b34-01-store-doc-asset-held-locked-doc`,
`c-894@sat c-894-c002-s184-h1-hub-agent-model`,
`c-934@sat c-934-c003-wui-topic-pdf-all-posts`,
`c-937@sat c-937-c002-s123-l5-orc-cost-labels-translate-cron` — all "no files recorded",
all on the other box; by slug none is a rotation-cron, hubclient or cleancode lane
(same class as r85's N1). Additionally
`--check csi-spl-api/src/go/spool-hub-api/cmd/spool/hub.go --agent m-035` -> **exit 3**:
`owned by c-806@<box> c-806-c002-spl6182-native-auth-whole-flow` — and row 02 does not touch
`hub.go` (the caller stays; verified at `hub.go:1200,1215,1218`).
`cd csi-spl-orc && env SPOOL_ROOT=/var/spool-hub ./run -a do_spl_spawn_queue` ->
`INFO 10 queued, 0 placing`; none of the 10 placements is an orc rotation cron, hubclient
or cleancode lane by slug.

## 7. Inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` is **not readable from this
  box** (`ls` -> No such file; `find /var/spool-hub -iname '*next-round*'` -> nothing).
  NOT RUN as a direct read. The plan quotes the holder's inline of its refactor-shaped
  lines (msg `a726c92c`, 19:42Z): `:1 :2 :25 :26 :29 :48 :74 :76 :83 :94 :104 :105`. Each
  is either served (plan 1.2(a): `:1`, `:25`, `:48`) or left out in the plan's section 7
  (`:2`, `:26`, `:29`, `:74`, `:76`, `:83`, `:94`, `:104`, `:105`). No refactor-shaped
  input is neither served nor accounted for.
- r85 plan section 7: `git diff --name-only f074057b5 8dc0ce94` -> only
  `csi-spl-doc/doc/md/refactor-round-86-plan.md`, so the r85 plan (section 7 included) is
  unchanged on the base; its left-out items stay out for their recorded reasons.
- Each row is ONE logical refactor with no behaviour change: row 01 moves byte-identical
  lines and keeps every exit code, message, path and default (check 4); row 02 is a
  one-line call into a byte-identical body. No row changes an exit code, a message, a
  path or a default — no bug row hidden in a refactor row.

## 8. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`ok - owner mail address or domain`, `ok - hidden workspace or private literal (SPL-1874)`,
`ok - retired relay estate (SPL-1910)`, `ok - no tracked .vibe/ dir`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-035`,
rc **0**.

## Defects

None (no W1...).

## Notes

- **N1** the lane map exits 4 on all 7 row paths (unknown-scope lanes, all @sat, none a
  rotation-cron / hubclient / cleancode lane by slug); the row lanes re-run R3 at spawn.
- **N2** the candidates file lives on the other box; check 7 rests on the plan's quoted
  inline of msg `a726c92c` plus the r85 section-7 read at base, not on a direct read of
  the file.
- **N3** in my row-01 red reproduction the FAIL's got-string was `orch-rotate-cron.sh `
  (only that wrapper is copied into the section-10 sandbox at :911), vs the plan's
  `orch-rotate-cron.sh dispatch-rotate-cron.sh ` — same failure reason.
- **N4** `git log origin/master -1 -E --grep='^docs\(r85-plan'` now reads the r85 close
  record `6a68f6938` (landed 2026-11-21T20:26:13+01:00, after the round opened); the plan
  records W as read at open, and both dates give 0 for the `(r86-` grep (checked both).
