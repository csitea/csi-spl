# Bug-fix round 25 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6009 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `e4423a32-ac00-4eee-95c9-3fdd18b06a60` ("Bug round 25", opener msg 618f1116, opened by c-003@sat 02:19:17Z). Round 24 ([bug-round-24-plan.md](bug-round-24-plan.md) v1.1, 2 rows) is closed: b24-01 landed `6fedc5bbb` (SPL-6001), b24-02 landed `d32ff2ed8` + `d5ca55d20` (SPL-6002), plan v1.1 `cb8f0f117`; served dev + prd in `99029842f` (the brief). Bug share: c-001 spawn share 389de28d (bug 8%).  
Round focus: one scheduled-CI flake in an orc test whose negative assertion reads environment-dependent text.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. One input gives a live, unowned defect with a red control that fails on `origin/master`; every other input is accounted for in sections 2, 4 and 5: 1 row (rulebook 5.2: "1 row is a round").  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-24-plan.md](bug-round-24-plan.md) (same shape, same 5 sources).

**Status: v1.0**, for the panel's signature (folds the holder's answer to v0.1; no row changed).  
Editor: **c-184@sat** (claude, `specs_and_docs`).  
Panel: one mistral seat, queued by the dispatch holder c-002@sat (ask 00cb4825, section 8).

**One sha:** every count below is measured on **`82f0e0b0f`** (`origin/master`, committed 2026-11-20T03:18:42+01:00), on sat, between 02:25Z and 02:40Z on 2026-11-20, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b24-plan')` -> `Window: W=2026-11-19T22:43:09+01:00` (commit `cb8f0f117`).

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 24. `<PUSH_USER>` is the OS user that owns the checkouts and pushes (the public repo names none).

---

## 1. How to read this

- Round 24 measured on `17f0d7b00`. This plan re-measures what changed since (`git rev-list --count 17f0d7b00..82f0e0b0f` -> 28 commits), round 24's first inputs for round 25 (its section 7), the brief's new input (the boot-restore flake), and says for each why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `82f0e0b0f`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `82f0e0b0f`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner and member reports since W** | `cd csi-spl-orc && sudo -u <PUSH_USER> env ENV=prd SQL="select tenant_id, count(*), count(*) filter (where body ~* '(bug\|broken\|does not work\|not working\|error\|wrong\|fails\|failed\|crash\|blank\|missing\|stuck\|regress\|leak)' and body not like '[spool-probe]%'), count(*) filter (where body like '[spool-probe]%') from messages where ts > '2026-11-19T21:43:09Z' and from_id like 'HUM%' group by 1" ./run -a do_spl_db_query` (02:32Z) | t1 4 (0 hits, 0 `[spool-probe]`), csitea 2 (0 hits) | **0 rows** from new reports. |
| **2. CI signatures** | `cd csi-spl-iac && sudo -u <PUSH_USER> env CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (02:28Z, done 02:3xZ) | 100 runs, 16 failed; every job's last green is 44655865817 / 44655802340 on `99029842` (01:44Z) | **1 row.** One failed run after W: 44655865817 (01:44Z, `99029842`, `orc: feature tests`, `FAIL - 3. ... a shell that only mentions vibe is not (unexpected '4245')`): row 01. Every other failed run is older than round 24's read: the newest, 44570765247 (16:51Z, `ee958d2b`), is round 24's `gcp-billing-invoices` n=1; the `4j Shift+O` (16:44Z) is fixed by `31b731d7b`; the 9 + 9 `wui 2/8` / `7/8` lines (11:14Z..13:56Z) are before round 23's read and green since. |
| **3. Skipped or disabled tests** | `git diff 17f0d7b00 82f0e0b0f -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | 1 file: `internal/hub/repo_sync_test.go` (+289, new) | **0 rows.** Its one skip is `t.Skip("memory store only")` in a new test of `fac04b413` (SPL-5808, c-046@sat's live lane): a driver guard, not a disabled test. |
| **4. Box cron logs** | sat: `/var/csi/csi-spl/done-claim-check/cron.log`, rows since W (from line 44748, 55 runs): `awk 'NR>=44748 && /\talert\t/'` | 3 alert rows | **0 rows.** No `job <hex>` token alerts (section 4): two rows (c-946, one result twice) name `75e18c60e654`, a real commit on `origin/review/c-946-spl-5963`, not on master (`git merge-base --is-ancestor` -> no); one (c-046) is `no-sha`. The check alerts on both by its rules. `<box2>`'s logs: not read from sat. |
| **5. Round 24's first inputs, the brief's new input** | round 24 section 7; the brief (c-001@sat 184f240a, routing c-638's 2475e21a) | 5 inputs | **1 row**: 01 from the boot-restore flake (the same as source 2). The other 4: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `82f0e0b0f`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b25-01-orc-boot-restore-test-pid-needle)` | Case 3 of `test-agent-boot-restore.sh` proves that a shell is NOT flagged by searching the action's WHOLE output for a bare pid: `hasnt "4243" "$out"` (`:97`) and `hasnt "4245" "$out"` (`:101`). That output also carries text that changes per run: the box and agent user names `boxu-$$` / `agentu-$$` (`:28`, the test shell's pid), the sandbox's mktemp paths (`restore: tmux socket <T_TMP>/tmux.sock`, the `boot-FAILED` marker path) and the restored agent's pid (`SKIP    CLE-61: already running (pid <n>)`). When any of them holds the 4 digits, the test fails with nothing wrong in the code. What a wrongly flagged shell would print is an ALERT line, `ALERT   runs as <box user>, not <agent user>: 4245 bash -c vibe-notes` (`csi-spl-orc/src/bash/run/spl-agent-boot-restore.func.sh:72`); the needle should be that line, not the bare number. | Scheduled run 44655865817 on `99029842f`, job 136021944607 (orc feature tests): `FAIL - 3. ... a shell that only mentions vibe is not (unexpected '4245')`, `-- test-agent-boot-restore.sh: 36 passed, 1 failed` (lines 504 and 528 of `gh api repos/csitea/csi-spl/actions/jobs/136021944607/logs`). 1 failed of the last 8 scheduled runs (`gh run list --workflow 10_ci-quality.yml --event schedule -L 12`: 18:45Z..01:44Z, the other 7 `success`; the push run of the same sha passed, the brief). The test is unchanged since `4c1304bcb` (`git log --oneline -1 -- <test>`). Which text held `4245` in CI is not in the log (the test prints only the needle); the sandbox there was `tmp.lnipS02eZX` (log line 513), which does not hold it, so a pid is the likely source: inferred, not read. On sat, the output case 3 searches (one run, printed from a copy): `boot-restore: box user boxu-174344, agent user agentu-174344` / `restore: tmux socket /tmp/tmp.vOoo31TmIZ/tmux.sock, ...` / `SKIP    CLE-61: already running (pid 176374)` / `ALERT   runs as boxu-174344, not agentu-174344: 4244 Vibe CLI` / `FAILED ... marker: /tmp/tmp.vOoo31TmIZ/spool/agents/boot-FAILED`. | `csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh:97` and `:101` (the two needles); read only: `:28` (`BX`, `AG`), `:93` and `:98` (the fake `ps` lines), `csi-spl-orc/src/bash/run/spl-agent-boot-restore.func.sh:66-74` (the ALERT form), `spawn-agents/tests/lib.inc.sh:30-32` (`hasnt`, a substring match) | `bash /var/spool-hub/dispatch/b25-red-controls/rc01.sh 82f0e0b0f 4245` (section 3.2), run from a checkout as `<PUSH_USER>`: the test on a `git archive` copy with `TMPDIR` a fresh mktemp dir named `...-4245`, so the sandbox paths hold the digits -> `FAIL - 3. ... a shell that only mentions vibe is not (unexpected '4245')` / `-- test-agent-boot-restore.sh: 36 passed, 1 failed` / `rc01 sha=82f0e0b0f tag=4245 rc=1`, exit 1, n=3 of 3: the CI failure line, word for word. Tag `4243` fails `:97` the same way (`FAIL - 3. ... a plain shell is not (unexpected '4243')`, n=1). Control: tag `ctl` -> `37 passed, 0 failed`, `rc=0`, exit 0 (02:28Z). | The two needles name the ALERT line of that pid, e.g. `hasnt "..." "not $AG: 4243" "$out"` and `"not $AG: 4245"`, so only an ALERT for that pid fails them. Test file only; no change to the action or to `hasnt`. The lane's commit body carries: rc01 with tags `4245` and `4243` on its fix -> PASS (the flake is gone), and a red control that the fixed needles still catch the defect they guard: on a copy whose ALERT filter also takes a shell (e.g. `$2 ~ /vibe/` in the awk of `spl-agent-boot-restore.func.sh:73`), the fixed case 3 fails. `Docs: none (a test's needle; no behaviour changes)`. The third bare-number `hasnt` of the same shape (`test-agent-name-shape.sh:89`, `"900006"`) has no observed failure: out of the row (section 5). | sat or `<box2>` | claude | claude waiver seat (1a7c70da), fresh session, tree only | `tests` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01, one file: `csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh`.
- **Test column (R2):** `git grep -l test-agent-boot-restore 82f0e0b0f -- '*tests*'` -> none but the test itself; `boot-cron-gate.tst.sh` sources the action's install-cron file, not the test, and is unaffected. At least: `test-agent-boot-restore.sh` (37 passed), `rc01.sh` with tags `4245`, `4243` and `ctl`, and the spawn-agents suite's run of it.
- **Off limits** for the row lane: every live lane's files (below); `spl-agent-boot-restore.func.sh` and `lib.inc.sh` (read only).
- **How the files were checked (2026-11-20, sat):**
  - 02:31:44Z `lane-map.sh --check csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh,csi-spl-doc/doc/md/bug-round-25-plan.md --agent c-184` -> `WARN no live lane lists` them; exit 4 for 8 `<box2>` lanes that record no files: c-049, c-060, c-625, c-741, c-812, c-924, c-927 (each `<id>-rotate`, orchestrator rotations) and c-764 (`c-764-c002-r71-02-claude-waiver-reviewer`, a review seat, which commits only its seat file, rulebook 2.7.6).
  - 02:31:50Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `0 queued, 0 placing`.
  - The brief's live lanes: r71-01 landed (`82f0e0b0f`); r71-02 c-182@sat: `git diff --name-only $(git merge-base origin/master FETCH_HEAD) FETCH_HEAD` on `review/r71-02-v2` (02:33Z, tip `af581e009`) -> `prune-docker-images-install-cron.func.sh`, `spl-workspace-docs-purge.func.sh` and their two tests; refactor round 71 names `test-agent-boot-restore.sh` only in its test column (run, not edited: `refactor-round-71-plan.md:145`, `:167`). c-046@sat (spec 143 B-6b.2): `git -C <its worktree> diff --name-only origin/master...HEAD` -> api `cmd/spool/`, `internal/config/`, `internal/github/`, `internal/hub/` files only. c-640@`<box2>` SPL-6000: landed (the brief). None names the row's file.
- **Slug b25 is unused as a round id** (sat, 02:25Z): `git log origin/master --since="$W" --oneline -E --grep='\(b25-'` -> 0; `git ls-remote origin 'refs/heads/review/b25-*' 'refs/heads/wip/*b25*' 'refs/heads/*-b25-*'` -> nothing; `ls /var/spool-hub/dispatch/briefs \| grep -cE 'b25-[0-9]{2}\|bug-round-25'` -> 1, this planner's brief; `git worktree list \| grep -cE 'b25-[0-9]{2}'` -> 0. `<box2>`'s half: asked of the holder (section 8).

  After this plan's pushes, `--grep='(b25-'` matches the plan's commits (`docs(b25-plan, ...)`) and `ls-remote` the planner's review branch. The row form `--grep='\(b25-[0-9]{2}'` stays 0 until a row lands.

### 3.2 Red control run on `82f0e0b0f`

The file is on sat in `/var/spool-hub/dispatch/b25-red-controls/`: `rc01.sh` (977 B, `sha256sum` first 12 hex `4df52c39d3b7`). It is printed below, so a seat on `<box2>` can rebuild it.

| row | command | output on `82f0e0b0f` | who |
|---|---|---|---|
| 01 | `bash rc01.sh 82f0e0b0f 4245` (n=3), `bash rc01.sh 82f0e0b0f 4243` (n=1); control `bash rc01.sh 82f0e0b0f ctl` (n=1), each from a checkout as `<PUSH_USER>` | RED, 3 of 3: `FAIL - 3. ... a shell that only mentions vibe is not (unexpected '4245')` / `-- test-agent-boot-restore.sh: 36 passed, 1 failed` / `rc01 sha=82f0e0b0f tag=4245 rc=1`, exit 1. Tag 4243: `FAIL - 3. ... a plain shell is not (unexpected '4243')`, `36 passed, 1 failed`, exit 1. Control: `-- test-agent-boot-restore.sh: 37 passed, 0 failed` / `rc01 sha=82f0e0b0f tag=ctl rc=0`, exit 0 (02:28:34Z). | editor c-184 |

No prototype fix was written: the needle change is the row lane's, with its own red control (the fixed needles still fail on a copy that flags a shell).

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha> [tag]: b25-01 red control. A git archive of <sha>'s csi-spl-orc
# and csi-spl-api, then test-agent-boot-restore.sh run with TMPDIR set to a
# fresh mktemp dir whose name ends in -<tag> (default 4245). The test's own
# mktemp sandbox, and every path it prints, then holds the tag. With tag 4245
# case 3's `hasnt "4245" "$out"` finds it in env-dependent text (the tmux
# socket path), not in an ALERT for pid 4245. Control: tag ctl.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha> [tag]}"; tag="${2:-4245}"
C="$(mktemp -d)"; P="$(mktemp -d --suffix="-$tag")"
trap '[ -n "$C" ] && rm -rf -- "$C"; [ -n "$P" ] && rm -rf -- "$P"' EXIT
git archive "$sha" csi-spl-orc csi-spl-api | tar -x -C "$C"
out="$(cd / && TMPDIR="$P" timeout 300 bash "$C/csi-spl-orc/src/bash/features/spawn-agents/tests/test-agent-boot-restore.sh" 2>&1)"; rc=$?
grep -E '^FAIL|passed,' <<<"$out" | sed "s#$P#<tmpdir>#g"
echo "rc01 sha=$sha tag=$tag rc=$rc"
[[ $rc -eq 0 ]]
```

---

## 4. Round 24's inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b24-01, b24-02 | `git log origin/master --oneline -E --grep='\(b24-0[12]-'` | landed `6fedc5bbb` (b24-01), `d32ff2ed8` + `d5ca55d20` (b24-02) | Served (round 24 closed, the brief). |
| b24-01's leftover 1: `FlowFanout`'s counts are not cut per box | `6fedc5bbb`'s body; `grep -n 'flowCutCounts\|FlowFanout' csi-spl-api/src/go/spool-hub-api/internal/hub/flow.go` | `:267` `fe.FlowFanout(...)`, then `:277` `s.flowCutCounts(ctx, fe, row.TenantID, member, locks, &p)` for a member a lock hides a box from; `:285-286` "flowCutCounts replaces p's counts with member's counts cut by the boxes locks hide from them: FlowFanout's counts are not cut per box" | **Served in b24-01**: the fan-out keeps `FlowFanout` and re-reads the counts cut for each member a lock hides a box from (a lock read error sends nothing). c-644's report names no leftover (the brief: `grep -ciE 'FlowFanout\|flow_read'` -> 0). |
| b24-01's leftover 2: the agent `flow_read` frame reads no lock | `csi-spl-api/src/go/spool-hub-api/internal/hub/flow_agent.go:20-61`; `hub/box_lock_view.go:133-145` (`lockViewFor(ctx, tenant, hum)`: a lock hides a box from a HUMAN who is not its owner, `l.IsOwner(hum)`); spec 130 `:174-181` | the frame reads the agent's own folded Flow (`q.Member = <id>@<box>`); b24-01 left it unchanged by design (its body: "the agent flow_read frame (hub/flow_agent.go) is unchanged") | **Not a bug on the record**: the box owner lock is a rule between people (spec 130: the lock is "the reader's", a member's); no spec line or owner message says an agent's own Flow is cut by a person's lock. If the owner wants that, it is a feature ask. |
| The done-claim `job` label (round 24 section 5: a row if a `job <hex>` token alone alerts again) | source 4 (section 2) | 0 `job` alerts since W: 3 alert rows, a real review-branch sha (2) and `no-sha` (1) | **Not a row**: the condition did not occur (n=0 since W, 55 runs, sat's log). Stays an input on the same condition. |

---

## 5. Not a row this round, or no red control yet

| candidate | command | result |
|---|---|---|
| **SPL-5850 N1: an AltGr letter may pick a kind** (`csi-spl-wui/src/utils/kind-picker-keys.ts`; c-264 8352e059) | read: `kindForKey` returns '' for any `ctrlKey` / `altKey` (`:58`; Windows reports AltGr as both); else `letterOf` takes `ev.key` A-Z or the physical `KeyX` of `ev.code` (`:45-50`), on purpose, so a Cyrillic `т` on KeyT picks (SPL-5836 R7 W1). By that reading, a Linux AltGr `ń` on KeyN (no `altKey`) picks `note`. Not run: node 20 on sat has no TypeScript strip, and no browser was driven. | **No red control, and no rule it breaks.** The fallback to the physical key is the design for non-Latin layouts; whether an AltGr letter should be the exception is a design question, not a demonstrated defect. Carried as an input; a row needs a spec line or an owner word that it must not pick. |
| **`blog.test.mjs:329` fails when run alone** (SPL-5960 R7 c-395 N3, c-002 msg 577d03b7: 3/3 alone on `67232dbc8`) | not re-run on `82f0e0b0f`: it needs a generated bundle and Chrome, and this worktree has no `node_modules` (the brief: install nothing) | **No red control on this sha.** An order-dependent e2e, green in CI (which runs the suite): a test-isolation defect, no product behaviour. Next bug round's input with a `BASE_URL=<bundle> node --test --test-name-pattern 'picking bg' tests/e2e/blog.test.mjs` run on its sha, on a box with the wui deps. |
| **Rows A and B of the reflection** (Qto 71e1dbd3, SPL-5992) | as round 24 section 5 | **Not bugs: detectors** (round 24's reason holds; the brief). |
| **`fallback_postgres.go:83-86` probes uncovered** (r34-01 R7 c-321 N1/N2) | as round 24 section 5 | **A test-coverage gap, not a bug row** (the brief). |
| **`test-agent-name-shape.sh:89`, `hasnt ... "900006"`**, the same shape as row 01 | `git grep -nE "hasnt [\"'][^\"']*[\"'] [\"'][0-9]{3,6}[\"']" -- 'csi-spl-orc/**' 'csi-spl-iac/**' 'csi-spl-utl/**'` -> 3 lines: row 01's two and this one; not run with a planted value | **No observed failure** (n=0 in the 100 runs): six digits in a 10-character mktemp name or a pid are far rarer than four. A row only once it is seen red. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes of the brief and the queue (section 3.1) | their lanes | None lists the row's file (lane map 02:31:44Z, queue 02:31:50Z, r71-02 and c-046 diffs 02:33Z). The orchestrator re-runs R3 before the spawn. |
| `repo_sync_test.go`'s memory-only skip | c-046@sat (spec 143 B-6b.2) | A driver guard in its own lane's test; not a bug input. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 5 sources; 9 named inputs (round 24's section 7 and 5 inputs, the brief's flake, the 3rd bare-number needle); 6 human posts counted (0 hits); 100 CI runs; 12 scheduled runs listed; 1 cron log (55 runs); 1 red control, 5 runs |
| first inputs for round 26 | the done-claim `job` label if it alerts alone; the AltGr picker if a rule or the owner says it must not pick; the `blog.test.mjs:329` alone-run on a box with the wui deps; `test-agent-name-shape.sh:89` if seen red |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-184@sat (claude, `specs_and_docs`).
- **Panel:** one mistral seat on sat (ask 00cb4825, slug `c002-bug-round-25-mistral-panel-seat`), queued by the holder c-002@sat (msg 9f30fbdb); grok is held and sat has no agy cli, so one non-claude seat. The panel checks the red control (rebuild `rc01.sh` from section 3.2; it needs bash, git and tmux only), the fix scope (the needles name the ALERT line; the action and `hasnt` are unchanged; the lane proves the fixed needles still fail on a copy that flags a shell), and that every other input in sections 2, 4 and 5 is measured as written.
- **Asked of the holder with v0.1, answered** (msg 9f30fbdb): the panel seat (above); `<box2>`'s half of the slug check is asked of the orchestrator there, its outputs to follow (section 3.1; a non-zero count there holds the row's spawn, not the plan).
- **Row reviewer (R7):** claude waiver seat (1a7c70da), fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (02:32:41Z) -> `pick=hold reason=waiting: grok weekly >= 95% on sat, `<box2>` [sat 99% ...; `<box2>` 99% ...]`. Mistral reviews plans, not row code (c-001 ruling b71016ad), sat has no agy: the holder names this same-vendor review a waiver.
- **Review history:**
  - 2026-11-20 02:37Z: the editor pushed v0.1 (`fd658a9db`) to `review/c002-bug-round-25-planner` and asked the holder for a panel (msg 7dcca26d).
  - 02:4xZ: the holder answered (msg 9f30fbdb): the mistral panel seat queued (ask 00cb4825), `<box2>`'s slug check asked there. v1.0 folds it; no row changed.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-184@sat | **v1.0** |
| Panel | mistral seat, ask 00cb4825 (queued) | pending |
