# Bug-fix round 28 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6046 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `be1daf61-85bb-4870-8eb4-ffd8d71f51b2` ("Bug round 28", opener msg c069eda8, opened by c-002@sat 10:43:34Z). Round 27 ([bug-round-27-plan.md](bug-round-27-plan.md) v1.0, 2 rows) is closed: close record `d2e4c74eb` (SPL-6019); b27-01 `656ab3389` (SPL-6027), b27-02 `21abdb87e` (SPL-6028). Bug share: c-001 spawn share 37c4d3ff (bug 19%, under the 20% band).  
Round focus: the two follow-ups the round 27 rows left open: b27-02's panel-seat match misses the `-panel-seat-<vendor>` slug form (R7 c-325 W1), and spec 157 still describes b27-01's review-go path without its "on origin/master" case (b27-01 land report N5).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`; every other input is accounted for in sections 2, 4 and 5.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-27-plan.md](bug-round-27-plan.md) (same shape, same 5 sources).

**Status: v0.1, draft for the panel (section 8).**

Editor: **c-362@sat** (claude, `specs_and_docs`).  
Panel: the b28 mistral panel seat (ask `c002-bug-round-28-mistral-panel-seat`, queued with this planner): pending.

**One sha:** every count below is measured on **`d2f3f3b90`** (`origin/master` at this seat's first fetch, 11:47:53Z), on sat, between 11:47Z and 11:56Z on 2026-11-20, unless a row says otherwise. n=1 per command unless stated. At 11:56Z `origin/master` was `62daca7aa`, one commit on (a cnf mark, `chore(cnf, SPL-5432)`); `git diff --name-only d2f3f3b90 origin/master -- <the row and site files of section 3>` -> empty.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b27-plan')` -> `Window: W=2026-11-20T12:33:38+02:00` (commit `d2e4c74eb`, 10:33:38Z).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 27. `<PUSH_USER>` is the OS user that owns the checkouts and pushes, `<AGENT_USER>` the OS user the agents run as (the public repo names neither).

---

## 1. How to read this

- Round 27 measured on `0509f0b7b`. This plan re-measures what changed since (`git rev-list --count 0509f0b7b..d2f3f3b90` -> 33 commits; 8 since W), round 27's first inputs for round 28 (its section 7), the holder's candidates file and b27-01's land report (the brief), and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `d2f3f3b90`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `d2f3f3b90`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since W** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-20T10:33:38Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (11:49:29Z); the same window with `body ~* '(altgr\|enter\|picker\|switcher\|kind pick)'` | t1: 15 posts, 0 with a bug word, 6 `[spool-probe]`; csitea: 7 posts, 0 with a bug word. The picker / switcher words: 0 | **0 rows** from new reports; no owner word on section 4's two product questions. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <PUSH_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (started 11:47Z) | wf 10: 100 runs (2026-11-19T16:04Z..2026-11-20T11:45Z): 71 success, 20 cancelled, 8 failure, 1 running. Since W (`gh run list --workflow 10_ci-quality.yml --branch master`, `createdAt >= W`): 3 `failure` (44721014389 and 44721863161 on `b106c0e76`, 44725157504 on `061a53899`), 5 `success`, 3 `cancelled`, 2 `in_progress`; the newest completed run, 44729864583 on `d2f3f3b90`, is `success`. `grep -c agent-name-shape <the report>` -> 0 | **0 rows** from a red. orc 1/4 `M1. ... login-mode: own -> own (own at 91% (mark 95) ...)` (44719335863, 44721014389, 44721863161): fixed by `fcaccd5ce` `fix(orc, SPL-5432): the login-mode test pins claude's mark at 90, not the cnf's`, green from 44725547076. iac `gcp-billing-invoices.tst.sh` (`FAIL: download iframe: FATAL ... no documents list on the "Invoices" page`, job log of 44725157504, `1 FAILED`, `258/259 test files passed`): its **2nd** sighting (the 1st, 44570765247 on 2026-11-19, round 23 section 4), green on the next run 44725547076: a flake candidate under rulebook 2.11.3 (a fixing lane at the 3rd), section 6. orc 4/4 `start on A: 4 descendants, want 3` (44713446284, 09:45Z, the brief's `wd-reload-leak.tst.sh:148`): 1 sighting in 100 runs, not red again. The others predate W and were read by rounds 23 to 25. |
| **3. Skipped or disabled tests** | `git diff 0509f0b7b d2f3f3b90 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file: `csi-spl-api/src/go/spool-hub-api/cmd/spool-pdf/main_test.go`, a new file (+208), its two `t.Skip("NOT RUN: no pdftotext on this box")` / `t.Skip("NOT RUN: no Chrome or Chromium on this box")` | **0 rows.** No existing test was skipped; the new file is spec 183 P2's (`061a53899`, a live lane, R3), and it skips on a missing tool, not a red. |
| **4. Box cron logs** | sat: `/var/csi/csi-spl/done-claim-check/cron.log` from the first run after W (line 45500, 10:35:01Z) to 11:50:01Z: `grep -c START`, `grep -cP '\talert\t'`, `grep -cE 'job [0-9a-f]{6,}'`, `grep -oE '[0-9]+ alerted'` | 16 runs (15 ended `rc=0`, 1 running), 0 alert rows, 0 `job <hex>`; 13 OK summaries, each `0 alerted` (the 10:40Z and 10:45Z runs printed no summary line, rc 0). `<box2>`: asked of the holder (section 8) | **0 rows** (sat half). |
| **5. Round 27's first inputs, the holder's candidates, the land reports** | round 27 section 7; `/var/spool-hub/dispatch/c002-next-round-candidates.md`, its "next BUG round" and "Bug-shaped" entries; c-307 msg 1fcad9af (b27-01 land report) | 6 + 7 + 1 inputs | **2 rows**: 01 from c-325's R7 W1 on b27-02 (candidates file, last entry), 02 from b27-01's N5. The other 12: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `d2f3f3b90`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b28-01-orc-place-panel-seat-vendor-suffix)` | **b27-02 spares a read-only mistral panel seat from the UI swap only when its slug ENDS in `-panel-seat`; the `-panel-seat-<vendor>` form still swaps to agy.** `spl_spawn_place_swap` (`spl-spawn-place.func.sh:1019`) tests `[[ "$(basename "$2" .md)" == *-panel-seat ]]`. A panel seat named `<x>-panel-seat-mistral` (the form of the spec and design panels) has `Kind: specs_and_docs`, so a quoted `csi-spl-wui/<letter>` path trips `spl_lane_mix_ui_target` and the seat swaps to agy (`:1028`), which the placer holds (agy out on sat, at quota on `<box2>`, round 27 row 02). | c-325 R7 PASS on b27-02 `f1ed08d34` (msg 5f6e2dfc) W1, n=1, re-measured here on sat 11:4xZ: `ls /var/spool-hub/dispatch/briefs \| grep -c panel-seat` -> 104; `grep -E 'panel-seat\.md$'` -> 61; `grep -E 'panel-seat[^.]'` -> 43, of them `-panel-seat-mistral.md` 15, `-panel-seat-mistral-2.md` 1 (plus one `.bak` copy); one of those quotes a WUI path (`grep -c 'csi-spl-wui/' c002-s152-panel-seat-mistral.md` -> 1) and still swaps on `d2f3f3b90` (rc01). Every `-panel-seat-mistral` brief carries the mtime 2026-11-18T12:51Z (no newer one): the form is latent, not in today's queue; the next spec panel that uses it is held. | `csi-spl-orc/src/bash/run/spl-spawn-place.func.sh:1019` (the slug test), `:1003-1014` (its comment), `:107-111` (the action's @description); the test `csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh:1110-1159` (the SPL-3776 / SPL-3954 / SPL-6028 cases); read only: `spl-spawn-place.func.sh:1041-1044` (`spl_spawn_place_review_seat`), `csi-spl-orc/src/bash/run/spl-lane-mix.func.sh` (`spl_lane_mix_ui_target`), `csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh` (the other caller of `spl_spawn_place_review_seat`) | `bash /var/spool-hub/dispatch/b28-red-controls/rc01.sh d2f3f3b90 /var/spool-hub/dispatch/briefs/c002-s152-panel-seat-mistral.md /var/spool-hub/dispatch/briefs/c002-bug-round-28-mistral-panel-seat.md /var/spool-hub/dispatch/briefs/c002-b27-02-orc-place-panel-seat-no-ui-swap.md` (section 3.2) -> `rc01 x-panel-seat-mistral.md -> agy (mistral takes no UI work until do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/))` / the same for `x-panel-seat-mistral-2.md` and `c002-s152-panel-seat-mistral.md` / `rc01 sha=d2f3f3b90 wrong=3`, exit 1, n=3 (11:56Z). | `spl-spawn-place.func.sh` and `spl-spawn-queue.tst.sh` only. A slug ending `-panel-seat`, or `-panel-seat-<vendor>` with an optional `-<suffix>` (vendor one of `agy`, `claude`, `grok`, `mistral`, `qwen`; e.g. `-panel-seat-mistral-2`), is a panel seat for the swap: the UI and coding rules do not swap it, and a mistral panel seat on a mistral author is still refused (`spl_spawn_place_authors`). **A coding lane whose slug merely holds the words is not a seat**: `c002-b27-02-orc-place-panel-seat-no-ui-swap` (`Kind: simple_coding`) still swaps off mistral (rc01's `x-orc-panel-seat-no-ui-swap` control); a bare `*-panel-seat*` glob is the wrong fix. Keep the change in the swap (as b27-02 did), not in `spl_spawn_place_review_seat`, unless the lane shows `spl-spawn-review-notify.func.sh` sends no wrong author note for a panel seat. The suite: a mistral `-panel-seat-mistral` brief, `Kind: specs_and_docs`, quoting a `csi-spl-wui/src/...` path, launches mistral (red on `d2f3f3b90`); the `-no-ui-swap` coding control still swaps; the SPL-3954 build-row controls stay green. Commit body: rc01 on the fix -> exit 0 (`wrong=0`), on `d2f3f3b90` -> exit 1. The comment at `:1010-1013` and the @description at `:108` say both slug forms. Docs: the @description is the doc, or `Docs: none (<why>)`, the lane's call. | sat | claude | claude waiver seat (1a7c70da), fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |
| 02 `fix(b28-02-doc-spec157-review-go-on-master)` | **Spec 157 describes the review GO's "elsewhere" path without b27-01's "on origin/master" case.** Since `656ab3389` (b27-01), `_spl_review_go_elsewhere` reports a reviewed sha that is an ancestor of origin's master as landed: `echo "is on origin/master (it landed; the row's branch '$1' is no longer on origin)"` (`spl-review-go.func.sh:816`, @description `:72`), before the local-branch and worktree checks. Spec 157's bullet "The reviewed sha off the row's branch" (`spec.md:258`) still lists only (c) a related origin branch and (a) a local branch or worktree HEAD, "found locally only (the author must still push it to land)": a reader of the spec expects the false "found locally only" GO that b27-01 removed. | c-307 msg 1fcad9af (b27-01 land report): "Still open: N5, spec 157 spec.md:258 (outside this row's files)". Re-measured: `git show d2f3f3b90:csi-spl-doc/specs/157-dispatch-automation/spec.md \| grep -n 'found locally only'` -> `258:`; that bullet names `origin/master` 0 times; `git grep -n 'is on origin/master (it landed' d2f3f3b90 -- csi-spl-orc/src/bash/run/spl-review-go.func.sh` -> `:816`; `git log -1 --format=%h d2f3f3b90 -- csi-spl-doc/specs/157-dispatch-automation/spec.md` -> `7b6cd900e` (b23-01), older than b27-01. | `csi-spl-doc/specs/157-dispatch-automation/spec.md:258` (the bullet); read only: `csi-spl-orc/src/bash/run/spl-review-go.func.sh:72`, `:790-835` (`_spl_review_go_elsewhere` and its comment) | `bash /var/spool-hub/dispatch/b28-red-controls/rc02.sh d2f3f3b90` (section 3.2) -> `rc02 sha=d2f3f3b90 bullet-line=258 code-on-master=1 bullet-names-origin-master=0`, exit 1, n=3 (11:5xZ). | `spec.md` only, the one bullet. Case (a) says, in the code's order: origin answers, has no branch of that name, and the sha is on origin's master (the tip `ls-remote` names, else this box's `refs/remotes/origin/master`, nothing fetched): the GO says "on origin/master" (it landed, b27-01, SPL-6027); else a local branch or worktree HEAD: "found locally only". It may add that the PASS record keeps the bare message id whatever `do_log` writes (b27-01 (a)), if the record bullet does not say it already. No code change. Commit body: rc02 on the fix -> exit 0, on `d2f3f3b90` -> exit 1. A docs-only sha: the R7 line may say `ran: none` with the rc02 output in `read:` (rulebook 2.7.4, `DOCS-ONLY`). | sat | claude | the b28 mistral panel seat (a non-author seat, cross-vendor, read-only doc review; rulebook 2.7.2), backup the claude waiver seat (1a7c70da) | `specs_and_docs` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** rows 01 and 02, disjoint. Row 01: `spl-spawn-place.func.sh`, `spl-spawn-queue.tst.sh`. Row 02: `csi-spl-doc/specs/157-dispatch-automation/spec.md`.
- **Test column (R2):**
  - Row 01: `git grep -l 'place_swap\|review_seat\|panel-seat' d2f3f3b90 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features` (as round 27 row 02): at least `spl-spawn-queue.tst.sh`, `spl-spawn-place-argmax.tst.sh`, `spl-box-pick.tst.sh`, `spawn-agents/tests/test-lane-issue.sh`, and `rc01.sh`.
  - Row 02: `rc02.sh`; `cd csi-spl-iac && ./run -a do_check_dist_hygiene`.
- **Off limits** for the row lanes: every live and queued lane's files (below); `spl-lane-mix.func.sh`, `spl-spawn-review-notify.func.sh` and `spl-review-go.func.sh` (read only).
- **Shared test file, queued:** refactor round 75 row 01 (ask 6f3ec664, `claude:c002-r75-01-orc-var-app-subdir-own-logdir-crons`, queued) adds one case to `spl-spawn-queue.tst.sh` (its brief, line 18) and lists `spl-spawn-place.func.sh` as off limits (line 19). R3: the orchestrator places row 01 only while no live lane holds `spl-spawn-queue.tst.sh` (`lane-map.sh --check`); if r75-01 is live first, row 01 waits for it to land, then rebases. Row 01 edits only the SPL-6028 block (`:1110-1159`).
- **How the files were checked (2026-11-20, sat):**
  - 11:54:08Z `lane-map.sh --check csi-spl-orc/src/bash/run/spl-spawn-place.func.sh,csi-spl-orc/src/bash/tests/spl-spawn-queue.tst.sh,csi-spl-doc/specs/157-dispatch-automation/spec.md,csi-spl-doc/doc/md/bug-round-28-plan.md --agent c-362` -> `WARN no live lane lists` them; exit 4 for 13 `<box2>` lanes that record no files: 7 orchestrator rotation branches (`c-049-rotate`, `c-060-rotate`, `c-625-rotate`, `c-812-rotate`, `c-924-rotate-2`, `c-927-rotate`, `c-977-rotate`), spec 182 L1, L2b, L3 (c-968, c-973, c-975), spec 183 P1 (c-981), `c970-review-build` (c-970, spec 182 L2's scope per the brief) and `c-052-c002-s-msg-forward-spec` (a spec lane). By the brief's scopes, none is a row file; the holder confirms the `<box2>` half (section 8).
  - 11:54:17Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `18 queued, 0 placing`; `grep -l -E 'spl-spawn-place.func.sh\|spl-spawn-queue.tst.sh\|157-dispatch-automation/spec.md'` over the 18 queued briefs -> 1, r75-01 (above).
- **Slug b28 is unused as a round id** (sat, 11:47:53Z, on `d2f3f3b90`): `git log origin/master --since="$W" --oneline -E --grep='\(b28-'` -> 0; `git ls-remote origin 'refs/heads/review/b28-*' 'refs/heads/wip/*b28*' 'refs/heads/*-b28-*'` -> nothing; `ls /var/spool-hub/dispatch/briefs \| grep -E 'b28-[0-9]{2}\|bug-round-28'` -> 2, this planner's brief and its mistral panel seat's (`c002-bug-round-28-planner.md`, `c002-bug-round-28-mistral-panel-seat.md`), no UUID hit; `git worktree list \| grep -E 'b28-[0-9]{2}\|bug-round-28'` -> 1, this planner's own (`c-362-c002-bug-round-28-planner`), 0 row worktrees. `<box2>`'s half: asked of the holder (section 8).

  After this plan's pushes, `--grep='(b28-'` matches the plan's commits (`docs(b28-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b28-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red controls run on `d2f3f3b90`

Both files are on sat in `/var/spool-hub/dispatch/b28-red-controls/`, and printed below so a seat on `<box2>` can rebuild them. `rc01.sh` 2441 B, `rc02.sh` 839 B (`sha256sum` first 12 hex `ce884e8d3052`, `1161749de2a6`). rc01 exports `csi-spl-orc` and `csi-spl-cnf` of the sha with `git archive` (no worktree, nothing installed) and needs bash, git, python3 and `yq`; rc02 reads two files with `git show`.

| row | command | output on `d2f3f3b90` | who |
|---|---|---|---|
| 01 | `bash rc01.sh d2f3f3b90 <briefs>/c002-s152-panel-seat-mistral.md <briefs>/c002-bug-round-28-mistral-panel-seat.md <briefs>/c002-b27-02-orc-place-panel-seat-no-ui-swap.md`, from a checkout, n=3 (11:56Z) | RED in 3 of 3: `rc01 x-mistral-panel-seat.md -> mistral` / `rc01 x-panel-seat-mistral.md -> agy (mistral takes no UI work until do_spl_vendor_ui_retest passes (the brief names csi-spl-wui/))` / `rc01 x-panel-seat-mistral-2.md -> agy (...)` / `rc01 x-orc-panel-seat-no-ui-swap.md -> claude (...)` / `rc01 c002-s152-panel-seat-mistral.md -> agy (...)` / `rc01 c002-bug-round-28-mistral-panel-seat.md -> mistral` / `rc01 c002-b27-02-orc-place-panel-seat-no-ui-swap.md -> claude (mistral writes no code, kind simple_coding (...))` / `rc01 sha=d2f3f3b90 wrong=3`, exit 1. Read: the two `-panel-seat` suffix seats stay mistral (b27-02 works); the three `-panel-seat-<vendor>` seats swap; the two coding controls swap, as they must. | editor c-362 |
| 02 | `bash rc02.sh d2f3f3b90`, from a checkout, n=3 (11:5xZ) | RED in 3 of 3: `rc02 sha=d2f3f3b90 bullet-line=258 code-on-master=1 bullet-names-origin-master=0`, exit 1 | editor c-362 |

No prototype fix was written: each change is its row lane's, with its own red controls. There is no green control on this sha: the green half is the lane's.

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha> [brief...]: b28-01 red control. Exports csi-spl-orc and
# csi-spl-cnf of <sha> (git archive, no worktree), sources its lane-mix and
# spawn-place functions and asks spl_spawn_place_swap what a mistral placement
# of each brief launches. Built-in briefs (same text, Kind: specs_and_docs, a
# live-lanes line quoting csi-spl-wui/src/components/Foo.vue):
# x-mistral-panel-seat.md (the suffix form b27-02 spares, the control),
# x-panel-seat-mistral.md and x-panel-seat-mistral-2.md (the vendor-suffix
# forms), and x-orc-panel-seat-no-ui-swap.md (Kind: simple_coding, a coding
# lane whose slug merely holds the words: the control that must NOT stay
# mistral). Extra briefs given as args are checked too. A panel seat is a slug
# ending -panel-seat, or -panel-seat-<vendor> with an optional -<suffix>
# (vendor agy|claude|grok|mistral|qwen). RED when such a seat does not stay
# mistral, or the coding control does. Run from a checkout.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha> [brief...]}"; shift
full="$(git rev-parse "$sha^{commit}")" || exit 2
C="$(mktemp -d)"; trap 'rm -rf -- "$C"' EXIT
git archive "$full" csi-spl-orc csi-spl-cnf | tar -x -C "$C" || exit 2
for s in x-mistral-panel-seat x-panel-seat-mistral x-panel-seat-mistral-2 x-orc-panel-seat-no-ui-swap; do
  k=specs_and_docs; [[ $s == *no-ui-swap ]] && k=simple_coding
  printf '# Lane brief: %s\n\nKind: %s\n\nRead only. Live lanes to stay off: r99-01 edits `csi-spl-wui/src/components/Foo.vue`.\n' "$s" "$k" >"$C/$s.md"
done
rx='-panel-seat(-(agy|claude|grok|mistral|qwen)(-[0-9a-z]+)?)?$'
bad=0
for b in "$C/x-mistral-panel-seat.md" "$C/x-panel-seat-mistral.md" "$C/x-panel-seat-mistral-2.md" "$C/x-orc-panel-seat-no-ui-swap.md" "$@"; do
  got="$(cd "$C/csi-spl-orc" && PROJ_PATH="$PWD" APP_PATH="$C" bash -c 'set -uo pipefail
    do_log() { echo "$*" >&2; }
    for f in lib/bash/funcs/*.func.sh; do source "$f"; done
    source src/bash/run/spl-lane-mix.func.sh; source src/bash/run/spl-spawn-place.func.sh
    spl_spawn_place_swap mistral "$1"' _ "$b" 2>/dev/null)"
  to="${got%%$'\t'*}" why="${got#*$'\t'}"
  echo "rc01 $(basename "$b") -> ${to:-?}${why:+ ($why)}"
  if [[ "$(basename "$b" .md)" =~ $rx ]]; then [[ "$to" != mistral ]] && bad=$((bad + 1))
  elif [[ "$(basename "$b" .md)" == x-orc-panel-seat-no-ui-swap && "$to" == mistral ]]; then bad=$((bad + 1)); fi
done
echo "rc01 sha=${full:0:9} wrong=$bad"
(( bad == 0 ))
```

`rc02.sh`, as run:

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b28-02 red control. Reads spec 157's "The reviewed sha off
# the row's branch" bullet at <sha> and the code's (a) branch of
# _spl_review_go_elsewhere: RED when the code says "is on origin/master" and
# the bullet does not name origin/master (spec behind the code, b27-01 N5).
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
spec="$(git show "$full:csi-spl-doc/specs/157-dispatch-automation/spec.md" | grep -n '^- \*\*The reviewed sha off the row.s branch\*\*')"
code="$(git show "$full:csi-spl-orc/src/bash/run/spl-review-go.func.sh" | grep -c 'is on origin/master (it landed')"
n="$(grep -c 'origin/master' <<<"$spec")"
echo "rc02 sha=${full:0:9} bullet-line=${spec%%:*} code-on-master=$code bullet-names-origin-master=$n"
(( code == 0 || n > 0 ))
```

---

## 4. Round 27's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b27-01, b27-02 | `git log origin/master --oneline -E --grep='\(b27-0[12]-'` | landed `656ab3389`, `21abdb87e` | Served (round 27 closed, `d2e4c74eb`). Their open follow-ups are this round's rows. |
| The done-claim `job` label (a row if a `job <hex>` token alone alerts) | source 4 (section 2) | sat: 16 runs since W, 0 alert rows, 0 `job <hex>` | **Not a row**: the condition did not occur. Stays an input on the same condition. |
| `test-agent-name-shape.sh:89` (a row once seen red) | source 2 | `grep -c agent-name-shape <the report>` -> 0 | **Not a row**: not seen red. Stays an input on the same condition. |
| SPL-5850 N1: an AltGr letter may pick a kind (`csi-spl-wui/src/utils/kind-picker-keys.ts`) | source 1: 0 owner posts with the picker words since W | no rule, no owner word | **No rule it breaks, no owner word.** Carried on round 27's condition. |
| The desktop blog switcher's Enter on its one match | source 1; `git log -1 --format='%h %s' d2f3f3b90 -- csi-spl-wui/tests/e2e/blog.test.mjs csi-spl-wui/src/components/LanguageSwitcher.vue` -> `c540aca24` (b26-01) | no rule, no owner word | **A product question, no rule.** Carried on round 27's condition. |
| The orc/iac suites as the agent OS user, if seen red | as `<AGENT_USER>` on `d2f3f3b90`, 11:50Z: `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` -> rc 0, `ALL PASS`; `bash csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh` -> rc 0, `81 passed, 0 failed` | not red (n=1 each) | **Not reproduced**, as in round 27. An input if seen red with its user and tree. |
| Doc input: the slug regex `b27-[0-9]{2}` also matches UUID-named briefs | the regex is the planner brief's slug proof (`ls dispatch/briefs \| grep -E 'b<N>-[0-9]{2}\|bug-round-<N>'`), not rulebook 5.3's text: `git grep -c 'ls /var/spool-hub/dispatch/briefs' d2f3f3b90 -- csi-spl-doc/doc/md/rounds-rulebook.md` -> 0. On sat today `b28-[0-9]{2}` hits 0 UUID-named briefs | a false hit costs one read (round 27 resolved 3 by hand) | **Not a row**: no rule text to fix in the rulebook. The brief template's regex could anchor on `(^\|-)b28-[0-9]{2}-`; handed to the holder (section 6). |

---

## 5. The holder's candidates, re-measured; not a row this round

| candidate | command | result |
|---|---|---|
| **The placer's `-panel-seat-<vendor>` miss** (c-325 R7 W1 on b27-02, msg 5f6e2dfc) | section 3 | **Row 01.** |
| **b27-01 N5, spec 157 `spec.md:258`** (c-307 msg 1fcad9af) | section 3 | **Row 02.** |
| **`unanswered-sweep.tst.sh` section 12 fails as the push user** (c-973 msg fecf24d8, c-001 99942044, n=1) | `bash csi-spl-orc/src/bash/tests/unanswered-sweep.tst.sh` on `d2f3f3b90` as `<AGENT_USER>`, 11:52Z -> rc 0, `PASS: 12. a burst every 2 min is listed at minute 3, once`, `unanswered-sweep: all passed` | **Owned (R3)**: the file is spec 182 L2b's (c-973@`<box2>`, "the unanswered-sweep tests", the brief), the lane that reported it; a bug row may not take it. Not re-run as `<PUSH_USER>` here (a read-only planner seat); handed to the holder for c-973 (section 6). |
| **orc/iac suites not hermetic to the OS user** (c-947 75843c44) | section 4 | **Not reproduced.** |
| **review-notify takes `author c-NNN` inside a never-list** (c-001 364398a4) | `git log -1 --format='%h %s' d2f3f3b90 -- csi-spl-orc/src/bash/run/spl-spawn-review-notify.func.sh` | **Fixed**: `3e46a758c` `fix(b22-02-orc-review-notify-author-line-wins, SPL-5976)`. |
| **done-claim check takes a sha256sum prefix for a git sha** (c-001 95722c63) | `git grep -n 'sha256sum' d2f3f3b90 -- csi-spl-orc/src/bash/run/spl-done-claim-check.func.sh` | **Fixed** (SPL-5990): `:344`, the token after the label is skipped. |
| **`csi-spl-wui/tests/e2e/blog.test.mjs:329` fails run alone** (SPL-5960 R7 N3) | `git log -1 --format='%h %s' d2f3f3b90 -- csi-spl-wui/tests/e2e/blog.test.mjs` -> `c540aca24` | **Served** by b26-01 (round 27 section 5); its one open part is section 4's product question. |
| **Rows A and B of the reflection; `fallback_postgres.go:83-86`** | the brief | **Not bugs** (detectors; a test round's input). |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row's file (lane map 11:54:08Z); r75-01 (queued) shares `spl-spawn-queue.tst.sh` with row 01: R3 orders them. |
| `unanswered-sweep.tst.sh` section 12 as the push user | spec 182 L2b, c-973@`<box2>` | Green as `<AGENT_USER>` on `d2f3f3b90` (n=1); the push-user run is the lane's to show. |
| iac `gcp-billing-invoices.tst.sh` `download iframe` | the holder (rulebook 2.11.3) | 2nd sighting in 100 runs (44570765247, 44725157504), each green on the next run; a fixing lane at the 3rd. |
| The planner brief's slug regex | the holder (brief template) | Anchor it so a UUID-named brief does not match (section 4). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 6 round 27 inputs, 7 holder candidates, 1 land report note; 22 human posts since W (6 probes, 0 bug words); 100 CI runs and one failed job log; 1 cron log (16 runs); 2 red controls (n=3 each); 3 suites re-run as the agent OS user |
| first inputs for round 29 | the done-claim `job` label if it alerts alone; the AltGr picker if a rule or the owner says how it must pick; the desktop blog switcher's Enter on its one match if a rule or the owner says Enter must pick; `test-agent-name-shape.sh:89` if seen red; the orc/iac suites as the agent OS user if seen red, with user and tree; `gcp-billing-invoices.tst.sh` `download iframe` at its 3rd sighting; `unanswered-sweep.tst.sh` section 12 if L2b closes without it |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-362@sat (claude, `specs_and_docs`).
- **Panel:** the b28 mistral panel seat (ask `c002-bug-round-28-mistral-panel-seat`, queued with this planner; its slug ends `-panel-seat`, so b27-02 keeps it on mistral, rc01). Row 01 is orc bash, row 02 a spec text; no WUI file, so a mistral seat may sit (developer guide 5.1). This plan quotes `csi-spl-wui/` paths in sections 3 and 4; the seat's brief need not copy them (b27-02 spares the `-panel-seat` form either way).
- **Asked of the holder with v0.1:** the `<box2>` halves: the slug check (briefs and worktrees matching `b28-[0-9]{2}\|bug-round-28`), the done-claim cron counts since W, and the 13 exit-4 lanes of section 3.1. The holder confirms `do_spl_review_line_check` rc 0 on the panel's line before the plan lands.
- **Row reviewer (R7):** row 01: the claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (11:55:19Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, <box2> [sat 99% billing read 25m ago; <box2> 99% billing read 25m ago]: queue the lane, spawn nothing`. Row 02: the b28 mistral panel seat (cross-vendor to a claude author, read-only doc review), backup the claude waiver seat.
- **Review history:**
  - 2026-11-20 12:0xZ: the editor pushed v0.1 to `review/c002-bug-round-28-planner` and asked the holder for the panel.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-362@sat | v0.1 |
| Panel | the b28 mistral panel seat | pending |
