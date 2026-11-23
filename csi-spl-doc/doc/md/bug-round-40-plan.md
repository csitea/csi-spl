# Bug-fix round 40 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6288 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `19153ef2-1761-4323-a7b9-95e0e09e332f` ("Bug round 40", opened by c-002@sat 08:55Z). Round 39 ([bug-round-39-plan.md](bug-round-39-plan.md)) closed with 0 rows (`e6de4e229`, Closes: SPL-6235).  
Round focus: rounds 37, 38 and 39 closed with 0 rows, so this round widened its inputs (planner brief): the prd error log, the prd alert incidents, the open issues labelled bug, and the R7 notes of the lanes landed since W. Both rows come from those new sources.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-39-plan.md](bug-round-39-plan.md).

**Status: v1.0, the panel's notes folded (m-048 PASS on v0.1 `699e09331`, no W); for the holder's GO.**

Editor: **c-591@sat** (claude, `specs_and_docs`).  
Panel: m-048@`<box2>` (mistral), seat file [bug-round-40/seat-mistral.md](bug-round-40/seat-mistral.md).

**One sha:** every count below is measured on **`2286c85ce`** (`origin/master` at this seat's second fetch, 2026-11-23T09:01:54Z), on sat, 08:58Z..09:17Z on 2026-11-23, unless a line says otherwise. The first reads (lane map, CI report, round 39's `rc01.sh`) ran on `7959f8f9c`, its parent's parent; the two commits between (`1a91b4f55`, `2286c85ce`, SPL-6286) touch only `csi-spl-orc` invite e2e files and spec 015, none of this plan's sites. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b39-plan')` -> `Window: W=2026-11-22T09:15:08+02:00` (commit `e6de4e229`).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 39. The public repo does not name it.

---

## 1. How to read this

- Since round 39 measured, `origin/master` moved by 103 commits (`git log --oneline e6de4e229..2286c85ce | wc -l` -> 103): spec 154 contacts (api, wui, iac), spec 158 V1 and H3, SPL-6182 native auth, the r88 to r91 refactor rounds, and bug lanes SPL-6234, 6236, 6240, 6242, 6250, 6257, 6261, 6264, 6268, 6270, 6271, 6273, 6277, 6278, 6279, 4463.
- **Paths** are repo-relative. Line numbers are as of `2286c85ce`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- Both red controls are scripts printed in section 4. Each extracts the named sha's tree with `git archive` into a `mktemp -d` dir and changes nothing in the checkout.

---

## 2. Where rows could come from (measured on `2286c85ce`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** (new) | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=26h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (08:59Z) | 42 entries, 2026-11-22T08:34Z..2026-11-23T08:43Z: 4 hub `issue backlog` (`"error":"conflict"`, tenant t1, at 12:34Z, 13:11Z, 19:26Z and 08:38Z, hub versions 3.2.3, 3.3.2, 3.4.1); 7 Cloud Run request errors in one burst at 21:53:01Z..21:53:02Z (4 x 500 "aborted after waiting too long for an available instance" on `/v1/ws`, 3 x 503 "malformed response or connection error" on `/v1/pins?probe=1`); 31 Cloud SQL statement errors as the hub's runtime user | **Row b40-01** (the 4 `issue backlog` lines, section 3.1). The 21:53Z burst: one second, no repeat in 26 h and no alert incident (source 2): **not a row**. The 31 Cloud SQL errors are malformed hand-written statements (`column "key" does not exist` x6, `relation "members" does not exist`, `operator does not exist: uuid ~~ unknown`, `aggregate functions are not allowed in GROUP BY`, ...). I believe, not proven line by line, that they are agents' read-only `do_spl_db_query` reads: that action connects with the hub's own DSN (`csi-spl-orc/lib/bash/funcs/spl-cloud-cnf.func.sh:800`), so its user is the hub's; no hub code path was matched to any of them. **Not a row.** |
| **2. prd alert incidents** (new) | MCP `gcp_alert_incidents env=prd since=26h` (= `ENV=prd SINCE=26h ./run -a do_gcp_list_alert_incidents`), 08:59Z | 9 policies, 0 incidents in 2026-11-22T06:59Z..2026-11-23T08:59Z | **0 rows.** |
| **3. Open issues labelled bug, t1** (new) | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, created_at, title from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (read-only, 09:06Z) | 13 issues, the newest created 11-18; 8 of them have a commit citing the key on master (`git log origin/master --grep="SPL-<n>\b" -E`), e.g. `7e3ef69db fix(orc, SPL-5847)` and `66a4c0be6 fix(iac, SPL-5368)`, and still read `wip` | **Row b40-02** (section 3.2): a closed issue goes back to `wip` when an R7 reviewer lane is placed on it after its fix landed. The issues themselves are each their own lane's or the holder's (none has a live lane in the lane map, 08:58Z). |
| **4. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (08:58Z..09:0xZ) | wf 10: 100 runs (2026-11-22T05:05Z..2026-11-23T08:46Z): 78 success, 15 cancelled, 5 failure, 2 running. First red per job: `wui: browser e2e 3/8` x2 (`box-seat-counts.test.mjs`, 13:07Z and 13:23Z), `iac: tfvars parity ...` x2 (19:39Z on `03c463f1`, 19:44Z on `447095af`), `wui: browser e2e 2/8` x1 (`monitoring-costs.test.mjs`, 06:33Z on `70ebbfa6`). Last green of all three jobs: run 45139056778 on `fdcd3179` (08:29Z). Every job's p90 is under 75 % of its timeout (the highest, hermetic 1/4, 59 %) | **0 rows.** `box-seat-counts`: fixed by `e20037af4` (test(wui): box-seat-counts centres a count before it clicks it), green since. The iac pair: the SPL-6271 lane's own red between its two pushes, I believe fixed by `a3c49a190` (check 21 replays fixtures, under the runner's 120 s cap); the failing line was not isolated in the 3000-line tail, but the job is green on every run since. `monitoring-costs`: 1 sighting, red on its run and its retry, green on the run before (`42434d77c`) and the two after on `bed9d989c`, with no change to the test or the costs page between (`70ebbfa6` is a docs commit). The run waited 20 s for `[data-test=cost-row]` after switching back to the hr tab, then `tap` found no `[data-test=cost-delete]` (`csi-spl-wui/tests/e2e/monitoring-costs.test.mjs:358-359`; the `waitFor` result on line 358 is not checked). A flake on its first sighting gets a lane on its 3rd (2.11.3): **carried** (section 5). `git merge-base --is-ancestor <fix> origin/master` rc 0 for `e20037af4` and `a3c49a190`. |
| **5. R7 notes of lanes landed since W** (new) | the PASS review messages with W or N notes in the holder, orchestrator and standby inboxes and archives on sat since W (python over `c-00{1,2,3}/*/*.json`, mtime after 07:15:08Z on 2026-11-22), refactor-round panels left out | 45 messages with notes, 34 outside the refactor panels; 4 match `out of scope\|follow-up\|not fixed\|pre-existing\|separate\|outside` | **0 rows**: section 3.3. |
| **6. Owner, member and lane reports** | the brief's inputs (b9919163, the round's topic) | no new defect report | **0 rows.** |
| **7. Round 39's first inputs** | round 39 section 6, re-run | 6 items | **0 rows**: section 3.4. |

---

## 3. The candidates, read

### 3.1 b40-01: the hub logs an error for every issue that links an already posted Issue backlog topic

- **What happens.** `checkDiscussion` (`csi-spl-api/src/go/spool-hub-api/internal/hub/issue_discussions.go:236-242`) calls `postIssueBacklog` each time an issue links the tenant's default discussion (`:174`, an issue created with no discussion of its own), and logs any error at level error (`:240`). `postIssueBacklog` (`internal/hub/issue_backlog.go:53`) signs a fresh envelope stamped `now` (`:58`) every call. Its comment says "a second call is a no-op insert" (`:51-52`). It is not: the store keeps the first envelope and answers `ErrConflict` to a different one (`internal/store/postgres.go:510`, `internal/store/memory.go:404`), so every link after the first second answers `conflict` and the hub logs `issue backlog` at error level. Nothing else goes wrong: `checkDiscussion` returns nil and the issue is created.
- **Why it is a bug.** A false error line on prd, and a comment that describes behaviour the code does not perform (C5). Since SPL-6212 (`645718660`, 2026-11-22T09:24Z) t1's default discussion is its Issue backlog topic, so every t1 issue filed without a discussion now writes one: the 4 prd lines of source 1, all tenant t1, the first at 12:34Z. These lines feed the `hub error log rate` alert policy (source 2), which they did not trip.
- **Red control** (`rc01-b40.sh`, section 4.1): on `2286c85ce` -> `rc01 issue-backlog error lines: 1 (clock step 1 s)`, `--- FAIL`, `rc01 sha=2286c85ce same_second=0 rc=1`. **Control** `RC01_SAME_SECOND=1` (the clock does not move, so the second envelope is byte-equal) -> `error lines: 0`, `--- PASS`, rc 0: the timestamp in the envelope is the cause.
- **Fix scope.** Make the second post a no-op as the comment says: `postIssueBacklog` answers `(false, nil)` when the backlog message already exists (an `ErrConflict` from the insert, or a read of the stored row first), so neither caller logs. The row's test is the same check in `issue_discussions_test.go` beside `TestIssueBacklogPostedOnce` (`:177`), red before the fix. No store change, no migration.

### 3.2 b40-02: an R7 reviewer lane placed after the fix landed reopens the closed issue for good

- **What happens.** `spl_lane_issue_place` (`csi-spl-orc/src/bash/run/spl-lane-issue.func.sh:305`) sets every keyed placement's issue to `wip` and assigns the lane (`:314`), whatever its status. Rulebook 2.11.3 lands a trunk-red fix first and places its R7 reviewer on the landed sha, with `Issue: <key>` in the brief; by then the closer has set the issue `done`. The placement sets it back to `wip`. The reviewer only reviews: its end is refused and its exit needs none (SPL-6099, `spl_lane_issue_shared` `:182`, `li_review_lane` in `csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh:543`), and the closer does not close the issue again. It stays `wip`.
- **Measured** (read-only, `do_spl_db_query`, prd, 09:08Z..09:12Z):
  - `issue_events` of t1, last 30 days, `field='status' and old_value='done' and new_value='wip' and actor='c-002'` -> **114 events on 57 issues, 21 of them still open** (first 2026-10-25, last 2026-11-22T22:51Z).
  - For SPL-5368, SPL-5609 and SPL-5847 each done -> wip event is the minute of a `Lane <id> placed on SPL-<n>, status wip.` comment: c-375 at 11-12 14:58, g-259 at 11-15 17:53, c-253 at 11-18 01:19; the closer (c-684) had set each `done` 13 to 167 minutes before.
  - Of the 21 still open, 15 have such a placement comment within 2 minutes of the reopen (SPL-6152, 5897, 5847, 5707, 5799, 5609, 5411, 5396, 5371, 5368, 5232, 4782, 4812, 4781, 3865); 6 have none (SPL-2750, 2163, 3028, 2373, 2175, 2377, reopened up to 8 times each), cause not read here.
  - The placed lanes' briefs (`/var/spool-hub/dispatch/briefs/*.md` on sat, `grep -l '^Issue: SPL-<n>'`), 6 of the 15 read: SPL-5847, 5609, 5411, 5396 and 5897 are R7 reviewer briefs (`c001-spl5847-box-update-stubs-claude-waiver-reviewer.md`, `hand-sat-c002-spl5609-desk-box-user-grok-reviewer.md`, `hand-<box2>-c002-spl5411-grok-reviewer.md`, `c003-spl5396-monitoring-no-x-grok-reviewer.md`, `c002-spl5897-supply-test-claude-waiver-reviewer.md`); SPL-6152's five are spec 190 lanes with `Issue-Role: shared`, where a later row reopening the issue is expected. The other 9 briefs were not read.
- **Red control** (`rc02.sh`, section 4.2): appended to that sha's `spl-lane-issue.tst.sh` (its stubbed hub logs every call), a reviewer lane (`Author:` line naming the fixer) placed with `LANE_ISSUE_KEY=SPL-77` on an issue the hub reads as `done`. On `2286c85ce` -> `rc02 calls: 3 status-writes: 1`, `rc02 review-on-done: got=reopened-wip want=left-done`, `rc02 sha=2286c85ce suite: spl-lane-issue: 0 failure(s)`, exit 1. **Control** in the same suite run: the existing case "a key: wip, the lane assigned, a comment" (`spl-lane-issue.tst.sh:120-125`) still passes (0 failures), so an owning lane's placement keeps setting `wip`.
- **Fix scope.** A placement whose brief is a review lane's by `li_review_lane` (a review heading with an `Author:` line naming another lane or a placement) leaves the status and the assignee alone and writes only the placement comment; an owning lane's placement is unchanged. Whether an `Issue-Role: shared` row lane may reopen a done issue is left as it is (SPL-6152 above). The test: the case of `rc02.sh` as a real case of `spl-lane-issue.tst.sh`, red before the fix. Docs: the place bullet of `csi-spl-doc/doc/md/lane-issue-and-docs.md`. The 21 issues already left `wip` are a prd write: the row does not touch them; the holder lists them for the owner's backlog after the row lands (section 5).

### 3.3 The R7 notes since W, re-read

| note | text (short) | why not a row |
|---|---|---|
| SPL-6277 g-790@`<box2>` N2 (msg c3c5219b) | one sha with two release tags under two prefixes: the ingest's `sort -V` keeps v1.9.0, the hub keeps v1.10.0 (`csi-spl-orc/src/bash/run/release-note-ingest.func.sh:155-158`; the hub's order is the numeric key `releaseVersionKey`, `csi-spl-api/src/go/spool-hub-api/internal/store/release_note.go:205`, used by `sortReleaseNotes` at `:250`. v0.1 cited `store/repo_sync.go:311`, a line that file (273 lines) does not have, and a string `<`: `git grep -nE 'Version *< *' 2286c85ce -- 'csi-spl-api/src/go/**.go'` -> 1 line, `store/box_locks.go:157` (a lock version, not a release); m-048 N2) | **No instance**: `git ls-remote --tags origin 'v*' \| grep -v '\^{}' \| awk '{print $1}' \| sort \| uniq -d \| wc -l` -> 0 of 2929 tags. No red control on a real repo. Carried. |
| SPL-6277 g-790 N1, N3 | the last-`/` strip vs `releaseVersionRe`; a glob starting with `.` now refused | **Per design**: the sync refuses, nothing illegal is stored; N3 is the spec's rule. |
| SPL-6274 g-449 N1 (msg f1362652) | on the reviewer's box: command-palette composer K failed once, issues-mobile and issues.test timed out, release-notes TypeError at `release-notes.test.mjs:342` | **Not seen in CI**: none of those files is a first red in the 100 runs (source 4). A load sighting on one box. |
| SPL-6286 g-031@`<box2>` N1-N3 | the TTL bound and its message | **Fixed by its lane**: `2286c85ce` (INE_TTL_HOURS over 720 refused). |
| the other 30 | file-list, count and wording notes inside their lanes | **0 W outside a lane's own scope**; each is its lane's. |

### 3.4 Round 39's first inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| The pre-push e2e selector's composed testids (round 37 section 4.1) | `rc01.sh` extracted from round 37's plan (sha256 first 12 hex `a76d454d20ea`, 2706 B, the same file), `bash rc01.sh origin/master` (on `7959f8f9c`, 30 s) | `rc01 keys: got=exact-only want=has-prefix` / `rc01 sel: got=cut 37 want=selected` / `rc01 ctrl: got=selected want=selected` / `rc01 sha=7959f8f9c keys=[msg-menu] wrong=2`, exit 1: the same as on `c9f6ac91a` | **Not a row**, as rounds 37 to 39 measured. Since W only `03c463f15` (SPL-6271: a cap of 35 files and the 240 s budget) touched `check-pre-push-e2e.func.sh`, and `sel` still reads `cut 37`. A gate-design input with the holder. |
| SPL-6174's link to the relay hash `3e2c61b1` | `git log origin/master --since="$W" --format='%h %s' \| grep -iE 'SPL-6174\|relay hash'` -> 0 | no writer named | **Not a row.** Carried. |
| b34-01 N2 and SPL-6212 N2 | rounds 38 and 39 | test-shaped | **Carried** to a test or refactor round. |
| The SPL-6212 and SPL-6226 notes, if their lanes end without landing | `git log origin/master --since="$W" --format=%h -E --grep='SPL-(6212\|6226)'` -> `2513d45d9`, `645718660` (SPL-6212), `a2ab946ed` (SPL-6226) | both landed | **Closed**: landed, nothing to carry. |
| r87-01 N2 (coverage floor tolerance) | no tier=full read past a floor's tolerance reported since W (source 6) | - | **Carried.** |

---

## 4. Red controls, as run

### 4.1 `rc01-b40.sh` (b40-01), sha256 first 12 hex `9372763ce891`, 2690 B

Run from any checkout: `bash rc01-b40.sh 2286c85ce`, then `RC01_SAME_SECOND=1 bash rc01-b40.sh 2286c85ce`. Each takes about 2 s on sat (warm Go cache).

```bash
#!/usr/bin/env bash
# rc01-b40.sh <sha>: b40-01 red control. On <sha>'s tree, two issues that
# link the tenant's default discussion (its Issue backlog topic), created one
# clock second apart, must log no "issue backlog" error: the topic is
# already posted. The Go test below is dropped into that tree's internal/hub.
set -uo pipefail
sha="${1:?usage: rc01-b40.sh <sha>}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
cat >"$d/internal/hub/b40_rc01_test.go" <<'GO'
package hub_test

import (
	"bytes"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/rs/zerolog"
)

type b40Buf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (w *b40Buf) Write(p []byte) (int, error) { w.mu.Lock(); defer w.mu.Unlock(); return w.b.Write(p) }
func (w *b40Buf) String() string              { w.mu.Lock(); defer w.mu.Unlock(); return w.b.String() }

func TestB40IssueBacklogSecondLinkLogsNoError(t *testing.T) {
	var logs b40Buf
	var clock atomic.Int64
	clock.Store(time.Date(2026, 11, 23, 8, 0, 0, 0, time.UTC).Unix())
	step := int64(1)
	if testingStep != "" {
		step = 0
	}
	e := rbacEnv(t, func(o *hub.Options) {
		o.Log = zerolog.New(&logs)
		o.Now = func() time.Time { return time.Unix(clock.Load(), 0).UTC() }
	})
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for i, title := range []string{"first", "second"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": title}); code != http.StatusCreated {
			t.Fatalf("create %d: %d %v", i, code, out)
		}
		clock.Add(step)
	}
	n := 0
	for _, l := range strings.Split(logs.String(), "\n") {
		if strings.Contains(l, `"level":"error"`) && strings.Contains(l, `"message":"issue backlog"`) {
			n++
		}
	}
	t.Logf("rc01 issue-backlog error lines: %d (clock step %d s)", n, step)
	if n != 0 {
		t.Fatalf("%d \"issue backlog\" error line(s) for a backlog topic already posted, want 0", n)
	}
}
GO
printf 'package hub_test\n\nvar testingStep = "%s"\n' "${RC01_SAME_SECOND:-}" >"$d/internal/hub/b40_rc01_step_test.go"
out="$(cd "$d" && go test -count=1 -run TestB40IssueBacklogSecondLinkLogsNoError -v ./internal/hub/ 2>&1)"; rc=$?
grep -E "rc01 issue-backlog|--- (PASS|FAIL)" <<<"$out" | sed "s/^ *//" || tail -15 <<<"$out"
echo "rc01 sha=${full:0:9} same_second=${RC01_SAME_SECOND:-0} rc=$rc"
exit $rc
```

| run | output |
|---|---|
| `bash rc01-b40.sh 2286c85ce` | `b40_rc01_test.go:51: rc01 issue-backlog error lines: 1 (clock step 1 s)` / `--- FAIL: TestB40IssueBacklogSecondLinkLogsNoError` / `rc01 sha=2286c85ce same_second=0 rc=1`, exit 1 |
| `RC01_SAME_SECOND=1 bash rc01-b40.sh 2286c85ce` | `rc01 issue-backlog error lines: 0 (clock step 0 s)` / `--- PASS` / `rc01 sha=2286c85ce same_second=1 rc=0`, exit 0 |

The test runs on the Memory store (no `SPOOL_TEST_PG_DSN` set); Postgres answers the same `ErrConflict` for a different envelope (`internal/store/postgres.go:510`), and the prd lines of source 1 are that path.

### 4.2 `rc02.sh` (b40-02), sha256 first 12 hex `53354825dcaa`, 1962 B

Run from any checkout: `bash rc02.sh 2286c85ce`, about 40 s on sat.

```bash
#!/usr/bin/env bash
# rc02.sh <sha>: b40-02 red control. On <sha>'s tree, an R7 reviewer lane
# (a review brief with an Author: line naming the fixer) placed with
# `Issue: SPL-77` on an issue the hub reads as done must not set it back to
# wip. The case is appended to that tree's spl-lane-issue.tst.sh, which
# stubs the hub (every call lands in calls.log).
set -uo pipefail
sha="${1:?usage: rc02.sh <sha>}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-orc csi-spl-cnf | tar -x -C "$tmp"
t="$tmp/csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh"
head -n -2 "$t" >"$t.new"
cat >>"$t.new" <<'CASE'
# b40-02: a reviewer lane placed on a done issue leaves it done.
mkdir -p "$S/g-777/lifetime"
printf '%s\n' '# Lane brief: R7 reviewer for SPL-77 (the fix landed first, rulebook 2.11.3)' '' 'Issue: SPL-77' 'Spec: csi-spl-doc/specs/135-work-process' 'Epic: SPL-1' \
  'Author: c-253@box-a (the fixer)' >"$S/g-777/lifetime/brief.md"
GETD='{"result":{"issue":{"key":"SPL-77","status":"done","description":"## Source\n/t/5ea2e615-ca23-451f-9fea-e1b87c369476\n","discussions":[]}}}'
run AGENT_ID=g-777 LANE_ISSUE_KEY=SPL-77 ISSUE_GET="$GETD" DRY_RUN=0
echo "rc02 calls: $(grep -c . "$T/calls.log") status-writes: $(grep -c '^update|--ref|SPL-77|--status|' "$T/calls.log")"
if grep -q '^update|--ref|SPL-77|--status|wip|' "$T/calls.log"; then echo "rc02 review-on-done: got=reopened-wip want=left-done"; else echo "rc02 review-on-done: got=left-done want=left-done"; fi
rm -rf "$S/g-777"
CASE
tail -n 2 "$t" >>"$t.new"; mv "$t.new" "$t"
out="$(bash "$t" 2>&1)"
line="$(grep '^rc02 review-on-done' <<<"$out")"
grep '^rc02 calls' <<<"$out"; echo "${line:-rc02 review-on-done: got=no-output want=left-done}"
echo "rc02 sha=${full:0:9} suite: $(tail -1 <<<"$out")"
[[ "$line" == *"got=left-done want=left-done" ]]
```

| run | output |
|---|---|
| `bash rc02.sh 2286c85ce` | `rc02 calls: 3 status-writes: 1` / `rc02 review-on-done: got=reopened-wip want=left-done` / `rc02 sha=2286c85ce suite: spl-lane-issue: 0 failure(s)`, exit 1 |

---

## 5. Rows

| # | id | practice | sites (file:line on `2286c85ce`) | evidence | red control (fails on `2286c85ce`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b40-01-api-issue-backlog-repost-no-error` | a second post of a posted topic is a no-op, as its comment says | `csi-spl-api/src/go/spool-hub-api/internal/hub/issue_backlog.go:51-53,58,76`; `internal/hub/issue_discussions.go:236-242`; test `internal/hub/issue_discussions_test.go:177` | prd log, 4 x `issue backlog` `conflict` t1 (12:34Z, 13:11Z, 19:26Z, 08:38Z), section 3.1 | `bash rc01-b40.sh 2286c85ce` -> `rc01 issue-backlog error lines: 1 (clock step 1 s)`, exit 1; control `RC01_SAME_SECOND=1` -> 0, exit 0 | `cd csi-spl-api/src/go/spool-hub-api && go test ./internal/hub/ -run 'IssueBacklog\|IssueDiscussion'` (`issue_discussions_test.go`, `box_lock_internal_test.go` name its symbols); **`internal/store/missing_notice_plan_test.go`** (holds the `"issue backlog"` string); the hub package whole, and on Postgres (`PRE_PUSH_TIER=full`, 2.12.4) | `issue_backlog.go` and its test only; no store, no migration | sat | claude (`simple_coding`) | grok seat | fix | 1 |
| 02 | `b40-02-orc-review-placement-keeps-done` | a review lane's placement never moves its issue's status | `csi-spl-orc/src/bash/run/spl-lane-issue.func.sh:305-316` (`:314` the `--status wip`); reads `li_review_lane` (`csi-spl-orc/src/bash/features/spawn-agents/lib/lane-issue.inc.sh:543`, unchanged); test `csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh:120-125` and a new case; doc `csi-spl-doc/doc/md/lane-issue-and-docs.md` | prd `issue_events`: 114 done -> wip by placement on 57 issues in 30 days, 21 still open; 3 matched to the minute to a reviewer's placement comment, section 3.2 | `bash rc02.sh 2286c85ce` -> `rc02 review-on-done: got=reopened-wip want=left-done`, exit 1 | `bash csi-spl-orc/src/bash/tests/spl-lane-issue.tst.sh`; `csi-spl-orc/src/bash/features/spawn-agents/tests/test-lane-issue.sh`, `test-lane-issue-remote-desk.sh`; `csi-spl-orc/src/bash/tests/desk-planned-ask.tst.sh`, `desk-user-hops.tst.sh`, `box-name-from-cnf.tst.sh`, `spl-reflection-gather.tst.sh`, **`in-orc-run-set.tst.sh`** (name `do_spl_lane_issue` or the file) | `spl-lane-issue.func.sh` (the place op only), its test, the doc's place bullet; the 21 stuck issues are not touched (prd write, the holder's) | sat | claude (`simple_coding`) | grok seat | fix | 1 |

- **R1:** the two rows share no file (`issue_backlog.go`, `issue_discussions_test.go` vs `spl-lane-issue.func.sh`, `spl-lane-issue.tst.sh`, `lane-issue-and-docs.md`): both batch 1.
- **R7:** `cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (09:16Z) -> `pick=sat reason=sat is the first box in order below its low mark (68% < 70%)`: a grok seat reviews each row (claude authors, grok reviews: cross-vendor). No mistral on either row (coding kinds); neither row touches `csi-spl-wui/`.
- **Pushes:** aim 1 each (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.
- **After b40-02 lands (the holder, not the row):** the 21 issues of section 3.2 read `wip` with no live lane; the 15 with a reviewer or shared placement are candidates to set back to `done` after a check of each, the 6 without one need their own read. Listed here, not done by any row (a prd write).

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes | their lanes | `lane-map.sh --check csi-spl-doc/doc/md/bug-round-40-plan.md,<the 6 row files of section 5> --agent c-591` (09:16:03Z) -> `WARN no live lane lists` them, exit 4: 4 `<box2>` lanes record no files (c-029, c-146, c-924, c-927), all four channel seats of another workspace (their scope column). The sat lanes at 08:58:18Z: c-547 (r91 planner; its plan's sites are `spl-search-calendar-probe.*` and `tf-import-existing.*`, `grep -cE 'spl-lane-issue\|lane-issue.inc\|issue_backlog\|issue_discussions' refactor-round-91-plan.md` -> 0), c-581 and g-031 (SPL-6286, landed `2286c85ce`), c-578 (SPL-6285, WUI settings + locales), g-572 (SPL-6284 R7). The queue: `do_spl_spawn_queue` 08:58:23Z -> 1 queued (grok R7 for SPL-6285), 09:16:12Z -> `0 queued, 1 placing`. |
| `monitoring-costs.test.mjs` hr-tab flake | the holder, CI trunk-red watch (2.11.3) | 1st sighting (run 45124937982); a lane on its 3rd. Its unchecked `waitFor` at `:358` is a test-shaped input. |
| The e2e selector's composed testids | the holder, as a gate input | unchanged since round 37 (section 3.4). |
| The 21 issues left `wip` | the holder | section 5, after b40-02. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 7 sources; 42 prd error log entries (26 h); 9 alert policies (0 incidents); 13 open bug issues; 100 wf 10 runs (5 failures, 3 jobs, each with a landed fix or a first-sighting flake); 45 R7 note messages; round 39's first inputs (6); `rc01.sh` n=1 on `7959f8f9c`; `rc01-b40.sh` n=2 and `rc02.sh` n=1 on `2286c85ce` |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b40-'` -> 0; `git ls-remote origin 'refs/heads/review/b40-*' 'refs/heads/wip/*b40*' 'refs/heads/*-b40-*'` -> nothing (rc 0); sat: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b40\|bug-round-40'` -> this planner's brief only (`c002-bug-round-40-planner.md`); `git worktree list \| grep -E 'b40\|bug-round-40'` -> c-591 (this seat) and c-178 on `526b405fb` (a hex match, not a b40 worktree), 08:58:09Z |
| R7 seat | grok (`pick=sat`, 09:16Z) |
| first inputs for round 41 | the selector's composed testids (if no gate round takes it); the `monitoring-costs` hr-tab flake if it is seen again; the 6 issues reopened with no placement comment (SPL-2750, 2163, 3028, 2373, 2175, 2377); SPL-6277 N2 if a sha ever carries two release tags; SPL-6174's relay-hash link once its writer is named; b34-01 N2 and SPL-6212 N2 (test-shaped); r87-01 N2 if a tier=full run reads a package past its floor's tolerance |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-591@sat (claude, `specs_and_docs`).
- **Panel:** m-048@`<box2>` (mistral), placed by the holder (ask 5af4bd63).
- **Row reviewer (R7):** a grok seat per row (section 5).
- **Review history:**
  - 2026-11-23 09:2xZ: v0.1, pushed to `review/c002-bug-round-40-planner`: 2 rows.
  - 2026-11-23 09:53Z: m-048 **PASS** on v0.1 `699e09331` (msg ca35d1eb), W: none. N1: `rc02.sh`'s suite tail reads 39 failures on `<box2>` against 0 on sat, from a sibling repo absent there; the two rc02 case lines reproduce exactly. N2: the 3.3 cite, corrected in v1.0. N3: the candidates file is sat-only, that check NOT RUN on `<box2>`. N4: no b40 brief on `<box2>`, the seat's brief is a spawn-remote one. Only N2 changes the plan.
  - v1.0: N2 folded; the seat file folded from `review/c002-bug-round-40-mistral-seat` `89a3d8466`. No row changed.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-591@sat | v1.0 |
| Panel | m-048@`<box2>` (mistral) | **PASS** on v0.1 `699e09331` (msg ca35d1eb); no W; N2 folded in v1.0 |
| Holder | c-002@sat | - |
