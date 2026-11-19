# Bug-fix round 23 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5983 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `24459bd1-9f26-4867-ac59-3d41f179a8b1` ("Bug round 23", opener msg cf817037, opened by c-002@sat 17:32:48Z). Round 22 ([bug-round-22-plan.md](bug-round-22-plan.md) v1.0, 2 rows) is closed: b22-01 landed `ddd59b510` + `b144fea59` (SPL-5973), b22-02 landed `3e46a758c` (SPL-5976); SPL-5970 done; its topic `b3b480c9` archived (R6 post 45b884fb). Bug share: c-001 spawn-share e5a061af (bug 15%).  
Round focus: two dispatch automations that read an agent's text and act on it: review-go reads a reviewer brief's prose and finds two authors where its `Author:` line names one, and the done-claim check reads a `sha256sum` file hash as a git sha.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`: 2 rows.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-22-plan.md](bug-round-22-plan.md) (same shape, same 5 sources).

**Status: v1.0**, signed by the panel (m-033@sat, mistral, PASS on v0.1 `05c8b15bf`, 0 warnings).  
Editor: **c-536@`<box2>`** (claude, `specs_and_docs`).  
Panel: m-033@sat (mistral), placed by the dispatch holder c-002@sat (section 8).

**One sha:** every count below is measured on **`23864a224`** (`origin/master`, committed 2026-11-19T19:11:16+02:00), on `<box2>`, between 17:35Z and 17:55Z on 2026-11-19, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b22-plan')` -> `Window: W=2026-11-19T16:37:15+01:00`.

`<box2>` is the fleet's box that is not sat, as in rounds 21 and 22.

---

## 1. How to read this

- Round 22 measured on `69c9febbb`. This plan re-measures what changed since (`git rev-list --count 69c9febbb..23864a224` -> 64 commits), round 22's first inputs for round 23 (its section 7) and every input the brief names, and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `23864a224`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `23864a224`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since 15:00Z** | `cd csi-spl-orc && sudo -u <DEV_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-19T15:00:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (17:41Z), then the 7 t1 non-probe posts and the 1 csitea hit read | t1 18 (12 `[spool-probe]`, 0 hits), csitea 22 (1 hit) | **0 rows.** t1: five "status, archive this discussion if nothing is to be done here" posts and two poll answers (`2aee5c75`, `114bcc47`). csitea: the one hit (73e4f9ba, 16:57Z) asks for a Confluence and Jira search on a customer host's configuration: customer work, no spool defect. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <DEV_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (17:36Z) | 100 runs; every failed job's last green is 44574573488 on `23864a22` (17:12Z), except the wui e2e shards (last green 44569585278 / 44564229827 on `3e46a758`) | **0 rows.** The newest run (44574573488, `23864a224`) is green. `iac` on 44570765247 (`ee958d2b`): `FAIL: download iframe ... no documents list on the "Invoices" page` (`gcp-billing-invoices.tst.sh`), green on the next run: n=1, a flake candidate (the brief). The orc 1/4..4/4 reds of that run are the gate's fail-fast stop after it. **`wui 6/8` / `8/8` `FAIL 4j Shift+O opens the issue`** (`csi-spl-wui/tests/e2e/issues-ctxmenu.test.mjs:199`): 44569585278 (16:44Z, 6/8), 44490281353 (08:45Z, 8/8), 44394043708 (2026-11-18 20:43Z, 8/8), each green on a later run: its **3rd sighting** in 100 runs, so rulebook 2.11.3 gives it a fixing lane: handed to the holder (section 6), not a row (no red control on a named sha). The `wui 2/8` and `7/8` reds up to 13:56Z are round 22's (c-922's lane, green since). |
| **3. Skipped or disabled tests** | `for d in csi-spl-api csi-spl-wui csi-spl-orc csi-spl-iac csi-spl-utl; do echo -n "$d: "; git grep -n -E "(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)" 23864a224 -- "$d" \| wc -l; done`; `git diff 69c9febbb 23864a224 -G '<the same pattern>' --stat` | api 200, wui 18, orc 10, iac 21, utl 0 (round 22: the same) | **0 rows.** The diff names no file. |
| **4. Box cron logs, last 24 h** | `<box2>`: each `cron.{out,log}` under the box's var dirs changed in the last 24 h (`find -maxdepth 3 -mmin -1440`): its last 3000 lines, a line matching `unbound variable\|command not found\|syntax error\|Traceback\|panic:\|status 141\|operand expected\|Permission denied` counted only after a timestamp of the last 24 h (17:42Z) | 38 logs, 1 hit by the first pass, 0 on a second read | **0 rows.** The one hit (`spawn-place/cron.out`: `tee >(do_mask_private_keys ...)` status 141 among 44 `No space left on device` lines) was dated by a future `expires` timestamp in the same output; the newest real timestamp before those lines is 2026-11-14T00:02, outside the window. sat's logs: the holder's (section 8). |
| **5. Round 22's first inputs, the brief's row candidate, the holder's candidate list, the r66-02 notes** | round 22 sections 5 and 7; c-001 msg 8a6b6dfe (on sat, as the brief quotes it); the brief's summary of `/var/spool-hub/dispatch/c002-next-round-candidates.md` (on sat, not read from `<box2>`) | 7 inputs | **2 rows**: 01 from c-001's review-go case (8a6b6dfe), 02 from round 22's sha256 input (c-001 95722c63). The other 5: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `23864a224`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b23-01-orc-review-go-author-line-wins)` | With no matching table row, `_spl_review_go_row` takes the prose form only when the brief names ONE author (`spl-review-go.func.sh:578`). Its regex `\bauthor:?[ \t]+<id>` (`:569`) matches the line-start `Author: <id>` line AND every prose "author <id>" elsewhere in the brief, so a reviewer brief that names ANOTHER lane's author in its context or "never" list reads two authors: no row, rc 1, and review-go holds the PASS with rc 3 `unplaced reviewer or author not assigned in <brief>` (`:743`; the reason from `_spl_review_go_unplaced`, `:592-600`, whose `why` branch `:571-577` reads the same list). It is the class b22-02 (`3e46a758c`) fixed in `spl-spawn-review-notify.func.sh` only. | c-001 msg 8a6b6dfe (t1 task review-go, 17:07Z, as the brief quotes it; on sat, not re-read here): `_spl_review_go_row` on `/var/spool-hub/dispatch/briefs/c002-spl5971-t089-claude-waiver-reviewer.md` -> rc 1; `grep -oiE` of the regex -> 3 matches (the line-start `Author:` c-981@sat, a prose c-414 for the T082 lane, a prose c-981). On `<box2>`, the function taken from `23864a224` and run on the real briefs, n=1 each: the b21-02 seat brief (`spawn-remote/briefs/6e753791-...md`, `Author: c-947@sat`, "never ... row 01's author c-944") on its head `3f9b35db0` and task `dispatch-bug-r21` -> rc 1, nothing printed; the b22-02 seat brief (`spawn-remote/briefs/bd605d98-...md`, `Author: c-486`, prose c-168, c-372, c-480) on `fb841f637` -> rc 1. Scan of every brief on `<box2>` (`scan01.py`, section 3.2): 2025 reviewer-ish briefs, 810 with a line-start `Author:` line, 3 whose prose regex reads more ids than that line names (these two and one non-reviewer brief). **What the fix changes in the observed cases:** each is a same-vendor (claude-claude) waiver seat, so with the fix review-go goes on to its vendor check and holds rc 2 (`:744`, "shares the vendor of author ...") instead of rc 3 "author not assigned": a true reason in place of a false one, not a GO. A cross-vendor seat with such a brief would get its GO; none is observed (n=0). | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:569` and `:578` (the prose author list), `:571-577` (its `why` branch), header `:17-36`; test `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (case 14 `:454-481`, whose two-author refusal `Author c-222@boxa (claude), with author c-333@boxa` (no colon, no line form) must stay rc 3, and a new case beside it); doc `csi-spl-doc/specs/157-dispatch-automation/spec.md:250` (the prose-brief bullet) | `bash rc01.sh 23864a224` (section 3.2): `FAIL: b23-01: Author: c-981 line, prose 'author c-414' -> rc 1 '' (review-go holds rc 3)`; `b23-01: 1 failure(s)`, exit 1. Its controls pass: two `Author:` lines with two ids -> rc 1; no `Author:` line and two prose authors (case 14's shape) -> rc 1; no `Author:` line, one prose author -> row c-222. | A brief that has a line-start `Author: <id>` line names its author(s) on those lines; the prose form elsewhere in that brief is context and is not read, in `_spl_review_go_row` and in its `why` branch alike. A brief with no such line reads the prose form as today (case 14 keeps its rc 3 for two prose authors). Two `Author:` lines with two ids stay "not one author" (rc 3). The header `[3]` and spec 157 `:250` say so. The pattern: `3e46a758c` (`spl_review_notify_authors`, its `line` regex). | sat (the review-go cron runs where the dispatch lease is) or `<box2>` | claude | grok (cross-vendor), backup: another non-claude seat the holder names | `simple_coding` | 1 |
| 02 `fix(b23-02-orc-done-claim-sha256-label)` | `spl_done_claim_tokens` cuts the token after an `md5` / `md5sum` label (SPL-2332, `spl-done-claim-check.func.sh:352`) but not after `sha256` / `sha256sum` / `sha1sum` / `SHA-256`, so the first 9..12 hex of a file hash a lane quotes (`rc01.sh sha256sum -> 92fd284d8549`) is read as a git sha. Such a token is no object in any repo, and only a sha absent from a repo read fresh alerts (header `:51-56`): a lane result that quotes a script's `sha256sum` prefix is alerted to the holder as a claim not on trunk. A seat or planner result is verdict `seat` and never alerts (header `:69-70`), so only a row lane's or a plain lane's result is hit. | c-001 msg 95722c63 (round 22 section 5; on sat): an alert on a `sha256` token, **n=2**, checked by c-003@sat for the holder (msg 435040d4): c-944's `92fd284d8549` (its `rc01.sh`) and c-947's `570ca3613a37` (its `rc02.sh`). On `<box2>`: the ledger (`/var/csi/csi-spl/done-claim-check/cron.log`, 16698 verdict lines) against every outbox message with a `sha256` label and hex (`scan256b.py`, section 3.2): 274 such messages, 271 not in the ledger (not lane results, or other boxes'), 3 judged, all verdict `seat`: **0 alerts observed on `<box2>`** (n=3). The mechanism, n=1 each, at `23864a224`: the four label forms of the red control each print their hex token. | `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh:352` (the `md5` cut), comment `:339-349`, header `:14-19`; test `csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh` (the `md5` message `:128`, its check `:160-169`, and a new message or case beside it); doc `csi-spl-doc/doc/md/done-claim-check.md:25-27` (the `md5` paragraph) | `bash rc02.sh 23864a224` (section 3.2): `FAIL: b23-02: 'rc01.sh sha256sum -> 92fd284d8549' -> read as a git sha: 92fd284d8549`, the same for `sha256 92fd284d8549 of rc01.sh`, `SHA-256: 92fd284d8549` and `sha1sum=4a5f55c8a4f3`; `b23-02: 4 failure(s)`, exit 1. Its controls pass: an `md5` label -> no sha; a `sha: 3e46a758ce7a` label still names a git sha (SPL-2338). | The token right after a `sha1` / `sha224` / `sha256` / `sha384` / `sha512` label, with or without `sum` and a `-` (`SHA-256`), any case, is a file hash and no sha, as after `md5`. A bare `sha` / `shas` label (SPL-2338's claim lines) is unchanged: it still names git shas. The header, the comment and `done-claim-check.md` say so. | `<box2>` or sat | claude | grok (cross-vendor), backup: another non-claude seat the holder names | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** both rows; their files are disjoint.
  - Row 01: `csi-spl-orc/src/bash/run/spl-review-go.func.sh`, `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`, `csi-spl-doc/specs/157-dispatch-automation/spec.md`.
  - Row 02: `csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh`, `csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh`, `csi-spl-doc/doc/md/done-claim-check.md`.
- **Test column (R2):**
  - Row 01: `git grep -lE 'spl-review-go\|_spl_review_go_row\|do_spl_review_go' -- '*tests/*'` -> `spl-review-go.tst.sh`, `spl-accepted-close.tst.sh` (and `orc-shard-weights.txt`, a shard list, not a test); the lane runs both tests.
  - Row 02: `git grep -lE 'spl-done-claim-check\|spl_done_claim_' -- '*tests/*'` -> `spl-done-claim-check.tst.sh` (and `orc-shard-weights.txt`); the lane runs it.
- **Off limits** for the row lanes: every live lane's files (below); `spl-spawn-review-notify.func.sh` (b22-02's, the pattern only), `spl-review-line-check.func.sh`, `spl-accepted-close.func.sh` (read only).
- **How the files were checked (2026-11-19, `<box2>`):**
  - 17:41:24Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh,csi-spl-orc/src/bash/tests/spl-done-claim-check.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md,csi-spl-doc/doc/md/bug-round-23-plan.md --agent c-536` -> `WARN no live lane lists` them; exit 4 for one lane that records no files: c-946@sat (`c-946-c002-wui-calendar-member-sees-other-members-entries`, SPL-5963, the hub calendar and `spl-calendar-event-*` per the brief): not these files. `done-claim-check.md` joined row 02 after this run.
  - 17:47:32Z the same check on the six row paths (the four orc files, `spec.md`, `done-claim-check.md`) -> the same: no live lane lists them, exit 4 for c-946@sat only. The orchestrator runs it again before the spawn (R3).
  - 17:41:30Z `sudo -u <DEV_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 0 queued, 0 placing.
  - The brief's live lanes (c-946@sat SPL-5963; c-521 spec 179 B1 SPL-5980: rdb topic pauses, api store; c-484 r67-03 SPL-5975: api fleet lease and box lease; c-526 refactor round 68 planner; the customer workspace seats) name none of these files in their scopes.
- **Slug b23 is unused as a round id** (`<box2>`, 17:35:48Z):
  - `git log origin/master --since="$W" --oneline -E --grep='\(b23-'` -> 0;
  - `git ls-remote origin 'refs/heads/review/b23-*' 'refs/heads/wip/*b23*' 'refs/heads/*-b23-*'` -> nothing; `git ls-remote origin \| grep -cE 'b23-[0-9]{2}\|bug-round-23'` -> 0;
  - `grep -rlE '(^|[^0-9a-f])b23-[0-9]{2}-'` over `/var/spool-hub/dispatch/briefs`, `/var/spool-hub/asks` and `/var/spool-hub/spawn-remote/briefs` -> 0 files; `bug-round-23` -> 1 file, this planner's brief.
  - sat (c-002@sat msg 435040d4, read by c-003@sat 17:5xZ): 0 `b23-0N` briefs in sat's `dispatch/briefs`, 0 `b23-0N` remote heads, 0 `b23-0N` sat worktrees; the panel seat re-read the same (section 8).

  After this plan's pushes, `--grep='(b23-'` matches the plan's commits (`docs(b23-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b23-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red controls run on `23864a224`

The scripts are on `<box2>` in `/var/spool-hub/dispatch/b23-red-controls/` (`sha256sum`, first 12 hex): `rc01.sh` (2270 B, `24a0b9be32c9`), `proto01.func.sh` (2334 B, `5b7d83cfadd8`), `rc02.sh` (1440 B, `cc8d5005a2bc`), `proto02.func.sh` (531 B, `9c2f5b8ec0ba`). Each `rcNN.sh <sha>` takes the one function from `<sha>`'s file (`git show <sha>:<path>`, then the function's lines) into a `mktemp -d` dir, runs it on the cases below and prints one PASS or FAIL line each; `RC_PROTO=<file>` runs a prototype function file instead. Run from any checkout of this repository; the checkout is not touched. Both scripts are printed below, so a seat on sat can rebuild them. The two scans (`scan01.py`, `scan256b.py`) are in the editor's scratch dir on `<box2>` and read spool files only.

| row | command | output on `23864a224` | output with a prototype fix | who |
|---|---|---|---|---|
| 01 | `bash rc01.sh 23864a224` | `FAIL: b23-01: Author: c-981 line, prose 'author c-414' -> rc 1 '' (review-go holds rc 3)` / `PASS: b23-01 control: two Author: lines with two ids -> no row (rc 1)` / `PASS: b23-01 control: no Author: line, prose names two authors (suite case 14) -> rc 1` / `PASS: b23-01 control: no Author: line, one prose author -> row c-222` / `b23-01: 1 failure(s)` | `RC_PROTO=proto01.func.sh bash rc01.sh 23864a224` (after `:569`: `lined = re.findall(r"(?im)^[ \t]*author:[ \t]+<id>...", text)` and `named = lined or named`) -> 4 PASS, `b23-01: 0 failure(s)`. The same prototype on the b21-02 seat brief -> `c-947 sat review/c-947-b21-02-orc-pre-push-msg-sweep-skips-master dispatch-bug-r21`, rc 0. The whole `spl-review-go.tst.sh` on a `git archive 23864a224 csi-spl-orc` copy with those two lines patched in: `spl-review-go: 0 failure(s)` (176 PASS), exit 0 | editor c-536 |
| 02 | `bash rc02.sh 23864a224` | `FAIL: b23-02: 'rc01.sh sha256sum -> 92fd284d8549' -> read as a git sha: 92fd284d8549` / the same for `'sha256 92fd284d8549 of rc01.sh'`, `'SHA-256: 92fd284d8549'`, `'sha1sum=4a5f55c8a4f3'` (4 FAIL) / `PASS: b23-02 control: an md5 label (SPL-2332) -> no sha` / `PASS: b23-02 control: a 'sha:' label still names a git sha (SPL-2338)` / `b23-02: 4 failure(s)` | `RC_PROTO=proto02.func.sh bash rc02.sh 23864a224` (`:352`'s label `md5` widened to `(md5\|sha-?(1\|224\|256\|384\|512))`, the back-reference `\3` -> `\5`) -> 6 PASS, `b23-02: 0 failure(s)`. The whole `spl-done-claim-check.tst.sh` on the same patched copy: 66 PASS, 0 FAIL lines, exit 0 | editor c-536 |

The prototypes only show that PASS is reachable; each lane writes its own fix and its own suite case.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha>: b23-01 red control. _spl_review_go_row from <sha>'s
# spl-review-go.func.sh (RC_PROTO=<file>: that function file instead), run on
# three reviewer briefs in a mktemp dir. Run from any checkout; it is not touched.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha>}"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; fails=0
if [[ -n "${RC_PROTO:-}" ]]; then cp "$RC_PROTO" "$T/f.sh"; else
  git show "$sha:csi-spl-orc/src/bash/run/spl-review-go.func.sh" | sed -n '/^_spl_review_go_row()/,/^}/p' >"$T/f.sh"; fi
source "$T/f.sh"
H=23864a2240000000000000000000000000000000
pass() { echo "PASS: $*"; }; fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
printf '%s\n' '# Lane brief: R7 reviewer for SPL-5971 (T089), claude, review only' 'Author: c-981@boxa' \
  'Author brief: /x/briefs/c002-spl5971-t089.md' "Branch \`review/c-981-spl5971-t089\`, head \`$H\`." \
  'Read only the tree. The T082 lane (author c-414) touched the same file; never the author c-981.' >"$T/b1.md"
out="$(_spl_review_go_row "$T/b1.md" "$H" t1)"; rc=$?
[[ $rc -eq 0 && "${out%%$'\t'*}" == c-981 ]] && pass "b23-01: Author: c-981 line, prose 'author c-414' -> row c-981" ||
  fail "b23-01: Author: c-981 line, prose 'author c-414' -> rc $rc '${out//$'\t'/|}' (review-go holds rc 3)"
printf '%s\n' "Author: c-981@boxa" "Author: c-414@boxa" "Branch \`review/x\` at \`$H\`." >"$T/b2.md"
_spl_review_go_row "$T/b2.md" "$H" t1 >/dev/null; rc=$?
[[ $rc -eq 1 ]] && pass "b23-01 control: two Author: lines with two ids -> no row (rc 1)" || fail "b23-01 control: two Author: lines -> rc $rc"
printf '%s\n' "Author c-222@boxa (claude), with author c-333@boxa. Branch \`review/x\` at \`$H\`." >"$T/b3.md"
_spl_review_go_row "$T/b3.md" "$H" t1 >/dev/null; rc=$?
[[ $rc -eq 1 ]] && pass "b23-01 control: no Author: line, prose names two authors (suite case 14) -> rc 1" || fail "b23-01 control: case 14 shape -> rc $rc"
printf '%s\n' "Author c-222@boxa (claude). Branch \`review/x\` at \`$H\`." >"$T/b4.md"
out="$(_spl_review_go_row "$T/b4.md" "$H" t1)"; rc=$?
[[ $rc -eq 0 && "${out%%$'\t'*}" == c-222 ]] && pass "b23-01 control: no Author: line, one prose author -> row c-222" || fail "b23-01 control: prose form lost (rc $rc)"
echo "b23-01: $fails failure(s)"; [[ $fails -eq 0 ]]
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b23-02 red control. spl_done_claim_tokens from <sha>'s
# spl-done-claim-check.func.sh (RC_PROTO=<file>: that file instead), on bodies
# that cite a file hash. Run from any checkout; it is not touched.
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT; fails=0
if [[ -n "${RC_PROTO:-}" ]]; then cp "$RC_PROTO" "$T/f.sh"; else
  git show "$sha:csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh" | sed -n "/^spl_done_claim_tokens()/,/^}/p" >"$T/f.sh"; fi
source "$T/f.sh"
spl_done_claim_commits() { cat; }   # no repo: print every candidate token
pass() { echo "PASS: $*"; }; fail() { echo "FAIL: $*"; fails=$((fails + 1)); }
for body in 'rc01.sh sha256sum -> 92fd284d8549' 'sha256 92fd284d8549 of rc01.sh' 'SHA-256: 92fd284d8549' 'sha1sum=4a5f55c8a4f3'; do
  out="$(spl_done_claim_tokens <<<"$body")"
  [[ -z "$out" ]] && pass "b23-02: '$body' -> no sha" || fail "b23-02: '$body' -> read as a git sha: $out"
done
out="$(spl_done_claim_tokens <<<'files md5 d99415cbcf6b')"
[[ -z "$out" ]] && pass "b23-02 control: an md5 label (SPL-2332) -> no sha" || fail "b23-02 control: md5 label -> $out"
out="$(spl_done_claim_tokens <<<'sha: 3e46a758ce7a landed')"
[[ "$out" == 3e46a758ce7a ]] && pass "b23-02 control: a 'sha:' label still names a git sha (SPL-2338)" || fail "b23-02 control: 'sha:' label -> '$out'"
echo "b23-02: $fails failure(s)"; [[ $fails -eq 0 ]]
```

---

## 4. Round 22's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b22-01, b22-02 | `git log origin/master --oneline -E --grep='\(b22-0[12]-'` | landed `ddd59b510`, `b144fea59` (b22-01), `3e46a758c` (b22-02) | Served (round 22 closed, the brief). |
| Round 22 section 5 items not repeated in section 5 below (b20-01 N3 wording, the "nothing pushed" done-claim alerts, the `workflow-tool-checksums.tst.sh:33` guard never asserted, the relative `log:` path) | as round 22 | unchanged | Closed as round 22 says: wording; by design; a test-coverage gap with no failing behaviour (not a bug row); a seat-brief defect. |

---

## 5. Not a row this round, or no red control yet

| candidate | command | result |
|---|---|---|
| **review-go retries a GO forever to a retired author on another box** (round 22 section 5; the holder's list) | `<box2>`'s `/var/csi/csi-spl/review-go/cron.out`: its tail is `INFO the dispatch lease is held by c-002@sat, on another machine: its machine sends the GO` on every tick; `grep -ac 'review-go.*rc=3' /var/spool-hub/dispatch/automation.log` -> 6, the newest 2026-11-09 | **No observed case on `<box2>`, no red control.** The review-go cron acts only where the lease is (sat). Round 22's reading stands: the relay's exit 3 also covers transient failures, so exit 13 alone does not mean "retired". The holder reads sat's `review-go/cron.out` for `failed (rc 13)` (section 8); with a case, the control is a relay stub that answers `unknown_agent`. |
| **orc / iac suites not hermetic to the OS user** (the holder's list; c-001 a9ee75ee) | round 22's measurement (`watcher-read-only.tst.sh` fails only for a user that cannot write the worktree: `t_spool_bin` builds into the source tree's `bin/`) | **Not re-measured this round; no sat output.** c-001's a9ee75ee is on sat and is not in the prd hub's `messages` table (`msg_id::text like 'a9ee75ee%'` -> 0 rows, 17:38Z): asked of the holder (section 8). It breaks developer guide 2.12.2 (a test writes outside its temp dir); with sat's failing output it is round 24's first row. |
| **r66-02 N1: a shallow APP_PATH gives `SPL_VAR_ORG_DIR=/var/`** | `source csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh; APP_PATH=/app spl_run_paths` at `23864a224` -> `SPL_VAR_ORG_DIR=/var/`, `SPL_VAR_APP_DIR=/var//app`; `APP_PATH=/opt/csi/csi-spl` -> `/var/csi`, `/var/csi/csi-spl` (`spl-run-paths.func.sh:66-73`) | **Mechanism reproduced, no observed case (n=0).** Only a checkout one level under `/` does it, a layout the canonical path rule (developer guide 2.3.1, `${BASE_PATH}/${ORG}/${APP}`) does not allow. Not a row until a real run on such a path is seen. |
| **r66-02 N2: `FATAL no cargo` in `_scg_build` is swallowed** | `spl-cmd-guard-mode.func.sh:42` at `23864a224`: `do_log "FATAL no cargo ..."` without `>&2`, inside `bin="$(_scg_build)"`; the rust-home FATAL at `:39` has `>&2` | **Unchanged; a lost diagnostic only** (round 22): the run still fails and the log file keeps the line. A one-token `>&2` for whichever lane next edits the file. |
| **iac `gcp-billing-invoices.tst.sh`** (`FAIL: download iframe ... no documents list on the "Invoices" page`) | section 2, source 2 | n=1 (44570765247), green on the next run: a flake candidate, not a row unless it repeats (the brief). |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The `issues-ctxmenu` e2e failure `4j Shift+O opens the issue` (3rd sighting in 100 runs) | the holder's ask 05200a28 (`c002-wui-e2e-issues-ctxmenu-4j-shift-o`, msg f5fbb900); when this plan was drafted, **none found**: `lane-map.sh --check csi-spl-wui/tests/e2e/issues-ctxmenu.test.mjs --agent c-536` (17:4xZ) -> no live lane lists it (exit 4 for c-946@sat only); the newest commits on the file: `b6c01b230`, `43b290114`, `cf945aa32` | Handed to the holder as a rulebook 2.11.3 fixing lane (a trunk-red fix, `fix(wui, SPL-<n>)`, not a round row). The holder read the 3 job logs: `4j` fails on the first run and on the retry in all three; queued as ask 05200a28. |
| The live lanes of the brief (c-946@sat SPL-5963; c-521 SPL-5980; c-484 r67-03 SPL-5975; c-526 refactor round 68 planner; the customer workspace seats) | their lanes | None touches the rows' files (section 3.1). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 7 named inputs; 40 human posts counted (7 t1 and 1 csitea read); 100 CI runs; 38 cron logs (0 hits in 24 h); 2025 reviewer-ish briefs scanned for row 01; 274 outbox messages with a `sha256` label checked against 16698 ledger lines for row 02 |
| first inputs for round 24 | the hermetic-suite failure (sat's output, c-001 a9ee75ee); the relayed retired-author send (sat's `review-go/cron.out`); the `issues-ctxmenu` failure if ask 05200a28's lane does not fix it |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-536@`<box2>` (claude, `specs_and_docs`).
- **Panel:** asked of the dispatch holder on task `dispatch-bug-r23`, with at least one non-claude seat. The panel checks both red controls (`rc01.sh 23864a224` and `rc02.sh 23864a224`: RED; it may rebuild them from section 3.2), the fix scopes (row 01: only a brief with a line-start `Author:` line drops the prose form, and case 14's two prose authors stay rc 3; row 02: only the `sha<N>` labels are cut, a bare `sha:` label still names git shas), the evidence (c-001 8a6b6dfe and 95722c63 on sat; the two seat briefs on `<box2>`), what row 01's fix changes for the observed waiver seats (rc 3 -> rc 2, no GO), and that every other input in sections 2, 4, 5 and 6 is measured as written.
- **Asked of the holder with the panel request:** the sat half of the slug check (3.1: 0 on sat, msg 435040d4); whether c-001's 95722c63 is an alert on a `sha256` token (yes, n=2: row 02 stays); c-001's a9ee75ee and sat's `review-go/cron.out` for `failed (rc 13)` (round 24 inputs, section 5); the `issues-ctxmenu` lane (ask 05200a28, msg f5fbb900).
- **Row reviewers (R7):** a grok seat per row (cross-vendor to the claude authors); backup named by the holder.
- **Review history:**
  - 2026-11-19 17:48Z: the editor pushed v0.1 (`05c8b15bf`) to `review/c002-bug-round-23-planner` and asked the holder for a panel (msg 9ca4df7d). grok was on hold and agy out of quota on `<box2>`, so the panel is one mistral seat (msg 435040d4).
  - 2026-11-19: panel seat m-033@sat (mistral, placed by c-002@sat, msg f5fbb900): **PASS** on `05c8b15bfe97fd9fca9fb2cd98b31af3d59c5a8c`, 0 warnings (msg 63a036dd); seat file `csi-spl-doc/doc/md/bug-round-23/seat-mistral.md` on `review/c002-bug-round-23-mistral-seat` at `c8c98ff0b`. It rebuilt both red controls from section 3.2 and ran them on `23864a224` (`rc01.sh` -> 1 FAIL, 3 controls PASS, exit 1; `rc02.sh` -> 4 FAIL, 2 controls PASS, exit 1), both prototypes rebuilt from their description (4 PASS and 6 PASS, exit 0), every cited line at `23864a224` and `origin/master`, the slug check on sat, `lane-map.sh --check`, the test columns, `do_check_dist_hygiene` (clean) and `do_check_pre_push` (all parts passed).
  - Panel notes, folded in v1.0 (none changes a row):
    - N1: `origin/master` moved to `a97766b47` during the read; the six row files are byte-identical between `23864a224` and it (`git diff --stat` empty, re-run by the editor on `a97766b47`).
    - N2: `lane-map.sh --check` on the six row paths from sat exits 4: no lane lists them, 10 `<box2>` lanes record no files: ask first, not free. The orchestrator re-runs R3 before the spawn.
    - N3: section 4's round 22 leftovers rest on round 22's plan, not a new measurement.
    - N4: the hermetic-suite item (section 5) is not re-measured this round; it waits for sat's output (round 24).
    - N5: section 5's retired-author counts are `<box2>`'s and cannot be re-run from sat.
    - N6: both prototypes, rebuilt from the plan's description, reach 0 failures with the controls intact.
    - N7: `W` re-measured as written.
  - v1.0: the editor folded the notes above, the sat slug result (3.1), c-003's 95722c63 check (row 02) and the holder's ask 05200a28 (section 6).

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-536@`<box2>` | **v1.0** |
| Panel | m-033@sat (mistral) | **PASS** on `05c8b15bf` (msg 63a036dd, seat file `c8c98ff0b`) |
