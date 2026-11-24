# Bug-fix round 43 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6349 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `d6f3e1c5-3186-4b3e-b528-3096df9486da` ("Bug round 43", opened by c-002@sat 06:04Z). Round 42 ([bug-round-42-plan.md](bug-round-42-plan.md)) served its one row (b42-01 `c41b7080e`, SPL-6340).  
Round focus: the sources of rounds 40 to 42 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W, owner posts), read since W, and the first candidate the holder handed in: a CI flake of the key desk socket test.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. One candidate met the bar (section 3); rulebook 5.2: "1 row is a round".  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-42-plan.md](bug-round-42-plan.md).

**Status: v0.1, draft for the panel.**

Editor: **c-971@sat** (claude, `specs_and_docs`).  
Panel: placed by the holder (rulebook 3.2).

**One sha:** every count below is measured on **`c4000b25b`** (`origin/master` at this seat's fetch, 2026-11-24T06:1xZ), on sat, 06:10Z..06:25Z on 2026-11-24, unless a line says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b42-plan')` read at 06:15:46Z -> `Window: W=2026-11-24T02:03:55+02:00` (commit `c23d5019c`, the last b42 plan commit).

---

## 1. How to read this

- Since W, `origin/master` took 14 commits (`git log origin/master --since="$W" --oneline | wc -l` -> 14): the b42 close, SPL-6239 T5/T6 (box stats), spec 181 B7/B9 (SPL-6329, SPL-6344), SPL-6343 (private workspace provisioning), SPL-6346 (cost labels cron), SPL-6342 (the lazy hub socket), SPL-6347 (the `/tmp` worktree reap).
- `<box2>` is the fleet's box that is not sat, `<ws>` one customer workspace and `<box3>` one of its boxes, as in rounds 21 to 42: the public repo names none of them.
- **Paths** are repo-relative; `<api>` is `csi-spl-api/src/go/spool-hub-api`. Line numbers are as of `c4000b25b`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red control is a script printed in section 4. It extracts the named sha's tree with `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).

---

## 2. Where rows could come from (measured since W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (06:15:54Z; 6 h covers W) | 8 entries, 01:45Z..03:55Z: 4 Cloud SQL statement errors as the hub's runtime user (`uuid ~~ unknown` x2, `column "created_at" does not exist`, `column "id" does not exist`); 4 Cloud Run lines in 2 s at 03:55:03Z..03:55:05Z on revision `01991`: one 503 on `/v1/pins?probe=1`, three 500 on `/v1/ws` ("aborted after waiting too long for an available instance", "response was malformed") | **0 rows.** The SQL errors are hand-written reads with wrong column names, the shape rounds 41 and 42 traced to seats' `do_spl_db_query` (this seat's own first `messages` read added one more at 06:18Z, after this read). The Cloud Run lines are one burst at a hub roll: source 6's `db.schema_head` `ahead` line (`applied 0318`, `bundled 0317`) is the same roll; no repeat, no incident (source 2). |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=6h ./run -a do_gcp_list_alert_incidents` (06:16Z) | 9 policies, 0 incidents in 00:15:59Z..06:15:59Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,100), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (06:18:19Z) | 6 issues (SPL-5911, 5254, 5104, 4994, 4934, 4849); 0 new since W (round 42's 7 less SPL-6330, closed) | **0 rows.** Each is its lane's or the holder's. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (06:10Z..06:17Z, background) | 100 runs, 2026-11-23T01:38Z..2026-11-24T06:02Z: 81 success, 10 cancelled, 8 failure, 1 running; every job's p90 under 75 % of its timeout (highest: hermetic 1/4, 59 %); 1 failure since W: run 45328560134 (04:45Z, schedule, `c5fa1ded8`), hub job, `--- FAIL: TestKeyDeskOnListensWithIdentity`; every job green again in run 45335561961 (`11c6582f`, 05:45Z) | **Row b43-01** (section 3.1). The other 7 failures: section 3.2. |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 60` (06:18Z), filtered to `createdAt` after W | 1 failed run, 45328560134, and it is wf 10 (source 4) | **0 rows** beyond row 01. |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=6h LINES=3000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (06:16:26Z; the 401 bursts left out, as rounds 41 and 42 did: cap not reached, the full 6 h read) | 843 entries, 00:17Z..06:01Z: 450 `ws hello refused`, 379 `upload token refused`, 4 `github: request refused`, 1 `db.schema_head`, 9 scanner probes and single 404s (`/.env` x5, `robots.txt`, `sftp-config.json`, `.vscode/sftp.json`, a `DELETE` of a CI join pin already gone) | **0 rows**, section 3.3. |
| **6b. who sends the 401s** (new, from 6) | `ENV=prd FRESHNESS=1h LINES=1000 FORMAT=json FILTER='resource.type="cloud_run_revision" AND httpRequest.status=401 AND httpRequest.requestUrl:"/v1/pins"' ./run -a do_gcp_tail_logs` (06:17Z) | 129 entries in 05:49:31Z..06:01:44Z: all `Go-http-client/2.0` (the box CLI, not a browser), 100 `GET /v1/pins?probe=1` and 29 `GET /v1/pins`, from one IPv6 client and from `0.0.0.0`; none from sat's address | **0 rows**, section 3.3. |
| **7. R7 notes of lanes landed since W** | the reviewers' and authors' messages in the sat spool (`c-001`, `c-002`, `c-003` inbox and archive, files newer than W, bodies with `PASS` and an `N<n>`/`W<n>`) | 14 messages with a `PASS` and a note: g-568 PASS (SPL-6347), g-565 PASS (B11), g-445 PASS (B13), g-554 PASS (B9), g-547 PASS (T6), g-531 FAIL then PASS (SPL-6342, W1 and N1 fixed by c-432 in `e5e6253e4`, `69dc02d2f`, `e62b847c3`), g-568 FAIL then PASS (SPL-6347 W1, fixed in `11c6582fc`); T6 N2 (c-478, twice relayed): spec 071 lines 343 and 349 say a 7 s wait where code and cnf use 45 s (`SPOOL_HUB_BOX_REFRESH_WAIT=45s`), "the spec owner's call" | **0 rows**: every W was fixed by its lane before landing; T6 N2 is a spec-text mismatch owned by the live SPL-6239 lane (section 6). |
| **8. Owner and member posts** | `ENV=prd SQL="select from_id, count(*) from messages where tenant_id='t1' and from_id like 'HUM-%' and accepted_at > '2026-11-24T00:03:55Z' group by 1" ./run -a do_spl_db_query` (06:19Z) | 0 rows: no `HUM-` post in t1 since W | **0 rows.** |
| **9. Round 42's first inputs** | round 42 section 7, re-run | 9 items | **0 rows**: section 3.4. |
| **10. The holder's first candidate** | c-001@sat msg 41277866 (from c-478@`<box2>` 863e9ccf): the key desk socket test flake | read on `c4000b25b`, red control in section 4 | **Row b43-01.** |

---

## 3. The candidates, read

### 3.1 b43-01: the key desk socket test reads the socket's mode before Listen has set it

- **What happens.** `TestKeyDeskOnListensWithIdentity` (`<api>/cmd/spool/key_desk_test.go:42-62`) starts the desk (`startKeyDesk`, `<api>/cmd/spool/key_desk.go:25-39`), which runs `keydesk.Server.Run` in a goroutine. `Run` calls `Listen` (`<api>/internal/keydesk/keydesk.go:381`), and `Listen` binds the socket with `net.Listen` (`keydesk.go:187`), which creates the file with the process umask's bits, then chmods it to 0600 (`keydesk.go:191`). The test polls with `os.Lstat` until the file exists (`key_desk_test.go:49-54`) and then, once, reads `os.Stat(sock).Mode().Perm()` and requires 0600 (`:55-58`). The file exists from the bind on, so the test can read it between `:187` and `:191`: the race is in the test's wait, which waits for the file and not for the state it asserts (developer guide 2.12.6: "a test waits on the event it then asserts").
- **Seen.** CI run 45328560134 (schedule, 04:45Z, `c5fa1ded8`), job 138223998337 (hub: gofmt, go vet, go test, smoke, GCS gate): `key_desk_test.go:57: key socket: &{key.sock 0 16777709 ...}`, mode 16777709 = socket bit + `0755` (the runner's umask 022). The same sha was green in its push run 45323770328 (04:04Z). In the 100 runs of source 4 the hub job completed n=63 times, this test failed once. On sat, unloaded: `go test -count=300 -run '^TestKeyDeskOnListensWithIdentity$' ./cmd/spool/` on `c4000b25b` -> 0 FAIL in 300 (06:20Z..06:21Z). The rate is low and load-bound; the defect is proven by the red control, which widens the window instead of waiting for load.
- **Exposure, the brief's open question.** The production window is no exposure, though the dir is not always 0700:
  - The hub dir is not 0700 in every start order. `keyDeskServer` (`key_desk.go:57`) and `Listen` (`keydesk.go:179`) call `os.MkdirAll(..., 0o700)`, which sets no mode on a dir that already exists. The hub-run's host facts (`<api>/internal/hubclient/host.go:130`, path `<api>/cmd/spool/hub.go:1288`) and the pending queue (`<api>/internal/hubclient/flush.go:321`) write through `writeAtomic` (`<api>/internal/hubclient/hubclient.go:1329-1331`), whose `MkdirAll(..., 0o775)` creates `.hub` 0775 less the umask when it runs first. So the comment "0600 in its 0700 dir" (`keydesk.go:172`) holds only when the key desk made the dir.
  - Still no exposure: on Linux, `connect(2)` to a unix socket needs write permission on the socket file. Under umask 022 the bind leaves `0755`, so no other user can connect in the window. Under umask 002 a group member could connect in the microseconds before `:191`, and `handle` (`keydesk.go:216-224`) runs `peerOf` and `DefaultPeerOK` -> `OwnUID` (`<api>/internal/keydesk/peer_linux.go:44-47,74-78`) before any read: a peer of another uid gets nothing. Nothing in this row changes production code; the dir mode and the comment are carried (section 7).
- **Red control** (`rc01-b43.sh`, section 4.1): on `c4000b25b`, with a 50 ms sleep inserted after `keydesk.go:187` in the extracted copy (the window a loaded runner makes, made wide on purpose), the unchanged test fails at `key_desk_test.go:57` with mode `0775` (sat's umask 002), `rc01 exit 1`. **Control** in the same tree: `rc01-b43.sh c4000b25b fix-shape`, the same injection with the test's wait polling until the mode is 0600 -> `ok`, `rc01 exit 0`.
- **Fix scope.** `<api>/cmd/spool/key_desk_test.go` only. The wait in `TestKeyDeskOnListensWithIdentity` polls until the socket's `os.Stat` mode is 0600, bounded, and the failure names the last mode it read (or that the socket never appeared). Keep the identity-file check as it is. **Not** in scope: `syscall.Umask` around `net.Listen` (the brief's second option). The umask is process-wide, and the hub-run sidecar has other goroutines creating files at the same time (`writeAtomic`, the submit socket); a 0177 umask there would create their files without group or other bits. The production window is no exposure (above). No store, migration, WUI or cnf change. Docs: none name this test; the commit carries `Docs: none (a test-only wait fix)` unless the lane finds one.

### 3.2 CI reds in the 100 runs, read

| run | job | first red line | why not a row |
|---|---|---|---|
| 45328560134 (04:45Z, schedule, `c5fa1ded8`) | hub gofmt/vet/test | `--- FAIL: TestKeyDeskOnListensWithIdentity` | **Row b43-01.** |
| 45244623103 (2026-11-23 19:02Z, `e675b87d`) and 45197570926 (14:45Z, `c0fe7647`) | iac tfvars parity | `FAIL: download iframe: ... no documents list on the "Invoices" page, or it never stopped loading` | Fixed by its lane: `c6e04cff2` fix(iac, SPL-6333), "the billing download's page wait counts poll waits, not the wall clock" (2026-11-23T19:53:10Z); `git merge-base --is-ancestor c6e04cff2 e675b87d` -> false, so both reds ran before the fix. Its test now carries the control (`gcp-billing-invoices.tst.sh:425-426`). |
| 45223415636, 45220059471, 45217594068 (11-23 16:32Z..17:03Z) | orc hermetic 4/4 | `an orc check skipped in CI` | Fixed by its lane before round 42 (`ef80e6a01`, SPL-5985), round 42 section 3.2. |
| 45220059471 (11-23 16:45Z) | orc hermetic 2/4 | `The job has exceeded the maximum execution time of 30m0s` | Still 1 sighting in 100 runs; the job's p90 is 56 % of its timeout. Carried (2.11.3). |
| 45208818805 (11-23 15:45Z) | hub gofmt/vet/test | `TestContactsSyncLogsNoValues` | Fixed by its lane (`1797577cb`, SPL-6324), round 42 section 3.2. |
| 45124937982 (11-23 06:33Z) | wui e2e 2/8 | `monitoring-costs.test.mjs` | The hr-tab flake rounds 41 and 42 carried; still 1 sighting in 100 runs. Carried (2.11.3). |

### 3.3 The other candidates, read

| candidate | read | why not a row |
|---|---|---|
| `upload token refused`, 379 in 6 h (round 41: 254 in 6.5 h; round 42: 218 in 6 h) | every line `reason=unknown_token`, `GET /v1/pins` (`<api>/internal/hub/resolve.go:164-181`). Source 6b: the matching 401s are the box CLI's session probe (`<api>/internal/hubclient/hubclient.go:534-539`, every 30 s, `defaultSessionProbe`) from one client off sat, ~10 a minute. Round 41 read them as "an expired browser session polling": the user agent says otherwise. | **Not a row**: one box keeps an upload token no hub process minted. Spec 094's gap G9 (`csi-spl-doc/specs/094-hub-multi-instance/spec.md:118`, the per-process token map, not built) also yields `unknown_token` while prd runs `max_instances: 2` (`csi-spl-cnf/csi-spl/all.env.yaml:446`). But sat's own box clients sent none in the same 12 minutes, so the hub is not refusing every box: this is one client. Which box it is and why it never redials onto a fresh token (an old CLI before the stranded-session redial at `<api>/internal/hubclient/flush.go:593-624`, or a token of another env) is a box question: handed to the holder (section 6). |
| `ws hello refused`, 450 in 6 h (round 42: 479) | every line `reason=unpinned_box`, tenant `<ws>`, box `<box3>` | **Not a row**: the hub refuses a box with no pin, as designed. That workspace's box is not pinned and keeps redialling: a box of that workspace's owner, not code. Handed to the holder (section 6). |
| `github: request refused`, 4 | `op=contents`, `status=404`, `github_message: "Not Found"` | **Not a row**: a repo path that does not exist, answered 404. The key is `github_message` since b42-01 (`c41b7080e`): round 42's row served as designed. |
| `db.schema_head` `ahead`, 1 | hub started with bundled `0317`, applied `0318` | **Not a row**: one line at a roll (spec 181 B7's `0318`); no repeat. |
| T6 N2 (c-478, SPL-6239): spec 071 lines 343, 349 say 7 s, code and cnf 45 s | c-478's message | **Owned** by the live SPL-6239 lane (T6, hub deploy pending; R3). |
| The other R7 notes of source 7 | each read | W1s fixed by their lanes before landing (SPL-6342, SPL-6347); the rest confirmations. |

### 3.4 Round 42's first inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| The hours `PUT /v1/me/hours/minutes` 400 | source 6 | 0 in 6 h | **Carried**: not seen again; its code is still not logged. |
| The release-preview 404 | source 6 | 0 in 6 h | **Carried** with SPL-6274's design. |
| The hermetic 2/4 timeout, the `monitoring-costs` flake | source 4 | 1 sighting each, unchanged | **Carried** (2.11.3). |
| The billing-invoices iframe failure | source 4 | 2 sightings, both before `c6e04cff2` | **Done**: fixed by SPL-6333. |
| The pre-push e2e selector's composed testids | `git log origin/master --since="$W" --format=%h -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh \| wc -l` -> 0 | unchanged | **Not a row**, as rounds 37 to 42: a gate-design input with the holder. |
| SPL-6277 N2 (one sha, two release tags) | `git ls-remote --tags origin 'v*' \| grep -v '\^{}' \| awk '{print $1}' \| sort \| uniq -d \| wc -l` -> 0 | no instance | **Carried.** |
| SPL-6174's link to the relay hash | `git log origin/master --since="$W" --format='%h %s' \| grep -ciE 'SPL-6174\|relay hash'` -> 0 | no writer named | **Carried.** |
| `run.sh:797`'s "is not version" note (g-724 N2) | `git grep -c 'is not version' origin/master -- src/bash/run/run.sh csi-spl-orc/src/bash/run/run.sh` -> 1 each | unchanged | **Carried** (a DEBUG wording, round 42 section 3.3). |
| g-162 N2, the `i18n-lang-review-exempt.json:2` `_doc` | `git grep -n 'Lang-review' origin/master -- csi-spl-wui/i18n/i18n-lang-review-exempt.json` -> 1 line (`:2`) | unchanged | **Carried** to a docs or refactor round. |
| b34-01 N2, SPL-6212 N2, r87-01 N2 | rounds 38 to 42 | test-shaped | **Carried.** |

---

## 4. Red control, as run

### 4.1 `rc01-b43.sh` (b43-01), sha256 first 12 hex `47bfabe0172e`, 1826 B

Run from any checkout: `bash rc01-b43.sh c4000b25b` (exit 1), then `bash rc01-b43.sh c4000b25b fix-shape` (exit 0). 50 s on sat with a cold Go cache in the extracted tree.

```bash
#!/usr/bin/env bash
# rc01-b43.sh <sha> [fix-shape]: b43-01 red control. On <sha>'s tree, the
# key desk socket test (cmd/spool TestKeyDeskOnListensWithIdentity) must hold
# when the window between the socket's bind (keydesk.go net.Listen) and its
# chmod 0600 is 50 ms wide, as a loaded CI runner widens it. The tree is
# extracted with git archive into a mktemp dir; a 50 ms sleep is inserted
# there after net.Listen (the fault injection), and nothing in the checkout
# changes. fix-shape also rewrites the test's wait to poll until 0600.
set -uo pipefail
sha="${1:?usage: rc01-b43.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
kd="$d/internal/keydesk/keydesk.go"
sed -i 's|^\tln, err := net.Listen("unix", s.Path)$|&\n\ttime.Sleep(50 * time.Millisecond) // rc01-b43 window|' "$kd"
n=$(grep -c 'rc01-b43 window' "$kd")
[ "$n" = 1 ] || { echo "rc01 injection applied $n times, want 1"; exit 2; }
if [ "${2:-}" = fix-shape ]; then
  python3 - "$d/cmd/spool/key_desk_test.go" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = "\t\tif _, err := os.Lstat(sock); err == nil {\n\t\t\tbreak\n\t\t}\n"
new = "\t\tif st, err := os.Stat(sock); err == nil && st.Mode().Perm() == 0o600 {\n\t\t\tbreak\n\t\t}\n"
assert s.count(old) == 1, "fix-shape: wait loop not found once"
open(p, "w").write(s.replace(old, new))
PY
  echo "rc01 fix-shape: the wait polls until the socket is 0600"
fi
cd "$d" && go test -count=1 -run '^TestKeyDeskOnListensWithIdentity$' ./cmd/spool/ 2>&1 | tail -5
rc=${PIPESTATUS[0]}
echo "rc01 exit $rc"
exit "$rc"
```

### 4.2 Output on `c4000b25b` (sat, 06:12Z..06:14Z)

| run | output |
|---|---|
| `bash rc01-b43.sh c4000b25b` | `--- FAIL: TestKeyDeskOnListensWithIdentity (0.02s)` / `key_desk_test.go:57: key socket: &{key.sock 0 16777725 ...} <nil>` (16777725 = socket bit + `0775`) / `FAIL github.com/csitea/csi-spl/spool-hub-api/cmd/spool` / `rc01 exit 1` |
| `bash rc01-b43.sh c4000b25b fix-shape` | `rc01 fix-shape: the wait polls until the socket is 0600` / `ok github.com/csitea/csi-spl/spool-hub-api/cmd/spool 0.114s` / `rc01 exit 0` |

The fix-shape is the shape, not the fix: the lane bounds the wait and names the last mode read on a failure.

---

## 5. Rows

| # | id | practice | sites (file:line on `c4000b25b`) | evidence | red control (fails on `c4000b25b`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b43-01-api-key-desk-test-waits-for-0600` | a test waits on the state it asserts | `<api>/cmd/spool/key_desk_test.go:42-62` (the wait `:49-54`, the assert `:55-58`); read only: `<api>/internal/keydesk/keydesk.go:174-197` | CI run 45328560134 job 138223998337 (`key_desk_test.go:57`, mode `0755`), same sha green in 45323770328; source 10 | `bash rc01-b43.sh c4000b25b` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | `go test -count=1 -run 'TestKeyDesk' ./cmd/spool/` (3 tests); `go test -count=1 ./internal/keydesk/` (unchanged, regression); `bash rc01-b43.sh <fix sha>` -> exit 0 with the injection kept; `go test -count=200 -run '^TestKeyDeskOnListensWithIdentity$' ./cmd/spool/` -> 0 FAIL | section 3.1: the test only, a bounded poll until 0600, the last mode named; no `syscall.Umask`, no production change | `<box2>` (`pick=<box2>`, 06:20Z, both kinds) or where the holder places it | claude | a grok seat (`pick=<box2>`) | `tests` | 1 |

- **R1:** one row, batch 1.
- **R3, before the holder places it:** `lane-map.sh --check csi-spl-doc/doc/md/bug-round-43-plan.md,<api>/cmd/spool/key_desk_test.go,<api>/cmd/spool/key_desk.go,<api>/internal/keydesk/keydesk.go --agent c-971` (06:19:52Z) -> exit 4: no live lane lists any of the four files, and 10 live lanes record no files: six standing seats of other workspaces and one more such seat on `<box2>` (other workspaces' topics, rotate branches), c-384@`<box2>` (spec 181 B13, the overdue invoice list: store and hub), g-554@`<box2>` and g-565@`<box2>` (R7 seats of B9 and B11, review only). `grep -lE 'key_desk\|keydesk\|key-desk'` over `/var/spool-hub/dispatch/briefs/*.md /var/spool-hub/spawn-remote/briefs/*.md` -> 7 briefs from 2026-11-18 (closed reviews of SPL-3738, 3756, 4027, 4749, 4769, refactor round 18) and this planner's brief; none of the live ones. The queue, `./run -a do_spl_spawn_queue` (06:20:05Z): empty (header only). `git log origin/master --since="$W" --format=%h -- <api>/cmd/spool/key_desk_test.go <api>/internal/keydesk/` -> 0. **Not free until the holder re-runs that check at placement**: an `unknown:` answer is not free (seed rule (b)).
- **R7:** `cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (06:20Z) -> `pick=<box2> reason=every box is at or above its high mark; <box2> is the least past its band (141% on high 90%, overflow 180%)`: a grok seat reviews the row (claude authors, grok reviews: cross-vendor). `BOX_PICK_KIND=claude` (the same minute) -> the same pick. No mistral (a coding kind); the row does not touch `csi-spl-wui/`.
- **Pushes:** aim 1 (1.2).
- **Priority 2** (5.4): the row's issue carries `Class: bug`.
- **2.11.3 and one sighting:** a flake gets its lane on the 3rd sighting. This row does not wait for it: the red control proves the race on one sha instead of counting runs, and the fix is one test's wait.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes | their lanes | section 5, R3 (06:19:52Z, 06:20:05Z). |
| The box sending `unknown_token` probes (~10 a minute, one IPv6 client off sat, `Go-http-client/2.0`) | the holder, as a box question | which box, and its CLI version (section 3.3). If it turns out to be every box behind the second instance, that is spec 094's G9 and not a bug row. |
| Workspace `<ws>`'s unpinned box `<box3>` (450 `ws hello refused` in 6 h) | the holder, for that workspace's owner | refused as designed (section 3.3). |
| T6 N2 (spec 071 says 7 s, code 45 s) | the SPL-6239 lane (c-478@`<box2>`) | live. |
| The `monitoring-costs` hr-tab flake, the hermetic 2/4 timeout | the holder, CI trunk-red watch (2.11.3) | 1 sighting each. |
| The e2e selector's composed testids | the holder, as a gate input | unchanged (section 3.4). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 10 sources (+6b); 8 prd error log entries (6 h); 843 prd WARNING entries (6 h, 401s left out, cap not reached); 129 prd 401s on `/v1/pins` (1 h); 9 alert policies (0 incidents); 6 open bug issues; 100 wf 10 runs (8 failures, 1 since W); every other workflow: 0 failures since W; 14 R7 messages since W; 0 owner posts since W; round 42's first inputs (9); `rc01-b43.sh` n=1 each way on `c4000b25b`; the test unloaded n=300 |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b43-'` -> 0; `git ls-remote origin 'refs/heads/review/b43-*' 'refs/heads/wip/*b43*' 'refs/heads/*-b43-*' 'refs/heads/*bug-round-43*'` -> nothing (rc 0); `grep -lE '(^\|[^0-9a-f])b43-\|[Bb]ug round 43\|bug-round-43' /var/spool-hub/spawn-remote/briefs/*.md /var/spool-hub/dispatch/briefs/*.md` -> this planner's brief and refactor round 95's planner and mistral panel briefs (each names "bug round 43's planner" as a lane to stay off, no b43 row); `git worktree list \| grep -E 'b43\|bug-round-43'` -> this seat's worktree only, 06:15:46Z |
| R7 seat | grok (`pick=<box2>`, 06:20Z) |
| first inputs for round 44 | the `unknown_token` box, if the holder finds code behind it; the hub dir mode (`.hub` is 0775 less the umask when `writeAtomic` makes it before the key desk, and `keydesk.go:172` says "0700 dir"): no exposure today (section 3.1), a hardening or comment input for a refactor round; the hermetic 2/4 timeout and the `monitoring-costs` flake on a 2nd sighting; the composed testids; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`, g-162 N2 as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-971@sat (claude, `specs_and_docs`).
- **Panel:** placed by the holder (cross-vendor).
- **Row reviewer (R7):** a grok seat (section 5).
- **Review history:**
  - 2026-11-24 06:2xZ: v0.1, pushed to `review/c002-bug-round-43-planner`: 1 row.
