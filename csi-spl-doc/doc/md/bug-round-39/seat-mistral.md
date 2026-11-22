# Bug round 39 — panel seat mistral (m-331@<box2>)

Issue: SPL-6235 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/d0dfeeb1-6cd4-4981-84f4-ef8e49c55a20.md`.
Review target: `csi-spl-doc/doc/md/bug-round-39-plan.md` on branch
`review/c002-bug-round-39-planner`, at the plan version sha
`9b2609c16e4de0abab1f7e1e4251ce004a6cb1a7` (v0.1), named by the brief (planner
c-125@sat, msg 9a31d620). `git ls-remote origin refs/heads/review/c002-bug-round-39-planner`
-> exactly that sha, still the branch head at my check. The branch is one docs
commit on `c9f6ac91a`: `git merge-base --is-ancestor origin/master 9b2609c1` ->
rc 0; `git diff origin/master 9b2609c1 --stat` ->
`csi-spl-doc/doc/md/bug-round-39-plan.md | 109 ++...`, 1 file changed,
109 insertions — the "+109" the brief names. `origin/master` at my fetch:
`c9f6ac91ac6b783f537ff51a2fa9a4cd52cb7276` (the plan's measurement sha;
`git merge-base --is-ancestor c9f6ac91a origin/master` -> rc 0).
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the
panel signs the plan sha; 5.1: 1 to 3 rows, 0 is a valid verdict when every
input is accounted for; 5.3 numbering and window; 5.4 bugs priority 2).
Model: `csi-spl-doc/doc/md/bug-round-38-plan.md` on origin/master.

**Verdict: PASS on `9b2609c16e4de0abab1f7e1e4251ce004a6cb1a7` (v0.1), 0 rows.**
The plan's 0 rows is right: every input it lists was re-measured below and
accounts for no row. No defect W found. All checks run by me on <box2> on
2026-11-22, ending 07:05:36Z (`date -u +%Y-%m-%dT%H:%M:%SZ`), unless a line says
otherwise. Every command below was run by me; its output is quoted as printed.
Every file:line cited was printed with `git show <sha>:<file> | sed -n <N>p`
first.

## Check 1 — slug b39 unused since the plan's `Window: W=`

- Plan line 19 records `Window: W=2026-11-22T06:35:43+01:00` (commit `c9f6ac91a`).
  My re-read: `git log origin/master -1 --format=%cI -E --grep='^docs\(b38-plan'`
  -> `2026-11-22T06:35:43+01:00`, and
  `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(b38-plan'`
  -> `c9f6ac91ac6b783f537ff51a2fa9a4cd52cb7276 2026-11-22T06:35:43+01:00 docs(b38-plan, SPL-6232): ...`.
  Matches.
- `W=2026-11-22T06:35:43+01:00; git log origin/master --since="$W" --oneline -E --grep='\(b39-' | wc -l`
  -> `0` (and the bare grep prints nothing, rc 0).
- `git ls-remote origin | grep -E 'b39-[0-9]{2}|bug-round-39'` ->
  `9b2609c16e4de0abab1f7e1e4251ce004a6cb1a7\trefs/heads/review/c002-bug-round-39-planner`
  only — the planner's branch, expected; this seat's review branch did not exist
  yet at this check. Nothing else.
- The plan's own patterns: `git ls-remote origin 'refs/heads/review/b39-*' 'refs/heads/wip/*b39*' 'refs/heads/*-b39-*'`
  -> empty, rc 0.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b39-[0-9]{2}|bug-round-39'` ->
  no match (rc 1) on this box: the dir is readable here (3277 files) but holds no
  b39-named brief; the planner's brief (`c002-bug-round-39-planner.md`, per the
  plan's slug proof) lives on sat. This seat's brief:
  `grep -l 'bug-round-39' /var/spool-hub/spawn-remote/briefs/*.md` ->
  `d0dfeeb1-6cd4-4981-84f4-ef8e49c55a20.md` only — this brief, expected.
- `git worktree list | grep -E 'b39|bug-round-39'` ->
  `/opt/csi/csi-spl-wt/m-331 c9f6ac91a [m-331-c002-bug-round-39-mistral-panel-seat]`
  (this seat's, expected) plus `/opt/csi/csi-spl-wt/c-906 15eb398c8 [...]` and
  `/opt/csi/csi-spl-wt/c-937 15eb398c8 [...]` — both match only on the sha
  `15eb398c8` containing the hex letters `b39`: grep false positives, not b39
  worktrees (same class as round 38's N6). The planner's worktree is on sat, not
  listed here.

## Check 2 — CI: the plan's wf 10 claims re-run

- `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
  (run by me, rc 0) -> `== 10_ci-quality.yml on master -- last 100 run(s),
  2026-11-21T09:46:41Z .. 2026-11-22T06:45:22Z` — `56 success / 28 cancelled /
  15 failure / 1 running` (the plan read 56/29/15 over 09:33Z..05:36Z; the window
  moved, the 15 failures are the same — N1).
- First red per job over the 15 failed runs: `wui: browser e2e 3/8` x8,
  `6/8` x6, `1/8` x6, `orc: hermetic action tests 4/4` x2, `wui 4/8` x1 — exactly
  the plan's counts.
- Newest failure in the window: `44959763821 2026-11-21T23:02:14Z 61977111` —
  the plan's "newest at 23:02Z (`61977111`)"; no failure after 23:02Z, and no
  red on any sha newer than the plan's `c9f6ac91a` (all failed runs are on
  61977111, 1685e0eb, f6703d2b, 4e873475, d2557fbc, 05848e16, e1ee705d, 24722b49,
  6aee259c, 54dcbdae).
- Last green per failed job (newest in the window): all five e2e-shard jobs and
  hermetic 4/4 on `44990752760 c9f6ac91 2026-11-22T05:45:15Z` — later than the
  plan's `44986423470 09bf7208 04:45Z` / `44987888837 964e12e4 05:05Z`, the same
  forward-moving pattern as round 38's N2 (N1).
- Timeout headroom: every job `ok`, p90 under 75 % of its timeout; the highest
  `orc: hermetic ... 1/4` and `3/4` at 57 % — as the plan says.
- Each red's landed fix, all ancestors of `origin/master`
  (`git merge-base --is-ancestor <fix> origin/master` rc 0) with matching
  subjects: `75acaab9f fix(wui, SPL-6205): ... topic-menu-parity knows Export
  topic to PDF`, `acf2b4555 test(wui, SPL-6143): move-by-drag step 6 ...`,
  `c7c2247b6 chore(orc, SPL-6152): tf-030 importer covers
  google_service_account_iam_member.hub_self_sign ...`.
- Other workflows: `gh run list -R csitea/csi-spl -L 150 --json
  name,conclusion,status,createdAt,headSha,databaseId`, runs created after
  04:55Z that are not `success`/`skipped` -> one: `10 ci: quality gate
  in_progress 2026-11-22T06:45:22Z c9f6ac91a 44995156715`. 0 red in any workflow
  since 04:55Z. The wf 20 run the plan saw in progress (`44990382175` on
  `c9f6ac91a`) is now `success` (`gh run view 44990382175` ->
  `{"conclusion":"success",...}`).

## Check 3 — the e2e cut: rc01.sh re-run on c9f6ac91a

- Extracted from round 37's plan on origin/master (the plan points there):
  `git show origin/master:csi-spl-doc/doc/md/bug-round-37-plan.md | sed -n '83,126p' > rc01.sh`
  -> `wc -c` -> `2706`; `sha256sum` ->
  `a76d454d20ea8dd3cdffc7eee6061ebb46353c4eb0ce7be5706bc799b40c4307` — first 12 hex
  `a76d454d20ea`, 2706 B: exactly the plan's claim ("the same file").
- `bash rc01.sh c9f6ac91a` (run by me from the worktree, 61 s) ->
  `rc01 keys: got=exact-only want=has-prefix` /
  `rc01 sel: got=cut 37 want=selected` /
  `rc01 ctrl: got=selected want=selected` /
  `rc01 sha=c9f6ac91a keys=[msg-menu] wrong=2`, exit 1 — the plan's reading
  (wrong=2, exit 1 on `c9f6ac91a`) holds.
- The script touches no live state: I read it — it makes a throwaway
  `git clone --shared --no-checkout` into `mktemp -d`, checks out the sha there,
  runs `_ppe_keys` / `do_check_pre_push_e2e` inside the clone, and `trap 'rm -rf
  -- "$T"' EXIT`. No network, no browser, no push, no write outside `$T`.
- `git log --oneline a42fff43c..origin/master -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh csi-spl-wui/src/components/UiPointMenu.vue csi-spl-wui/src/components/MessageMenu.vue | wc -l`
  -> `0`: nothing changed in the three files, as the plan says.
- `git log --oneline a42fff43c..origin/master` -> exactly the 5 commits the plan's
  section 1 names: `5fac25f55`, `964e12e4a` (SPL-6199) and `463e08773`,
  `1740cc172`, `c9f6ac91a` (the b38 plan commits).

## Check 4 — inputs accounted for

- Round 38's section 6 "first inputs for round 39" (read on origin/master,
  `bug-round-38-plan.md`) names 5 items: the selector's composed testids;
  SPL-6174's relay-hash link; b34-01 N2 and SPL-6212 N2 (test-shaped); the
  SPL-6212 and SPL-6226 notes if their lanes end without landing; every item
  round 38 carried in its section 4. The b39 plan's section 4 has one row per
  item (5 rows): rc01 re-run (check 3 above); SPL-6174 re-checked
  (`git log origin/master --since=2026-11-21T20:00Z --format='%h %s' | grep -iE 'SPL-6174|relay'`
  -> no match, rc 1: the writer is still not named); b34-01 N2 + SPL-6212 N2;
  the SPL-6212/SPL-6226 notes (`git log origin/master --format='%h %s' --grep='SPL-6212'`
  and `--grep='SPL-6226'` -> `463e08773` each, the b38 plan commit whose subject
  only names them; both lanes live per the lane map, check 5); the carried items.
  All 5 accounted for.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md`: NOT RUN on this box —
  `ls /var/spool-hub/dispatch/c002-next-round-candidates.md` ->
  `No such file or directory`; the file is sat-only (the brief says so).
- The new R7 notes g-118 on r87-01 (SPL-6229), N1-N2: the plan says it read them
  in the holder's archive on sat (msg 6dcd57e5). Not readable here:
  `ls /var/spool-hub/g-118` -> No such file or directory, and
  `grep -rl '6dcd57e5' /var/spool-hub/c-002/` -> no match (the holder c-002@sat's
  archive is on sat). NOT RUN from the archive; I verified what the plan cites
  from the notes instead: `git log origin/master --format=%h --grep='SPL-6229' | wc -l`
  -> `0` (r87-01 not on master, as the plan says; its review sha `ea2bf74e2`
  resolves: `git cat-file -t ea2bf74e2` -> `commit`,
  `refactor(r87-01-api-hub-one-move-frame, SPL-6229): ...`). N2's file:line
  citations on `c9f6ac91a`: `git show c9f6ac91a:csi-spl-api/src/bash/tests/run-all-tests.sh | sed -n '59p'`
  -> `if (c + 1.0 < floor[p]) { print "FAIL - " ...` (the 1.0 tolerance is the
  gate's own); `git show c9f6ac91a:csi-spl-api/src/bash/tests/go-coverage-floor.txt | sed -n '23p;155p'`
  -> `cmd/spool 77.8` and `internal/hub 82.2 pg` — the plan's floors. So N2's
  "per design" reading checks out on the tree; N1's PASS-line count (1502 on both
  `964e12e4a` and `ea2bf74e2`) I did not re-run (it needs a full go test run on
  two review shas; NOT RUN, and it is a count in the author's report, not a
  tree claim).
- Skipped/disabled tests: `git diff a42fff43c c9f6ac91a -G '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' --stat`
  -> empty, as the plan's source 4 says.
- The plan's header claims check out: `git log -1 --format=%B c9f6ac91a | grep Closes`
  -> `Closes: SPL-6232` (round 38 closed); plan line 85 -> `| rows | 0 |`.
- No bug-shaped input is left unserved: the only inputs the brief names beyond
  the plan's sources are the sat-only candidates file (NOT RUN, above) and the
  g-118 archive (NOT RUN, above); nothing else was named.

## Check 5 — R3 lane map

- `bash .../spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/bug-round-39-plan.md --agent m-331`
  -> `WARN no live lane lists csi-spl-doc/doc/md/bug-round-39-plan.md, but 6 live lane(s) record no files`
  + `FATAL ... status 4`, exit 4. The unknown no-file lanes named:
  c-054@sat (s154-b7), c-101@sat (r87-01), c-107@sat (SPL-5882 T4), c-120@sat
  (lane-map case 23), c-125@sat (this round's planner), g-118@sat (rotate).
  Exit 4 = ask them first, never free; no live lane lists the plan file. The
  plan's own run (on sat, `--agent c-125`, 05:42:32Z) also read exit 4 with its
  12 no-file lanes; this box's hub answers with its 6 sat lanes — same verdict
  class, different box view (N2).
- Same check on this seat's own file,
  `--check csi-spl-doc/doc/md/bug-round-39/seat-mistral.md --agent m-331` ->
  exit 4, same 6 unknown lanes, no live lane lists it. The file is new (this
  commit creates it), so no collision.

## Check 6 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> every line `ok`/`allowed`
  (the cnf owner-key allowances), `INFO distribution-hygiene: clean over the
  tracked tree of /opt/csi/csi-spl-wt/m-331`, exit 0.

## Defects

None. No W.

## Notes

- **N1**: the 100-run CI window moved since the planner's read (09:46:41Z..06:45:22Z,
  56/28/15/1 vs its 09:33Z..05:36Z, 56/29/15); the 15 failures, their per-job
  first-red counts (8/6/6/2/1), the newest at 23:02:14Z (`61977111`) and the
  three landed fixes are unchanged; last green per failed job moved forward to
  `44990752760 c9f6ac91 05:45:15Z`.
- **N2**: the lane map answers per box: on this box 6 sat no-file lanes, on sat
  the planner read 12 <box2> ones; both exit 4, neither lists the plan file.
- **N3**: the candidates file and the g-118 archive msg 6dcd57e5 are sat-only;
  NOT RUN here (commands and outputs in check 4). The plan's citations from the
  g-118 notes that live on the tree (run-all-tests.sh:59, go-coverage-floor.txt:23
  and :155) were verified on `c9f6ac91a`.
- **N4**: `git worktree list | grep -E 'b39|bug-round-39'` also matches c-906 and
  c-937 on the sha `15eb398c8` — hex false positives, not b39 worktrees (round
  38's N6 class).
- **N5**: on this box `/var/spool-hub/dispatch/briefs` holds no b39-named file
  (rc 1); the planner's brief is on sat, this seat's is the only
  `bug-round-39` hit in `/var/spool-hub/spawn-remote/briefs/`.

**PASS on `9b2609c16e4de0abab1f7e1e4251ce004a6cb1a7` (v0.1): 0 rows is right.**
