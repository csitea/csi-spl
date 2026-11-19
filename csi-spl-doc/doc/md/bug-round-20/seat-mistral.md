# Bug round 20 (b20): mistral panel seat (m-305)

Seat: m-305 (this box), placement `c002-bug-round-20-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/spawn-remote/briefs/2f393e7d-69c2-49dc-99c1-df05b34a6652.md`
(Issue SPL-5951, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `22556ffa-dad9-4b7d-9366-6d62474fff52`).

Review target: plan v0.1 `bfce48e3579ff3971849a3574d31ce9fa7014027`, named in the
brief. Provenance: `git ls-remote origin | grep bug-round-20` ->
`bfce48e3579ff3971849a3574d31ce9fa7014027  refs/heads/review/c002-bug-round-20-planner`;
`git merge-base --is-ancestor bfce48e3579ff3971849a3574d31ce9fa7014027 origin/master`
-> exit 1 (NOT on master); `git show bfce48e3 --stat` -> 1 file, +151,
`csi-spl-doc/doc/md/bug-round-20-plan.md` (151 lines, read in full at that sha);
base `6b5656493` is on origin/master (`git merge-base --is-ancestor 6b5656493
origin/master` -> exit 0). origin/master at my read: `8c6ea8825` (moved past the
plan's `93a625324` during the read, N1; no drift on the row's files, check 6).
No later plan version was named to me at the v0.1 read, so v0.1 `bfce48e35` is
signed above. Plan v1.0 `70764ad05` was named by the editor c-291 at
2026-11-19T10:11:04Z (msg 9902bd3e, task dispatch-bug-r20); it is signed in the
last section.

## Verdict

**PASS on `bfce48e3579ff3971849a3574d31ce9fa7014027`** (plan v0.1, 1 row b20-01).
Defects W1..: none. Notes N1..N5 below.

## Checks (each with the command run and what it printed, 2026-11-19 09:5x-10:0xZ)

### 1. Slug b20 unused

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b19-plan')` ->
  `W=2026-11-19T09:53:30+02:00` (exactly the plan's W);
  `git log origin/master --since="$W" --oneline -E --grep='\(b20-' | wc -l` -> `0`.
- `git ls-remote origin 'refs/heads/review/b20-*' 'refs/heads/wip/*b20*' 'refs/heads/*-b20-*'`
  -> empty; `git ls-remote origin | grep -cE 'b20-[0-9]{2}|bug-round-20'` -> `1`,
  the one line being the planner's own `review/c002-bug-round-20-planner` at
  `bfce48e35` (expected, as the plan's own slug bullet predicts).
- `grep -rlE '(^|[^0-9a-f])b20-[0-9]{2}-' /var/spool-hub/dispatch/briefs /var/spool-hub/asks /var/spool-hub/spawn-remote/briefs | wc -l`
  -> `1`, the hit being this seat's own brief (spawned after the plan's 09:06Z
  measurement, N4); `grep -rl 'bug-round-20'` over the same dirs -> 3 files (the
  planner's brief and the panel seats' briefs).
- `git branch -a | grep -cE 'b20-[0-9]{2}'` -> `0`.

### 2. The row b20-01: defect real, fix smallest, case 9 kept, other-box path

Every cited line checked with `git show 6b5656493:<file> | sed -n <N>p` (nl -v
numbering), all match as cited:

- `spl-review-go.func.sh:819-829` -> `_spl_review_go_send()` at `:819`; the send
  at `:825-826` ends `|| { do_log "WARN msg $2: GO to $to failed; the next run tries again"; return 9; }`
  — any send failure logs nothing and returns 9. `:93` -> header `@description
  failed GO send is not logged, so the next run tries again.` `:113` ->
  `REVIEW_GO_MAX_AGE:-60`. `:160-162` -> `_spl_review_go_seen` greps
  `^(PASS|WAIT) [^ ]+ $1 | review-go $1 ` in automation.log. `:851-864` ->
  `_spl_review_go_hold` writes `review-go <msg> action=refused rc=...` to the log.
  Main loop `:136-141` skips only `_spl_review_go_seen` messages, so a failed send
  (nothing logged) is re-checked every tick until `REVIEW_GO_MAX_AGE`.
- `spool-send.sh:533-537` -> rc 4 from `spool_cli` prints "retired on this machine
  less than 24 h ago ... a reject is in <from>'s inbox" and `exit 14`.
  `:405-407` -> a same-box `--to <id>@<box>` clears TO_BOX (`:407`), so it takes the
  local path; `:510-522` -> the other-box path relays via the hub and on failure
  `exit $((10 + rc))` at `:521`.
- `spl-review-go.tst.sh:302-306` -> case 9: `run REVIEW_GO_MSG="$f" SEND_RC=1; rc=$?`
  expects `rc == 9` and an empty log ("a failed GO send logs nothing (the next run
  tries again)").
- `spl-review-go-install-cron.func.sh:41` -> the cron line starts `* * * * *`.
- `retired.go:84` -> `return fmt.Errorf("%w: %s retired at %s (quarantined until
  %s); nothing was delivered, a reject is in %s's inbox", ErrRetiredRecipient, ...)`.
- `spec.md:256` -> documents exit 9 ("the GO send failed: nothing logged, retried
  next run").

So the defect is real as described: exit 14 (retired author, quarantine 24 h >
`REVIEW_GO_MAX_AGE` 60 min) can never succeed, yet every tick re-sends and drops
another reject. The fix (exit 14 terminal, held once via the existing
`_spl_review_go_hold`, whose `review-go <msg> action=refused` line makes
`_spl_review_go_seen` skip the message next tick) is the smallest that closes it —
it reuses the hold machinery and touches only the caller; other failures still
return 9 and are retried, so case 9 stays (proven by the control case below, both
RED and GREEN).

**Other-box path (the plan's open question): handled by the same exit code.** The
hub maps `ErrRetiredRecipient` to exit 4 (`spool.go:685-686` in `ExitCode`:
`case errors.Is(err, ErrRetiredRecipient): return 4`; `retired_test.go:43` asserts
`ExitCode(err) != 4` fails), and `spool-send.sh:521` exits `10 + rc` = **14** for a
hub-refused retired id. So spool-send exit 14 uniquely means "retired" on both the
same-box path (`:536`) and the relayed path (`:521`), and the row's "exit 14 is
terminal" covers both (N2).

### 3. Red control (plan section 3.2)

- The script is on this box: `ls -la /var/spool-hub/dispatch/b20-red-controls/rc01.sh`
  -> 14822 B; `sha256sum` -> `faa73d5664fe8e3b7ec3cd830efd057e9882210ace336fb1c6e19cdc7671e24e`
  (the plan's `faa73d5664fe...`).
- `diff <(git show 6b5656493:csi-spl-orc/src/bash/tests/spl-review-go.tst.sh | sed -n '1,213p') <(sed -n '1,213p' rc01.sh)`
  -> empty: rc01.sh lines 1-213 are byte-identical to the suite fixture at
  `6b5656493` (suite is 1083 lines).
- RED on `6b5656493`: in a `mktemp -d`, `git archive 6b5656493 csi-spl-orc | tar -x`,
  copy rc01.sh into `csi-spl-orc/src/bash/tests/`, `bash rc01.sh` ->
  `FAIL: b20-01: retired author -> 3 GO send(s) in 3 ticks; automation.log: 0 line(s); out: 1 'tries again' in the last tick` /
  `PASS: b20-01 control: a transient send failure (rc 1) is retried, nothing logged` /
  `FAIL: 1`, exit 1 — exactly the plan's claimed output.
- GREEN only with the fix: applied the plan's prototype (in the mktemp copy only,
  not shipped: on rc 14 in `_spl_review_go_send`, call `_spl_review_go_hold ... 9
  "author $to is retired (quarantined): the GO was not delivered"` and return 9),
  re-ran `bash rc01.sh` ->
  `PASS: b20-01: a retired author (send rc 14) gets one GO try, logged once, no retry` /
  `PASS: b20-01 control: a transient send failure (rc 1) is retried, nothing logged` /
  `PASS: all`, exit 0 — exactly the plan's claimed output. The whole
  `spl-review-go.tst.sh` on the same copy -> `spl-review-go: 0 failure(s)`, exit 0.
- So the control is falsifiable (RED on `6b5656493`, GREEN only with the fix) and
  its control case keeps case 9's retry in both runs.

### 4. The sat evidence

Not re-readable from this box, and I do not claim it: this box's
`/var/csi/csi-spl/review-go/cron.out` has `grep -c 'GO to c-836@sat failed'` -> `0`
and holds only `INFO the dispatch lease is held by c-002@sat, on another machine:
its machine sends the GO` lines — consistent with the plan's note that the log is
sat's. The 52 `GO to c-836@sat failed` lines and the 56 rejects (07:26:09Z..08:46:11Z)
are the holder's read on sat (msg bd1192ad); judged on that read, not re-measured.

### 5. Dropped candidates (sections 2, 4, 5, 6)

- **wui 8/8 `issues-ctxmenu` "4j Shift+O" flake (2 sightings):** `gh run view` ->
  44394043708 failure, `wui: browser e2e (mock, generated) 8/8`, headSha `ba846ec4`,
  2026-11-18T20:43:43Z, push; 44490281353 failure, same job, headSha `6b5656493`,
  2026-11-19T08:45:14Z, schedule; push run 44487062602 on the same sha `6b5656493`
  -> success (08:22:34Z). `git diff --stat 6b5656493^ 6b5656493 -- csi-spl-wui | wc -l`
  -> `0` (the sha touches no WUI file). `git show 6b5656493:csi-spl-wui/tests/e2e/issues-ctxmenu.test.mjs | sed -n '199p'`
  -> `ok('4j Shift+O opens the issue', ...)`. Two sightings = a flake (rulebook
  2.11.3: a fixing lane on the 3rd); rightly a watch item, not a row.
- **orc 2/4 canary `ps.log` (1 sighting):** 44404675709 failure, `orc: hermetic
  action tests ... 2/4`, headSha `f1048ab3`, 2026-11-18T21:45:07Z, schedule;
  `gh run list --workflow '10_ci-quality.yml' -L 25` -> every completed run after it
  is success except 44490281353 (the wui job above). Watch item, rightly not a row.
- **(b) the SPL-5613 wip sweep:** the refusal
  `/var/spool-hub/c-001/outbox/20261119T082711Z--c-001--relayed-f4a8fcb8.json` is on
  this box; its body names 10 distinct shas, and `git merge-base --is-ancestor <sha>
  origin/master` -> all 10 ancestors. `git show 6b5656493:.../hooks/pre-push |
  sed -n '215p'` -> `_pp_mr+="$_pp_rsha..$_pp_lsha "` (no `--not <remote>/master`);
  `git ls-remote origin 'refs/heads/wip/c-390*'` -> empty (the old remote tip cannot
  be read back). Plausible, no red control — rightly deferred to round 21, not a row.
- **(a) c-091's staged index:** another box's worktree, NOT RUN from this box (no red
  control, writer unknown); the plan reports it to the orchestrator as a finding and
  keeps it a watch item — rightly not a row.
- **The review-go SPOOL_ROOT log line:** `git log origin/master --oneline
  -S'SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"' -- csi-spl-orc/src/bash/run/spl-review-go.func.sh`
  -> `a125b0d5d fix(orc, SPL-4316): review GO defaults SPOOL_ROOT ...`; the default is
  at `:118` (`SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"`). Fixed, rightly not a row.
- **Source 1 (human posts), re-run on prd:** the plan's count query ->
  `t1 7 (6 [spool-probe], 0 regex hits), csitea 7 (1 regex hit, 0 probe)` — exactly
  the plan's table; 0 rows stands.
- **Source 3 (skips):** `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" 6b5656493 -- "$d" | wc -l; done`
  -> `api 200, wui 18, orc 10, iac 21, utl 0` (the plan's `\|` in a table cell is the
  markdown escape; typed with a plain `|` as the plan says). `git diff 0268cbab8
  6b5656493 -G '<pattern>' --stat` -> one file, `hours_price_sql_tab_test.go`;
  `git log -1 10e324efa` -> `fix(api, SPL-5913)...`; its `t.Skip` is at `:19`
  ("Postgres only (hub-pg.tst.sh)...") — a store split, not a disabled test.
- **Section 4:** `git log origin/master --oneline -E --grep='\(b19-01-'` ->
  `6b5656493 fix(b19-01-orc-box-link-watch-..., SPL-5947)...`; `git log -1 87d56eaae`
  -> `refactor(r64-01-orc-cron-script-state-dirs, SPL-5944)...`. As the plan says.
- **Source 4 (cron logs):** the plan's readings are from the planner's box, not
  re-readable from this box; this box's review-go cron log is INFO-only (check 4).

### 6. Every cited sha exists; drift since 6b5656493

- `git cat-file -t <sha>` -> `commit` for all cited shas: 0268cbab8, 87d56eaae,
  a125b0d5d, 10e324efa, ba846ec4, f1048ab3, 06eff273f, f7c388910, b97a764ff,
  6b5656493, 93a625324.
- `git rev-list --count 0268cbab8..6b5656493` -> `46` (the plan's 46).
- `git diff --stat 6b5656493 origin/master -- csi-spl-orc/src/bash/run/spl-review-go.func.sh csi-spl-orc/src/bash/tests/spl-review-go.tst.sh csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-send.sh csi-spl-api/src/go/spool-hub-api/internal/spool/retired.go csi-spl-doc/specs/157-dispatch-automation/spec.md csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push`
  -> empty (origin/master is now `8c6ea8825`): no drift on any cited file;
  `git show origin/master:.../spl-review-go.func.sh | sed -n '819p;826p'` and
  `spool-send.sh | sed -n '533,537p'` print the same lines as at `6b5656493`.

### 7. R3 (lane-map)

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md --agent m-305`
  -> exit 4: no live lane lists the three paths; 4 lanes record no files
  (`unknown: c-706@sat ... wui-export-to-pdf`, `c-852@sat ... spl5883-t01-migration`,
  `c-855@sat ... spl5883-t16-filter-pref`, `c-859@sat ... r64-02-orc-no-literal-paths-scripts`)
  — the same 4 the plan's 09:30:05Z check named; by their titles none is the review
  GO. Exit 4 is not free; this seat writes only its own new file.

### 8. Distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-305`,
  exit 0 (re-run with this file tracked: still clean, exit 0).

## Defects

None. W1..: none.

## Notes

- **N1:** origin/master moved during the read: `93a625324` (the plan's read) ->
  `8c6ea8825` now; `git diff --stat 6b5656493 origin/master` over the row's six
  cited files is empty, so every measurement holds on both (check 6).
- **N2:** the plan leaves the other-box path as "the lane checks ... if that exit
  is distinguishable it is terminal as well": it is — hub `ExitCode` maps
  `ErrRetiredRecipient` to 4 (`spool.go:685-686`) and `spool-send.sh:521` exits
  `10+4=14`, so spool-send exit 14 means retired on both paths and the row's fix
  covers the relayed case with no extra code.
- **N3:** the sat evidence (52 failed-GO lines, 56 rejects) is the holder's read on
  sat (msg bd1192ad); not re-readable from this box (check 4), so it is judged on that
  read, not re-measured.
- **N4:** the single `b20-01-` hit in the spool brief dirs is this seat's own brief,
  spawned after the plan's 09:06Z slug measurement — expected, not a collision.
- **N5:** in the plan's table cells the alternation prints as `\|` (the markdown
  escape); typed literally with `\|` under `git grep -E` it returns 0 counts — run
  with a plain `|` as the plan's own note under the table says (same as b18's N7).

## v1.0 signature (2026-11-19 10:1xZ, this session)

The editor c-291 named plan v1.0 `70764ad056963d86b92c605b5656a46f4c2e17b5`
(msg 9902bd3e, 2026-11-19T10:11:04Z, task dispatch-bug-r20). Checks run by this
session:

- `git ls-remote origin 'refs/heads/review/c002-bug-round-20-planner'` ->
  `70764ad056963d86b92c605b5656a46f4c2e17b5`;
  `git log -1 --format='%H %s' 70764ad0` -> `docs(b20-plan, SPL-5951): bug round 20
  plan v1.0, panel m-305 mistral PASS on bfce48e35, notes N1-N5 answered, row 01
  unchanged in code scope`;
  `git merge-base --is-ancestor bfce48e35 70764ad0` -> exit 0 (fast-forward on v0.1);
  `git merge-base --is-ancestor 70764ad0 origin/master` -> exit 1 (NOT on master);
  `git diff --stat bfce48e35 70764ad0` -> 1 file, +16 -8,
  `csi-spl-doc/doc/md/bug-round-20-plan.md`.
- `git diff bfce48e35 70764ad0 -- <plan>` -> only the status line, row 01's
  fix-scope cell (the other-box path out of scope, exit 11), section 7 (round 21
  inputs), section 8 (notes N1-N5 answered) and section 9 (consensus). Row 01's
  defect, evidence, sites and red-control cells are unchanged; the title is still
  `# Bug-fix round 20 - plan (1 row)` and the counts table still `rows | 1`
  (`grep -cE 'b20-01'` 5 -> 6, the +1 being prose in the new section 8 text, not a
  row).
- **N2 re-checked as the editor asked:** `git show
  origin/master:csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-fleet-relay.sh
  | sed -n '222,232p'` -> the relay runs the binary at `:222-223` and on failure
  (`:224-231`) exits 3 for a roster miss (`cannot resolve to_box` /
  `ambiguous_to_box` / `unknown_agent`) and **1** for everything else. So
  `spool-send.sh:521` exits `10 + 1 = 11`, not 14, for a retired author on another
  box: my v0.1 N2 (exit 14 covers the relayed path) was **wrong**, the v1.0 answer
  is verified, and row 01's code scope (exit 14 only, the observed same-box case)
  is unchanged by it. The relayed retired-author send is recorded as a round 21
  input with no red control yet.
- Slug: `git log origin/master --since="$W" --oneline -E --grep='\(b20-' | wc -l`
  -> `0` still (v1.0 lives on the review branch only).
- Red control unchanged: `rc01.sh` RED on `6b5656493` as run this session
  (`FAIL: 1`, exit 1; GREEN with the prototype, suite 0 failures); the v1.0 commit
  is docs-only and `git diff --stat 6b5656493 origin/master -- <the 6 row files>`
  -> empty, so every v0.1 measurement holds on v1.0.

**Verdict on v1.0 `70764ad056963d86b92c605b5656a46f4c2e17b5`: PASS** — the v1.0
delta touches no measurement, only status, the verified N2 answer, round-21
inputs and consensus. W1..: none on v1.0 either.
