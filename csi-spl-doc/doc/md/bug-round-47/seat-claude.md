# Bug round 47 - panel seat claude (c-642)

Seat: c-642 (claude, cross-vendor panel seat of rulebook 3.2), placement `c002-bug-round-47-claude-panel-seat`.  
Review target: `csi-spl-doc/doc/md/bug-round-47-plan.md` v0.1 on `review/c002-bug-round-47-planner`, sha **`50f3a73d19d494abbca0186fe85001bcc0deda43`** (`git ls-remote origin refs/heads/review/c002-bug-round-47-planner` -> that sha, 19:2xZ). Plan base: `8b97f2979db3a269f2b74060caa915029f11e402`. `origin/master` at this seat's fetch: `3582fc44b9d3915d38109393bc2acaf3fdbb1473`.

**Verdict: PENDING (state record before a lane rotation at 19:38Z; checks 3 to 8 not finished).** No PASS or FAIL is given on this commit.

## State for the next session

- Done: checks 1 and 2 (row 01 and row 02 sites), reading of rulebook sections 1 to 3 and 5 and of `bug-round-46-plan.md`.
- Not done: check 2 for row 03; checks 3 (run the three red controls), 4 (row 03), 5, 6 (lane map), 7 (inputs), 8 (hygiene).
- Report goes to `a-709@sat` (editor) and the dispatch lease holder (`LEASE_CMD=show`; it read `c-002@sat` at 18:4xZ, the planner names `c-003@sat`) on task `dispatch-bug-r47`.

## 1. Slug b47 unused since W

- `W=2026-11-25T08:53:09+02:00`: `git log b1aea77d5 -1 --format=%cI` -> `2026-11-25T08:53:09+02:00` (round 46 v1.0 plan commit). `git log 8b97f2979 -1 --format=%cI -E --grep='^docs\(b46-plan'` now prints `2026-11-25T21:03:26+02:00` (the close record `8b97f2979`); the plan says it read W before that commit landed, as rulebook 5.3 allows.
- `git log origin/master --since="$W" --oneline -E --grep='\(b47-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'b47-[0-9]{2}|bug-round-47'` -> only `50f3a73d... refs/heads/review/c002-bug-round-47-planner`.
- `git ls-remote origin 'refs/heads/review/b47-*' 'refs/heads/wip/*b47*' 'refs/heads/*-b47-*' 'refs/heads/*bug-round-47*'` -> only the planner branch.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b47-[0-9]{2}|bug-round-47'` -> nothing (rc 1) on this box; this seat's brief is in `/var/spool-hub/spawn-remote/briefs/` (one other file there matches `b47-` only inside a message uuid `32759b47-...`, not a round brief).

## 2. Sites on `8b97f2979` (so far)

Row 01:
- `mcp_test.go:79` -> `cmd.Env = append(os.Environ(),` (the statement is `:79-82`; `:77-78` are the comment). The plan cites `:77-80` in sections 3.1 and 5: see N1.
- `topic_pdf_test.go:86-88` -> the `cmd.Env = append(os.Environ(), ...)` statement, matches.
- `git grep -n 'Environ' 8b97f2979 -- csi-spl-api/src/go/spool-hub-api/internal/mcp/` -> 2 hits (`mcp_test.go:79`, `topic_pdf_test.go:86`), matches the plan.
- `cmd/spool/main_verbs_test.go:100-111` cited for `localBox`: wrong lines. `git grep -n 'func localBox' 8b97f2979` -> `main_verbs_test.go:20`; the helper is `:20-41`, and it blanks a named list of 13 `SPOOL_*` keys with `t.Setenv`, it does not strip by prefix: see N2.

Row 02:
- `spl-dispatch-subscribe.func.sh:128` `_spl_dispatch_subs_read() {`, `:139-142` `hon|`, `:165-173` the `hum|` query, `:168` `FROM messages m`, `:171` `AND m.loop_id IS NULL`: all match. `git grep -n 'FROM messages' 8b97f2979 -- csi-spl-orc/src/bash/run/spl-dispatch-subscribe.func.sh` -> 1 hit `:168`.
- `wui.go:774` `channelHumansOnly`, `:777` `isNoteToSelf`, `:815` `fanOut: !rt.noteToSelf && ...`; `channels.go:352` `if channel == "" || env.Sig == ""`, `:355` `channelAgentsHear`; `replay_postgres.go:19` `AND NOT note_to_self`: all match.
- Consumer: `spl-dispatch-subscribe.func.sh:358` reads `hum|`, `:361` UNSIGNED when `uns > 0`, `:369` SILENT when the desk has 0 inbound files.

## Findings so far (provisional)

- N1: row 01 cites `mcp_test.go:77-80`; the `cmd.Env` statement is `:79-82`.
- N2: section 3.1 cites `localBox` at `main_verbs_test.go:100-111`; it is `:20-41` and overrides a named key list, it does not strip `SPOOL_*`.
- N3 (to confirm): row 02's `wh` fixture stores the humans-only post with `env_sig = ''`; by `wui.go:815` an ordinary post in a humans-only channel gets `fanOut` true and is signed, so its real shape is `hum|1|0` (a false SILENT, not a false UNSIGNED).
