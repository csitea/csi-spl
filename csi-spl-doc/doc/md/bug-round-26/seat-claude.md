# Bug round 26 - panel seat claude (same-vendor panel, waiver 1a7c70da)

Seat: c-811@`<box2>` (claude), fresh session, ask ff933b29. Same-vendor panel
under waiver 1a7c70da (c-001 ruling 41f53f3c), this seat only; not a
cross-vendor panel (rulebook 3.2 asks one; the waiver stands in for it).

Plan read: `csi-spl-doc/doc/md/bug-round-26-plan.md` at
**`fb96fa9cf7a4e9d011d87e6426b352fb461c87ef`** (v1.0, head of
`review/c002-bug-round-26-planner`; named to this seat by the planner c-789
in msg 05835b21 and by the holder c-002@sat in msg 6aa906da, both in place
of the brief's `634c55bdf`). `git log --oneline 2f49bfad2..fb96fa9cf` ->
`fb96fa9cf`, `634c55bdf`, `b74379bcd`: three plan commits on the measured sha.

**Verdict: PASS on `fb96fa9cf`**, with one defect for the editor (W1, the
full-mode red control is not deterministic) that changes no row.

Run on `<box2>`, 2026-11-20 04:30Z to 04:4xZ, n=1 per command unless stated.
`origin/master` was `2453d5770` at the time: `git diff --name-only
2f49bfad2 origin/master` -> two orc files
(`spl-reflection-gather.func.sh` and its test), none of the row's.

## 1. Slug b26 unused

- `git log origin/master --oneline -E --grep='\(b26-[0-9]{2}' | wc -l` -> `0`
- `git ls-remote origin | grep -E 'b26-[0-9]{2}|bug-round-26'` ->
  `fb96fa9cf7a4e9d011d87e6426b352fb461c87ef refs/heads/review/c002-bug-round-26-planner`
  only (the planner's; this seat's branch did not exist yet).
- `ls /var/spool-hub/dispatch/briefs | grep -cE 'b26-[0-9]{2}|bug-round-26'` -> `0`.
  The briefs on this box live in `/var/spool-hub/spawn-remote/briefs/`:
  `grep -lE 'b26-[0-9]{2}|bug-round-26' /var/spool-hub/spawn-remote/briefs/*`
  -> 3 files: `a846a53c...` (the planner's brief), `1be15518...` (this
  seat's brief) and `005ba65a...`, whose one match is `b26-57ba-a`, a uuid
  fragment in a SPL-4496 brief, not a round id.
- `git worktree list | grep -E 'b26-[0-9]{2}|bug-round-26'` ->
  `/opt/csi/csi-spl-wt/c-789 fb96fa9cf [c-789-c002-bug-round-26-planner]`,
  the planner's own; 0 row worktrees.
- sat's half (c-002@sat 04:3xZ, per the brief): not re-read by this seat.

## 2. Sites file:line, on `2f49bfad2` and `origin/master`

For each range, `git show <sha>:<file> | sed -n <a>,<b>p | sha1sum` on both
shas compared -> `same=yes` for all six:
`blog.test.mjs:283-289`, `blog.test.mjs:318-332`, `sync-blog.mjs:279-284`,
`sync-blog.mjs:472-475`, `10_ci-quality.yml:701-713`,
`LanguageSwitcher.vue:290-305`. No drift.

Each line the row cites, read on `2f49bfad2`:

| cite | `sed -n <N>p` prints |
|---|---|
| `blog.test.mjs:286` | `const id = '2026-10-26-kids-human-experience'` |
| `blog.test.mjs:288` | `if (!has('en') \|\| ...some((e) => e.id === id)) { console.log(... the switcher steps did not run ...); return }` |
| `blog.test.mjs:319` | `/* search + keyboard, as in the app: type, Enter picks the one match */` |
| `blog.test.mjs:321` / `:324` | `await p.keyboard.type('bulg')` / `... p.keyboard.press('ArrowDown').then(() => p.keyboard.press('Enter'))` |
| `sync-blog.mjs:283-284` | `shallow clone counts every older post on its boundary day: stricter,` / `never looser.` |
| `sync-blog.mjs:472-473` | `const shallow = git(BLOG_REPO, ['rev-parse', '--is-shallow-repository'])` / the `blog: shallow clone - ...` warning |
| `sync-blog.mjs:475` | `for (const d of dropped) console.warn(... blog cap: ${d.id} not rendered ...)` |
| `10_ci-quality.yml:701` / `:713` | `wui-generate:` / `- uses: actions/checkout@11d5960a... # v4` (no `with: fetch-depth`) |

`git log -1 --format='%h %cI' 2f49bfad2 -- csi-spl-wui/tests/e2e/blog.test.mjs`
-> `4b79fdf1b 2026-10-27T23:48:55+02:00`: unchanged since the steps landed,
as the plan says.

## 3. The row is a real defect

CI, run 44663072878 (`schedule`, `f589257ba`, 2026-11-20T02:45:43Z,
`success`), read with `gh api repos/csitea/csi-spl/actions/jobs/<id>/logs`
(`gh run view --log --job` printed nothing here, N1):

- e2e job 136046749184 (`wui: browser e2e (mock, generated) 8/8`):
  `grep -n 'switcher steps did not run\|blog: all'` ->
  `602: (no 2026-10-26-kids-human-experience in this build: the switcher steps did not run)`,
  `603: blog: all 64 passed`. The plan's "log lines 601-603" holds.
- generate job 136045785355: `45: fetch-depth: 1`,
  `97: git ... fetch ... --depth=1 origin +f589257ba...`,
  `375: blog: shallow clone - every older post counts on the boundary day (a stricter cap)`,
  `376-383`: 8 `blog cap: ... not rendered (2026-11-20: over the cap of 7 a day (6 besides the digest))`
  lines, `380` is `2026-10-26-kids-human-experience`. The plan's "lines 375-383" holds.
- The other three dated runs, each e2e job's log
  `grep -c 'kids-human-experience in this build: the switcher steps did not run'`:
  run 40789509550 job 123171645852 -> 1; run 41741639331 job 126285440174
  -> 1; run 42536674714 job 128903068149 -> 1. n=4 dates, as the plan says.
  This seat did not re-read the 11-12..11-19 generate jobs (the plan's n=8).

Red control, rebuilt from section 3.2:
`git show fb96fa9cf:<plan> | awk '/^```bash$/{f=1;next} /^```$/{f=0} f'`
into a throwaway dir outside the tree; read whole before running.
`sha256sum` of the copy from `b74379bcd`, the copy from `fb96fa9cf` and
`/var/spool-hub/dispatch/b26-red-controls/rc01.sh` -> all three
`1cf2b13ed68dfcf3...`, 2609 B each. It installs nothing; it fetches the sha
into a `mktemp -d` under `/var/tmp`, hard-links the given node_modules and
deletes its dir on exit.
node_modules: `/opt/csi/csi-spl-wt/c-054/csi-spl-wui/node_modules`;
`git show 2f49bfad2:csi-spl-wui/pnpm-lock.yaml | cmp - <nm>/.pnpm/lock.yaml`
-> equal. Run as `<PUSH_USER>` from this seat's checkout, pnpm from that
user's PATH, node `v20.20.2`, `/usr/bin/google-chrome`.

- `bash rc01.sh 2f49bfad2 <nm>` (04:33:03Z to 04:35:04Z):

  ```text
  rc01 shallow=true
  rc01 blog cap dropped 8 post(s)
    (no 2026-10-26-kids-human-experience in this build: the switcher steps did not run)
  blog: all 64 passed
  rc01 sha=2f49bfad2 mode=shallow test-rc=0 switcher-skipped=1
  ```

  exit 1.

- `bash rc01.sh 2f49bfad2 <nm> full`, n=3 (each a fresh rc01 run; the
  e2e runner retries a failed file once):

  run 1, 04:35:04Z to 04:37:51Z, **green**, exit 0:

  ```text
  rc01 shallow=false
  rc01 blog cap dropped 0 post(s)
    OK   desktop: picking bg lands on /bg/blog/2026-10-26-kids-human-experience "<base>/bg/blog/2026-10-26-kids-human-experience"
    OK   phone: picking bg lands on /bg/blog/2026-10-26-kids-human-experience "<base>/bg/blog/2026-10-26-kids-human-experience"
  blog: all 93 passed
  rc01 sha=2f49bfad2 mode=full test-rc=0 switcher-skipped=0
  ```

  runs 2 (04:38:04Z to 04:43:35Z, load 8.49) and 3 (04:43:35Z to
  04:48:46Z, load 9.10), **red**, the same lines in both, exit 1:

  ```text
  rc01 shallow=false
  rc01 blog cap dropped 0 post(s)
    FAIL desktop: picking bg lands on /bg/blog/2026-10-26-kids-human-experience "<base>/blog/2026-10-26-kids-human-experience"
    FAIL desktop: there bg is the current language "🇬🇧 English"
    OK   phone: picking bg lands on /bg/blog/2026-10-26-kids-human-experience "<base>/bg/blog/2026-10-26-kids-human-experience"
    (the same three lines again: the retry)
    FAIL tests/e2e/blog.test.mjs (exit 1, then exit 1)
  rc01 sha=2f49bfad2 mode=full test-rc=1 switcher-skipped=0
  ```

Shallow mode matches the plan's section 3.2. Full mode matches it in 2 of
3 runs, and 4 of 5 desktop attempts failed (run 1 passed on its first
attempt). That is the rate the plan's own probe predicts (type, ArrowDown,
Enter picks bg 1 of 6). The defect is real; the full-mode control is not
deterministic (W1). The plan's 4-sequence key probe was not re-run by this
seat.

## 4. Fix scope

The row's fix column names one file, `blog.test.mjs`, and lists
`sync-blog.mjs`, the cap, wf 10's checkout and `LanguageSwitcher.vue` as
"No change" (row 01) and as read only / off limits (section 3.1). Held.

"Fail, never skip, when the build has no en post with a bg copy" keeps the
check honest on the shallow CI build, and does not make it red there:
`git ls-tree -r --name-only 2f49bfad2 csi-spl-doc/blog/posts` -> 31 `en`
and 29 `bg` files. Taking away the 8 ids in the generate job's `blog cap`
lines and intersecting with the bg ids
(`comm -23 en.ids drop.ids | comm -12 - bg.ids | wc -l`) gives `22` en posts
with a bg copy that the 11-20 shallow build kept. So the switcher steps get
a post on every build like today's, and only a build with no such post goes
red. That build would be a real loss, not a cap artefact. This count comes
from the tree and the CI cap lines, not from a built `index.json`; drafts
were not separated out (N2).

## 5. The row's form

- Defect: yes (section 3 above). Control fails today in both modes and the
  lane's green half is named (rc01 on the fix, both modes, exit 0) (R2): yes.
- Test list (3.1): `blog.test.mjs` through rc01, both modes;
  `blog-lang-switcher.test.mjs`; `public-seo.test.mjs`; typecheck; the e2e
  files the pre-push map selects: yes.
- Vendor claude, kind `tests`, batch 1: yes. No mistral coding or testing
  row: yes (WUI, developer guide 5.1).
- R7 reviewer: "claude waiver seat (1a7c70da) ... unless `do_spl_box_pick`
  picks grok": a waiver seat or cross-vendor, never mistral: yes.
- Sections 0, 8 and 9 name this panel seat "same-vendor panel, waiver
  1a7c70da" and c-001 msg 41f53f3c: yes; `git show fb96fa9cf:<plan> | grep -ci cross-vendor` -> 0, `grep -c 'waiver 1a7c70da'` -> 4.

## 6. Lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-wui/tests/e2e/blog.test.mjs --agent c-811`
-> exit `4`:
`unknown: c-212@sat c-212-c002-r72-01-api-move-message-req has no files recorded`,
`unknown: m-206@sat review/c002-refactor-round-72-mistral-seat has no files recorded`,
`WARN no live lane lists csi-spl-wui/tests/e2e/blog.test.mjs`.
No lane lists the file. The two unknowns are r72-01 (api `message_move`)
and the r72 mistral panel seat (its seat file). The plan's section 3.1
names both, and the planner read neither as a wui writer. The orchestrator
re-runs R3 before the spawn (plan section 6).

## 7. Sections 4 and 5: is each "not a row" backed by a measurement?

| item | backed? | this seat's check |
|---|---|---|
| done-claim `job` label | yes | `/var/csi/csi-spl/done-claim-check/cron.log`: `sed -n 53352p` -> `2026-11-20T02:55:01Z START done-claim-check`; `awk 'NR>=53352 && /START/ && $1<="2026-11-20T03:55:59Z"' \| wc -l` -> 13 runs; `awk 'NR>=53352 && /\talert\t/' \| wc -l` -> 0; `grep -cE 'job [0-9a-f]{6,}'` from that line -> 0 (21 runs to 04:35Z); every OK summary reads `0 alerted to c-002@sat`. sat's 19 runs: the holder's (msg 06fc7780), not re-read |
| `test-agent-name-shape.sh:89` | yes | `sed -n 89p` -> `hasnt "5. ... an unknown kind letter x-004 is no agent id (control)" "900006" "$out"`; the plan's "none names it" in the 100-run report was not re-run by this seat |
| AltGr (SPL-5850 N1) | yes | `kind-picker-keys.ts:45-50` is `letterOf` (`key`, then `Key<X>` from `code`); `:58` is the modifier guard (`altKey` refuses); `git log --oneline 82f0e0b0f..2f49bfad2 -- <file> \| wc -l` -> 0; `grep -rnil altgr csi-spl-doc --include=*.md` -> 6 round plans only. The owner-post count (0) was not re-run |
| ArrowDown on one match | yes, by the plan's probe | probe not re-run (section 3 above); the plan calls it a product question with no rule, which holds |
| reflection rows A/B | by the brief | "Not bugs: detectors (the brief)": a ruling, not a measurement; carried from round 24 |
| `fallback_postgres.go:83-86` | by the brief | `sed -n 83,86p` -> the `fallbackHumanPostSQL` query lines; "a test-coverage gap" is carried from round 24, not re-measured |

Also re-measured from sections 1 and 2: `git rev-list --count 82f0e0b0f..2f49bfad2`
-> 10; the skip grep `git diff 82f0e0b0f 2f49bfad2 -G '(t\.Skip|...)' --stat`
-> `repo_sync_gaps_test.go` (+101) and `bug-round-25-plan.md`; the window
`git log origin/master -1 --format='%h %cI' -E --grep='^docs\(b25-plan'` ->
`64b5499b0 2026-11-20T04:52:19+02:00`. All as the plan says.

## 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/c-811`.

## Defects

- W1. Plan section 3.2 (`fb96fa9cf`, line 68) and row 01's evidence and
  red control columns (line 48) report the full-mode control as red,
  "n=3, each red on the first run and on the runner's retry". On this seat
  `rc01.sh 2f49bfad2 <nm> full` was green in 1 of 3 runs (exit 0,
  `blog: all 93 passed`, section 3 above). The keyboard pick races Headless
  UI's active option, as the plan's own probe shows (section 5, line 126:
  ArrowDown then Enter picks bg 1 of 6). So: (a) section 3.2 should state
  the measured rate, not "red" alone; (b) the lane's red control "ArrowDown
  put back -> FAIL in full mode" (row 01 fix column) needs n>=3 runs with at
  least one FAIL, because one green there proves nothing; (c) the lane's
  green half, rc01 full on the fix exit 0, should also be n>=3, all green.
  No row changes: the defect and the fix stand.

## Notes

- N1. The brief's command `gh run view 44663072878 --log --job 136046749184`
  printed nothing on this box (exit 0, 0 lines). The same log came through
  `gh api repos/csitea/csi-spl/actions/jobs/136046749184/logs`. A seat or
  the R7 reviewer should use the `gh api` form.
- N2. The fix's "an `en` post that has a `bg` copy, e.g. the newest" should
  read the post list from the built `index.json` (as the row says) and not
  from git, so drafts and capped posts are already out. The count of 22 in
  section 4 above is from the tree and comes with that caveat.
- N3. The slug check of the brief and of the plan reads
  `/var/spool-hub/dispatch/briefs`, which holds 0 b26 briefs on this box;
  the spawn briefs are in `/var/spool-hub/spawn-remote/briefs/` (section 1
  above). The next round's plan should name both dirs.
- N4. Section 2 source 4 and section 4 rest on 13 runs on `<box2>`; at this
  seat's read the same log had 21 runs since line 53352, still 0 `job <hex>`
  lines and 0 alert rows.
