# Refactor round 68 (r68): mistral panel seat (m-028)

Seat: m-028@<box>, placement `c002-refactor-round-68-mistral-panel-seat` (mistral;
docs and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-68-mistral-panel-seat.md`
(Issue SPL-5982, Epic SPL-2402, Spec `csi-spl-doc/specs/011-spool-project-refactor`,
class refactor, kind specs_and_docs, topic `0a622877-52ce-4ed3-b2e9-a11d95d602fb`).

Review target: plan v0.2 `2d9900128b736c70399f544f10bd10ac5f5aa977`, named by
c-526@<box2> msg 51034841 and in the brief. Provenance:
`git ls-remote origin | grep -E 'r68-[0-9]{2}|refactor-round-68'` ->
`2d9900128b736c70399f544f10bd10ac5f5aa977 refs/heads/review/c002-refactor-round-68-planner`
(only the planner's branch; my own review branch did not exist yet at my read);
`git show 2d9900128 --stat` -> 1 file `csi-spl-doc/doc/md/refactor-round-68-plan.md`,
12 insertions(+), 3 deletions(-) vs v0.1 `7606cff46` (`git cat-file -t 7606cff46` ->
commit; the diff touches only the status line, section 7 rows, the section 8 entry
and the consensus editor line — rows unchanged). All reads below are
`git show <ref>:<file>` / `git grep ... <ref>` unless a command names another ref.
origin/master at my read: `23864a22465b2c8409da9129614d07bc8a3ffc2f` — the plan's own
measuring sha, so every count holds on trunk by identity (N1).

## Verdict

**PASS on `2d9900128b736c70399f544f10bd10ac5f5aa977`** (2026-11-19 ~17:45Z).
W1..: none. N1-N5 below.

### 1. Slug r68 unused

- `git log origin/master --oneline -E --grep='\(r68-' | wc -l` -> **0**.
- `git ls-remote origin | grep -E 'r68-[0-9]{2}|refactor-round-68'` -> only
  `2d9900128b736c70399f544f10bd10ac5f5aa977 refs/heads/review/c002-refactor-round-68-planner`
  (the planner's, expected); no `r68-NN` row branch, no other round-68 branch.
- `grep -rlE 'r68-[0-9]{2}' /var/spool-hub/dispatch/briefs /var/spool-hub/dispatch/asks 2>/dev/null | wc -l`
  on sat -> **1**: `/var/spool-hub/dispatch/briefs/c002-refactor-round-68-mistral-panel-seat.md`
  (my own brief, expected); over `/var/spool-hub/spawn-remote/briefs` -> **0**.
- Control: `git log origin/master --oneline -E --grep='\(r67-[0-9]' | wc -l` -> **2**
  (`1d0c30d99` r67-01, `c4c841171` r67-02), so the log read sees a used id.
- Window W re-derived: `git log origin/master -1 --format='%H %cI' -E --grep='^docs\(r67-plan'`
  -> `bb5657d3f82ea9201015a40ef80afddb33f2f2c3 2026-11-19T16:42:53+01:00` — matches the
  plan's recorded W.

### 2. Every site file:line of both rows exists on `23864a224` and on origin/master

Full paths (`git ls-tree -r --name-only origin/master | grep <name>`), one per row
file: `.shellcheck-warning-baseline.txt`,
`csi-spl-orc/src/bash/tests/release-stable.tst.sh`,
`csi-spl-orc/src/bash/tests/responder-run.tst.sh`,
`csi-spl-orc/src/bash/tests/spec-import-issues.tst.sh`,
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-watch.sh`,
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-top.sh`,
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-strip-agy-optin.sh`,
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-strip-two-envs.sh` — all 8 exist
on both refs.

`git show 23864a224:<file> | sed -n <N>p` and `git show origin/master:<file> | sed -n <N>p`
— identical on the two refs (origin/master IS `23864a224`):

- `release-stable.tst.sh:46` -> `c1=$(commit "feat(hub): old feature one")`;
  `:48` -> `c3=$(commit "feat(rdb): 0100 a new table" csi-spl-rdb/src/sql/postgres/spool-hub/0100_new_table.sql)`;
  `:49` -> `c4=$(commit "perf(hub): faster send")`;
  `:78` -> `c6=$(commit "feat(hub): new feature six")`
- `responder-run.tst.sh:120` -> `for i in 1 2 3 4; do`
- `spec-import-issues.tst.sh:504` -> `IFS=$'\x1f' read -r action item ref pkey pitem status labels desc kind title_b64 <<<"$line"`
- `test-agent-watch.sh:22` -> `P1="$(agent 'CLE-07 x' claude CLE-07 '❯ 1. Yes  Do you want to proceed?')"`;
  `:25` -> `P4="$(agent 'GRK-10 x' grok GRK-10 'esc to interrupt')"`;
  `:26` -> `P5="$(agent 'CLE-00 orc' claude CLE-00 '❯ ')"`;
  `:27` -> `P6="$(agent 'CLE-90 me' claude CLE-90 '❯ ')"`;
  `:29` -> `P8="$(t_window 'CLE-12 plain' 'sleep 600')"`
- `test-agent-top.sh:40` -> `P6="$(t_window 'tbx: AGY-11 legacy'  "bash -c \"$(fake agy AGY-11 'ready')\"")"`
- `test-strip-agy-optin.sh:47` -> `P4="$(t_window AGY-74 'sleep 600')"`;
  `:52` -> `P5="$(t_window AGY-75 'sleep 600')"`
- `test-strip-two-envs.sh:107` -> `P91="$(t_window CLE-91 'sleep 600')"`

Drift: `git log 23864a224..origin/master --oneline -- <the 8 paths> | wc -l` -> **0**.
Newest change of each (`git log origin/master -1 --format='%h %cI' -- <file>`):
`f2ec7d955` (release-stable), `35458b740` (responder-run), `b3fc696fd`
(spec-import-issues), `1d5843c62` (test-agent-watch), `a454a2a66` (test-agent-top),
`8c8e1530b` (test-strip-agy-optin), `f4d5776b1` (test-strip-two-envs), `c4c841171`
(baseline) — matches the plan's 2.2 list. No file drifted.

### 3. The baseline

Real path: `git ls-tree -r --name-only origin/master | grep shellcheck-warning-baseline`
-> `.shellcheck-warning-baseline.txt` (repo root).

- `git show origin/master:.shellcheck-warning-baseline.txt | grep -vcE '^\s*(#|$)'` ->
  **80** non-comment lines (matches plan 1.2).
- `git show origin/master:.shellcheck-warning-baseline.txt | grep -c '^SC2034'` -> **35**
  (`grep -c 'SC2034'` -> 36 counts the header comment line too); by tree:
  `awk -F'|' '{print $2}' | awk -F/ '{print $1}' | sort | uniq -c` -> **4 csi-spl-iac,
  31 csi-spl-orc** (matches plan 1.2). Per-code totals:
  SC2034 35, SC2154 20, SC2120 7, SC1090 5, SC2088 4, SC2046 3, SC2319 2, SC2164 2,
  SC2155 2 — identical to the plan's 1.2 row.
- The 7 SC2034 lines the rows drop are in it today:
  `grep '^SC2034' | grep -E 'release-stable|responder-run|spec-import-issues|test-agent-watch|test-agent-top|test-strip-agy-optin|test-strip-two-envs'`
  -> `release-stable.tst.sh|4`, `responder-run.tst.sh|1`, `spec-import-issues.tst.sh|3`
  (row 01: 3 lines, 8 warnings), `test-agent-watch.sh|5`, `test-agent-top.sh|1`,
  `test-strip-agy-optin.sh|2`, `test-strip-two-envs.sh|1` (row 02: 4 lines, 9 warnings).
- Batch order: both rows edit the shared baseline file with disjoint line sets, so
  row 02 after row 01 (R1) makes each row apply on the trunk it starts from.
- `command -v shellcheck` -> found on this box,
  `shellcheck --version` -> 0.10.0. `shellcheck -S warning -f gcc <file>` on
  `git show origin/master:<file>` output, SC2034 lines only:
  - `release-stable.tst.sh` -> `:46 c1`, `:48 c3`, `:49 c4`, `:78 c6` (4)
  - `responder-run.tst.sh` -> `:120 i` (1)
  - `spec-import-issues.tst.sh` -> `:504 item`, `:504 labels`, `:504 desc` (3)
  - `test-agent-watch.sh` -> `:22 P1`, `:25 P4`, `:26 P5`, `:27 P6`, `:29 P8` (5)
  - `test-agent-top.sh` -> `:40 P6` (1)
  - `test-strip-agy-optin.sh` -> `:47 P4`, `:52 P5` (2)
  - `test-strip-two-envs.sh` -> `:107 P91` (1)
  Total 17 = 8 (row 01) + 9 (row 02), matching plan section 6.

### 4. Row shape (practice, R2 control, test list, vendor, kind, batch, R7)

Both rows of plan section 2 carry: practice (developer guide 2.4.3, the WARNING
ratchet only shrinks), a red control that fails today and passes after (sites fixed
with the baseline lines left -> `do_sec_shellcheck` FATAL "fewer findings than
baselined" at `csi-spl-iac/lib/bash/funcs/sec-baseline.func.sh:67-69`, rc 1; lines
dropped -> PASS), a test list (plan 1.4: the row files, `sec-shellcheck.tst.sh`,
`do_check_pre_push_lint`), vendor **claude**, kind **simple_coding**, batches 1 and 2
(row 02 `SPAWN_AFTER` row 01, R16). No mistral coding or testing row. R7 reviewers
(plan section 4): cross-vendor first (agy if its pick holds, else a fresh claude seat
under the claude waiver), explicitly "Not a mistral code R7" — never mistral.

### 5. Behaviour: each removed variable is never read

- `release-stable.tst.sh`: `git show origin/master:<f> | grep -nE '\$(c1|c3|c4|c6)\b|\$\{(c1|c3|c4|c6)[}:]'`
  -> rc 1 (**0 reads**); `c2`, `c5` are read at `:52` (`vtag 1.0.0 "$c2"; vtag 1.0.1 "$c5"`),
  `:68`, `:69` and stay. `commit()` at `:29-34` uses `local` only and its last command
  is `git ... rev-parse HEAD`, so `commit ... >/dev/null` keeps the fixture commit and
  discards only the sha.
- `responder-run.tst.sh:120`: the loop body (`:121`) is one `in_resp` call; a
  word-boundary grep for `i` outside the `for i in` line -> rc 1 (**never read**).
- `spec-import-issues.tst.sh:504-506`: `grep -nE '\$(item|labels|desc)\b|\$\{(item|labels|desc)[}:]'`
  -> rc 1 (**never read**); the check at `:506` reads `action ref pkey pitem status kind`
  and `title_b64` (via `title`). `read -r` is positional, so
  `read -r action _ ref pkey pitem status _ _ kind title_b64` keeps the column order.
- `test-agent-watch.sh`: `grep -nE '\bP[0-9]+\b'` -> P1/P4/P5/P6/P8 only at their
  assignments `:22,25,26,27,29`; P2/P3/P7 are read at `:40-42,50-51` and stay.
  `agent()` at `:20` is `t_window "$1" "bash -c ..."`.
- `test-agent-top.sh`: `grep -nE '\bP6\b'` -> `:40` only; `:41` already writes the same
  kind of window as `t_window 'notes' 'sleep 600' >/dev/null`.
- `test-strip-agy-optin.sh`: `grep -nE '\bP[45]\b'` -> `:47`, `:52` only.
- `test-strip-two-envs.sh`: `grep -n P91` -> `:107` only.
- `t_window()` (`sa:tests/lib.inc.sh:86-88`) is one
  `tmux ... new-window -d ... -P -F '#{pane_id}'` — prints the pane id, keeps no caller
  state. Each of the 7 files runs under `set -uo pipefail` (no `-e`):
  release-stable `:18`, responder-run `:21`, spec-import-issues `:4`,
  test-agent-watch `:11`, test-agent-top `:25`, test-strip-agy-optin `:11`,
  test-strip-two-envs `:11` — so a bare call's exit status is not acted on, as the
  assignment's was not.
- The red control is real today: `sec-shellcheck.func.sh:175-176` holds counts per
  (code, file) equal to the baseline; `sec-baseline.func.sh:67-69` FATALs ("fewer
  findings than baselined -- lower this line") with rc 1 when a fixed warning's line
  is left, so sites fixed + lines left fails and lines dropped passes.

### 6. R3: lane-map over the 8 written paths

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
--check csi-spl-orc/src/bash/tests/release-stable.tst.sh,csi-spl-orc/src/bash/tests/responder-run.tst.sh,csi-spl-orc/src/bash/tests/spec-import-issues.tst.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-watch.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-top.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-strip-agy-optin.sh,csi-spl-orc/src/bash/features/spawn-agents/tests/test-strip-two-envs.sh,.shellcheck-warning-baseline.txt
--agent m-028` -> **exit 4**: no live lane lists the paths, but 9 live lanes record
no files: `c-049@<box2>`, `c-060@<box2>`, `c-443@<box2>`, `c-484@<box2>` (r67-03),
`c-521@<box2>` (spec 179 B1), `c-526@<box2>` (this round's planner), `c-812@<box2>`,
`c-924@<box2>`, `c-927@<box2>` ("unknown, ask first", not free). The plan's 2.2 read exit 4
with 1 such lane (c-946) at 2026-11-19T17:29:24Z — live state moved; the holder's R3
re-check before each row's spawn governs. My seat writes only this seat file, so no
collision with any lane.

### 7. R1 across rounds: no live perf or bug round row names these files

- Newest perf plan on origin/master: `csi-spl-doc/doc/md/perf-round-18-plan.md` (last
  touched by `da68ad993` 2026-11-18T16:51:12+01:00);
  `git grep -cE 'release-stable\.tst|responder-run\.tst|spec-import-issues\.tst|test-agent-watch|test-agent-top|test-strip-agy-optin|test-strip-two-envs|shellcheck-warning-baseline'
  origin/master -- csi-spl-doc/doc/md/perf-round-18-plan.md` -> rc 1 (**0**).
- Newest bug plan on origin/master: `csi-spl-doc/doc/md/bug-round-22-plan.md` (last
  touched by `dc6d40e29` 2026-11-19T16:37:15+01:00); the same `git grep -cE` -> rc 1
  (**0**).

### 8. The candidates file's refactor-shaped items, re-measured on origin/master

- (a) `csi-spl-orc/src/bash/scripts/reverse-tunnel-cron.sh`: `git show
  origin/master:<f> | sed -n 20,28p` -> `:23` is the shellcheck source comment,
  `:24-26` source `spl_run_paths` and derive, `:27` is
  `ls "${REVERSE_TUNNEL_STATE_DIR:-$SPL_VAR_APP_DIR/reverse-tunnel}"/*.conf ...` — no
  literal box path: **served in code**. The guide's prose still prints it:
  `git show origin/master:csi-spl-doc/doc/md/guides/installation-and-configuration-guide.md
  | sed -n 592,596p` -> `:594` names `/var/csi/csi-spl/reverse-tunnel` — left as a docs
  follow-up, as the plan's section 7 says.
- (b) `spl-watchdog.func.sh`: `git grep -n LOGIN_STATE_DIR 23864a224 -- <watchdog>
  <lane-rotate>` -> `:72` is the `@param` text (default `spl_claude_login_state_dir`),
  `:1318` is `dir="$(spl_claude_login_state_dir)"`; `spl-lane-rotate.func.sh` has no
  `/var/` line (`grep -nE '/var/'` -> rc 1) and calls the function at `:116` —
  **served**. The only `/var/` lines in the watchdog are `:76` (an `@example` with
  `/var/tmp`, not a box path) and `:535,:539` (the new item below).
- New item, confirmed live: `git show origin/master:csi-spl-orc/src/bash/run/spl-watchdog.func.sh
  | sed -n 536,542p` -> `:539` `echo "${BOOT_CRON_LOG_DIR:-/var/${oa%%-*}/$oa/agent-boot-restore}/retired"`;
  `git show origin/master:csi-spl-orc/src/bash/run/spl-agent-boot-restore-install-cron.func.sh
  | sed -n 54,60p` -> `:57` `logdir="${BOOT_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/agent-boot-restore}"`;
  `git grep -nE 'agent-boot-restore' origin/master -- 'csi-spl-orc/src/bash/run/*.sh'`
  lists both plus the `@param` at `:31`. A computed `/var/<org>/<org>-<app>` default,
  invisible to `no-literal-paths.tst.sh`'s literal pattern — correctly recorded as
  round 69 input, not a row here.

### 9. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-028`,
exit **0**.

## Defects

W1..: none.

## Notes

- N1: origin/master at my read is `23864a22465b2c8409da9129614d07bc8a3ffc2f`, the
  plan's own measuring sha, so every cited file:line and count holds on trunk by
  identity (drift 0, check 2).
- N2: my lane-map read returned exit 4 with 9 unknown lanes (all @<box2>) vs the plan's 1
  (c-946) at 17:29:24Z — live state moved; exit 4 means "ask first", not free, and the
  plan defers to the holder's R3 re-check before each row's spawn. The brief's named
  live lanes c-484 (r67-03) and c-521 (spec 179 B1) are among them; c-946 and c-536 no
  longer record as unknown at my read.
- N3: check 1's briefs grep prints 1 today — my own brief; `/var/spool-hub/spawn-remote/briefs`
  prints 0. The row-id log grep is 0 and no `r68-NN` branch exists on the remote, so
  the row slug is free.
- N4: shellcheck 0.10.0 was present (found on this box via `command -v shellcheck`);
  I ran it on `git show origin/master:<file>` output, not on a checkout, so the gcc
  line numbers match the tree exactly.
- N5: the brief names the (b) sites as `spl-watchdog.func.sh:72,1311` and
  `spl-lane-rotate.func.sh:112`; on origin/master `:1311` is the `spl_wd_login_human()`
  def line (the LOGIN_STATE_DIR default site is the `:72` `@param`, the call `:1318`)
  and lane-rotate `:112` is the `if [[ -z ...` line (the call is `:116`). The plan's
  own section 7 refs (`:72`, `:1318`, `:116`) verified exact; the brief's are off by a
  few lines, no claim changes.

## Seat state

Verdict report sent on task `dispatch-refactor-r68` (kind result) to c-526@<box2> and the
current dispatch lease holder, in the brief's form. This seat waits for a message on
that task whose body starts with ACCEPTED from c-526 or the dispatch holder; until then
no /exit-clean. Branch `review/c002-refactor-round-68-mistral-seat` holds this commit;
a later v1.0 sha named by c-526 gets a second commit on the same branch and a second
report in the same form.
