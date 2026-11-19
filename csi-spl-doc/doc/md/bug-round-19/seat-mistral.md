# Bug round 19 (b19): mistral panel seat (m-817)

Seat: m-817@sat, placement `c002-bug-round-19-mistral-panel-seat` (mistral; docs
and reviews only, no code written, no file touched but this one).
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-19-mistral-panel-seat.md`
(Issue SPL-5916, Epic SPL-2402, Spec `csi-spl-doc/specs/157-dispatch-automation`,
class bug, kind specs_and_docs, topic `7a8fd595-45c2-4fbc-8278-477da23154dc`).

Review target: plan v0.1 `a608c6fe02a1f114683f49ea9f8f2d3e6b6774c3`, named in the
brief. Provenance, all run 2026-11-19 06:0x-06:2xZ from `/opt/csi/csi-spl-wt/m-817`:
`git ls-remote origin 'refs/heads/review/c002-bug-round-19-planner'` ->
`a608c6fe02a1f114683f49ea9f8f2d3e6b6774c3  refs/heads/review/c002-bug-round-19-planner`;
`git log -1 --format=%P a608c6fe0` -> `0268cbab8f7bf9b129e653a57f2e6ab4e7bda039`;
`git merge-base --is-ancestor 0268cbab8 origin/master` -> exit 0 (parent on trunk);
`git merge-base --is-ancestor a608c6fe0 origin/master` -> exit 1 (NOT on master yet);
`git show a608c6fe0 --stat` -> 1 file, +135, `csi-spl-doc/doc/md/bug-round-19-plan.md`
(135 lines, read in full at that sha). origin/master at my read: `32a261c24`.

## Verdict

**PASS on `a608c6fe02a1f114683f49ea9f8f2d3e6b6774c3`** (plan v0.1, 1 row b19-01:
`box-link-watch.py` keeps a withdrawn pack pending for good, so its LINK STUCK
incident never clears). Defects W1..: none. Notes N1..: below.

## Checks (each with the command run and what it printed)

1. **Slug b19 unused since W** (`W=2026-11-18T18:24:57+01:00`, re-derived:
   `git log origin/master -1 --format=%cI -E --grep='^docs\(b18-plan'` ->
   `2026-11-18T18:24:57+01:00`):
   - `git log origin/master --since="$W" --oneline -E --grep='\(b19-' | wc -l` -> `0`
   - `git log origin/master --oneline -E --grep='\bb19-[0-9]{2}-' | wc -l` -> `0`
   - `git ls-remote origin 'refs/heads/review/b19-*' 'refs/heads/wip/*b19*' 'refs/heads/*-b19-*'` -> (nothing)
   - `git ls-remote origin | grep -cE 'b19-[0-9]{2}|bug-round-19'` -> `1`, and the one line is
     `a608c6fe0...  refs/heads/review/c002-bug-round-19-planner` — the planner's own
     review branch, which the plan itself says is expected after its push. No row
     branch, no wip branch. Slug unused: holds.

2. **The row (defect real as described).** Every cited line checked with
   `git show 0268cbab8:csi-spl-orc/src/bash/scripts/box-link-watch.py | sed -n <N>p`:
   - `:156` -> `def pending_items(rows, results):`; `:191` -> `return out` (so the
     cited range `:156-191` is exactly the function)
   - `:162` -> `or re.search(r"queued \S+/outbound/launch/(\S+\.zip)", text)` (the match)
   - `:163` -> `or re.search(r"^sent (\S+) hub -> \S+ .*waiting for", text)`
   - `:169-170` -> the only `done.add` paths for bundles: `^delivered (\S+) to ` or
     `^outbound: (\S+) not sent: same content`
   - `:188` -> `else ("bundle %s sent, no receipt" % name)` (the message text)
   - `:286-293` -> `def conditions(box, now, inc=None):` ... `:292-293`
     `if inc:` / `since = min(since, int(inc["since"]) - 60)` (the reach-back)
   - `:9` -> `  a  a queued or sent bundle/command with no receipt (`delivered <name>`); a`
   - `:18-21` -> the condition c docstring; `:400` -> `def in_flight(conds):`,
     `:412` -> `return conds, quiet`
   Reading the code: a pack with a `queued .../outbound/launch/<pack>` line (:162)
   enters `items`; only a `delivered` / `not sent: same content` line (:169-170)
   removes it. A pack withdrawn from `launch/` unsent gets neither, so it stays in
   `out["a:"+name]` (:190) forever; while an incident is open, `conditions` reads
   back to `inc["since"] - 60` (:292-293), so the 6 h window never ages it out and
   the incident never clears; the blocker text (:188) says "sent, no receipt" though
   it was never sent. **The defect is real as described.**
   - **Smallest fix?** The proposed fix (withdrawn = `queued` line + no `sent` line +
     no file at `<root>/<box>/outbound/launch/<pack>` -> no condition a; a `sent`
     line keeps it pending; `gr-cmd-*` unchanged; relay untouched) is confined to
     `pending_items`/`conditions` and closes exactly this path. I see no smaller
     change that closes it without also clearing genuinely pending items.
   - **Real stuck link still covered?** Yes, and the plan says how: a pack still in
     `launch/` and unsent has its file present, so it is not "withdrawn" and stays
     pending -> the incident still raises. The plan states this explicitly ("a file
     gone from `launch/` does not prove the send stopped: the upload may already
     run"). No W.

3. **Red control rc01.** `/var/spool-hub/dispatch/b19-red-controls/` does not exist
   on this box (`ls` -> `No such file or directory`), so per the brief I judge from
   the plan text plus the code: the control is falsifiable — on `0268cbab8` it must
   print `FAIL: b19: withdrawn pack -> 1 message(s): ... LINK STUCK > 7 min ...`
   and `after 3 h: 1 message(s); incident open since ...`, and passes only with the
   fix (`PASS: ... 0 message(s)`), with the whole suite still green. Mechanism
   verified in code (check 2) and the suite baseline run by me:
   `bash csi-spl-orc/src/bash/tests/box-link-watch.tst.sh` in this worktree (the file
   is unchanged since `8de1d37b1`: `git diff --stat 8de1d37b1 0268cbab8 --
   csi-spl-orc/src/bash/scripts/box-link-watch.py` -> empty) -> `ALL PASS`, exit 0.
   The fixture claim holds: the test is 377 lines, lines 1-87 are fixture/helpers
   (case 1 starts at `:88`), case 7b exists at `:147` (`git show 0268cbab8:... |
   sed -n '147p'`), so "a new case after 7b" is well-defined.

4. **Dropped candidates (sections 4-6).**
   - Holder's-list files: `git diff --stat 8de1d37b1 0268cbab8 -- 'csi-spl-iac/src/bash/run/tf-*.func.sh' csi-spl-iac/lib/bash/funcs/tf-log-mask.func.sh csi-spl-orc/src/bash/run/spl-reflection-gather.func.sh csi-spl-orc/lib/bash/funcs/spl-desk-moved.func.sh csi-spl-orc/src/bash/run/spl-lane-issue.func.sh csi-spl-orc/src/bash/run/spl-uplink-probe.func.sh csi-spl-wui/src/utils/kind-picker-keys.ts csi-spl-wui/src/utils/msg-shortcuts.mjs csi-spl-orc/src/bash/run/spl-watchdog.func.sh csi-spl-orc/src/bash/run/spl-lane-rotate.func.sh csi-spl-api/src/go/spool-hub-api/internal/store/fallback_postgres.go` -> empty (unchanged since round 18).
   - `git diff --stat 8de1d37b1 0268cbab8 -- csi-spl-orc/src/bash/scripts/box-link-watch.py` -> empty.
   - Skipped-test counts: `git grep -n -E "(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)" 0268cbab8 -- <d> | wc -l` -> api 199, wui 18, orc 10, iac 21, utl 0 — exactly the plan's numbers.
   - `git grep -c mdp_10_report 0268cbab8 | wc -l` -> `0`.
   - The hygiene spin flake: `gh api repos/csitea/csi-spl/actions/jobs/135008392699/logs | grep -a 'control: SETUP'` -> `2026-11-18T17:53:05.4860237Z FAIL: control: SETUP, the step's planted wait() never ran (verdict: clean)`; `gh run view 44362658751 --json conclusion,headSha` -> failure on `71152a944...`; `gh run view 44369022256 --json conclusion,headSha` -> success on `69ccfa3b1...` ("green since" holds). The cited test lines exist: `hygiene-killed-cleanup.tst.sh:98` -> `if [[ ! -e "$T/spin.mark" ]]; then fail "control: SETUP, ..."`; `:58-63` -> the TERM control loop. Ask `4293e172-504d-4832-8df5-a0e0ff108ff1.json` exists in `/var/spool-hub/asks/` and now reads `"state":"done"`, `"reason":"placed: c-031@<box3>"` — owned by a live lane (even stronger than the plan's "queued"). The wf10 `sweep_join`/`sweep_stop` the lead names exist (`.github/workflows/10_ci-quality.yml:1771`, `:1787`, TERM trap `:1801`).
   - `b9b22d2f9` -> `test(orc, SPL-5897): ...` (exists); `454edf844` -> `fix(wui, SPL-5904): ...` (exists); `232902108` on origin/master, `gh run view 44358523357` -> success on it (round 18 closed as stated).
   - Source-1 counts re-run on prd bounded at the plan's read time
     (`... where ts > '2026-11-18T14:34:00Z' and ts < '2026-11-18T19:10:00Z' ...`):
     t1 20 (2 regex hits, 12 probe), csitea 5 (1 regex hit) — exactly the plan's
     numbers; the regex-hit counts still match unbounded today (t1 2, csitea 1).
   - Source-5 issues re-run bounded at 19:10Z: 22 issues, 7 `bug` (plan said 21/7 —
     one boundary issue, see N3).
   **No dropped candidate should have been a row.**

5. **Every file:line and sha cited exists as cited.** Shas: `0268cbab8` (on
   origin/master, committed 2026-11-18T19:36:11+01:00), `8de1d37b1` (on master),
   `71152a944`, `69ccfa3b1`, `b9b22d2f9`, `454edf844`, `232902108` all resolve with
   the subjects the plan implies; `git rev-list --count 8de1d37b1..0268cbab8` ->
   `21` (the plan's "21 commits"). GH runs/job: 44362658751 failure, 44369022256
   success, 44358523357 success, job 135008392699 failure on 71152a944 — all as
   cited. Asks 4293e172, e37476d3, 8508b9a7, 2c936b7f, d2f0ca24 all exist as files
   in `/var/spool-hub/asks/`. Files on `0268cbab8`: `csi-spl-doc/specs/016-spool-testability/box-link-7min-watcher.md`,
   `csi-spl-orc/src/bash/run/spl-box-link-watch.func.sh`, `.github/workflows/10_ci-quality.yml`,
   `csi-spl-doc/doc/md/rounds-rulebook.md` all exist (`git cat-file -e`); on
   origin/master: `bug-round-17-plan.md`, `bug-round-18-plan.md` exist.
   `addc262c` appears in `/var/spool-hub/dispatch/sender-audit.jsonl` (the SPL-5911
   lane's brief exists in `/var/spool-hub/dispatch/briefs/`: `grep -l SPL-5911` ->
   one `hand-…-seat-5911.md` file). Drift: N2, N3.

6. **R3 lane map:** `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/scripts/box-link-watch.py,csi-spl-orc/src/bash/tests/box-link-watch.tst.sh --agent m-817`
   -> `free`, exit 0.

7. **Distribution hygiene:** `cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
   `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-817`, exit 0.

## Defects

None. W1..: none.

## Notes

- **N1:** the red control `rc01.sh` is not readable on this box
  (`/var/spool-hub/dispatch/b19-red-controls/` absent; it lives on the planner's
  box). Check 3 is judged from the plan text plus the code and the suite run above,
  not from executing rc01 itself.
- **N2:** the holder's candidate list changed after the plan's read:
  `stat -c '%s B, mtime %y' /var/spool-hub/dispatch/c002-next-round-candidates.md`
  -> `4242 B, mtime 2026-11-18 21:24:07 +0200` (the plan read 2967 B,
  2026-11-18T01:57:39Z). The repo files the list points to are unchanged
  (`git diff --stat 8de1d37b1 0268cbab8 -- <their files>` -> empty, verified), so
  the "unchanged since round 18" verdict stands; only the list file itself moved.
- **N3:** source-5 issue count at the 19:10Z bound is 22 (7 `bug`), the plan says 21
  (7 `bug`) — one issue at the boundary of the plan's read time; the `bug` count
  matches exactly.
- **N4:** residual edge of the proposed fix, for the row lane's suite case: a pack
  actually sent whose `sent` line has rotated out of the read window and whose file
  is gone from `launch/` would read as withdrawn. While an incident is open the read
  reaches back to the incident's start (`box-link-watch.py:292-293`), which covers
  the realistic case; worth one case in the new test.
- **N5:** the topic msg ids the plan cites (d8a84a3f, 84f130a2, 5b573c2c, b8af597b,
  457144e2, 89afc3f6) were not re-verified from this box
  (`spool tail --task 7a8fd595-...` printed empty locally); they are context, not
  row evidence.
