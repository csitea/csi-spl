# Bug round 38 — panel seat mistral (m-289@<box2>)

Issue: SPL-6232 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/240e81af-9171-40bb-8195-9a4e4f69d7bb.md`.
Review target: `csi-spl-doc/doc/md/bug-round-38-plan.md` on branch
`review/c002-bug-round-38-planner`, at the plan version sha
`3f6c4c40758b9967d3bd14b2e32e8f56d20e4d08` (v0.1). The sha is named by the
planner (c-279@<box2>, msg 35bd0472); `git ls-remote origin
refs/heads/review/c002-bug-round-38-planner` -> exactly that sha, still the
branch head at my check (05:1xZ). The branch is one docs commit on
`a42fff43c`: `git merge-base --is-ancestor a42fff43c 3f6c4c40` -> rc 0 and
`git diff --stat 3f6c4c40^ 3f6c4c40` ->
`csi-spl-doc/doc/md/bug-round-38-plan.md | 118 +++...`, 1 file changed.
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the
panel signs the plan sha; 5.1: 1 to 3 rows, 0 is a valid verdict when every
input is accounted for; 5.3 numbering and window; 5.4 bugs priority 2).
Model: `csi-spl-doc/doc/md/bug-round-37-plan.md` on origin/master.

**Verdict: PASS on `3f6c4c40758b9967d3bd14b2e32e8f56d20e4d08` (v0.1), 0 rows.**
The plan's 0 rows is right: every input it lists is re-measured below and
accounts for no row. No defect W found. All checks run on <box2>,
2026-11-22 05:1xZ..05:24Z, unless a line says otherwise. Every command below was
run by me; its output is quoted as printed. Every file:line I cite was printed
with `git show <sha>:<file> | sed -n <N>p` first. origin/master at my first
fetch: `964e12e4a` (05:1xZ, two SPL-6199 api commits past the plan's
measurement sha `a42fff43c`) — see N1.

## Check 1 — slug b38 unused since the plan's `Window: W=`

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b37-plan')` ->
  `W=2026-11-22T05:37:58+01:00`, commit
  `09bf7208645235e833654dcfc4e74287d7a6fd72` (`docs(b37-plan, SPL-6228): ...`)
  — the value the plan records.
- `git log origin/master --since="$W" --oneline -E --grep='\(b38-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b38-[0-9]{2}|bug-round-38'` ->
  `3f6c4c40758b9967d3bd14b2e32e8f56d20e4d08\trefs/heads/review/c002-bug-round-38-planner`
  only — the planner's branch, expected. This seat's review branch did not
  exist yet at this check. Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b38-[0-9]{2}|bug-round-38'` ->
  no match (rc 1); the looser `grep -E 'b38|bug-round-38'` ->
  `20261009-b38743cb-agy-bg-review.md` only — a hex id, not a round brief, as
  the plan says.
- This seat's brief lives in `/var/spool-hub/spawn-remote/briefs/`:
  `grep -l 'bug-round-38' /var/spool-hub/spawn-remote/briefs/*.md` ->
  `2ad4435c-...md` (the planner's) and `240e81af-...md` (this brief) — both
  expected.
- `git worktree list | grep -E 'b38|bug-round-38'` ->
  `/opt/csi/csi-spl-wt/c-279 ... [c-279-c002-bug-round-38-planner]` and
  `/opt/csi/csi-spl-wt/m-289 ... [m-289-c002-bug-round-38-mistral-panel-seat]`
  — the planner's and this seat's, both expected. (`/tmp/g263-s154-b7` also
  matched, on the sha `2acddb381` containing "b38" — a grep false positive,
  not a b38 worktree; N6.)

## Check 2 — CI: the plan's wf 10 claims re-run

- `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
  (05:1xZ) -> `== 10_ci-quality.yml on master -- last 100 run(s),
  2026-11-21T09:32:50Z .. 2026-11-22T05:05:43Z` — `54 success / 30 cancelled /
  15 failure / 1 running` (the plan read 53/30/15/2 over 09:25Z..04:55Z; the
  window moved, N2).
- First red per job over the 15 failed runs: `wui: browser e2e 3/8` x8,
  `6/8` x6, `1/8` x6, `orc: hermetic action tests 4/4` x2, `wui 4/8` x1 —
  exactly the plan's counts.
- Newest failure in the window: `44959763821 2026-11-21T23:02:14Z 61977111` —
  the plan's "newest at 23:02Z (`61977111`)"; no failure after 23:02Z.
- Timeout headroom: every job `ok`, p90 under 75 % of its timeout; the highest
  `orc: hermetic ... 1/4` and `3/4` at 57 % — as the plan says.
- Last green per failed job: `44987157074 a42fff43 2026-11-22T04:55:37Z`
  (hermetic 4/4), `44986423470 09bf7208 2026-11-22T04:45:13Z` (wui 1/8, 3/8,
  4/8, 6/8) — later than the plan's `44982077734 e4662101 03:45Z`, the same
  running-then-green pattern as round 37's N2 (N2).
- Each red's landed fix, all ancestors of `origin/master`
  (`git merge-base --is-ancestor` rc 0) with matching subjects:
  `75acaab9f fix(wui, SPL-6205): ... topic-menu-parity knows Export topic to
  PDF` (the `d2557fbc4`..`61977111c` 21:17Z..23:02Z 1/8, 3/8, 6/8 reds),
  `acf2b4555 test(wui, SPL-6143): move-by-drag step 6 ...` (the 12:xxZ 3/8,
  4/8 reds), `c7c2247b6 chore(orc, SPL-6152): tf-030 importer covers
  ...hub_self_sign (master red at 54dcbdae5)` (the 11:xxZ hermetic 4/4 red).
  No red job without a landed fix.
- Other workflows since 02:30Z: `gh run list -R csitea/csi-spl -L 150 --json
  name,conclusion,createdAt,headSha,databaseId`, filtered to createdAt >=
  2026-11-22T02:30:00Z and conclusion not success/skipped -> 2 runs, both with
  no conclusion yet (still running) on `964e12e4a` at 05:05:43Z: `10 ci:
  quality gate` `44987888837` and `20 ci-cd: spool hub build + deploy`
  `44987889041`. **0 red** in any workflow since 02:30Z — the plan's claim
  holds (its "2 running" were the wf 10 runs on `09bf72086`/`a42fff43c`; the
  running pair has since moved to the new head `964e12e4a`, N3).
- Source 4's claim: `git diff e46621014 a42fff43c -G
  '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' --stat` -> empty (0 lines) —
  no test switched off, as the plan says.

## Check 3 — the e2e cut: rc01.sh on a42fff43c

- Extracted from round 37's plan section 4.1 (`git show
  origin/master:csi-spl-doc/doc/md/bug-round-37-plan.md`, the `bash` fence):
  `wc -c` -> `2706`, `sha256sum` ->
  `a76d454d20ea8dd3cdffc7eee6061ebb46353c4eb0ce7be5706bc799b40c4307` — first 12
  hex `a76d454d20ea`, 2706 B, exactly the plan's claim ("the same file").
- `bash rc01.sh a42fff43c` (05:2xZ, about 30 s) ->
  `rc01 keys: got=exact-only want=has-prefix` /
  `rc01 sel: got=cut 37 want=selected` /
  `rc01 ctrl: got=selected want=selected` /
  `rc01 sha=a42fff43c keys=[msg-menu] wrong=2`, exit 1 — the same reading the
  plan carries (wrong=2, exit 1, as on `e46621014`).
- The reading holds: it is a gate-design input, not a bug row — no narrow fix
  turns `sel` green, as the plan's section 4 says and round 37 measured the
  same.
- Live state: I read the script before running. It makes a throwaway
  `git clone -q --shared --no-checkout` of the checkout into `mktemp -d`,
  checks the sha out in the clone, sources the selector func and runs
  `./run -a do_check_pre_push_e2e` inside the clone, and `trap 'rm -rf' EXIT`
  removes it. `RC01_PLANT` was not set. No network, no browser, no push, no
  write outside the temp clone — it never touches live state.

## Check 4 — inputs accounted for

- Round 37's section 6 "first inputs for round 38" (read on origin/master)
  names four inputs; each appears in the b38 plan's section 4: the selector's
  composed testids -> row 1 (check 3 above, re-run); SPL-6174's relay-hash
  link -> row 2 (re-checked: `git log origin/master --since=2026-11-21T20:00Z
  --format='%h %s' | grep -iE 'SPL-6174|relay'` -> 0 matches, no writer named);
  b34-01 R7 c-855 N2 -> row 3; the items round 37 carried -> row 4.
- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md`
  is on sat, not on this box: `ls` here -> No such file or directory. NOT RUN
  (N5).
- The 16 R7 notes, read on this box:
  - g-251 (SPL-6212, PASS on `79ed989d3`), N1-N5, in its outbox review result
    msg `08c36de9` (the `review:` line names g-251 on this box, PASS
    `79ed989d33926a838eb903e81a68604612e87341`). The plan's section 3 re-reads
    all five correctly; its citations check out on `a42fff43c`:
    `git grep -n fcf09921 a42fff43c -- csi-spl-doc/doc/md/lane-issue-and-docs.md
    csi-spl-doc/specs/172-work-chain-enforcement/spec.md` ->
    `lane-issue-and-docs.md:83` and `spec.md:66` both name `fcf09921` (N1);
    the 0310 predicate `NOT IN ('done','diss')` is the same as
    `store.IssueClosed` (N2); N3-N5 as the plan says.
  - g-263 (SPL-6226, PASS on `2acddb381`), N1-N3, in its relayed review msg
    `cab2848c` (outbox, to c-002@sat). N1 verified on the review sha:
    `git show 2acddb381:csi-spl-api/src/go/spool-hub-api/internal/hub/gcal_connect.go
    | sed -n '209,217p'` -> the want switch: a repeated `calendar` token falls
    through to `default` -> 400 `bad_want`, a repeated `contacts` token is
    appended twice and deduped by JoinScopes — the plan's
    "`want=calendar,calendar` is 400, `want=contacts,contacts` is accepted"
    holds. N2 (authorize URL scope query unsigned, oauth.go:241; consent, not
    a forged State) and N3 (refresh path does not write GrantedScopes,
    gcal_sync.go:286-313) match the plan's "not a bug" readings.
  - g-080 (SPL-6224, PASS on `cdf8f5074`), N1-N8, relayed verbatim by the
    holder (c-002@sat, msg d7c203fd; read in c-279's inbox on this box,
    file `20261122T045818Z--c-002@sat--...-d7c203fd.json`, quoting sat msg
    88b3323a). The plan's section 3 re-reads all eight; its citations check
    out on `a42fff43c`: `git show a42fff43c:csi-spl-cnf/csi-spl/all.env.yaml |
    sed -n 528p` -> `SPOOL_HUB_EVLOG_FLUSH_S: "30"` (N1);
    `git show a42fff43c:csi-spl-doc/specs/162-event-log/spec.md | sed -n
    '610p;937p'` -> `:610` names `hub.evlog.flush_s` and the `:937` T3 row
    records the landed shas `316422e7c`, `5e0abcbe3`, `d125fb00f`,
    `cdf8f5074` — so N3 is closed on master as the plan says;
    `git show a42fff43c:.../hub/server.go | sed -n '965p;978,980p'` ->
    `:965` `Str("path", r.URL.Path)`, `:978-979` the comment, `:980`
    `ev.Msg("http 5xx")` (N4, N8); `git show a42fff43c:.../spec.md | sed -n
    '649,650p;752p'` -> the `evlog.overflow` row and its
    `<n> error groups not kept (cap 1000)` message (N7);
    `git show a42fff43c:.../hub/evlog.go | sed -n '204,206p;228p'` and
    `.../evlog/evlog.go | sed -n '268,270p;278p'` -> the overflow folding
    (N7). N5's "per spec 10.4.2" holds (spec section 10.4.2 at `:585`).
  - `git log origin/master --format='%h %s' --grep='SPL-6212' | wc -l` -> `0`
    and `--grep='SPL-6226' | wc -l` -> `0` (both lanes still live, as the plan
    says); `git merge-base --is-ancestor cdf8f5074 origin/master` -> rc 0
    (SPL-6224 landed).
- The plan's source 1 (inboxes since W): `find /var/spool-hub/c-001
  /var/spool-hub/c-002 /var/spool-hub/c-003 -maxdepth 2 -name '20261122T0[45]*'
  -newermt '2026-11-22 04:37:00Z'` minus rotation/lease/relay/standby/spawn ->
  2 files: c-248's b37 close note
  (`20261122T044200Z--c-248--bug-round-37-closed-0-rows-plan--ca6fc4a7.json`)
  and m-261's b37 PASS
  (`20261122T044231Z--m-261--b37-panel-seat-pass-0-rows-v0-1--6ca93131.json`)
  — exactly the plan's "2 files ... no owner word".
- The plan's section 4 selector claim: `git log --oneline e46621014..a42fff43c
  -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh
  csi-spl-wui/src/components/UiPointMenu.vue
  csi-spl-wui/src/components/MessageMenu.vue` -> 0 lines — nothing changed.
- No bug-shaped input is neither served nor accounted for.

## Check 5 — R3: lane map on the plan file

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
  --check csi-spl-doc/doc/md/bug-round-38-plan.md --agent m-289` (05:2xZ) ->
  exit 3: `csi-spl-doc/doc/md/bug-round-38-plan.md owned by c-279@<box2>
  c-279-c002-bug-round-38-planner (changed in its worktree; no files
  recorded)` — the planner owns the plan, expected; this seat touches only its
  own seat file.
- Same check on this seat's path
  `csi-spl-doc/doc/md/bug-round-38/seat-mistral.md` -> exit 4: `unknown:` lanes
  with no files recorded — c-054@sat (s154 B7 contacts scope), c-101@sat
  (r87-01 api hub one move frame), c-107@sat (SPL-5882 T4 evlog routes). The
  plan's own 05:00:09Z run listed the same plus c-894 (since ended); none owns
  the plan or this seat file (N4).
- Queue: `cd csi-spl-orc && ./run -a do_spl_spawn_queue` (05:2xZ) ->
  `1 queued, 0 placing`: ask `32816dc0` (lane-map case23 flake) — the plan read
  ask `78986553` (SPL-5882 T6) at 04:58:17Z; the queue moved on, neither ask is
  b38-shaped (N4).

## Check 6 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (05:2xZ) -> all `ok -`
  lines, `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-289`, exit 0.

## Defects W

- None.

## Notes N

- **N1**: origin/master moved after the plan's measurement sha: `a42fff43c` ->
  `964e12e4a` (`5fac25f55`, `964e12e4a`, both SPL-6199 api). Every count re-run
  above still matches the plan's; the reviewed sha is the planner-named v0.1
  `3f6c4c40`, whose branch head is unchanged.
- **N2**: the CI window shifted (09:32:50Z..05:05:43Z): 54 success / 30
  cancelled / 15 failure / 1 running vs the plan's 53/30/15/2; the last-green
  runs moved later (`44986423470 09bf7208 04:45:13Z`, `44987157074 a42fff43
  04:55:37Z` vs `44982077734 e4662101 03:45Z`) — the same running-then-green
  pattern as round 37's N2. Newest failure still 23:02:14Z `61977111`; no
  failure after 23:02Z.
- **N3**: the 2 non-green workflow runs since 02:30Z are still-running runs on
  the new head `964e12e4a` (wf 10 and wf 20, 05:05:43Z), not failures; 0 red.
- **N4**: time differences since the planner's reads: the spawn queue now
  holds ask `32816dc0` (not `78986553`), and the lane map lists 3 no-file sat
  lanes (c-894 ended). Neither is b38-shaped.
- **N5**: the candidates file is sat-only; NOT RUN on this box (`ls
  /var/spool-hub/dispatch/c002-next-round-candidates.md` -> No such file or
  directory), as the brief anticipated.
- **N6**: `git worktree list | grep 'b38'` also matched `/tmp/g263-s154-b7` on
  the sha `2acddb381` — a grep false positive, not a b38 worktree.

**PASS on `3f6c4c40758b9967d3bd14b2e32e8f56d20e4d08` (v0.1): 0 rows is right.**

## v1.0 signature

**PASS on `1740cc17225607f8b931ab0978bf5dd3aeaead49` (v1.0).** The sha is named
by the editor c-279@<box2> (result on task `825883a1-4a10-5b3e-96e5-dbced010993d`,
msg `ba4318af`) and is the head of `review/c002-bug-round-38-planner-v1`:
`git ls-remote origin refs/heads/review/c002-bug-round-38-planner-v1` ->
`1740cc17225607f8b931ab0978bf5dd3aeaead49`.

Checks re-run by me on <box2>, 2026-11-22 05:3xZ:

- v1.0 vs master: `git diff --stat origin/master 1740cc17` -> only the 2 b38
  files (plan 125 lines, seat 234 lines), +359;
  `git merge-base --is-ancestor origin/master 1740cc17` -> rc 0 (the branch is
  rebased onto `964e12e4a`; `git log --oneline origin/master..1740cc17` ->
  `463e08773` (the rewritten v0.1) and `1740cc172` (v1.0), so the old
  `review/c002-bug-round-38-planner` at `3f6c4c40` could not fast-forward —
  the editor pushed v1.0 to a new branch, no force).
- Verdict unchanged: plan section 6 at v1.0 -> `| rows | 0 |` (line 94); the
  status line reads "v1.0, for the holder's GO: the panel passed v0.1
  `3f6c4c407` (m-289, mistral, msg f97fdd1b), no W (section 7)".
- The folded seat file is blob-identical to my push:
  `git rev-parse 1740cc17:csi-spl-doc/doc/md/bug-round-38/seat-mistral.md` ->
  `1212bd7f5f21ffc30a246befcde10a4261cdb8da`;
  `git rev-parse 6425c1f55:csi-spl-doc/doc/md/bug-round-38/seat-mistral.md` ->
  `1212bd7f5f21ffc30a246befcde10a4261cdb8da`. Equal.
- N6 folded: plan section 6 at v1.0 (line 96) now says the worktree grep also
  matches `/tmp/g263-s154-b7` (its sha `2acddb381` holds the letters `b38`: a
  hex match, the SPL-6226 R7 scratch, not a b38 worktree; panel N6).
- Slug at v1.0: `git log origin/master --since="$W" --oneline -E
  --grep='\(b38-' | wc -l` -> `0`;
  `git ls-remote origin | grep -E 'b38-[0-9]{2}|bug-round-38'` ->
  `review/c002-bug-round-38-planner` `3f6c4c40...`,
  `review/c002-bug-round-38-planner-v1` `1740cc17...` and
  `review/c002-bug-round-38-mistral-seat` `6425c1f55...` — all three expected.
- Hygiene: `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> clean, exit 0.

The verdict stands: **PASS, 0 rows, on both `3f6c4c40` (v0.1) and
`1740cc17` (v1.0).**
