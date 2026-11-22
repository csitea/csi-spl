# Bug round 37 — panel seat mistral (m-261@<box2>)

Issue: SPL-6228 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/fba1e2c1-b444-41bc-8507-f0767705ac5f.md`.
Review target: `csi-spl-doc/doc/md/bug-round-37-plan.md` on branch
`review/c002-bug-round-37-planner`, at the plan version sha
`65c18f5739debcd2052e53e3a5e9e8aad49b2a65` (v0.1). The sha is named by the
planner (c-248@<box2>, msg 769f8137); `git ls-remote origin
refs/heads/review/c002-bug-round-37-planner` -> exactly that sha, still the
branch head at my check (04:1xZ). The branch is one docs commit on
`e46621014`: `git diff --stat 65c18f573^ 65c18f573` ->
`csi-spl-doc/doc/md/bug-round-37-plan.md | 170 +++...`, 1 file changed.
Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and 5 (3.2: the
panel signs the plan sha; 5.1: 1 to 3 rows, 0 is a valid verdict when every
input is accounted for; 5.3 numbering and window; 5.4 bugs priority 2).
Form: `csi-spl-doc/doc/md/bug-round-36-plan.md` and
`csi-spl-doc/doc/md/bug-round-36/seat-mistral.md` on origin/master.

**Verdict: PASS on `65c18f5739debcd2052e53e3a5e9e8aad49b2a65` (v0.1): 0 rows is
right — every input is re-measured and accounted for, and the one new finding
(section 4.1) is a gate-design input, not a bug row. One defect W1 (two
off-by-one line citations in the plan's section 3; it does not change the
0-row verdict). Notes N1-N5.**

Reviewed sha: `65c18f5739debcd2052e53e3a5e9e8aad49b2a65`. The plan's base is
`e46621014` ("One sha" line; `origin/master` at the planner's fetch, unchanged
at 03:57Z); `Window: W=2026-11-22T04:08:54+02:00` (commit `b220e7464`).
origin/master at my first fetch: `c24e47b1c` (04:0xZ, the r87 plan docs landed
after the planner's fetch) — see N1. All checks run on <box2>,
2026-11-22 04:10Z..04:26Z, unless a line says otherwise. Every command below was
run by me; its output is quoted as printed. Every file:line I cite was printed
with `git show <sha>:<file> | sed -n <N>p` first.

## Check 1 — slug b37 unused since the plan's `Window: W=`

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b36-plan')` ->
  `W=2026-11-22T04:08:54+02:00`, commit
  `b220e7464fa329ab7ab625dd733b83162f4086d5` (`docs(b36-plan, SPL-6216): ...`)
  — the value the plan records.
- `git log origin/master --since="$W" --oneline -E --grep='\(b37-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b37-[0-9]{2}|bug-round-37'` ->
  `65c18f5739debcd2052e53e3a5e9e8aad49b2a65\trefs/heads/review/c002-bug-round-37-planner`
  only — the planner's branch, expected. This seat's review branch did not
  exist yet at this check. Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b37-[0-9]{2}|bug-round-37'` ->
  `c002-bug-round-37-planner.md` only (3277 briefs total). This seat's brief
  lives in `/var/spool-hub/spawn-remote/briefs/`:
  `grep -l 'bug-round-37' /var/spool-hub/spawn-remote/briefs/*.md` ->
  `53287d24-...md` (the planner's) and `fba1e2c1-...md` (this brief) — both
  expected.
- `git worktree list | grep -E 'b37-[0-9]{2}|bug-round-37'` ->
  `/opt/csi/csi-spl-wt/c-248 ... [c-248-c002-bug-round-37-planner]` and
  `/opt/csi/csi-spl-wt/m-261 ... [m-261-c002-bug-round-37-mistral-panel-seat]`
  — the planner's and this seat's, both expected.

## Check 2 — CI: the plan's wf 10 claims re-run

- `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate`
  (04:1xZ) -> `== 10_ci-quality.yml on master -- last 100 run(s),
  2026-11-21T09:12:31Z .. 2026-11-22T03:45:38Z` — the same window the plan
  quotes — `51 success / 34 cancelled / 15 failure` (the plan read 48 success
  + 3 running at 03:49Z; the 3 completed as success, see N2).
- First red per job over the 15 failed runs: `wui: browser e2e 3/8` x8,
  `6/8` x6, `1/8` x6, `orc: hermetic action tests 4/4` x2, `wui 4/8` x1 —
  exactly the plan's counts.
- Timeout headroom: every job `ok`, p90 under 75 % of its timeout; the highest
  `orc: hermetic ... 1/4` and `3/4` at 57 % — as the plan says.
- Last green per failed job: `44982077734 e4662101 2026-11-22T03:45:38Z` for all
  five (the plan read `44977527180 b220e746 02:45Z` while 3 runs were still
  running — consistent, N2). Newest failure in the window: `44952643663
  2026-11-21T21:39:11Z f6703d2b`, so wf 10 is green from `e4b824abe` (23:24Z)
  on — the plan's claim holds.
- Each red's landed fix, all ancestors of `origin/master`
  (`git merge-base --is-ancestor` rc 0) with matching subjects:
  `75acaab9f fix(wui, SPL-6205): ... topic-menu-parity knows Export topic to
  PDF` (the `d2557fbc4`..`61977111c` 1/8, 3/8, 6/8 reds),
  `acf2b4555 test(wui, SPL-6143): move-by-drag step 6 ...` (the 12:xxZ 3/8, 4/8
  reds), `c7c2247b6 chore(orc, SPL-6152): tf-030 importer covers
  ...hub_self_sign (master red at 54dcbdae5)` (the 11:xxZ hermetic 4/4 red).
  No red job without a landed fix.
- Other workflows since 2026-11-21T22:00Z
  (`gh run list -L 300 --json ... | jq` filtered): exactly one non-success,
  non-skipped run — `00 ops: spool hub deploy lag watch` `44967708480`
  failure `2026-11-22T00:39:45Z` on `cd1c499ee`, then success at `01:18:10Z`,
  `02:23:13Z`, `03:20:19Z` (and `04:19:36Z`) — as the plan says.
- Source 1's claim: `git log origin/master --since="2026-11-22T04:08:54+02:00"
  --format=%s | grep -cE '^fix\('` -> `1`, and it is `cdf8f5074 fix(api,
  SPL-6224): logServerError writes its 5xx line as the literal ev.Msg("http
  5xx") again ...` — the one fix since W, fixing the `316422e7c` feat of the
  same lane. Holds.
- Source 3's claim: `git diff 1685e0ebe e46621014 -G
  '(t\.Skip|test\.skip|\.skip\(|ci-skip\.txt)' --stat` -> 1 file,
  `csi-spl-doc/doc/md/bug-round-36-plan.md | 297 +++...` (its quoted grep) —
  no test switched off. Holds.

## Check 3 — the e2e cut (plan section 4.1): rc01.sh extracted, hashed, run

- Extracted the plan's one ```bash block:
  `awk '/^```bash$/{f=1;next} /^```$/{if(f){f=0}} f' <plan> > rc01.sh` ->
  `2706` bytes, `sha256sum` -> `a76d454d20ea8dd3cdffc7eee6061ebb46353c4eb0ce7be5706bc799b40c4307`,
  first 12 hex `a76d454d20ea` — the plan's claim.
- Ran in a scratch copy: `git clone -q --shared /opt/csi/csi-spl-wt/m-261
  /tmp/rc01-scratch`, then from there:
  - `bash rc01.sh e46621014` -> `rc01 keys: got=exact-only want=has-prefix` /
    `rc01 sel: got=cut 37 want=selected` / `rc01 ctrl: got=selected
    want=selected` / `rc01 sha=e46621014 keys=[msg-menu] wrong=2`, exit 1 —
    the plan's table row, verbatim.
  - `RC01_PLANT=1 bash rc01.sh e46621014` -> `rc01 keys: got=has-prefix
    want=has-prefix` / `rc01 sel: got=cut 46 want=selected` / `rc01 ctrl:
    got=selected want=selected` / `rc01 sha=e46621014 keys=[msg-menu msg-menu-]
    wrong=1`, exit 1 — the plant raises the test from 37 to 46 and it is still
    cut, as the plan says.
  - `bash rc01.sh d2557fbc4` -> `rc01 sha=d2557fbc4 keys=[msg-menu] wrong=2`,
    exit 1 — as the plan says.
- The plan's reading holds: a narrow fix (the prefix key) cannot turn `sel`
  green — the cap (6 files) still cuts `topic-menu-parity.test.mjs` — so this
  is a gate-design input, not a bug row. The `keys` half alone would be
  correct but ineffective, exactly as the plan argues.
- Live state: the script touches none. Read in full: `mktemp -d` + `trap 'rm
  -rf -- "$T"' EXIT`, `git clone -q --shared --no-checkout` of the checkout it
  runs from into `$T`, `checkout` of the sha inside the clone, then read-only
  sourcing of `check-pre-push-e2e.func.sh` and `WUI_E2E_RANGE=... ./run -a
  do_check_pre_push_e2e` inside the clone. No network, no hub call, no push,
  nothing installed (python3 only for `RC01_PLANT=1`, inside the temp clone).
- The plan's file:line citations, printed on `e46621014`:
  - `git show e46621014:csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh |
    sed -n '119p;127p'` -> `_ppe_keys() {` / `}` (the function spans 119-127);
    `sed -n '186p;187p'` -> `# exact keys end at a non-testid character; a
    prefix key ("x-") need not` / the `pat` build — the `_ppe_score` cite
    `:186-188` holds.
  - `git show e46621014:csi-spl-wui/src/components/MessageMenu.vue | sed -n
    14p` -> `    testid="msg-menu"` — holds.
  - `git show e46621014:csi-spl-wui/src/components/UiPointMenu.vue | sed -n
    50p` -> `            :data-testid="testid + '-' + item.id"` — holds.
  - `git show e46621014:csi-spl-wui/src/utils/msg-menu.mjs | sed -n 129p` ->
    `    if (o.topicPdf) items.push({ id: 'export-topic-pdf', ... })` — holds.

## Check 4 — inputs accounted for

- The candidates file `/var/spool-hub/dispatch/c002-next-round-candidates.md`
  is on sat, not on this box: `ls` here -> No such file or directory. NOT RUN
  directly on <box2>; read via the holder's archived answer (c-002@sat, msg
  `53225b14`, 03:52Z, in c-248's archive on this box): `wc -l` -> `110`, "No
  line after 110, so there is no new candidate entry, bug-shaped or
  otherwise" — the plan's "110 lines, unchanged, the holder's read" holds.
- The b36 plan's "first inputs for round 37" row (section 7 of
  `bug-round-36-plan.md` on origin/master) names five inputs; each appears in
  the b37 plan: the R7 notes of b36-01/b36-02 -> section 3; the e2e cut ->
  section 4.1 (check 3 above); SPL-6174's relay-hash link -> section 4 row 2
  (re-checked: `git log origin/master --since=2026-11-21T20:00Z --format='%h
  %s' | grep -iE 'SPL-6174|relay'` -> empty, 0 matches — no writer named);
  b34-01 N2 -> section 4 row 3; every item carried in b36 section 4 ->
  section 4 row 4 ("As round 36 read them. Carried.").
- The b36 rows' R7 notes, read in the retired outboxes on this box:
  g-158 FAIL `1c75262c88fd...` with `W1 csi-spl-orc/src/bash/run/spl-spawn-share.func.sh:229`,
  then PASS `48ca10bea9858...` with `read: ... section 15 dotdot seat stays
  feature ...`; g-161 PASS `3e0bd6619aec8...` with N1 (`:95` optional opening
  quote, no closer, no end anchor), N2 (`:66` full-line comment skipped, inline
  comment and quoted tag matched), N3 (author brief absent, `ls` exit 2). The
  b37 plan's section 3 re-reads all of them correctly: W1 fixed in
  `b2a96ef8f` (`fix(b36-01-..., SPL-6221): the share never reads a seat brief
  through a slug with / or ..`, on master), N1/N2 fail closed, N3 a process
  input. No defect among them.
- No bug-shaped input is neither served nor accounted for.

## Check 5 — R3: lane map on the plan file

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
  --check csi-spl-doc/doc/md/bug-round-37-plan.md --agent m-261` (04:1xZ) ->
  exit 3: `csi-spl-doc/doc/md/bug-round-37-plan.md owned by c-248@<box2>
  c-248-c002-bug-round-37-planner (changed in its worktree; no files
  recorded)` — the planner owns the plan, expected; this seat touches only its
  own seat file.
- Same check on this seat's path
  `csi-spl-doc/doc/md/bug-round-37/seat-mistral.md` -> exit 4: `unknown:`
  lanes with no files recorded — c-035@sat (SPL-5882 T3 hub errors), c-054@sat
  (s154 B7 contacts scope), c-894@sat (s184 H1 hub agent model), g-080@sat
  (rotate), m-085@sat (r87 mistral panel seat) — none plan- or
  selector-shaped; the plan's own 03:57:01Z run listed the same four sat lanes
  before m-085 spawned (N5).
- Queue: `cd csi-spl-orc && SPOOL_ROOT=/var/spool-hub ./run -a
  do_spl_spawn_queue` (04:2xZ) -> `2 queued, 0 placing` (r87-02 row,
  SPL-5882 T4) — the plan read `0 queued, 0 placing` at 03:47:54Z; neither
  queued brief is b37-shaped (N4).

## Check 6 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (04:2xZ) -> all `ok -`
  lines, `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-261`, exit 0.

## Defects W

- **W1** — plan section 3 (the b36-02 g-161 N1/N2 rows) cites
  `csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh:94` for
  `SPL_CBR_ESTATE_RX` and `:65` for `SPL_CBR_INLINE_VAULT_RX`. On the plan's
  own line-number sha `e46621014` (section 1: "Line numbers are as of
  `e46621014`"): `git show e46621014:<file> | sed -n '94p;95p'` -> line 94 is
  the comment `# read: a header may say what the set leaves out.` and line 95
  is `SPL_CBR_ESTATE_RX='...'`; `sed -n '65p;66p'` -> line 65 is the comment
  `# An inline vaulted value: ...` and line 66 is `SPL_CBR_INLINE_VAULT_RX='...'`.
  The correct lines are `:95` and `:66` — g-161's own notes cite exactly those
  (`:95`, `:66`). Off by one in both citations; the described regex behaviour
  (optional opening quote, no closer, no end anchor; full-line comment skipped)
  is accurate at the real lines. Does not change the 0-row verdict; fold the
  two line numbers into v1.0.

## Notes

- **N1**: origin/master moved after the planner's fetch: `e46621014` (03:57Z)
  -> `c24e47b1c` (04:11:40Z, the r87 plan docs `a9731a592`, `c18a4ba46`,
  `c24e47b1c`). The plan's "unchanged at 03:57Z" was true at its read. The
  review branch head is still the named v0.1 sha `65c18f57...`; all counts
  re-run now (checks 1-2) still match the plan.
- **N2**: the wf 10 100-run window is identical to the plan's
  (`2026-11-21T09:12:31Z .. 2026-11-22T03:45:38Z`) but now reads 51 success /
  34 cancelled / 15 failure: the plan's "48 success, 3 running" was read at
  03:49Z while 3 runs were still running; they completed as success, and the
  last green per failed job is now `44982077734 e4662101 03:45:38Z` instead of
  `44977527180 b220e746 02:45Z`. Consistent, not a defect.
- **N3**: the candidates file lives on sat; on <box2> it is NOT RUN directly
  (`ls /var/spool-hub/dispatch/c002-next-round-candidates.md` -> No such file).
  Its content was read through the holder's archived answer (msg 53225b14:
  110 lines, no entry after line 110), which is the read the plan itself
  quotes.
- **N4**: the spawn queue now holds 2 asks (r87-02, SPL-5882 T4) vs the plan's
  `0 queued, 0 placing` at 03:47:54Z — a time difference; neither is b37-shaped.
- **N5**: the plan's lane-map run (03:57:01Z) listed 4 no-file sat lanes; the
  same check now lists 5 (m-085, the r87 panel seat, spawned after) — a time
  difference; none owns the plan or this seat file.
