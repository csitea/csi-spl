# Bug round 47 - panel seat claude (c-642)

Seat: c-642@`<box2>` (claude, cross-vendor panel seat of rulebook 3.2), placement `c002-bug-round-47-claude-panel-seat`.  
Review target: `csi-spl-doc/doc/md/bug-round-47-plan.md` v0.1 on `review/c002-bug-round-47-planner`, sha **`50f3a73d19d494abbca0186fe85001bcc0deda43`** (`git ls-remote origin refs/heads/review/c002-bug-round-47-planner` -> that sha, 19:2xZ; named by the editor a-709@sat, msg `81daf703`). Plan base: `8b97f2979db3a269f2b74060caa915029f11e402`. `origin/master` at this seat's fetches (19:2xZ..19:3xZ): `3582fc44b`.

**Verdict: PASS on `50f3a73d19d494abbca0186fe85001bcc0deda43`. W: none. N1 to N6 (below), none blocking.** Every row site exists on the base and is unchanged on `origin/master`; the three red controls match their printed hashes and sizes byte for byte, fail on the base for the reason the plan gives and pass with `fix-shape`; each defect is real on the tree.

n=1 per command unless stated. All commands ran on this seat's box, 2026-11-25 19:2xZ..19:3xZ.

## 1. Slug b47 unused since W

- `W=2026-11-25T08:53:09+02:00`: `git log b1aea77d5 -1 --format=%cI` -> `2026-11-25T08:53:09+02:00` (round 46 v1.0 plan commit). `git log 8b97f2979 -1 --format=%cI -E --grep='^docs\(b46-plan'` prints `2026-11-25T21:03:26+02:00` today (the close record `8b97f2979`, a newer `docs(b46-plan` commit); the plan read W before that commit landed and records it, as rulebook 5.3 says.
- `git log origin/master --since="$W" --oneline -E --grep='\(b47-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b47-[0-9]{2}|bug-round-47'` -> only `50f3a73d... refs/heads/review/c002-bug-round-47-planner` (before this seat's own branch was pushed).
- `git ls-remote origin 'refs/heads/review/b47-*' 'refs/heads/wip/*b47*' 'refs/heads/*-b47-*' 'refs/heads/*bug-round-47*'` -> only the planner branch.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b47-[0-9]{2}|bug-round-47'` -> nothing (rc 1) on this box. This seat's brief is in `/var/spool-hub/spawn-remote/briefs/`; the one other file there that matches `b47-` does so only inside a message uuid (`32759b47-...`), not a round brief. The planner's brief is on sat, not read here.

## 2. Sites on `8b97f2979`, and drift to `origin/master`

Drift: `git diff --name-only 8b97f2979 origin/master -- <the 6 row files> | wc -l` -> `0` (`origin/master` = `3582fc44b`).

Row 01:
- `mcp_test.go:79` -> `cmd.Env = append(os.Environ(),`; the statement is `:79-82`, `:77-78` are its comment. The row table cites `:77-80` (N1).
- `topic_pdf_test.go:86-88` -> the `cmd.Env = append(os.Environ(), ...)` statement: matches.
- `git grep -n 'Environ' 8b97f2979 -- csi-spl-api/src/go/spool-hub-api/internal/mcp/` -> 2 hits, `mcp_test.go:79`, `topic_pdf_test.go:86`: matches the plan's sweep.
- `localBox` cited at `cmd/spool/main_verbs_test.go:100-111`: `git grep -n 'func localBox' 8b97f2979` -> `main_verbs_test.go:20`; the helper is `:20-41` (N2).

Row 02:
- `spl-dispatch-subscribe.func.sh:128` `_spl_dispatch_subs_read() {`, `:139-142` `hon|`, `:165-173` the `hum|` query, `:168` `FROM messages m`, `:171` `AND m.loop_id IS NULL`: all match. `git grep -n 'FROM messages' 8b97f2979 -- <that file>` -> 1 hit, `:168`.
- `wui.go:774` `channelHumansOnly`, `:777` `isNoteToSelf`, `:815` `fanOut: !rt.noteToSelf && ...`; `channels.go:352` `if channel == "" || env.Sig == ""`, `:355` `channelAgentsHear`; `replay_postgres.go:19` `AND NOT note_to_self`; `note_to_self.go:17-22` (reaches no agent, carries `messages.note_to_self`): all match.
- `dispatch-inbound-pg.tst.sh` is 194 lines; "section 8 after `:191`" is in range.

Row 03:
- `spl-spawn-place.func.sh:831` `spl_spawn_place_pin_full() {` .. `:847` `}`; `:1437` `spl_spawn_place_pin_hold() {` .. `:1453` `}`; `:1444` `[[ -n "$out" ]] || out="$(spl_spawn_place_pick_out)"`; `:564-579` `spl_spawn_place_hold_class`; `:1484` `spl_spawn_place_agy_box_hold` .. `:1532` `}`: all match.
- `spl_spawn_place_wait_keep ... "^pinned to [a-z0-9]+: "` is at `:1451`, not `:1453` (N3).
- `spl-box-pick.func.sh:277`: the `not picked` markers are emitted at `:274-275` (`grep -n 'not picked'` on the base: `:274`, `:275` in code; `:277` is the `INFO ... weekly usage unknown` line) (N3).
- `spawn-window.sh:315-326` `place_box()`: matches; it does refuse a missing CLI for a named `SPAWN_BOX` (`sw_lacks_kind`, `:319` and `:324`) (N4).
- `spl-spawn-queue.tst.sh:2590-2597` ends with case 43d; case 44 after it is in range.

## 3. Red controls, read and run on the base in scratch copies

Extracted from the plan's three `bash` blocks (python `re` over `git show 50f3a73d:csi-spl-doc/doc/md/bug-round-47-plan.md`):

| script | `sha256sum` | bytes | plan says |
|---|---|---|---|
| `rc01-b47.sh` | `daed9f6a49a7b1a29011384c0cc9001f8b11a159c3f5381856df7066abcc60d5` | 3725 | `daed9f6a49a7`, 3725 B: match |
| `rc02-b47.sh` | `a4d03b302a1c00d3deb1ecda78e762d4166304228a8898a30680fb3513de0951` | 4812 | `a4d03b302a1c`, 4812 B: match |
| `rc03-b47.sh` | `c48085295e9e9225b0d4cfa4d99195dadbd268d6ab4ca4598d34da6e09e175ec` | 7727 | `c48085295e9e`, 7727 B: match |

| run | last lines | exit |
|---|---|---|
| `bash rc01-b47.sh 8b97f2979` | `rc01_b47_test.go:21: rc01 mcp_test.go: harness.run inherited caller SPOOL_* env: rc=1 stderr="spool: SPOOL_MSG_VERSION 99 must be 1 or 2"` / `topic_pdf_test.go:102: cli rc 1 "spool: SPOOL_MSG_VERSION 99 must be 1 or 2\n"` / `FAIL ... internal/mcp 31.629s` / `rc01 exit 1` | 1 |
| `bash rc01-b47.sh 8b97f2979 fix-shape` | `PASS` / `ok ... internal/mcp 33.049s` / `rc01 exit 0` | 0 |
| `bash rc02-b47.sh 8b97f2979` | `rc02 note_to_self(wn)=hum\|1\|1 (want hum\|0\|0); humans_only(wh)=hum\|1\|1 (want hum\|0\|0); mixed_control(wc)=hum\|3\|3 (want hum\|1\|1)` / `rc02 exit 1` | 1 |
| `bash rc02-b47.sh 8b97f2979 fix-shape` | `... (wn)=hum\|0\|0 ...; (wh)=hum\|0\|0 ...; (wc)=hum\|1\|1 ...` / `rc02 exit 0` | 0 |
| `bash rc03-b47.sh 8b97f2979` | `rc03 unheld=10000001-...,...,10000006-... (want 10000002-...,10000006-...)` / `rc03 waits=` / `rc03 exit 1` | 1 |
| `bash rc03-b47.sh 8b97f2979 fix-shape` | `rc03 unheld=10000002-...,10000006-...` / waits hold `claude weekly 94% >= 90%`, `claude weekly 96% >= 95%`, `grok weekly unknown, its own mark 95%`, `DISK /mnt/data 88% >= 85%` / `rc03 exit 0` | 0 |

Each fails for the plan's reason (rc01: the CLI child reads the caller's `SPOOL_MSG_VERSION`; rc02: the `hum|` counts; rc03: no pinned row held), not for an environment reason. Live state: rc01 builds into a `mktemp -d` tree from `git archive`; rc02 runs a throwaway `postgres:16-alpine` container with `--rm` and `docker rm -fv` on exit (`docker ps -a --filter name=rc02-b47` -> none after the runs) and a hand-made schema; rc03 sets `SPOOL_ROOT` to its temp dir and stubs `SPAWN_PLACE_PICK_CMD`. None touches the live spool, the hub or a box.

## 4. The defects, on the tree

- **b47-01: real, narrow.** `harness.run` and the topic-pdf `cli` both append to `os.Environ()`; Go's `exec` keeps the last value of a duplicated key, so the explicit overrides win, but any `SPOOL_*` key they do not name reaches the child. On this seat's box the agent shell exports 6 `SPOOL_*` keys (`env | grep -c '^SPOOL_'` -> 6, among them `SPOOL_AGENT_ID`), which the harness does not name. Test-only fix; the red control proves it at both sites and goes green on the fix shape.
- **b47-02: real, narrow.** A note to self gets `fanOut` false (`wui.go:815`) and reaches no agent; a humans-only channel's `channelAgentsHear` is false (`channels.go:355`), so neither reaches the desk, yet both pass the `hum|` filter at `:169-173` and feed SILENT at `:369`. The fix is two predicates in one query; the red control proves both and keeps an ordinary post counted (`wc` control).
- **b47-03: real.** `do_spl_box_pick` prints the weekly marks only when `$kind` is set (`spl-box-pick.func.sh:275`: `if $kind == "" or .nokind then ""`), and `pin_hold` calls it with no `BOX_PICK_KIND` (`:1444`); `pin_full` matches neither weekly nor `DISK` marks (`:841-846`); a pinned `SPAWN_BOX` launch skips `do_spl_box_pick` (`spawn-window.sh:318-325`). The `DISK` mark is printed whatever the kind (it comes from the stats, `spl-box-pick.func.sh:222`), so that half is real too. Scope: two functions and one test case; see N4 and N5.

## 5. Row form (R1, R2, R7, kind, vendor, batch)

- Every row has a red control that fails today and passes on the fix shape, a test column, vendor `claude`, a kind (`tests`, `simple_coding`, `simple_coding`), batch 1: yes.
- No mistral coding or testing row: vendor column `claude` x3. R7 reviewer: agy, else the claude waiver seat `1a7c70da`; no mistral, no grok: yes.
- R1: the three file pairs share no file (row 01 `internal/mcp/*_test.go`, row 02 `spl-dispatch-subscribe.func.sh` + `dispatch-inbound-pg.tst.sh`, row 03 `spl-spawn-place.func.sh` + `spl-spawn-queue.tst.sh`): yes.

## 6. R3

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 6 row files> --agent c-642` (19:29Z, n=2: the first hub read timed out once and retried) -> **exit 4**: `WARN no live lane lists <the 6 paths>, but 5 live lane(s) record no files`: `unknown:` a-709@sat (this round's planner), c-298@sat (Taxes tab), c-692@sat (`c-692-rotate`), c-718@sat (lat-a6 in-turn protocol), c-737@sat (y9 agy/qwen rule parts). None of these lanes' slugs names a row file; the plan's own list (19:14Z) named 18 `<box2>` `unknown:` lanes, none of which is in today's list. Not free until the holder re-runs `--check` at placement, as the plan says.

## 7. Inputs accounted for

- Round 46 section 7 (first inputs for round 47), each against the plan's section 3.6: hours-minutes 400 follow-up (carried, 0 live warns since b46-01), `apply` rule [4] (carried), `spl-dispatch-subscribe.func.sh` SILENT gap (served by SPL-6523 `bbc2adb26`; its R7 notes are row 02), `spl-customer-box-role-check.func.sh:115-122` N3 (carried), the buffer-budget tests (carried), the `unknown_token` box, hub dir mode, hermetic 2/4 timeout, composed testids, `i18n-lang-review-exempt.json:2` and the N2 list (carried). None is left out.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md`: **NOT RUN** here, the file is on sat only (`ls` -> `No such file or directory` on this seat's box).
- prd logs, alert incidents, open bug issues, CI per job: **NOT RUN** by this seat (prd reads need the holder's box and key; this seat read the plan's counts only and does not vouch for them).
- Row count: 3, the cap of 5.1 (aim 2). All three are fresh R7 notes on landed commits, each with a working red control. If the editor trims to 2, row 01 (test-only, needs a foreign `SPOOL_*` key in the caller's shell) is the one to carry (N6).

## 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of <this worktree>` (with this seat file staged).

## Notes

- **N1** (row 01 site): the row table and section 3.1 cite `mcp_test.go:77-80`; the `cmd.Env` statement is `:79-82` (`:77-78` its comment). Cite `:79-82`.
- **N2** (section 3.1): `localBox` is at `cmd/spool/main_verbs_test.go:20-41`, not `:100-111`, and it blanks a named list of 13 `SPOOL_*` keys with `t.Setenv`; it does not strip by prefix. "Unlike `localBox`" holds only in that `localBox` names more keys.
- **N3** (section 3.3 evidence lines): `spl_spawn_place_wait_keep` is at `:1451` (not `:1453`); the `not picked` marks of `spl-box-pick.func.sh` are at `:274-275` (not `:277`).
- **N4** (row 03 scope): a named `SPAWN_BOX` with no CLI for the kind is already refused at launch (`spawn-window.sh` `place_box`, `sw_lacks_kind`). The `no <kind> CLI: not picked` match turns that refusal into a queued hold, which is fine, but section 3.3's "launches onto a box" is true for the weekly and `DISK` marks only.
- **N5** (row 03 red control): `rc03-b47.sh` has no fixture for the `no <kind> CLI: not picked` mark, so the red control proves the weekly and `DISK` halves only. Add a row to rc03 and case 44, or drop the CLI match from the fix scope.
- **N6** (row 02 fixture, row count): `rc02`'s `wh` post has `env_sig = ''`; by `wui.go:815` an ordinary post in a humans-only channel gets `fanOut` true and is signed, so its real shape is `hum|1|0` (a false SILENT, not a false UNSIGNED). Model the case 8(b) fixture as signed. And see section 7 for which row to carry if the round is trimmed to 2.
