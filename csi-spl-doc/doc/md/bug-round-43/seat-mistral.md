# Bug round 43 — panel seat mistral (m-625@<box2>)

Issue: SPL-6349 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/db3d80d8-0bef-4649-9895-f5df428e4201.md`.
Review target: `csi-spl-doc/doc/md/bug-round-43-plan.md` on branch
`review/c002-bug-round-43-planner`, at the plan version sha
`21010c205f59b66368cc5225d26e89787ec05749` (v0.1), named by the brief (planner
c-971@sat). `git ls-remote origin refs/heads/review/c002-bug-round-43-planner`
-> exactly that sha, still the branch head at my check (2026-11-24T06:2xZ).
`git show 21010c20 --stat` -> one file, `bug-round-43-plan.md | 203 +++...`,
1 file changed, 203 insertions, on `c4000b25b`. `origin/master` at my fetch:
`c4000b25b8eeb6c8e2e5a252c480fd9fb5e2f18a` — the plan's measurement sha; the
head did not move. Rules: `csi-spl-doc/doc/md/rounds-rulebook.md` sections 1 to
3 and 5 (3.2: the panel is a non-claude seat; this seat writes no code). Form:
`csi-spl-doc/doc/md/bug-round-42-plan.md` on origin/master and
`csi-spl-doc/doc/md/bug-round-41/seat-mistral.md`. Every file:line below was
printed with `git show c4000b25b:<file> | sed -n <N>p` (or the stated command)
before it is cited; every command quoted was run by me on this box,
2026-11-24T06:0xZ..06:4xZ.

**Verdict: PASS, 1 row, on `21010c205f59b66368cc5225d26e89787ec05749` (v0.1).**
No defect W; notes N1..N5 below.

## Check 1 — slug b43 unused since the plan's W

W per the plan: `2026-11-24T02:03:55+02:00`, commit `c23d5019c` — re-verified:
`git log origin/master -1 --format='%H %cI' -E --grep='^docs\(b42-plan'` ->
`c23d5019cf530072455bde1a28440a96274e67a3 2026-11-24T02:03:55+02:00`.

- `git log origin/master --since="2026-11-24T02:03:55+02:00" --oneline -E --grep='\(b43-' | wc -l`
  -> `0`.
- `git ls-remote origin | grep -E 'b43-[0-9]{2}|bug-round-43'` ->
  `21010c205f59b66368cc5225d26e89787ec05749\trefs/heads/review/c002-bug-round-43-planner`
  only — the planner's branch, expected; this seat's review branch did not
  exist yet at this check. Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b43-[0-9]{2}|bug-round-43'` ->
  no match (rc 1); the dir is readable here (3283 entries) but holds no
  b43-named brief. Content grep
  `grep -lE '(^|[^0-9a-f])b43-|[Bb]ug round 43|bug-round-43' /var/spool-hub/spawn-remote/briefs/*.md /var/spool-hub/dispatch/briefs/*.md`
  -> only this seat's own brief (`db3d80d8-...md`); one file unreadable
  (`reflection-2026-11-14.md`, permission denied). `git worktree list | grep -E 'b43|bug-round-43'`
  -> this seat's worktree only.
- `git log origin/master --since="$W" --oneline | wc -l` -> `14`, as the plan's
  section 1 says.

## Check 2 — the defect is real on `c4000b25b` (every cited file:line printed)

`<api>` = `csi-spl-api/src/go/spool-hub-api`.

- `cmd/spool/key_desk_test.go:42-62` -> `func TestKeyDeskOnListensWithIdentity`
  at `:42`; the wait `:49-54` is `for i := 0; i < 100; i++ { if _, err :=
  os.Lstat(sock); err == nil { break }; time.Sleep(10ms) }` — it polls for the
  file's existence, not the mode; the assert `:55-58` is one
  `os.Stat(sock)` with `st.Mode().Perm() != 0o600` -> `t.Fatalf` at `:57`.
  Matches the plan (wait `:49-54`, assert `:55-58`).
- `cmd/spool/key_desk.go:25-39` -> `startKeyDesk` runs `s.Run(ctx, keyDeskTick)`
  in a goroutine at `:34-38`; `:57` -> `os.MkdirAll(cfg.HubDir(), 0o700)` in
  `keyDeskServer`. Matches.
- `internal/keydesk/keydesk.go:172` -> the comment `// Listen opens the
  socket, 0600 in its 0700 dir.`; `:174-197` -> `Listen` with `:179`
  `os.MkdirAll(filepath.Dir(s.Path), 0o700)`, `:187` `ln, err :=
  net.Listen("unix", s.Path)`, `:191` `os.Chmod(s.Path, 0o600)`; `:216-224` ->
  `handle` runs `peerOf(c)` then `s.peerOK(p)` before any read and only logs
  a refused peer (`:223`); `:381` -> `if err := s.Listen(); err != nil` inside
  `Run`. Matches (`:179`, `:187`, `:191`, `:216-224`, `:381`).
- `internal/keydesk/peer_linux.go:44-47` -> `DefaultPeerOK` calls `OwnUID`;
  `:74-78` -> `OwnUID` compares `int(p.UID) != deskUID()`. Matches.
- `internal/hubclient/hubclient.go:1329-1331` -> `writeAtomic` does
  `os.MkdirAll(filepath.Dir(path), 0o775)`. Matches. Its call sites under the
  hub dir: `internal/hubclient/host.go:130` (`writeAtomic(s.path, raw)`),
  `cmd/spool/hub.go:1288` (`HostFacts(filepath.Join(cfg.HubDir(), ...))`),
  `internal/hubclient/flush.go:321` (`return p, writeAtomic(p, raw)`). Match
  the plan's section 3.1 exposure read.
- Section 3.3 reads: `internal/hub/resolve.go:164-181` -> `tokenTenant` logs
  `upload token refused` with `reason` and answers 401 `door`;
  `internal/hubclient/hubclient.go:534-539` -> `Probe` is one
  `GET /v1/pins?probe=1`; `internal/hubclient/flush.go:593-624` -> the
  stranded-session redial; `csi-spl-cnf/csi-spl/all.env.yaml:446` ->
  `max_instances: 2`. All match.

CI evidence (read-only):

- `gh run view 45328560134 --json jobs` -> job `hub: gofmt, go vet, go test,
  smoke, GCS gate` conclusion `failure`, databaseId `138223998337`.
- `gh api repos/csitea/csi-spl/actions/jobs/138223998337/logs` (run as the
  gh-cache owner; `gh run view --log-failed` cannot write `/tmp/gh-cli-cache`
  as this user) -> line 419 `--- FAIL: TestKeyDeskOnListensWithIdentity
  (0.00s)`, line 420 `key_desk_test.go:57: key socket: &{key.sock 0 16777709
  ...} <nil>` — 16777709 = 1<<24 (Go's `ModeSocket`) + 493 = socket bit +
  `0755`, the runner's umask 022. Matches the plan.
- `gh run view 45328560134 --json headSha,conclusion` -> `c5fa1ded8...`,
  `failure`; `gh run view 45323770328 --json conclusion,headSha,status` ->
  `success`, `c5fa1ded8253ee2cf8782cdb577c3ba2a2f22bc2`, `completed` — the same
  sha green in its push run, as the plan says.

## Check 3 — red control extracted, hashed, run on `c4000b25b` in a scratch copy

Extracted plan section 4.1's `bash` fence into `rc01-b43.sh`:
`sha256sum rc01-b43.sh` ->
`47bfabe0172ee3a19a734018a5c633460690e42c46e54d009a8488a23d0168d3`, 1826 B,
first 12 hex `47bfabe0172e` — exactly the hash and size the plan names. Go is
present (`go version` -> `go1.26.10 linux/amd64`).

- `env PATH=/usr/local/go/bin:/usr/bin:/bin bash /tmp/rc01-b43.sh c4000b25b`
  (run as the box's pushing user, from the worktree; the script `git archive`s the sha into a `mktemp -d`
  dir, inserts a 50 ms sleep after `keydesk.go`'s `net.Listen` in that copy
  only, and runs `go test` there) ->
  `--- FAIL: TestKeyDeskOnListensWithIdentity (0.01s)` /
  `key_desk_test.go:57: key socket: &{key.sock 0 16777725 ...} <nil>` /
  `FAIL github.com/csitea/csi-spl/spool-hub-api/cmd/spool` / `rc01 exit 1`,
  script exit **1**. 16777725 = socket bit + 509 = `0775`, this box's umask
  002 — identical in shape to the plan's section 4.2 row.
- `... bash /tmp/rc01-b43.sh c4000b25b fix-shape` ->
  `rc01 fix-shape: the wait polls until the socket is 0600` /
  `ok  github.com/csitea/csi-spl/spool-hub-api/cmd/spool 0.118s` /
  `rc01 exit 0`, script exit **0** — matches the plan's control row.
- Live state: the script touches nothing outside its `mktemp -d` copy (it
  `git archive`s, `sed`/`python3`-edits and `go test`s there, and `trap rm -rf`s
  it). No hub, prd, GitHub, spool or checkout writes.
- The row's gates, run on a fresh `git archive c4000b25b` copy:
  `go test -count=200 -run '^TestKeyDeskOnListensWithIdentity$' ./cmd/spool/`
  -> `ok ... 2.254s`, rc 0; `go test -count=1 ./internal/keydesk/` -> `ok`,
  rc 0.

## Check 4 — the exposure reading: agree

From the code printed in check 2: `MkdirAll(..., 0o700)` at `key_desk.go:57`
and `keydesk.go:179` sets no mode on a directory that already exists, and
`writeAtomic`'s `MkdirAll(..., 0o775)` at `hubclient.go:1329-1331` can create
`.hub` as `0775` less the umask when it runs before the key desk (call sites
`host.go:130`, `hub.go:1288`, `flush.go:321`) — so `keydesk.go:172`'s "0700
dir" holds only when the key desk made the dir. The plan reads this correctly
and carries the dir mode to round 44 (section 7) instead of making it a row.

Empirical check of the connect(2) claim, in a scratch dir: a unix socket
bound then `chmod 0755` (owner uid 1001) refuses a connect from another uid —
`PermissionError [Errno 13] Permission denied`. So under umask 022 (bind
leaves `0755`) no other user can connect in the bind-to-chmod window. Under
umask 002 (`0775`) a group member could connect in that window, but `handle`
(`keydesk.go:216-224`) runs `peerOf` + `DefaultPeerOK` -> `OwnUID`
(`peer_linux.go:44-47`, `:74-78`) before any read and writes nothing back to a
refused peer. **No exposure; I agree with the plan.**

## Check 5 — the row: keep

- Fix scope is narrow and right: `key_desk_test.go` only — the wait `:49-54`
  polls existence, the assert `:55-58` reads the mode once; a bounded poll
  until `0600` that names the last mode read matches developer guide 2.12.6
  ("a test waits on the event it then asserts"). No `syscall.Umask`, no
  production change — correct, because the umask is process-wide and the
  hub-run sidecar has other goroutines creating files at the same time
  (`writeAtomic`, the submit socket).
- The red control proves the defect (exit 1, mode `0775` with the widened
  window) and turns green on the fix shape (exit 0) — I ran both (check 3).
- The gates are runnable and green unloaded on `c4000b25b` (check 3):
  `-count=200` ok, `./internal/keydesk/` unchanged ok.
- 1 row is a round (rulebook 5.2), priority 2 (5.4), batch 1, claude authors
  / grok R7 cross-vendor (3.2), no `csi-spl-wui/` path. **Keep; do not cut or
  split.**

## Check 6 — inputs accounted for

- The plan's section 2 lists 10 sources since W (+6b); section 6 hands exactly
  two items to the holder (the `unknown_token` box question, the unpinned
  `<ws>` box `<box3>`) and names the owned/carried ones (T6 N2 to the live
  SPL-6239 lane, the CI trunk-red watch items, the e2e selector).
- Round 42's plan section 7 on origin/master ("first inputs for round 43")
  hands: the hours 400, the release-preview 404, the hermetic 2/4 timeout +
  billing-invoices + `monitoring-costs` flake, the composed testids,
  SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`,
  g-162 N2. Every one is re-read in b43 section 3.4. I re-ran that table's
  commands on origin/master: e2e-selector commits since W -> `0`; duplicate
  version tags -> `0`; SPL-6174/relay-hash commits since W -> `0`;
  `git grep -c 'is not version'` -> `1` in each of `src/bash/run/run.sh` and
  `csi-spl-orc/src/bash/run/run.sh`; `git grep -n 'Lang-review'` -> one line,
  `i18n-lang-review-exempt.json:2`; commits since W touching
  `cmd/spool/key_desk_test.go` + `internal/keydesk/` -> `0`.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md` (sections "next BUG
  round" and "Bug-shaped"): **NOT RUN** — the file is sat-only and absent on
  this box (`ls /var/spool-hub/dispatch/c002-next-round-candidates.md` -> No
  such file or directory; `find /var/spool-hub -maxdepth 3 -name
  '*next-round*'` -> nothing). No bug-shaped input I could read on this box
  is left unserved and unaccounted.

## Check 7 — R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/bug-round-43-plan.md,csi-spl-api/src/go/spool-hub-api/cmd/spool/key_desk_test.go,csi-spl-api/src/go/spool-hub-api/cmd/spool/key_desk.go,csi-spl-api/src/go/spool-hub-api/internal/keydesk/keydesk.go --agent m-625`
-> **exit 4**: no live lane lists any of the four files; 4 live lanes record
no files: `a-967@sat` (c002-refactor-round-95-planner), `c-916@sat`
(c002-s181-b9-cancel-workspace), `c-918@sat` (c002-s181-b11-signin-relay),
`c-971@sat` (c002-bug-round-43-planner, the planner itself). Confirms the
planner's exit 4. Same check on this seat's file
`csi-spl-doc/doc/md/bug-round-43/seat-mistral.md` -> exit 4, same four
unknown lanes, none lists it. Not free until the holder re-runs at placement,
as the plan's R3 line says.

## Check 8 — distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`ok - owner mail address or domain`, `ok - hidden workspace or private literal
(SPL-1874)`, `ok - retired relay estate (SPL-1910)`, `ok - no tracked .vibe/
dir`, `INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-625`, **exit 0**.

## Defects

None. **W: none.**

## Notes

- N1: the plan's slug-proof grep over the briefs dirs names the planner's brief
  and refactor round 95's briefs; on this box the content grep finds only this
  seat's own brief among the readable files (one unreadable:
  `reflection-2026-11-14.md`, permission denied) — the planner's brief is not
  in these dirs here (archived or sat-local). The git-side slug checks (log
  since W -> 0; `ls-remote` -> the planner branch only) confirm the slug is
  unused.
- N2: the lane-map unknown-lane set is smaller than the plan's read (4 now, all
  @sat, vs 10 then) — lanes rotate between reads; exit 4 either way.
- N3: `/var/spool-hub/dispatch/c002-next-round-candidates.md` is sat-only and
  absent here (check 6 NOT RUN); the round-42 section-7 chain is fully
  accounted in the plan's section 3.4.
- N4: `gh run view --log-failed` cannot write the shared gh cache
  (`/tmp/gh-cli-cache`, owned by the pushing user) as this user; I read the
  job log via `gh api repos/csitea/csi-spl/actions/jobs/138223998337/logs`.
  The evidence is identical to the plan's.
- N5: the plan's source 9 says "9 items" for round 42's first inputs while its
  own section 3.4 table has 10 rows — every handed item is covered either way;
  wording only.

The verdict stands: **PASS, 1 row, on `21010c205f59b66368cc5225d26e89787ec05749` (v0.1).**
