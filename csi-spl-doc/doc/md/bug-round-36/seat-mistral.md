# Bug round 36 — panel seat mistral (m-011@sat)

Issue: SPL-6216 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-36-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-36-plan.md` on branch
`review/c002-bug-round-36-planner`, at the plan version sha
`83f118d359003bc6b99c5de7691f050e65e61069` (v0.1). The sha is named by the
planner (c-009@sat, result on `dispatch-bug-r36` 22:58:05Z: "plan v0.1
`83f118d359003bc6b99c5de7691f050e65e61069` on `review/c002-bug-round-36-planner`")
and sent by the dispatch holder (c-002@sat, task msg `da4d0261` 22:59:13Z on
`dispatch-bug-r36`); `git ls-remote origin refs/heads/review/c002-bug-round-36-planner`
-> exactly that sha. The branch is one docs commit on `e69ffe2f9`:
`git diff --stat 83f118d35^ 83f118d35` -> `csi-spl-doc/doc/md/bug-round-36-plan.md | 273 +++...`,
1 file changed. Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to 3 and
5 (3.2: the panel signs the plan sha; 5.1: 1 to 3 rows; 5.3 numbering and
window; 5.4 bugs priority 2). Form: `csi-spl-doc/doc/md/bug-round-35-plan.md`
and `csi-spl-doc/doc/md/bug-round-35/seat-mistral.md` on origin/master.

**Verdict: PASS on `83f118d359003bc6b99c5de7691f050e65e61069` (v0.1). No W.
Notes N1-N5.**

Reviewed sha: `83f118d359003bc6b99c5de7691f050e65e61069`. The plan's base is
`1685e0ebe` ("One sha" line); `Window: W=2026-11-21T15:44:45+02:00` (commit
`962628106`). origin/master at my first fetch: `e69ffe2f9` (22:57Z); it moved
once more during the review to `61977111c` (23:05Z, r86-02 landed) — see N1.
All checks run on sat, 2026-11-21 22:52Z..23:05Z, unless a line says otherwise.
Every command below was run by me; its output is quoted as printed.

## Check 1 — slug b36 unused since the plan's `Window: W=`

- `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b35-plan')` ->
  `W=2026-11-21T15:44:45+02:00` (commit `962628106`), the value the plan records.
- `git log origin/master --since="$W" --oneline -E --grep='\(b36-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b36-[0-9]{2}|bug-round-36'` ->
  `83f118d359003bc6b99c5de7691f050e65e61069\trefs/heads/review/c002-bug-round-36-planner`
  only — the planner's branch, expected. This seat's review branch did not exist
  yet at this check. Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b36-[0-9]{2}|bug-round-36'` ->
  `c002-bug-round-36-mistral-panel-seat.md` and `c002-bug-round-36-planner.md`
  — this brief and the planner's, both expected. 0 row briefs.

## Check 2 — every site file:line on the plan's base sha and on origin/master

Row files: `csi-spl-orc/src/bash/run/spl-spawn-share.func.sh`,
`csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh`,
`csi-spl-doc/doc/md/fleet-rules-index.md` (row 01);
`csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh`,
`csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh` (row 02).
Read-only cited: `csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh`,
`csi-spl-orc/src/bash/run/spl-spawn-place.func.sh`,
`csi-spl-iac/src/ansible/customer-box/`.

- `git diff --name-only 1685e0ebe origin/master -- <the five row files>` ->
  empty at 23:05Z (origin/master then `61977111c`): no row file drifted. The
  full base..master diff names only `pre-push-gate.md`,
  `check-pre-push.func.sh`, `check-pre-push-interrupt.tst.sh`,
  `dispatch-rotate-cron.sh`, `orch-rotate-cron.sh`, `rotate-cron.inc.sh`,
  `dispatch-rotate.tst.sh`, `orch-rotate.tst.sh`, `agent_drop.go`,
  `queue_health.go` — none a row file.
- Every cited line printed with `git show <sha>:<file> | sed -n <N>p` at
  `1685e0ebe`, at `origin/master` `e69ffe2f9`, and re-spot-checked at
  `61977111c`; all exist and are identical on all three refs:
  - `spl-spawn-share.func.sh:146` `| ([$asks.asks[] | select(.state == "done" and ((.reason // "") | test("^placed: ")) and (.class // "") != "")`;
    `:147` `| {key: (.reason | sub("^placed: "; "") | split(" ")[0]), value: (.class | cls)}] | from_entries) as $placed`;
    `:149` `| {id: $id, class: ($placed[$id] // ($briefs[$id] // "" | cls) | if . == "" then "unknown" else . end)}] as $l`;
    `:63` `spl_spawn_share() {`; `:75` `}`; `:192` `spl_spawn_share_briefs() {  # LANES`; `:202` `}`.
  - `spl-spawn-enqueue.func.sh:133` `  [[ "$flag" != bypass || "$class" == feature ]] || ! spl_spawn_q_review_seat_go "$place" "$bymsg" || seat=1`;
    `:138` `  if [[ -n "$seat" ]]; then  # the hub flags bypass on a feature only (rdb 0195): ... (SPL-5638)`;
    `:140` `    class=feature`; `:276` `SPL_SPAWN_REVIEW_SEAT_GO=994f2257-8ad1-4010-88c8-4f0a16230937`;
    `:193` `  { [[ ! -s "$brief" || -z "$(tail -c1 "$brief")" ]] || printf '\n'; printf 'Issue-Role: shared\n'; } >>"$brief" ||`.
  - `spl-spawn-place.func.sh:1466` `spl_spawn_place_brief() {  # SLUG`.
  - `spl-customer-box-role-check.func.sh:3` `# @description Spec 181 row B6 (spec 122 4 point 4): prove the customer box`;
    `:8` `# @description   vault       an Ansible Vault file (its content is unreadable)`;
    `:23` `# @description It is a ban list: it cannot prove absence. It never sees the`;
    `:26` `# @description anything Ansible decrypts; review stays the check for those.`;
    `:65` `    if head -c 14 "$f" 2>/dev/null | grep -F '$ANSIBLE_VAULT' >/dev/null; then`;
    `:82` `SPL_CBR_ESTATE_RX='...|delegate_to:[[:space:]]*(localhost|127\.)|local_action|connection:[[:space:]]*local|...'`.
  - `customer-box-role-set.tst.sh:10` `#   3. CONTROLS on a copy of the set, each one refused by its check name: a`.
  - `fleet-rules-index.md` SPL-1817 row present (`git grep -n 'SPL-1817' ... fleet-rules-index.md` -> the row, naming `spl-spawn-share.func.sh` and the bands).
  - Section 4 cites: `store/topic_loop_postgres.go:183` `fires_in_hour = CASE WHEN hour_start IS NULL OR ...` and `:189` `AND (hour_start IS NULL OR ... OR fires_in_hour < $4)`;
    `spool-fleet-relay.sh:210` `TASK="$(python3 -c 'import sys, uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool-task:" + sys.argv[1]))' "$TASK")" ||`;
    `hub/lanes_registration.go:78` `return uuid.NewSHA1(uuid.NameSpaceURL, []byte("spool-task:"+name)).String()`;
    `spawn-core.inc.sh:285` `# or a lane's report task), which the hub resolves in the workspace that holds`;
    `:300` the task-uuid grep; `store/issue_discussions.go:121` `// a task name (uuid5 "spool-task:<name>"), never a discussion (spec 153 3.11).`;
    `:122` `var RelayTaskHashRe = regexp.MustCompile(...)`;
    `bug-round-31-plan.md:204` the spec 181 B6 R7 row.

## Check 3 — each red control: read, sha256, run on the base, last line + exit code

- `sha256sum /var/spool-hub/dispatch/b36-red-controls/rc01.sh rc02.sh` ->
  `4892e3219bbca40100b5c45987934a2a1cd9d82e02a6f88744486585ba87bbce  rc01.sh`
  (4292 B) and
  `f951e08671e80b9b1e6090ef9984b4c57fbf256e048e216a1297c10549bfc10f  rc02.sh`
  (3262 B). First 12 hex `4892e3219bbc` / `f951e08671e8` — exactly the values
  the plan prints in section 3.2, so the files on disk are the scripts the plan
  printed; I also read both scripts in full.
- `bash /var/spool-hub/dispatch/b36-red-controls/rc01.sh 1685e0ebe`, n=2
  (23:0xZ), from this checkout: both runs exit 1, last line
  `rc01 sha=1685e0ebe by={"refactor":0,"bug":1,"feature":3} wrong=2`, with
  `rc01 seat: got=feature want=bug` / `rc01 xbox: got=feature want=refactor` /
  `rc01 ctrl: got=feature/bug want=feature/bug`. `bash rc01.sh f6703d2b1` ->
  exit 1, `rc01 sha=f6703d2b1 by={"refactor":0,"bug":1,"feature":3} wrong=2`.
  `RC01_PLANT=1 bash rc01.sh 1685e0ebe` -> exit 1,
  `rc01 seat: got=bug want=bug` / `rc01 xbox: got=feature want=refactor` /
  `rc01 ctrl: got=feature/bug want=feature/bug` / `... wrong=1` — the half fix
  the plan describes (seat green, xbox still red).
- `bash /var/spool-hub/dispatch/b36-red-controls/rc02.sh 1685e0ebe`, n=2:
  both runs exit 1, last line `rc02 sha=1685e0ebe wrong=3`, with
  `rc02 dq: got=passed want=refused` / `rc02 sq: got=passed want=refused` /
  `rc02 ivault: got=passed want=refused` /
  `rc02 ctrl: got=refused/passed want=refused/passed`. `bash rc02.sh 3f33e9dab`
  -> exit 1, `rc02 sha=3f33e9dab wrong=3`. `RC02_PLANT=1 bash rc02.sh 1685e0ebe`
  -> exit 0, `rc02 sha=1685e0ebe wrong=0`.
- Both fail for the reason the plan gives (row 01: the ask's class wins over
  the brief's; row 02: the quoted spellings and the inline `!vault` pass), not
  for an environment reason — the controls' own `ctrl` cases hold on every run.
- Live state: neither script touches any. Both make `mktemp -d` +
  `git clone -q --shared --no-checkout` of the local checkout, check out the
  sha inside the clone, and work only under `$T`; rc01 stubs `SPOOL_ROOT` to a
  temp dir and stubs the lanes/hub commands (`SPAWN_SHARE_LANES_CMD`,
  `ASKS_HUB_CMD`); rc02 copies the role set to temp dirs and runs the action
  with `CUSTOMER_BOX_ROLE_DIR` pointed there. No network, no hub call, no push,
  nothing installed (read in both scripts; sha256 above matches the plan's
  printed copies).

## Check 4 — root cause of each row, read at the cited lines

- Row 01: `spl-spawn-share.func.sh:146-147` builds `$placed` from the asks'
  `.class` of every done "placed:" ask; `:149` then reads
  `$placed[$id] // $briefs[$id]` — the ask's class wins over the brief's.
  `spl-spawn-enqueue.func.sh:133` marks a review seat (`seat=1`) and `:138-140`
  sets `class=feature` for it, keyed on the review-seat GO
  `SPL_SPAWN_REVIEW_SEAT_GO=994f2257-...` (`:276`). `spl_spawn_share_briefs`
  (`:192-202`) reads only `$ASKS_BOX`'s `lifetime/brief.md` files, so a seat on
  the other box has no brief source at all. The plan's reading holds; rc01
  proves it empirically (seat and xbox both counted `feature`).
- Row 02: `SPL_CBR_ESTATE_RX` (`:82`) anchors `delegate_to:[[:space:]]*(localhost|127\.)`
  and `connection:[[:space:]]*local` immediately after the spaces, so
  `delegate_to: "localhost"` and `connection: 'local'` (quote before the value)
  do not match; `spl_cbr_key_files` (`:65`) tests only `head -c 14` for
  `$ANSIBLE_VAULT`, so an inline `!vault |` value inside a vars file is unseen.
  The header (`:3-26`) says READ ONLY and that a ban list cannot prove absence.
  The plan's reading holds; rc02 proves it empirically (dq/sq/ivault pass).

## Check 5 — each row: R2 control, test list, vendor, kind, batch, R7, R1

- Row 01 and row 02 each have a control that fails today on `1685e0ebe`
  (rc01/rc02 RED, check 3) and can pass after (rc02 planted: `wrong=0` exit 0;
  rc01 planted: `seat` green, `xbox` still red — the plan reports this itself,
  so the row's fix must also resolve the cross-box seat from the queued brief
  in `dispatch/briefs`, see N4). The RED-then-GREEN proof on the real fix is the
  row lane's commit body (C2), as the plan says.
- Test column row 01: `git grep -l -E 'spl-spawn-share|spl_spawn_share' 1685e0ebe -- '*.tst.sh' '*/tests/*.sh'`
  -> the 11 files the plan lists (`spl-epic-stall-check.tst.sh`,
  `spl-reflection-gather.tst.sh`, `spl-security-round-queue.tst.sh`,
  `spl-spawn-after.tst.sh`, `spl-spawn-fill.tst.sh`, `spl-spawn-group.tst.sh`,
  `spl-spawn-place-argmax.tst.sh`, `spl-spawn-place-owner-prio.tst.sh`,
  `spl-spawn-place-supply.tst.sh`, `spl-spawn-queue.tst.sh`,
  `spl-spawn-share.tst.sh`). Matches.
- Test column row 02: `git grep -l -E 'customer-box-role-check|spl_cbr_|do_spl_customer_box_role_check' 1685e0ebe`
  -> `customer-box-role-set.tst.sh`, the action, `customer-box-playbook.yaml`,
  `bug-round-31-plan.md`. Matches.
- Vendor `claude`, kind `simple_coding`, batch 1 for both rows; R7 reviewer
  "grok seat on sat, else the claude waiver seat" — cross-vendor against the
  claude author (rulebook 2.7.2) or the waiver; never mistral, and no mistral
  coding or testing row exists in the plan. R1: batch 1's two rows share no
  file (row 01: two orc files + one doc; row 02: two iac files) —
  `git diff --name-only` sets are disjoint, confirmed from the row table.

## Check 6 — R3 lane map on the row paths

- `bash .../spawn-agents/scripts/lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-share.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-share.tst.sh,csi-spl-doc/doc/md/fleet-rules-index.md,csi-spl-iac/src/bash/run/spl-customer-box-role-check.func.sh,csi-spl-iac/src/bash/tests/customer-box-role-set.tst.sh --agent m-011`
  (23:0xZ) -> exit 4: `WARN no live lane lists <the five row files>, but 13
  live lane(s) record no files: their scope is unknown, not free`. The 13
  unknown lanes are all on `<box2>`: c-028, c-063, c-101, c-146, c-806
  (SPL-6182 native auth), c-812, c-855, c-924, c-927, g-050, g-079, g-108
  (rotations / topic seat / auth / r86 R7 seat m-035). I grepped each one's
  brief in `/var/spool-hub/dispatch/briefs` for
  `spl-spawn-share|spl-customer-box-role-check|customer-box-role-set|fleet-rules-index`
  -> 0 hits for all: none names a row file. Per the rule, exit 4 means ask
  first, never free; the plan asked the holder for the `<box2>` half (its
  section 8, ask 1).
- With the read-only files added
  (`...,csi-spl-orc/src/bash/run/spl-spawn-enqueue.func.sh,csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-doc/doc/md/bug-round-36-plan.md`)
  -> exit 3: `csi-spl-doc/doc/md/bug-round-36-plan.md owned by c-009@sat` (the
  planner, expected) and
  `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh owned by c-012@sat
  c-012-bug-alerts-seat-held-names-issue-and-seat-r2 (changed in its worktree;
  no files recorded)`. I read c-012's worktree: uncommitted modifications to
  `spl-spawn-place.func.sh`, `spl-spawn-queue.tst.sh` and
  `specs/157-dispatch-automation/spec.md`. Row 01 marks
  `spl-spawn-place.func.sh` read-only, so this is no conflict with the row's
  own scope — see N2.

## Check 7 — inputs accounted for

- `/var/spool-hub/dispatch/c002-next-round-candidates.md` -> 110 lines at
  22:52Z, the count round 35 read (no entry since).
- The plan's "not rows" list (its sections 4 and 5) against the file's
  "next BUG round" and "Bug-shaped" entries: each is either served or carried
  with a verdict in the chain b36 -> b35 section 5 -> b34 section 5 -> b31
  section 5. Spot-verified served: `git log origin/master -E --grep='\(b(20-01|22-02|27-01|27-02|28-01|29-01|29-02|30-01|30-03|31-01|31-02|32-02|33-01)-'`
  -> 16 commits, among them `6f2a343bb fix(b30-03-orc-after-slug-far-box-key, SPL-6129)`
  and `22f50f64f fix(b33-02-orc-quota-token-key-private, SPL-6168)`;
  `git show origin/master:csi-spl-orc/src/bash/run/spl-spawn-after.func.sh | sed -n 67p`
  -> `  if [[ -z "$k" && -r "$f" ]]; then` — the `li_key_of_agent` call that
  dropped the `@box` is gone. b31 section 5 lines 207-208 carry the
  reflection's unanswered-sweep detector rows A/B, the `/tmp` worktrees
  (b30-02), `unanswered-sweep.tst.sh` section 12 (`74bd535d8`), the kept weekly
  reading (b29-01) and the rest as served or not-bugs.
- b35's "first inputs for round 36" row (`git show origin/master:csi-spl-doc/doc/md/bug-round-35-plan.md | sed -n 181p`)
  names the R7 notes of b34-01/b34-02, SPL-6174's relay-hash link, the other
  parts of the pre-push gate, and round 34's carried items — all four appear in
  the b36 plan's section 4 (b34-01 N1-N3 and b34-02 N1-N2 rows, the SPL-6174
  `3e2c61b1` row with the relay code cites verified in check 2, the pre-push
  gate row, and the carried-items row).
- The b34 rows' R7 N notes (c-855 N1-N3 + line fix db7a8207; c-823 N1-N2, read
  on `dispatch-bug-r34` 22:52Z) are accounted in b36 section 4: N1/N3 not bugs,
  N2 test-shaped, c-823's N1-N2 not bugs.
- The two bug-shaped inputs the plan serves are its rows: the share-counts-R7-
  seat candidate (added to the planner's brief, c-001 msg e9b303da) -> row 01;
  spec 181 B6 R7 c-502 N1-N2 -> row 02 (N3-N4 explicitly named out of scope in
  section 5).
- No bug-shaped input of the candidates file is neither served nor accounted
  for. The plan's CI source (100 runs) I did not re-run (a minutes-long
  background job); its one open-red claim is checkable cheaply and checks out:
  `git ls-remote origin | grep topic-pdf` ->
  `e928128e5...\trefs/heads/review/c003-wui-topic-pdf-all-posts-fix` (c-934's
  fix-forward, as the plan says).

## Check 8 — distribution hygiene

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (22:44Z and again 23:04:53Z)
  -> `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-011` (all `ok -` lines, no finding).

## Defects W

None.

## Notes

- **N1**: origin/master moved twice while I reviewed (`1685e0ebe` ->
  `e69ffe2f9` at 22:57Z -> `61977111c` at 23:05Z). The plan's base sha is
  unchanged and the row files did not drift
  (`git diff --name-only 1685e0ebe origin/master -- <row files>` empty at
  23:05Z); the cited lines were re-printed on `61977111c` and are identical.
- **N2**: `lane-map.sh --check` exits 3 when the read-only
  `spl-spawn-place.func.sh` is included: c-012@sat has it modified in its
  worktree right now. Row 01 treats the file as read-only, so the row's own
  scope is disjoint; the row lane must simply not write it while c-012 is
  live.
- **N3**: the lane map's exit 4 on the row files lists 13 unknown lanes, all
  on `<box2>`; I could not read `<box2>` worktrees from sat, but the map
  itself covered every machine, and none of the 13 briefs names a row file
  (grep 0 hits). The plan's section 8 ask 1 (the `<box2>` half of R3) goes to
  the holder.
- **N4**: rc01's planted half-fix leaves `xbox` red (`wrong=1`, exit 1) — the
  plan says so itself. The row's fix must take the cross-box seat's class from
  the queued brief in this box's `dispatch/briefs` (the `xbox` case), not only
  from the lifetime brief; the control can turn fully green only with that.
- **N5**: the plan's section 2 source 2 (the 100-run CI report) was not
  re-run by me; I verified its consequence claims that are cheap to check (the
  open WUI red's owner branch exists, check 7). Everything else in the plan I
  re-ran or re-read myself.

## v1.0 signature

**PASS on `aae0f987eaa83c75d6cbc322fac1c005948da834` (v1.0).** The sha is named
by the editor c-009@sat (result on `dispatch-bug-r36` 23:12:22Z: "plan v1.0
LANDED: `aae0f987e...`") and is on origin/master:
`git merge-base --is-ancestor aae0f987eaa83c75d6cbc322fac1c005948da834 origin/master`
-> rc 0; `git log -1 --format='%H %s' aae0f987e` ->
`aae0f987eaa83c75d6cbc322fac1c005948da834 docs(b36-plan, SPL-6216): bug round 36 plan v1.0: panel m-011 (mistral) PASS on v0.1 83f118d35, no W; ...`.
Checks re-run by me on sat 2026-11-21 23:16Z..23:18Z:

- v1.0 is v0.1 rebased (`b64a27da3`) plus one commit: `git diff --stat b64a27da3 aae0f987e`
  -> the plan file (33 lines) and this seat file (265 lines added), nothing
  else. The plan diff changes only the Status line, section 8 and the
  consensus table; the row table is unchanged (no row changed).
- The folded seat file is blob-identical to my push:
  `git rev-parse aae0f987e:csi-spl-doc/doc/md/bug-round-36/seat-mistral.md`
  -> `ccb01bc7daf7de5eac001d414a074ee3afff74fd`;
  `git rev-parse a01e164cf:csi-spl-doc/doc/md/bug-round-36/seat-mistral.md`
  -> `ccb01bc7daf7de5eac001d414a074ee3afff74fd`. Equal.
- Slug at v1.0: `git log origin/master --since="$W" --oneline -E --grep='\(b36-'`
  -> the two plan commits only (`b64a27da3`, `aae0f987e`, both `docs(b36-plan`);
  row ids `git log origin/master --since="$W" --oneline -E --grep='\(b36-[0-9]{2}-' | wc -l`
  -> `0`. `git ls-remote origin | grep -E 'b36-[0-9]{2}|bug-round-36'` ->
  `review/c002-bug-round-36-planner` `83f118d35...` and
  `review/c002-bug-round-36-mistral-seat` `a01e164cf...`, both expected.
  `ls /var/spool-hub/dispatch/briefs | grep -E 'b36-[0-9]{2}|bug-round-36'` ->
  the two round briefs plus the two row briefs `c002-b36-02-...md` and
  `hand-sat-c002-b36-01-...md` (the queued rows, expected).
- Row files: `git diff --name-only 1685e0ebe aae0f987e -- <the five row files>`
  -> empty; cited lines re-printed on `aae0f987e` are identical to the base
  (spot: `spl-spawn-share.func.sh:149`, `spl-customer-box-role-check.func.sh:82`).
- Red controls on the unchanged base, n=1 each at 23:1xZ:
  `bash rc01.sh 1685e0ebe` last line
  `rc01 sha=1685e0ebe by={"refactor":0,"bug":1,"feature":3} wrong=2` (exit 1 in
  the direct runs at 23:0xZ); `bash rc02.sh 1685e0ebe` last line
  `rc02 sha=1685e0ebe wrong=3` (exit 1). Still RED for the plan's reason.
- `lane-map.sh --check <the five row files> --agent m-011` (23:17Z) -> exit 4,
  same 13 no-file lanes (all on `<box2>`), no live lane lists a row file.
  `do_spl_spawn_queue` (23:17Z) -> `7 queued, 0 placing`; each of the two
  queued row briefs names only its own row file (grep 1 hit each).
- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (23:17:53Z) -> clean.

Verdict on v1.0: **PASS**, no W, notes N1-N5 stand.
