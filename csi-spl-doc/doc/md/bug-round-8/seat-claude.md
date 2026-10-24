# Bug round 8 - claude reviewer seat verdict on plan v0.2

Seat: **c-082@&lt;box&gt;** (claude), cross-vendor to the agy editor a-819 (rulebook 2.7.2).
Takeover of the voided mistral seat; its file and verdicts were not read.
Issue: SPL-3148. Plan reviewed: `csi-spl-doc/doc/md/bug-round-8-plan.md` **v0.2**,
commit `7bbe8f77c` (newest on origin/master at review time: `git log origin/master --
csi-spl-doc/doc/md/bug-round-8-plan.md` -> `7bbe8f77c`, `c0a38c8af`). Counts measured on `b9a9aea12`.
Worktree HEAD = origin/master = `a6ba6e3220bab34a13c8a3d3feca10dcd70bdacb` at start, `git status --short` empty.
`git diff --stat b9a9aea12 origin/master -- <func> <tst>` -> empty: the two row 01 files are unchanged since the plan's sha.
Session log: `~<HARNESS_USER>/.claude/projects/-opt-csi-csi-spl-wt-c-082/635d0cd8-cdd0-4928-838e-77b20ae2166f.jsonl`.

## 1. Verdict summary

| item | verdict |
|---|---|
| Row 01 (`fix(b08-01-orc-review-log-agent-match)`) | **agree with changes** (C1-C5 below) |
| Section 4 (a) Part 2, summary words in `ran:` | **agree** |
| Section 4 (b), store tests skipped without Postgres | **agree** |
| Section 4 (c), desk-cron `bin/spool` | **agree with changes** (the "why" is wrong, the verdict holds) |
| Section 4, owner report f8335e7f | **agree** |
| Section 5, `lane-restart.tst.sh` case 6 | **agree with changes** (wrong landed sha) |

## 2. Row 01

### 2.1 The red control, re-run (scratch `/tmp/c082-r8`, repo untouched)

Tree: `git archive b9a9aea12 csi-spl-orc | tar -x -C /tmp/c082-r8/tree`. Fixture `$T=/tmp/c082-r8/fx`:
`u11/s1/CURRENT` (`{}`), `u11/s1/meta.json` (`{"environment":{"working_directory":"/opt/csi/csi-spl-wt/m-901"}}`),
`u11/s1/chunks/c1.json` (`[{"input":{"command":"cd /x && bash csi-spl-orc/src/bash/tests/git-prune-round-branches.tst.sh"}}]`).
Command, run as `<DEV_USER>` from `csi-spl-orc` (n=1 each):

`env REVIEW_LINE_BOX=box-a SPOOL_ROOT=$T REVIEW_LINE="review: m-902@box-a mistral PASS 0123456789abcdef0123456789abcdef01234567 ran: bash csi-spl-orc/src/bash/tests/git-prune-round-branches.tst.sh | read: 9 PASS | log: m-902@box-a:$T/u11/s1" ./run -a do_spl_review_line_check`

| run | summary line | rc |
|---|---|---|
| today (`b9a9aea12`) | `OK 1 of 1 named in ran: are commands in /tmp/c082-r8/fx/u11/s1 (1 commands read)` | 0 |
| plan's fix applied to the scratch `spl-review-line-check.func.sh` | `FATAL log /tmp/c082-r8/fx/u11/s1 belongs to agent m-901, not reviewer m-902` | 1 |
| control, `meta.json` names `m-902` | `OK 1 of 1 named in ran: are commands in /tmp/c082-r8/fx/u11/s1 (1 commands read)` | 0 |

`./run` passes the action's rc through: the same line with `ran: bash nothere.tst.sh` -> `FAIL 0 of 1`, rc 3.
The red control **fails today**. No `NOTE read as ... (sudo -n)` line here: `/tmp` is readable as `<DEV_USER>`.

The fix I applied (scratch only) is my reading of the row's fix scope: the reviewer id passed as
`argv[2]` to `_SPL_REVIEW_LINE_PY`, then rules (a) meta.json, (b) `-opt-csi-csi-spl-wt-<id>`,
(c) `/var/spool-hub/<id>/`, (d) agy `/brain/<uuid>/` via `last_conversations.json`, else the
first worktree id in the first 64 KiB of `transcript.jsonl`; refuse when an id is found and differs.

### 2.2 Sites (printed with `git show b9a9aea12:<path> | cat -n` / `sed -n`)

- `spl-review-line-check.func.sh:56` `_spl_review_line_reviewer "${line%%$'\n'*}" || return 1`;
  `:134` `[[ "$who" == "$owner" ]] || { echo "SYNTAX FAIL reviewer $who is not the log: owner $owner"; return 1; }`
  is the only id check, string to string; `:74` `_spl_review_line_match "$path" "$owner" <<<"$names"`;
  `:177-179` the matcher; `:182-250` the python (the row says 177-249: `:249` is `sys.exit(3 if miss else 0)`, `:250` the closing quote). Correct.
- `spl-review-line-check.tst.sh:199-212` case 10, `:214` the summary echo; "new case 11 after :213" is right (`:213` is blank).
- Callers: `git grep -n -e do_spl_review_line_check -e _spl_review_line_ b9a9aea12 -- ':!csi-spl-doc' ':!<func>' ':!<tst>'`
  -> 1 hit, a comment (`spl-done-claim-check.func.sh:85`). No code caller; the check is run by hand.

### 2.3 Existing cases with the fix

Patched scratch tree, `bash src/bash/tests/spl-review-line-check.tst.sh` -> `spl-review-line-check: 0 failure(s)`,
rc 0, 33 `PASS` lines, 0 `FAIL` (the test lib sources the scratch tree's `src/bash/run/*.func.sh`).
No existing fixture has a `meta.json`, a `-opt-csi-csi-spl-wt-` or `/var/spool-hub/<id>/` path, or a `/brain/<uuid>/` path, so none can break.

### 2.4 False refusals: measured on this box (n per line)

| shape | measured | result |
|---|---|---|
| vibe `meta.json` (rule a) | 310 sessions under `<home>/.vibe/logs/session/unified/*/meta.json`: 285 carry a `csi-spl-wt/<id>`; working dir id vs `origin_directory` id vs `git_branch` prefix: **0 of 285 differ** | no false refusal seen |
| claude project path (rule b) | `.claude/projects` slugs of both users: 119 `-opt-csi-csi-spl-wt-<id>`; legacy `-wt-CLE-002` / `-wt-CLE-003` do not match `[acgmq]-` | a renamed legacy seat is a gap, not a refusal |
| live seats | 22 agent processes (`/proc/<pid>/cwd` + `SPOOL_AGENT_ID`): the 19 in a `*-wt/<id>` dir all run as that id (the live rotation seat here, `c-189-rotate-2`, included); c-001 runs in `/opt`, c-423 in `/var/tmp` | 0 of 19 differ; the seats outside a worktree match no rule (gap). Rotation seats on the other box were not measured |
| agy brain (rule d, cache) | 283 rows in `last_conversations.json`, one uuid per workspace (the LAST conversation only): 173 of 517 brain dirs are mapped | older conversations fall through to the transcript scan |
| agy brain (rule d, transcript scan) | 156 mapped worktree brains: first worktree id in `transcript.jsonl` = mapped workspace id **156 of 156**; 46 brains name 2+ worktree ids in the first 64 KiB, 45 of them without a seed id line, first id checked by hand: 0 wrong | no false refusal seen |
| agy, constructed takeover brief | transcript line 0: `TAKEOVER from a-901: do not read /opt/csi/csi-spl-wt/a-901. Your spool agent id is a-902. Worktree /opt/csi/csi-spl-wt/a-902`, reviewer a-902 | today rc 0 `OK 1 of 1`; with the fix **rc 1 `FATAL ... belongs to agent a-901, not reviewer a-902`**: a false refusal (n=1, constructed) |

### 2.5 The dispatcher's agy and vibe shapes (scratch fixtures, n=1 each)

Columns: `orig` = `b9a9aea12`; `fix` = my reading (meta.json looked up in the dir and its parent);
`lit` = the row's literal words, "`meta.json` in `path` (or its parent directory)".

| log: | reviewer | orig | fix | lit |
|---|---|---|---|---|
| vibe session dir, meta.json m-901 | m-902 | rc 0 OK | rc 1 FATAL m-901 | rc 1 FATAL m-901 |
| same | m-901 | rc 0 OK | rc 0 OK | rc 0 OK |
| vibe journal FILE `s1/journal/0001.jsonl`, meta.json m-901 in `s1/` | m-902 | rc 0 OK | rc 1 FATAL m-901 | **rc 0 OK (defect open)** |
| same | m-901 | rc 0 OK | rc 0 OK | rc 0 OK |
| vibe session dir without meta.json | m-902 | rc 0 OK | rc 0 OK (gap) | rc 0 OK (gap) |
| agy brain, transcript names a-901's worktree | a-902 | rc 0 OK | rc 1 FATAL a-901 | rc 1 FATAL a-901 |
| same | a-901 | rc 0 OK | rc 0 OK | rc 0 OK |
| agy brain, no id in transcript, `last_conversations.json` maps a-901's worktree to it | a-902 | rc 0 OK | rc 1 FATAL a-901 | rc 1 FATAL a-901 |
| same | a-901 | rc 0 OK | rc 0 OK | rc 0 OK |

An agy brain with no id in its transcript and no cache row, and a vibe session without meta.json,
stay open: the row names that as its known gap, which is right. 78 of 495 real agy transcripts
hold no worktree id in their first 64 KiB.

### 2.6 Changes asked for Row 01

- **C1 (rule a, a hole):** a vibe log cited as a live journal FILE (`<session>/journal/<n>.jsonl`; 306 of 310
  sessions here have one) keeps `meta.json` two levels up. "path or its parent" misses it (table 2.5, `lit`).
  Word it: look for `meta.json` from the path up to the session dir (the first dir holding `CURRENT` or `chunks/`),
  and add that shape to case 11.
- **C2 (rule a, a key):** `origin_directory` is a TOP-LEVEL key of `meta.json`, not under `environment`
  (real meta.json keys: `session_id`, ..., `environment` {`working_directory`}, `origin_directory`, ...). Say so in the fix scope.
- **C3 (rule d, a false refusal):** "scan `transcript.jsonl` for an agent worktree" must not take the first worktree
  mention: a takeover brief or a tool listing of other worktrees comes first (2.4, constructed). Use, in order:
  the seed's `spool agent id is <id>`, else the cache row, else refuse only when the reviewer's own worktree never
  appears and another does. Add the takeover fixture as case 11's control.
- **C4 (grammar):** use `[acgmq]-[0-9]{3,}` (the id grammar of `:133` and `spool-env.inc.sh:42`), not `[0-9]+`:
  4 real transcripts hold truncated tool output such as `/opt/csi/csi-spl-wt/a-2` and `/opt/csi/csi-spl-wt/a-9`.
- **C5 (rule d, location):** read `last_conversations.json` from the home the cited `brain/` path is under
  (`<prefix>/.gemini/antigravity-cli/cache/`), not a fixed `~<HARNESS_USER>`; and match `/brain/<uuid>(/|$)` so a
  cited brain DIR counts too.
- Known gap, add one line: worktrees of other repos (`/opt/<org>/<repo>-wt/<id>`, two live here) and seats run
  outside a worktree (two live) match no rule; the check falls back to command presence there.

One defect, one lane, the two named sites only, red control fails today: agree, with C1-C5 folded.

## 3. Section 4 and 5

### 3.1 (a) Part 2: summary words in `ran:` - agree

`cd csi-spl-orc && env REVIEW_LINE="review: m-937@box2 mistral PASS b9a9aea12596c8216b858014d0c928ee01e46f2a ran: fetch,test,red-control,lint | read: ok | log: m-937@box2:/tmp" REVIEW_LINE_BOX=box2 ./run -a do_spl_review_line_check`
-> `MISSING ran: names no test (*.tst.sh, *.test.mjs, *_test.go, go test, pnpm run): 'fetch,test,red-control,lint'`, rc 3 (n=1).
The same line on another box with `REVIEW_LINE_SYNTAX=1` (`REVIEW_LINE_BOX=box-a`) ->
`SYNTAX FAIL ran: names no test (...)`, rc 1 (n=1). Both match the plan.

### 3.2 (b) store tests skipped without Postgres - agree

By design: `spl-review-line-check.func.sh:20` "Tool OUTPUT never counts" (the plan says line 21; the phrase is on `:20`,
`:21` continues it). Running against Postgres is the pre-push full tier's job.

### 3.3 (c) desk-cron `bin/spool` - agree with changes

- `ls -l <desk-cron>/csi-spl-api/src/go/spool-hub-api/bin/spool` -> `No such file or directory`, rc 2 on this box.
- `git -C <desk-cron> check-ignore -v --no-index csi-spl-api/src/go/spool-hub-api/bin/spool` ->
  `csi-spl-api/src/go/spool-hub-api/.gitignore:1:/bin/`, rc 0; `git ls-files --error-unmatch` on it -> rc 1 (untracked).
- The other box's leftover file was not measured by this seat.
- **Change:** the plan's why says the desk-cron jobs use `~/.local/bin/spool`, "NOT the repository's git-ignored
  `bin/spool`". Wrong: `spool_env_resolve` prefers it, `spool-env.inc.sh:422-424`
  (`built="$repo/csi-spl-api/src/go/spool-hub-api/bin/spool"`; `if [ -x "$built" ] && ! _spool_bin_stale ...; then SPOOL_BIN="$built"`).
  A stale one is skipped with the very WARN reported (`:60-62`, `... is older than its sources ...; not using it`) and
  `_spool_bin_fallback` takes PATH, then `$HOME/.local/bin/spool` (`:72-73`); only with no other spool is the stale one used, loudly (`:74-77`).
  So: not a bug, the WARN is the guard working. Reword the why.

### 3.4 Owner report f8335e7f - agree

`git log -1 --format='%h %s' b9a9aea12` -> `b9a9aea12 fix(wui, SPL-3120): the bouncing dots show on every Back on a phone`. The prd query was not re-run by this seat.

### 3.5 Section 5, `lane-restart.tst.sh` case 6 - agree with changes

The plan cites `2087a0a37` as round 7 row 03's landing. `git merge-base --is-ancestor 2087a0a37 origin/master` -> rc 1:
not on master. The landed commit with that subject is `23a6a2eff`
(`fix(b06-03-orc-lane-restart-case6-diag, SPL-3114)`, ancestor rc 0). Cite `23a6a2eff`.
The "0 occurrences since" count was not re-measured by this seat.

## 4. Scope note

`lane-map.sh --check csi-spl-doc/doc/md/bug-round-8/seat-claude.md --agent c-082` -> exit 4: no lane lists it;
14 lanes record no files (rotation seats, s107-v2, s144, s149, r19 WUI decompose); none is on bug round 8.
This file is the only edit; the plan's rows are the editor's.

## 5. Signature

**Signed v1.0** (`e02cf9459`): C1-C5 in row 01, section 4 (b) line 20, 4 (c) why and section 5 sha `23a6a2eff` all folded, checked by `git show e02cf9459:csi-spl-doc/doc/md/bug-round-8-plan.md`. c-082@&lt;box&gt; (claude).
