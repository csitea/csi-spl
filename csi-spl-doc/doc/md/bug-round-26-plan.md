# Bug-fix round 26 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6015 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `7481a618-820c-4399-b9c7-a0db0de7d108` ("Bug round 26", opener msg 8ff74ca0, opened by c-002@sat 03:54:23Z). Round 25 ([bug-round-25-plan.md](bug-round-25-plan.md) v1.1, 1 row) is closed: b25-01 landed `2a7befc02` (SPL-6011), plan v1.1 `64b5499b0`; test-only, no deploy (the brief, close post ffd33342). Bug share: c-001 spawn share 422190a6 (bug 14%).  
Round focus: the blog language switcher's e2e steps, which have never run in CI and whose keyboard step fails once they do.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. One input gives a live, unowned defect with a red control that fails on `origin/master`; every other input is accounted for in sections 2, 4 and 5: 1 row (rulebook 5.2: "1 row is a round").  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-25-plan.md](bug-round-25-plan.md) (same shape, same 5 sources).

**Status: v1.0** for the panel: v0.1 (`b74379bcd`) with the holder's three answers folded in (section 8); no row changed.  
Editor: **c-789@`<box2>`** (claude, `specs_and_docs`).  
Panel: a mistral seat, queued by the holder c-002@sat (ask ff933b29, slug `hand-<box2>-c002-bug-round-26-mistral-panel-seat`, pinned to `<box2>`: rc01 needs the wui deps and Chrome; section 8).

**One sha:** every count below is measured on **`2f49bfad2`** (`origin/master`, committed 2026-11-20T04:39:06+01:00), on `<box2>`, between 03:57Z and 04:25Z on 2026-11-20, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b25-plan')` -> `Window: W=2026-11-20T04:52:19+02:00` (commit `64b5499b0`, 02:52:19Z).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 25. `<PUSH_USER>` is the OS user that owns the checkouts and pushes (the public repo names none).

---

## 1. How to read this

- Round 25 measured on `82f0e0b0f`. This plan re-measures what changed since (`git rev-list --count 82f0e0b0f..2f49bfad2` -> 10 commits) and round 25's first inputs for round 26 (its section 7), and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `2f49bfad2`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `2f49bfad2`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since W** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-20T02:52:19Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (03:57:47Z) | 0 result rows: no human post since W | **0 rows** from new reports. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <PUSH_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (started 03:57Z); `gh run list -L 60`, rows with `createdAt >= W` | 100 runs (08:22Z..03:45Z), 16 failed; every failed job's last green is 44667619025 (`2a7befc0`, 03:25Z) or 44666179933 (`6bac8a7f`, 03:12Z). Since W, wf 10: 6 runs, 5 `success`, 1 schedule run in progress (44669831627); no failed run of any workflow | **0 rows** from a red. The newest failed run, 44655865817 (01:44Z), is round 25's row, fixed by `2a7befc02`; the older ones were read by rounds 24 and 25. wf 45's "topic heads: long run" job, still running at 04:0xZ, is inside its usual 36 to 65 minutes (the 7 runs of 11-13 to 11-19). This round's row comes from a GREEN job: source 5. |
| **3. Skipped or disabled tests** | `git diff 82f0e0b0f 2f49bfad2 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 2 files: `internal/hub/repo_sync_gaps_test.go` (+101, new) and round 25's plan | **0 rows.** Its one skip is `t.Skip("memory store only")` in a new test of `6bac8a7fa` (SPL-6006, c-046@sat's lane): a driver guard, not a disabled test. The row's skip is a printed `return`, which this grep does not see (row 01). |
| **4. Box cron logs** | `<box2>`: `/var/csi/csi-spl/done-claim-check/cron.log`, the 13 runs from 02:55Z (line 53352) to 03:55Z: `awk 'NR>=53352 && /\talert\t/'` | 0 alert rows; sat (the holder, msg 06fc7780): 19 runs from 02:53:32Z to 04:2xZ, `grep -cE 'job [0-9a-f]{6,}'` -> 0, every OK summary (15) reads `0 alerted` | **0 rows.** No `job <hex>` alert on either box (section 4). |
| **5. Round 25's first inputs** | round 25 section 7 | 4 inputs | **1 row**: 01 from the `blog.test.mjs:329` alone-run. The other 3: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `2f49bfad2`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `test(b26-01-wui-blog-switcher-e2e-runs-in-ci)` | The blog language switcher's e2e steps (SPL-3871: the flagged switcher in the blog bar, its list, the keyboard and the tap pick, about 20 checks) have **never run in CI**, and their keyboard step fails once they do. (a) `blogSwitcher()` hard-codes one post, `2026-10-26-kids-human-experience` (`blog.test.mjs:286`); when the build lacks it, it prints `(no <id> in this build: the switcher steps did not run)` and returns (`:288`): a skip, not a failure. wf 10's `wui-generate` job checks out at the default depth 1 (`10_ci-quality.yml:713`, no `fetch-depth`), so `sync-blog.mjs` counts every older post on the boundary commit's day (`publishTimes`, `sync-blog.mjs:279-284`, "stricter, never looser"; the warning at `:472-473`) and the cap of 7 a day drops 6 to 8 posts, this one among them. (b) On a bundle that has the post (built with the history), the desktop pick types `bulg`, then presses ArrowDown and Enter (`:320-324`), while its own comment says "type, Enter picks the one match" (`:319`): ArrowDown then Enter leaves the page on `/blog/<id>`. | **CI**, n=4 dates: scheduled wf 10 runs 40789509550 (2026-10-28), 41741639331 (11-03), 42536674714 (11-08) and 44663072878 (11-20, `f589257ba`): the e2e shard that runs `blog.test.mjs` prints `(no 2026-10-26-kids-human-experience in this build: the switcher steps did not run)` and `blog: all 64 passed` (11-20: job 136046749184, log lines 601-603). Generate job 136045785355 of that run prints `blog: shallow clone - every older post counts on the boundary day (a stricter cap)` and 8 `blog cap: ... not rendered (2026-11-20: over the cap of 7 a day (6 besides the digest))` lines, this post's among them (lines 375-383); the generate jobs of the 02:45Z runs of 11-12 to 11-19 (n=8) drop it too (6 or 7 capped each). The steps landed in `4b79fdf1b` (2026-10-27); the file is unchanged since (`git log -1 -- <test>`). **Local**, `<box2>`, a mock bundle of `2f49bfad2` built with the history (0 posts capped), `blog.test.mjs` alone, n=3, each red on the first run and on the runner's retry: `FAIL desktop: picking bg lands on /bg/blog/2026-10-26-kids-human-experience "<base>/blog/2026-10-26-kids-human-experience"`, `FAIL desktop: there bg is the current language "🇬🇧 English"`, `OK phone: picking bg lands on ...`. A probe of 4 key sequences on that bundle (a fresh browser context each, n=3): type then Enter picks bg 6 of 6 (with or without opening the list first); type, ArrowDown, Enter picks it 1 of 6. It is the check round 25 carried: c-395's R7 line (msg 577d03b7) read `blog.test.mjs alone ... base 0/3 pass (same bg picker check, pre-existing)`. | `csi-spl-wui/tests/e2e/blog.test.mjs:283-289` (`blogSwitcher`, the hard-coded id and the skip), `:318-324` (the keyboard pick); read only: `:325-332` (the tap pick, the two checks), `csi-spl-wui/src/node/blog/sync-blog.mjs:279-284`, `:472-475` (the cap's shallow rule), `.github/workflows/10_ci-quality.yml:701-713` (the generate job's checkout), `csi-spl-wui/src/components/LanguageSwitcher.vue:290-305` (`onSelect`) | `bash rc01.sh 2f49bfad2 <node_modules dir>` (section 3.2): the sha fetched at depth 1, as CI does -> `rc01 blog cap dropped 8 post(s)` / `(no 2026-10-26-kids-human-experience in this build: the switcher steps did not run)` / `blog: all 64 passed` / `rc01 sha=2f49bfad2 mode=shallow test-rc=0 switcher-skipped=1`, exit 1. `bash rc01.sh 2f49bfad2 <node_modules dir> full`: the whole history -> `rc01 blog cap dropped 0 post(s)` / `FAIL desktop: picking bg lands on /bg/blog/2026-10-26-kids-human-experience "<base>/blog/2026-10-26-kids-human-experience"` / `FAIL desktop: there bg is the current language "🇬🇧 English"` (each twice: run and retry) / `rc01 sha=2f49bfad2 mode=full test-rc=1 switcher-skipped=0`, exit 1. | Test file only, `blog.test.mjs`: (1) `blogSwitcher` takes its post from the build's `/blog-md/index.json` (an `en` post that has a `bg` copy, e.g. the newest), not a hard-coded id, and FAILS, never skips, when the build has none; (2) the keyboard pick does what its comment says: type `bulg`, then Enter (no ArrowDown). No change to `sync-blog.mjs`, the cap, wf 10's checkout or `LanguageSwitcher.vue`. The lane's commit body carries: rc01 on its fix in both modes -> exit 0 (the steps ran, 0 FAIL); the fix's red controls (the hard-coded id put back -> FAIL in shallow mode, not a skip; ArrowDown put back -> FAIL in full mode); the wf 10 e2e shard log of its push showing the switcher checks (`picking bg lands`) where the skip line was. `Docs: none (a test; no behaviour changes)`. Whether ArrowDown on a single match should keep it active is a product question: section 5. | `<box2>` (it has the wui deps and Chrome; rc01 ran there) | claude (WUI: never mistral, developer guide 5.1) | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `tests` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01, one file: `csi-spl-wui/tests/e2e/blog.test.mjs`.
- **Test column (R2):** `git grep -l 'blog.test' 2f49bfad2 -- csi-spl-wui/tests csi-spl-wui/src/node/test csi-spl-iac/src/bash` -> `e2e-shard-weights.txt` (a weight, not a test), `tests/unit/blog-lang-switcher.test.mjs` (the switcher's unit half, names the e2e file), `tests/unit/public-seo.test.mjs` (names `publicSeo`), `tests/unit/blog-sync.test.mjs` (a git user name only). At least: `blog.test.mjs` alone through `rc01.sh` in both modes, `blog-lang-switcher.test.mjs`, `public-seo.test.mjs`, `pnpm run typecheck`, and every e2e file the pre-push map selects (`cd csi-spl-iac && WUI_E2E_RANGE=<sha>^..<sha> ./run -a do_check_pre_push_e2e`; rulebook 2.7.4).
- **Off limits** for the row lane: every live lane's files (below); `sync-blog.mjs`, wf 10, `LanguageSwitcher.vue` (read only).
- **How the files were checked (2026-11-20, `<box2>`):**
  - 04:06:47Z `lane-map.sh --check csi-spl-wui/tests/e2e/blog.test.mjs,csi-spl-doc/doc/md/bug-round-26-plan.md --agent c-789` -> `WARN no live lane lists` them; exit 4 for 5 sat lanes that record no files: c-046 (spec 143 B-6b.2: api `internal/hub/repo_sync*`, `internal/github/`, config, the brief), c-168 (`c-168-rotate`, an orchestrator rotation), c-212 (r72-01: api `message_move*`, `cleancode_test.go`, refactor-round-72-plan.md), c-213 (r72-02: `git diff --name-only $(git merge-base origin/master FETCH_HEAD) FETCH_HEAD` on `review/r72-02`, tip `24db13ae9` -> `spl-reflection-gather.func.sh` and its test), m-206 (the r72 panel seat, its seat file only, rulebook 2.7.6). None is under `csi-spl-wui/`.
  - 03:58:48Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `1 queued, 0 placing`: ask dc50870f, the r72-02 claude-waiver reviewer (a review seat, no code file).
- **Slug b26 is unused as a round id** (`<box2>`, 03:57Z): `git log origin/master --since="$W" --oneline -E --grep='\(b26-'` -> 0; `git ls-remote origin 'refs/heads/review/b26-*' 'refs/heads/wip/*b26*' 'refs/heads/*-b26-*'` -> nothing; `ls /var/spool-hub/dispatch/briefs \| grep -cE 'b26-[0-9]{2}\|bug-round-26'` -> 0; `git worktree list \| grep -cE 'b26-[0-9]{2}\|bug-round-26'` -> 1, this planner's own (`c-789-c002-bug-round-26-planner`), 0 row worktrees. sat: c-002 read 0 `(b26-` commits and 0 b26 refs at 03:5xZ on `2f49bfad2` (the brief); then (msg 06fc7780) `ls /var/spool-hub/dispatch/briefs \| grep -cE 'b26-[0-9]{2}\|bug-round-26'` -> 1, this planner's own brief (the panel seat's brief adds 1 from then on), and `git -C <main checkout> worktree list \| grep -cE 'b26-[0-9]{2}\|bug-round-26'` -> 0.

  After this plan's pushes, `--grep='(b26-'` matches the plan's commits (`docs(b26-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b26-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red control run on `2f49bfad2`

The file is on `<box2>` in `/var/spool-hub/dispatch/b26-red-controls/`: `rc01.sh` (2609 B, `sha256sum` first 12 hex `1cf2b13ed68d`). It is printed below, so a seat on sat can rebuild it. It installs nothing: it hard-links (else links) an installed `csi-spl-wui/node_modules` whose `.pnpm/lock.yaml` equals the sha's `pnpm-lock.yaml`, and refuses (exit 2) when they differ. It needs bash, git, node 20, pnpm on `PATH`, and Chrome.

| row | command | output on `2f49bfad2` | who |
|---|---|---|---|
| 01 | `bash rc01.sh 2f49bfad2 <node_modules dir>` (shallow) and `bash rc01.sh 2f49bfad2 <node_modules dir> full`, each from a checkout as `<PUSH_USER>`, n=1 each, 04:17Z to 04:24Z | RED in both. Shallow: `rc01 shallow=true` / `rc01 blog cap dropped 8 post(s)` / `(no 2026-10-26-kids-human-experience in this build: the switcher steps did not run)` / `blog: all 64 passed` / `rc01 sha=2f49bfad2 mode=shallow test-rc=0 switcher-skipped=1`, exit 1. Full: `rc01 shallow=false` / `rc01 blog cap dropped 0 post(s)` / `FAIL desktop: picking bg lands on ...` and `FAIL desktop: there bg is the current language "🇬🇧 English"`, twice (run, retry) / `OK phone: picking bg lands on ...` / `FAIL tests/e2e/blog.test.mjs (exit 1, then exit 1)` / `rc01 sha=2f49bfad2 mode=full test-rc=1 switcher-skipped=0`, exit 1. The same two results by hand, before rc01 was written: 3 shallow-equivalent alone-runs (`switcher steps did not run`, `blog: all 64 passed`, rc 0) and 3 full-history alone-runs (the two FAIL lines, rc 1). | editor c-789 |

No prototype fix was written: the change is the row lane's, with its own red controls. There is no green control on this sha: the green half is the lane's (rc01 on its fix, both modes, exit 0).

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha> <node_modules dir> [full]: b26-01 red control. Checks <sha> out
# as wf 10's wui-generate job does (actions/checkout, fetch-depth 1: a shallow
# clone), or with its whole history when the 3rd arg is `full`; builds the mock
# bundle with that job's env (_ppe_generate), runs tests/e2e/blog.test.mjs
# alone through wui-e2e-mock-serve.sh. RED when the blog switcher steps
# (SPL-3871) did not run, or when a check failed. <node_modules dir>: an
# installed csi-spl-wui/node_modules whose .pnpm/lock.yaml equals <sha>'s
# pnpm-lock.yaml (hard-linked in, else linked; nothing is installed). Builds under
# RC_TMP (default /var/tmp: the node_modules filesystem). Run from a checkout.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha> <node_modules dir> [full]}"; nm="${2:?node_modules dir}"; mode="${3:-shallow}"
repo="$(git rev-parse --path-format=absolute --git-common-dir)" || exit 2
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d "${RC_TMP:-/var/tmp}/rc01.XXXXXX")"; trap '[ -n "$C" ] && rm -rf -- "$C"' EXIT
git init -q "$C/r" && cd "$C/r" || exit 2
if [[ "$mode" == full ]]; then git fetch -q "file://$repo" "$full"; else git fetch -q --depth 1 "file://$repo" "$full"; fi || exit 2
git checkout -q FETCH_HEAD || exit 2
echo "rc01 shallow=$(git rev-parse --is-shallow-repository)"
cmp -s csi-spl-wui/pnpm-lock.yaml "$nm/.pnpm/lock.yaml" || { echo "rc01: $nm does not match $sha's pnpm-lock.yaml"; exit 2; }
cp -al "$nm" csi-spl-wui/node_modules 2>/dev/null || { rm -rf csi-spl-wui/node_modules; ln -s "$nm" csi-spl-wui/node_modules; } || exit 2
cd csi-spl-wui || exit 2
NUXT_PUBLIC_BUILD_COMMIT="$full" NUXT_PUBLIC_USE_MOCK=1 NUXT_PUBLIC_DEFAULT_LOCALE=en \
NUXT_PUBLIC_REPO_WEB_URL="https://git.example.org/acme/spool" NUXT_PUBLIC_REPO_COMMIT_PATH="/commit/" \
NUXT_PUBLIC_REPO_CLONE_URL="https://git.example.org/acme/spool" NUXT_PUBLIC_REPO_HELP_PATH="/blob/master/csi-spl-doc/doc/help/" \
  pnpm run generate > "$C/gen.log" 2>&1 || { tail -5 "$C/gen.log"; exit 2; }
echo "rc01 blog cap dropped $(grep -c '^blog cap: ' "$C/gen.log") post(s)"
out="$(CHROME_PATH="${CHROME_PATH:-/usr/bin/google-chrome}" bash ../csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh node src/node/test/run-e2e-tests.mjs tests/e2e/blog.test.mjs 2>&1)"; rc=$?
grep -E '^ *FAIL|switcher steps did not run|picking bg lands|^blog: all|passed, .* failed' <<<"$out" | sed -E 's#http://127\.0\.0\.1:[0-9]+#<base>#g'
skipped=$(grep -c 'switcher steps did not run' <<<"$out")
echo "rc01 sha=${full:0:9} mode=$mode test-rc=$rc switcher-skipped=$skipped"
[[ $rc -eq 0 && $skipped -eq 0 ]]
```

---

## 4. Round 25's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b25-01 | `git log origin/master --oneline -E --grep='\(b25-01-'` | landed `2a7befc02` | Served (round 25 closed, the brief). |
| The done-claim `job` label (round 25 section 7: a row if a `job <hex>` token alone alerts) | source 4 (section 2) | 0 alert rows since W: `<box2>` 13 runs, sat 19 runs (the holder, msg 06fc7780) | **Not a row**: the condition did not occur. Stays an input on the same condition. |
| `test-agent-name-shape.sh:89`, `hasnt ... "900006"` (a row once seen red) | source 2: the failed runs of the 100-run report | none names it | **Not a row**: not seen red. Stays an input on the same condition. |

---

## 5. Not a row this round, or no red control yet

| candidate | command | result |
|---|---|---|
| **SPL-5850 N1: an AltGr letter may pick a kind** (`csi-spl-wui/src/utils/kind-picker-keys.ts:45-50`, `:58`) | `git log --oneline 82f0e0b0f..2f49bfad2 -- <file>` -> 0; owner posts naming it: `select count(*) from messages where from_id like 'HUM%' and body ~* 'alt ?gr'` -> 0 (03:59:40Z); `grep -rni altgr csi-spl-doc --include=*.md` -> round plans only | **No rule it breaks, no owner word.** Unchanged; carried on round 25's condition. |
| **ArrowDown on the one match, then Enter, picks nothing** (the blog switcher; row 01's probe) | the probe of row 01 (n=3 per sequence): type then Enter, 6 of 6 pick; type, ArrowDown, Enter, 1 of 6 | **A product question, no rule.** The active option is moved by Headless UI's Combobox (`LanguageSwitcher.vue`), not by this repo's code; no spec line or owner word says ArrowDown must keep a single match. Enter alone picks, as the test's own comment says. Next round's input if a rule or the owner says it must pick. |
| **Rows A and B of the reflection** (Qto 71e1dbd3, SPL-5992) | as round 24 section 5 | **Not bugs: detectors** (the brief). |
| **`fallback_postgres.go:83-86` probes uncovered** (r34-01 R7 c-321 N1/N2) | as round 24 section 5 | **A test-coverage gap, not a bug row** (the brief). |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists the row's file (lane map 04:06:47Z, queue 03:58:48Z, r72-02 diff 04:0xZ). The orchestrator re-runs R3 before the spawn. |
| `repo_sync_gaps_test.go`'s memory-only skip | c-046@sat (spec 143 B-6b.2) | A driver guard in its own lane's test; not a bug input. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 5 sources; 5 named inputs (round 25's section 7 and 5 inputs) plus 1 found (ArrowDown on one match); 0 human posts since W; 100 CI runs; 11 generate job logs and the e2e shard logs of 4 scheduled runs; 2 cron logs (13 + 19 runs); 1 red control in 2 modes; 3 + 3 alone-runs of `blog.test.mjs`; 3 probe runs |
| first inputs for round 27 | the done-claim `job` label if it alerts alone; the AltGr picker and ArrowDown on one match, each if a rule or the owner says how it must pick; `test-agent-name-shape.sh:89` if seen red |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-789@`<box2>` (claude, `specs_and_docs`).
- **Panel:** one non-claude seat, mistral (as rounds 21 to 25; grok is held, below): ask ff933b29, slug `hand-<box2>-c002-bug-round-26-mistral-panel-seat`, pinned to `<box2>`, queued by the holder c-002@sat (msg 06fc7780). The panel checks the red control (rebuild `rc01.sh` from section 3.2), the CI evidence (the e2e and generate job logs named in row 01), the fix scope (test file only; the post comes from the build and a missing one fails; Enter without ArrowDown), and that every other input in sections 2, 4 and 5 is measured as written.
- **Asked of the holder with v0.1 (msg d168abd9), answered** (msg 06fc7780): the panel seat (above); sat's half of the slug check: 1 (this planner's brief) and 0 (section 3.1); sat's done-claim log since W: 0 `job` alerts in 19 runs (sections 2 and 4). The holder confirms `do_spl_review_line_check` rc 0 on the panel's line before the plan lands.
- **Row reviewer (R7):** claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (03:58:48Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% ...; <box2> 99% ...]`. A WUI row never goes to mistral; the holder names this same-vendor review a waiver.
- **Review history:**
  - 2026-11-20 04:2xZ: the editor pushed v0.1 (`b74379bcd`) to `review/c002-bug-round-26-planner` and asked the holder for a panel (msg d168abd9).
  - 04:3xZ: the holder answered (msg 06fc7780): the mistral panel seat queued (ask ff933b29); sat's slug half 1 and 0; sat's done-claim log 0 `job` alerts. v1.0 folds all three; no row changed.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-789@`<box2>` | v1.0 |
| Panel | mistral seat, ask ff933b29 (`<box2>`) | pending |
