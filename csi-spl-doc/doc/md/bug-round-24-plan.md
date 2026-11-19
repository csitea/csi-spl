# Bug-fix round 24 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-5998 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `d5a6519e-18d0-4354-9a52-2b7154a8b52a` ("Bug round 24", opener msg 72427ebd, opened by c-002@sat 20:57:17Z). Round 23 ([bug-round-23-plan.md](bug-round-23-plan.md) v1.0, 2 rows) is closed: b23-01 landed `7b6cd900e` (SPL-5989), b23-02 landed `a6f5a723d` (SPL-5990), plan v1.0 `e7627fc85`. Bug share: c-001 spawn share e7612fa3 (bug 15%).  
Round focus: one owner-visible leak (the reader's own Flow names and shows a topic of a box locked to someone else) and one test that only passes for the user who may write the source tree.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. Two inputs give a live, unowned defect with a red control that fails on `origin/master`: 2 rows.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-23-plan.md](bug-round-23-plan.md) (same shape, same 5 sources).

**Status: v1.1, signed** by the panel (m-636@`<box2>`, mistral, PASS on `f25630876`, 0 warnings; this commit records the signature and the panel's notes, no row changed).  
Editor: **c-629@`<box2>`** (claude, `specs_and_docs`).  
Panel: m-636@`<box2>` (mistral, ask 3f35daf4, slug `c002-bug-round-24-mistral-panel-seat`), placed by c-001 (msg d48afbba) for the dispatch holder c-002@sat (section 8).

**One sha:** every count below is measured on **`17f0d7b00`** (`origin/master`, committed 2026-11-19T21:46:55+01:00), on `<box2>`, between 21:02Z and 21:16Z on 2026-11-19, unless a row says otherwise. n=1 per command unless stated. `origin/master` moved to `99c0fd73b` (a spec 181 doc) during the read; `git diff --stat 17f0d7b00 99c0fd73b` on every row file below is empty.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b23-plan')` -> `Window: W=2026-11-19T19:12:42+01:00`.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 23. `<PUSH_USER>` is the OS user that owns the checkouts and pushes; `<AGENT_USER>` the OS user an agent runs as (the public repo names neither).

---

## 1. How to read this

- Round 23 measured on `23864a224`. This plan re-measures what changed since (`git rev-list --count 23864a224..17f0d7b00` -> 19 commits), round 23's first inputs for round 24 (its section 7), the brief's row candidate and every bug item of the holder's candidate list, and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `17f0d7b00`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `17f0d7b00`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since 17:30Z** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-19T17:30:00Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (21:12Z) | t1 19 (12 `[spool-probe]`, 0 hits), csitea 21 (0 hits) | **0 rows** from new reports. The owner's open question is older: HUM-10 asked "Status" in t1 32cb9c05 (20:53Z) on SPL-4895's N1, and the answer (msg 21127a7d) promised it to this round: row 01. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <PUSH_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (21:05Z) | 100 runs; every job's last green is 44605721651 on `79b22fa0` (20:09Z) | **0 rows.** No failed run after round 23's read (17:36Z): the newest red is 44570765247 (16:51Z, `ee958d2b`, round 23's `gcp-billing-invoices.tst.sh` n=1, green since; the orc 1/4..4/4 lines of that run are the fail-fast stop). `wui 6/8 FAIL 4j Shift+O opens the issue` (44569585278, 16:44Z) is fixed by `31b731d7b` (SPL-5987, the holder's ask 05200a28), green in every run since. |
| **3. Skipped or disabled tests** | `git diff 23864a224 17f0d7b00 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 0 files | **0 rows.** |
| **4. Box cron logs** | `<box2>`: `/var/csi/csi-spl/review-go/cron.out` (every line since round 23: `INFO the dispatch lease is held by c-002@sat, on another machine`), `grep -ac 'failed; the next run tries again'` -> 0; `/var/csi/csi-spl/done-claim-check/cron.log` (the one new alert, section 5) | 2 logs read for the named inputs | **0 rows.** sat's logs: the holder's (section 8). |
| **5. Round 23's first inputs, the brief's row candidate, the holder's candidate list** | round 23 section 7; the brief (SPL-4895 N1, c-148 msg 2e17eca7 thread); the bug items of `c002-next-round-candidates.md` as inlined in the brief's appendix (on sat, not read from `<box2>`) | 13 inputs | **2 rows**: 01 from SPL-4895 N1, 02 from the hermetic-suite item (round 23 section 5, c-001 a9ee75ee). The other 11: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `17f0d7b00`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b24-01-api-flow-own-read-cut-by-box-lock)` | The reader's OWN Flow is not cut by the box owner lock except for the unfolded events. `handleViewFlow` drops an event with `lv.hiddenByLock(e.FromBox, e.ToBox)` (`hub/flow.go:164`) but builds `counts`, `unread` and `keys` from the store's page unchanged (`:160`), so they count the hidden line and `keys` names its topic (`t:<task>`). The folded read the web UI's Flow pane uses (`csi-spl-wui/src/stores/flow.ts:74`, "Mine is the hub's folded lines (fold=day)") goes through `flowFoldBody` (`hub/flow_fold.go:70-93`), which reads no lock at all: the locked box's line is served with its title, text, author ids and link. The pushed counts (`pushFlowCounts`, `hub/flow.go:281-296`, a store `FlowRead` with no lock) carry the same numbers. `52eb8a9e8` (SPL-4895) closed the same leak for a read of SOMEONE ELSE by refusing it (403) while a box is locked, and spec 130 says why: "a folded line names no box to cut it by, and the target's counts, unread and keys are not cut per box" (`csi-spl-doc/specs/130-flow-what-is-happening/spec.md:174-180`); the reader's own read kept both gaps. | SPL-4895 N1 (c-148 msg 2e17eca7 thread, 2026-11-06 09:47Z); the declined ask d6f4b40b (its discussion archived 11-11, never built); the owner's "Status" (t1 32cb9c05, 20:53Z) and its answer 21127a7d, which promised this round. On `<box2>`, n=1: the red control (right) on a `git archive 17f0d7b00 csi-spl-api` copy. Its controls pass on the same run: the open box's line is the one event / line, and its key `t:<task>` is present. | `csi-spl-api/src/go/spool-hub-api/internal/hub/flow.go:155-160` (the own read's body), `:281-296` (`pushFlowCounts`); `hub/flow_fold.go:70-93` (`flowFoldBody`, also the agent `flow_read` frame's, `hub/flow_agent.go:47`); `internal/store/flow.go:99-107` (`FlowQuery`), `:512` (Memory `FlowRead`); `store/flow_fold.go:231` and `:369` (`FlowFoldRead`); `store/flow_postgres.go:341` (`FlowRead`); test beside `TestFlowMemberRefusedWhileABoxIsLocked` (`hub/flow_member_test.go:135`) on `newViewRig` (`hub/box_lock_view_test.go:46`); doc spec 130 `:174-180` and `csi-spl-doc/specs/062-flow-per-user-counts/contracts/flow-v1.md` section 2 | `go test ./internal/hub/ -run TestB24FlowOwnCountsCutByLock -count=1` with `rc01_flow_own_lock_test.go` (section 3.2) dropped into `internal/hub/` of a `17f0d7b00` copy: `--- FAIL`, 10 lines: for each of the unfolded, `counts_only=true` and `fold=day` reads `keys name the locked box's topic t:<task>`, `counts.total 2, want 1`, `unread.total 2, want 1`, and for `fold=day` also `a line opens the locked box's topic`. 0 CONTROL lines. | The store's flow reads take the boxes hidden from the reader (a new `FlowQuery` field, from `lockViewFor`) and leave out every event whose message's `from_box` or `to_box` is one of them, from the events, the folded lines, `counts`, `unread` and `keys`, in the Memory and the Postgres driver alike. The hub fills it on the own unfolded, `counts_only` and `fold=day` reads and in `pushFlowCounts`; the `?member=` 403 of `52eb8a9e8` stays. The `flow` frame of `fanoutFlow` (`hub/flow.go:228-258`) already skips a member the new line is hidden from (`s.locks.hides`, `:240`); its counts come from `FlowFanout` (`store/flow_postgres.go:379`), which takes no query: cut there too if it fits the row's pushes, else the lane names it in its result as round 25's first input. The agent `flow_read` frame (`hub/flow_agent.go:47`) is an agent's read, out of this row: unchanged. Postgres: `PRE_PUSH_TIER=full` (a store change). Spec 130 `:174-180` and contract flow-v1 section 2 say the own read is cut. | `<box2>` or sat | claude | claude waiver seat (1a7c70da), fresh session, tree only | `complex_coding` (a read-path security fix, two drivers) | 1 |
| 02 `fix(b24-02-orc-test-spool-bin-out-of-tree)` | `t_spool_bin` (`csi-spl-orc/src/bash/features/spawn-agents/tests/lib.inc.sh:96-103`) builds the spool binary INTO the checkout, `$T_REPO/csi-spl-api/src/go/spool-hub-api/bin/spool`, when it is absent. A user who may read but not write the tree fails every test that sources it before its first case (`mkdir: cannot create directory '.../spool-hub-api/bin': Permission denied`, `FAIL - cannot build spool`), and the push user's run leaves a 68 MB build in the source tree (`git status --ignored` -> `!! csi-spl-api/src/go/spool-hub-api/bin/`). It breaks developer guide 2.12.2 (a test writes only under its own temp dir). Which run passes depends on who ran first: once the push user has built `bin/spool`, every user passes. | c-947 msg 75843c44 (n=1, not reproduced by c-001 or c-002); c-001 a9ee75ee (ruled the row for the next bug round); round 23 section 5 ("with sat's failing output it is round 24's first row"). On `<box2>`, n=1 each at 21:10Z in this worktree (`17f0d7b00`, no `bin/` yet): as `<AGENT_USER>` `watcher-read-only.tst.sh` -> `0 passed, 1 failed`, rc 1; as `<PUSH_USER>` -> `81 passed, 0 failed`, rc 0, and the build is left in the tree. `git grep -l t_spool_bin -- csi-spl-orc` -> 24 files (19 tests, the test lib, 4 non-test scripts with their own `SPOOL_BIN` code). The other half of c-947's report is not reproduced: `check-commit-msg-hygiene.tst.sh` is green as both users (18 PASS each, rc 0). | `csi-spl-orc/src/bash/features/spawn-agents/tests/lib.inc.sh:96-103` (`t_spool_bin`); its callers, read only (`csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh:31-33` and the other test files of the `git grep`); doc: the comment above `t_spool_bin` | `bash rc02.sh 17f0d7b00 <PUSH_USER> <AGENT_USER>` (section 3.2): a fresh copy of `17f0d7b00` owned by the push user, `chmod -R go-w`, then the test as the agent user -> `mkdir: cannot create directory '<copy>/csi-spl-api/src/go/spool-hub-api/bin': Permission denied` / `FAIL - cannot build spool` / `-- watcher-read-only.tst.sh: 0 passed, 1 failed` / `FAIL: b24-02: ... rc 1`, exit 1. Its control: `bash rc02.sh 17f0d7b00 <PUSH_USER> <PUSH_USER>` -> `81 passed, 0 failed`, `PASS`, exit 0. | `t_spool_bin` keeps using the tree's `bin/spool` when it is there and executable; else it builds outside the tree, into a per-user cache keyed by the api source (e.g. `${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/spool-<tree sha of csi-spl-api/src/go/spool-hub-api>`), never into the checkout. The lane adds a case (a tree the runner cannot write -> the test runs, the tree is unchanged) with its red control, and says in the function's comment where the build goes. The 4 non-test scripts and `spool_agent_spool_bin` (`spool-env.inc.sh:632`) are out of the row. No developer guide edit (a Qto export; a change asks every coder to re-ack): the question "which user runs the suites" goes away when the suites do not depend on it. | `<box2>` (it has an agent user that cannot write a push-user tree) | claude | claude waiver seat (1a7c70da), fresh session, tree only | `tests` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** both rows; their files are disjoint.
  - Row 01: `csi-spl-api/src/go/spool-hub-api/internal/hub/flow.go`, `hub/flow_fold.go`, `hub/flow_member_test.go` (or a new `hub/flow_lock_test.go`), `internal/store/flow.go`, `store/flow_fold.go`, `store/flow_postgres.go` (and a store test beside `store/flow_headless_test.go` if the lane adds one), `csi-spl-doc/specs/130-flow-what-is-happening/spec.md`, `csi-spl-doc/specs/062-flow-per-user-counts/contracts/flow-v1.md`.
  - Row 02: `csi-spl-orc/src/bash/features/spawn-agents/tests/lib.inc.sh` and one new test case file (or a case in an existing spawn-agents test).
- **Test column (R2):**
  - Row 01: `git grep -lE 'hiddenByLock\|lockViewFor\|flowFoldBody\|FlowRead\|FlowFoldRead\|pushFlowCounts' -- 'csi-spl-api/**/*_test.go'` on `17f0d7b00`; at least `go test ./internal/hub/ ./internal/store/`, on Postgres (`PRE_PUSH_TIER=full`).
  - Row 02: `git grep -l t_spool_bin -- 'csi-spl-orc/**/tests/*'` (19 test files); at least `watcher-read-only.tst.sh` as both users and the spawn-agents suite.
- **Off limits** for the row lanes: every live lane's files (below); `hub/flow_member.go` (`52eb8a9e8`'s, read only); `hub/flow_agent.go` (read only); `spool-env.inc.sh` (read only).
- **How the files were checked (2026-11-19, `<box2>`):**
  - 21:04:56Z `lane-map.sh --check` on `hub/flow.go`, `hub/flow_fold.go`, `store/flow.go`, `store/flow_fold.go`, `store/flow_postgres.go`, `hub/flow_test.go`, spec 130 `spec.md` and this plan `--agent c-629` -> `WARN no live lane lists` them; exit 4 for three sat lanes that record no files: c-046@sat (spec 143 B-6b, hub GitHub sync), c-946@sat (SPL-5963, hub calendar), m-079@sat (refactor round 69 panel seat). None of their briefs names a flow file. Row 02's `lib.inc.sh` was added after this run: the orchestrator runs R3 on every row path before the spawn.
  - 21:05:04Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> 2 queued, 0 placing: the reviewer seat for SPL-5808 (spec 143 B-6b1) and SPL-5882 T2 (evlog store migration); neither names a row file.
  - The brief's live lanes (c-946@sat SPL-5963; c-521 spec 179 B1 SPL-5980: rdb topic pauses, api store topic pauses; c-046@sat spec 143 B-6b; r69-01 orc spawn tests shellcheck and r69-02 api merge topic request, per `refactor-round-69-plan.md`; SPL-5882 T2; the spec lane SPL-5997; the customer workspace seats): row 02's `lib.inc.sh` is a spawn-agents test file; r69-01 does not touch it (c-002@sat msg c6e214c3: `git diff --name-only $(git merge-base origin/master origin/review/r69-01) origin/review/r69-01` at `27cbe099d` -> `.shellcheck-warning-baseline.txt` and three spawn-agents tests, `test-agent-identity-reconcile.sh`, `test-agent-identity-restore.sh`, `test-spool-poke-queue.sh`).
- **Slug b24 is unused as a round id** (`<box2>`, 21:02Z): `git log origin/master --since="$W" --oneline -E --grep='\(b24-'` -> 0; `git ls-remote origin 'refs/heads/review/b24-*' 'refs/heads/wip/*b24*' 'refs/heads/*-b24-*'` -> nothing. sat (c-002@sat msg c6e214c3, 21:2xZ): `ls dispatch/briefs \| grep -cE 'b24-[0-9]{2}'` -> 0; `git worktree list \| grep -cE 'b24-[0-9]{2}\|bug-round-24'` -> 0; `git ls-remote origin \| grep -E 'b24-[0-9]{2}\|bug-round-24'` -> only this plan's `review/c002-bug-round-24-planner`; `git log origin/master --grep='\(b24-[0-9]{2}' \| wc -l` -> 0.

  After this plan's pushes, `--grep='(b24-'` matches the plan's commits (`docs(b24-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b24-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red controls run on `17f0d7b00`

The files are on `<box2>` in `/var/spool-hub/dispatch/b24-red-controls/` (`sha256sum`, first 12 hex): `rc01_flow_own_lock_test.go` (2201 B, `a68448d99d2e`), `rc02.sh` (1035 B, `f971d6719a4c`). Both are printed below, so a seat on sat can rebuild them.

| row | command | output on `17f0d7b00` | who |
|---|---|---|---|
| 01 | `git archive 17f0d7b00 csi-spl-api \| tar -x -C <dir>`; copy `rc01_flow_own_lock_test.go` into `<dir>/csi-spl-api/src/go/spool-hub-api/internal/hub/`; there `go test ./internal/hub/ -run TestB24FlowOwnCountsCutByLock -count=1` | `--- FAIL: TestB24FlowOwnCountsCutByLock`, 10 lines (each task id shown as `<task>`): `admin own flow: keys name the locked box's topic t:<task>` / `admin own flow: counts.total 2, want 1 (the locked line counted)` / `admin own flow: unread.total 2, want 1 (the locked line counted)` / the same three for `?counts_only=true` / `admin own flow?fold=day: a line opens the locked box's topic: map[... ids:[CLE-01] kind:mention ... text:wombat ping @HUM-2 look title:wombat ping @HUM-2 look ...]` / the same three for `?fold=day`; `FAIL`. No `CONTROL` line (21:15:42Z). | editor c-629 |
| 02 | `bash rc02.sh 17f0d7b00 <PUSH_USER> <AGENT_USER>`; control `bash rc02.sh 17f0d7b00 <PUSH_USER> <PUSH_USER>` | RED: `mkdir: cannot create directory '<copy>/csi-spl-api/src/go/spool-hub-api/bin': Permission denied` / `FAIL - cannot build spool` / `-- watcher-read-only.tst.sh: 0 passed, 1 failed` / `FAIL: b24-02: watcher-read-only as <runner> on a read-only 17f0d7b00 tree, rc 1`, exit 1. Control: `-- watcher-read-only.tst.sh: 81 passed, 0 failed` / `PASS: ... rc 0`, exit 0 (21:13:45Z). | editor c-629 |

No prototype fix was written for either row: row 01's cut belongs in the store's count queries, which the lane writes, and row 02's control run, as the push user, shows the test itself passes once the build is possible.

`rc01_flow_own_lock_test.go`, as run:

```go
package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// b24-01 red control: the reader's OWN Flow (unfolded, counts_only and
// fold=day) must not carry a line of a box locked to someone else
// in its events, lines, counts, unread or keys.
func TestB24FlowOwnCountsCutByLock(t *testing.T) {
	r := newViewRig(t)
	ctx := context.Background()
	say := func(b *box, agent, word string) string {
		cli, err := b.c.Dial(ctx, "cli")
		if err != nil {
			t.Fatal(err)
		}
		defer closeWait(cli)
		m := chanMsg(uuidV4(), "ALL-0", "note", word+" ping @"+r.admin+" look")
		m.From = agent
		if _, err := cli.Send(ctx, signedIn(t, b, hub.WUIBox, "ops", "", m)); err != nil {
			t.Fatalf("%s post: %v", agent, err)
		}
		return m.TaskID
	}
	lockedTask := say(r.own, "CLE-01", "wombat") // box-own is locked to r.owner
	openTask := say(r.sh, "CLE-02", "quokka")    // control: box-sh is not locked
	for _, q := range []string{"", "?counts_only=true", "?fold=day"} {
		code, out, n := flowOf(t, r.e, r.tid, "/v1/view/flow"+q, r.admin)
		if code != http.StatusOK {
			t.Fatalf("admin own flow%s: %d %v", q, code, out)
		}
		keys, _ := out["keys"].(map[string]any)
		if lines, _ := out["lines"].([]any); q == "?fold=day" {
			n = 0
			for _, l := range lines {
				if l.(map[string]any)["task_id"] == lockedTask {
					t.Errorf("admin own flow%s: a line opens the locked box's topic: %v", q, l)
				} else {
					n++
				}
			}
		}
		if q != "?counts_only=true" && n != 1 {
			t.Errorf("CONTROL admin own flow: %d events, want 1 (the open box's): %v", n, out)
		}
		if _, ok := keys["t:"+openTask]; !ok {
			t.Errorf("CONTROL admin own flow%s: no key for the open box's topic: %v", q, keys)
		}
		for k := range keys {
			if strings.Contains(k, lockedTask) {
				t.Errorf("admin own flow%s: keys name the locked box's topic %s", q, k)
			}
		}
		if c := countOf(out, "counts", "total"); c != 1 {
			t.Errorf("admin own flow%s: counts.total %v, want 1 (the locked line counted)", q, c)
		}
		if u := countOf(out, "unread", "total"); u != 1 {
			t.Errorf("admin own flow%s: unread.total %v, want 1 (the locked line counted)", q, u)
		}
	}
}
```

`rc02.sh`, as run (`RC_DEBUG=1` also prints the last 5 lines of the test):

```bash
#!/usr/bin/env bash
# rc02.sh <sha> <owner> <runner>: b24-02 red control. A fresh copy of <sha>
# owned by <owner> (the push user; modes 755/644, no bin/), then
# watcher-read-only.tst.sh run as <runner>, who may read the tree but not
# write it. Run from any checkout; it is not touched.
set -uo pipefail
sha="${1:?usage: rc02.sh <sha> <owner> <runner>}"; own="${2:?owner}"; u="${3:?runner}"
T="$(sudo -u "$own" mktemp -d)"; trap 'sudo -u "$own" rm -rf "$T"' EXIT
git archive "$sha" | sudo -u "$own" tar -x -C "$T"
sudo -u "$own" chmod -R go-w "$T"; sudo -u "$own" chmod 755 "$T"
out="$(cd / && sudo -u "$u" timeout 600 bash "$T/csi-spl-orc/src/bash/tests/watcher-read-only.tst.sh" 2>&1)"; rc=$?
{ [[ -n "${RC_DEBUG:-}" ]] && tail -5 <<<"$out"; grep -E "cannot build|denied|passed," <<<"$out"; } | sed "s#$T#<copy>#g" | head -4
[[ $rc -eq 0 ]] && echo "PASS: b24-02: watcher-read-only as <runner> on a read-only $sha tree, rc 0" ||
  echo "FAIL: b24-02: watcher-read-only as <runner> on a read-only $sha tree, rc $rc"
[[ $rc -eq 0 ]]
```

---

## 4. Round 23's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b23-01, b23-02 | `git log origin/master --oneline -E --grep='\(b23-0[12]-'` | landed `7b6cd900e` (b23-01), `a6f5a723d` (b23-02) | Served (round 23 closed, the brief). |
| The `issues-ctxmenu` failure `4j Shift+O opens the issue` (round 23 section 6) | `git log --oneline 23864a224..17f0d7b00 -- csi-spl-wui/tests/e2e/issues-ctxmenu.test.mjs` | `31b731d7b fix(wui, SPL-5987): issues-ctxmenu 4j waits for the ?issue= URL the modal's push writes`; no `4j` red in the 100 runs after 16:44Z (section 2) | Fixed by the holder's ask 05200a28. |
| The retired-author GO re-send (round 23 section 5; the holder's list: 13 `GO to c-836@sat failed` lines at 08:0xZ) | `git log --format='%h %cI %s' -S'the author is retired on this machine' -- csi-spl-orc/src/bash/run/spl-review-go.func.sh`; `spl-review-go.func.sh:832-850` at `17f0d7b00` | `2f634fbd4 2026-11-19T11:56:41+01:00 fix(b20-01-orc-review-go-retired-author-no-retry, SPL-5953)`: a spool-send exit 14 (the author retired on this machine) is held once and not sent again | Served by b20-01, which landed after the 08:0xZ count (10:56Z). What stays open is by design and written there: a relayed send to a retired author on ANOTHER box exits 11, as a hub error does, and is retried until `REVIEW_GO_MAX_AGE`. No observed case of that (n=0 on `<box2>`, whose review-go sends nothing while the lease is on sat). sat (c-002@sat msg c6e214c3): its `review-go/cron.out` has 52 `GO to ... failed` lines, all for c-836@sat (msg 6ac14d30); the last is line 30397 of 31204, and the 757 runs after it have 0 `failed` / `retired` lines; the desk tree runs `99c0fd73b`, which contains `2f634fbd4`. The lines carry no timestamps: that the last one is from ~08:5xZ is inferred from the run count, not read. |
| The hermetic-suite failure (round 23 section 5) | section 3, row 02 | reproduced on `<box2>` | **Row 02.** |

---

## 5. Not a row this round, or no red control yet

| candidate | command | result |
|---|---|---|
| **done-claim check: `76098a7b146f` read as a sha** (c-001@`<box2>` af28a599, c-924@`<box2>` 6977aa8e, n=1) | `grep -n 76098a7b146f /var/csi/csi-spl/done-claim-check/cron.log` -> `940766d4-... c-924 alert 018ec793e5 76098a7b146f` (20:55Z); the result's text: `... 018ec793e5 on <a customer feature branch>: box head + Bitbucket ls-remote = 018ec793e5 (job 76098a7b146f, push rc 0)`; the check's labels (`spl-done-claim-check.func.sh` header `:15-27`): `md5`, `sha1`..`sha512`, `gr-cmd`, `request id`, `req`, no `job` | **Not a row.** Both readings are partly right: `76098a7b146f` follows a `job` label the check does not know, but the same alert also names `018ec793e5`, a real commit on a customer repo's feature branch, not on a trunk: the check alerts on it by its rules (header `:59-66`), and cutting the `job` token would not have stopped this alert. n=1. If a `job <hex>` token alone alerts again, the row is a `job` label beside `gr-cmd` (the b23-02 shape), red control: `spl_done_claim_tokens <<<'(job 76098a7b146f, push rc 0)'` prints `76098a7b146f`. The result could also say "job id" in words. |
| **SPL-5850 N1: an AltGr letter may pick a kind** (`kind-picker-keys.ts:48`, `msg-shortcuts.mjs:94`; c-264 8352e059) | not run: it needs a browser with an AltGr layout | **No red control.** Unchecked in a browser since 11-18; bug-shaped, not proven. A row once an e2e with a synthetic AltGr keydown (`ctrlKey && altKey`, `ev.code` `KeyN`, `ev.key` `ń`) picks a kind. |
| **`blog.test.mjs:329` fails when run alone** (SPL-5960 R7 c-395 N3, c-002 msg 577d03b7: 3/3 alone on `67232dbc8`, passes in the suite) | not re-run on `17f0d7b00` (a generated bundle and Chrome) | **No red control on this sha.** An order-dependent e2e (green in CI, which runs the suite): a test-isolation defect, no product behaviour. Next bug round's input with a `BASE_URL=<bundle> node --test --test-name-pattern 'picking bg' tests/e2e/blog.test.mjs` run on its sha. |
| **The reviewer note to the wrong author** (c-001 1e0907c0, corrected by 364398a4: the never-list `author c-NNN`) | `git log --oneline -1 3e46a758c` | **Served** by b22-02 (`3e46a758c`, the `Author:` line wins in `spl-spawn-review-notify.func.sh`). |
| **done-claim: a `sha256sum` prefix read as a sha** (c-001 95722c63) | `git log --oneline -1 a6f5a723d` | **Served** by b23-02. |
| **Rows A and B of the reflection (Qto 71e1dbd3, SPL-5992; c-001 30bab7b0)**: a sweep that lists done issues whose linked topic has no agent post after `completed_at`, and topics with an owner-set priority and no issue | read as written | **Not bugs: detectors.** Nothing fails today; both add a check the rules call for (the holder posts at ACCEPTED; every discussion carries an issue). Feature rows for the holder's feature queue. |
| **`fallback_postgres.go:83-86` probes uncovered** (r34-01 R7 c-321 N1/N2) | as reported (a plant dropped -> all store/hub pg tests green) | **A test-coverage gap with no failing behaviour: not a bug row.** A test round's input. |
| **c-947's `check-commit-msg-hygiene.tst.sh` cases 6 + 8** (75843c44) | `bash csi-spl-iac/src/bash/tests/check-commit-msg-hygiene.tst.sh` as `<AGENT_USER>` and as `<PUSH_USER>` (21:10Z, this worktree) | **Not reproduced:** 18 PASS, rc 0, as both (n=1 each). |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes of the brief and the queue (section 3.1) | their lanes | None lists a row file (lane map 21:04:56Z, queue 21:05:04Z); r69-01 does not touch `lib.inc.sh` (section 3.1). The orchestrator re-runs R3 before the spawn. |
| The agent `flow_read` frame (`hub/flow_agent.go:47`) and `FlowFanout`'s counts, if row 01 leaves them | row 01's lane names them in its result | Round 25's first input. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 5 sources; 13 named inputs; 40 human posts counted (0 hits); 100 CI runs; 2 cron logs; 2 suites run as 2 users |
| first inputs for round 25 | row 01's leftovers (`FlowFanout` counts, the agent `flow_read` frame) if any; the `job` label of the done-claim check if it alerts alone; the AltGr e2e; the `blog.test.mjs:329` alone-run |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-629@`<box2>` (claude, `specs_and_docs`).
- **Panel:** m-636@`<box2>` (mistral, ask 3f35daf4, slug `c002-bug-round-24-mistral-panel-seat`; `<box2>` has both OS users row 02's control needs), placed by c-001 (msg d48afbba). grok is off (owner 2026-11-04) and sat has no agy, so one non-claude seat. The panel checks both red controls (rebuild them from section 3.2; row 01 needs Go only, row 02 two OS users, one of which cannot write a tree the other owns), the fix scopes (row 01: the cut is in the store, both drivers, and covers events, folded lines, counts, unread and keys; the `?member=` 403 stays. Row 02: the build leaves the tree, a present tree `bin/spool` is still used), and that every other input in sections 2, 4 and 5 is measured as written.
- **Asked of the holder with v0.1, answered** (c-002@sat msg c6e214c3): the sat half of the slug check (section 3.1: 0); r69-01's files (section 3.1: not `lib.inc.sh`); sat's `review-go/cron.out` (section 4: no failed GO after line 30397).
- **Row reviewers (R7):** claude waiver seat (1a7c70da), fresh session, tree only, for both rows. Mistral reviews plans, not row code (c-001 ruling b71016ad, 11-17, p13 SPL-5779; the owner's mistral rule 91bf8278 read as plan panels only), grok is off, sat has no agy: the holder names this same-vendor review a waiver.
- **Review history:**
  - 2026-11-19 21:21Z: the editor pushed v0.1 (`8c767953d`) to `review/c002-bug-round-24-planner` and asked the holder for a panel (msg 029e9bd9).
  - 21:2xZ: the holder answered (msg c6e214c3): the mistral panel seat queued, the R7 vendor changed from grok (off) to mistral, the three questions answered. v1.0 (`e1ad57824`) folded them; no row changed.
  - 21:3xZ: the holder (msg 7ae6099f): R7 for both rows is the claude waiver seat, not mistral (ruling b71016ad); the panel seat is m-636@`<box2>`. v1.1 (`f25630876`) folds it; no row's fix or red control changed.
  - 2026-11-19: panel seat m-636@`<box2>` (mistral, placed by c-001 d48afbba): **PASS** on `f2563087664e9fa7f4b3b3e55aa62e709f56553c`, 0 warnings (msg 6c05761d); seat file on `review/c002-bug-round-24-mistral-seat` at `db5164163`. It re-ran the slug check (0), all 29 cited sites on `17f0d7b00` and `origin/master` (29 OK), rc01 on a `17f0d7b00` copy (exit 1, 10 FAIL lines, 0 CONTROL), rc02 as the agent user (exit 1, `0 passed, 1 failed`) and as the push user (exit 0, `81 passed`), the red-control sha256 prefixes and printed sources (match), `lane-map.sh --check` on the row paths, r69-01's files, sections 4 and 5, and `do_check_dist_hygiene` (clean).
  - Panel notes (none changes a row):
    - N1: `lane-map.sh --check` on the row paths exits 4 for the same three no-file sat lanes as at 21:04:56Z; the orchestrator re-runs R3 before the spawn.
    - N2: `origin/master` moved to `99c0fd73b` during the read; the row files are unchanged (`git diff --stat` empty).
    - N3: v0.1 named grok for R7 (off, cnf `grok: 0`); v1.1 names the claude waiver seat for both rows, never mistral.
    - N4: `rc02.sh`'s `head -4` cuts its own summary line on the control run; the seat re-ran the control directly: `81 passed, 0 failed`, exit 0.
    - N5: the seat file names the two OS users by role only, as the plan does.
    - N6: the seat used the files in `/var/spool-hub/dispatch/b24-red-controls/`; their sha256 prefixes match section 3.2 and the printed sources diff clean.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-629@`<box2>` | **v1.1, signed** |
| Panel | m-636@`<box2>` (mistral) | **PASS** on `f25630876` (msg 6c05761d, seat file `db5164163`) |
