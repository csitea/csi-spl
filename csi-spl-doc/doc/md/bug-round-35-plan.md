# Bug-fix round 35 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6185 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 #spool-hub-bugs `eed1b396-0f6f-4474-91b9-66c3ec80a44f` ("Bug round 35", opener msg 7580a52e, opened by c-002@sat 11:55Z). Round 34 ([bug-round-34-plan.md](bug-round-34-plan.md)) is **open**: plan v1.0 and its panel signature are on master (`4cd8415f0`), rows b34-01 (c-809@sat) and b34-02 (c-811@sat) are building, and neither row is on origin/master at this plan's fetch. This round does not wait for it and stays off its row files (its section 3.1).  
Round focus: an iac/orc gate defect that let two lanes in one day turn trunk red. A push that changes only a terraform file of step 030 does not run the orc test that guards that step, so the pre-push gate passes and wf 10 goes red on the push.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2; bugs are priority 2. One row is a round (rulebook 5.2). Sections 4 and 5 account for every other input.  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-34-plan.md](bug-round-34-plan.md) (same shape, same 5 sources).

**Status: v0.1, for the panel.**

Editor: **c-838@sat** (claude, `specs_and_docs`; agy, the kind's main, is out on its limit until 11-24).  
Panel: the mistral seat queued with this planner (ask `c002-bug-round-35-mistral-panel-seat`, queue position 1 at 12:41Z). Row 01 has no WUI file (iac and orc bash), so a mistral seat may sit on the plan (developer guide 5.1); it writes no row code.

**One sha:** every count below is measured on **`e1ee705d8`** (`origin/master` at this seat's fetch, 12:39Z), on sat, between 12:34Z and 12:45Z on 2026-11-21, unless a row says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b34-plan')` -> `Window: W=2026-11-21T13:53:55+02:00` (commit `4cd8415f0`), the value the brief quotes.

`<box2>` is the fleet's box that is not sat, as in rounds 21 to 34. `<PUSH_USER>` is the OS user that owns the checkouts and pushes. The public repo names neither.

---

## 1. How to read this

- Round 34 measured on `31a976ffb`. This plan reads round 34's first inputs for round 35 (its section 7), the R7 notes of b34-01 and b34-02 (none exist yet, section 4), the holder's candidates file and the CI report. For each it says why it is or is not a row (sections 4 and 5).
- **Paths** are repo-relative. Line numbers are as of `e1ee705d8`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.

---

## 2. Where the rows come from (measured on `e1ee705d8`)

| source | command | count (n) | result |
|---|---|---|---|
| **1. Owner, member and lane reports since round 34** | the brief's inputs; the spool task `dispatch-bug-r34` read whole at 12:36Z | no owner word; no new lane report of a bug | **0 rows.** |
| **2. CI signatures** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (12:34:45Z..12:37:50Z) | wf 10: 100 runs (2026-11-20T22:13Z..2026-11-21T12:13Z): 52 success, 40 cancelled, 7 failure, 1 running. First red per job: `orc: hermetic action tests 4/4` x2 (`FAIL: dev: resources not covered: google_service_account_iam_member.hub_self_sign`, 44898746533 on `54dcbdae`, 44900133927 and 44900581542 on `6aee259c`, 11:21Z..11:45Z); `orc: hermetic action tests 2/4` x2 (`... google_project_iam_member.hub_cloudtranslate_user`, 44861302816 on `ad950c0e`, 44862245559 and 44862745983 on `75da57eb`, 03:28Z..03:45Z); `wui: browser e2e 6/8` x1 (`workspace-doc-preamble.test.mjs`, 44832401773, 2026-11-20 22:51Z, the run rounds 32 to 34 counted). Last green of both orc jobs: 44901326455 on `4cd8415f`, 11:54Z. Every job's p90 is under 75 % of its timeout (the highest, hermetic 1/4, 57 %) | **Row 01.** Each orc red is fixed and green since (`4a1c86baa`, SPL-6132; `c7c2247b6`, SPL-6152), so neither red has an open owner. The defect is that the same red came twice in one day from a step-030 terraform change that passed the pre-push gate (section 3). |
| **3. Skipped or disabled tests** | `git diff 31a976ffb e1ee705d8 -G '(t\.Skip\|test\.skip\|\.skip\(\|ci-skip\.txt)' --stat` | not run in v0.1 | **Unchecked**; the panel may run it, v1.0 records it. |
| **4. The R7 notes of round 34** | the spool task `dispatch-bug-r34`, read at 12:36Z | 0 R7 lines on b34-01 or b34-02 (reviewer seat for b34-02 queued at 12:09Z; none seen for b34-01 from sat) | **0 rows**: no note exists yet. They feed round 36. |
| **5. Round 34's first inputs, the holder's candidates** | round 34 section 7 (14 inputs); the candidates file (`/var/spool-hub/dispatch/c002-next-round-candidates.md`, 110 lines at 12:43Z) | 14 + the file's 4 entries after round 34's read (SPL-6174 and later) | **0 rows**: sections 4 and 5. |

---

## 3. The rows

| # | defect | evidence | sites file:line | red control (fails on `e1ee705d8`) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|
| 01 `fix(b35-01-iac-tf-step-selects-orc-test)` | **A push that changes only a terraform file of step 030 passes the pre-push gate but turns wf 10 red: the gate never runs `tf-030-import-existing-cloud-run.tst.sh`, the orc test that requires every step-030 resource to be covered by the importer.** The test reads `csi-spl-iac/src/terraform/030-cloud-run-hub` (`tf-030-import-existing-cloud-run.tst.sh:24-28`) and fails `resources not covered` (`:105`) when the step declares a resource the importer does not map. The pre-push gate selects the orc part only for a path under `csi-spl-orc` (`check-pre-push.func.sh:232`, `_pp_paths orc`); an iac-only push selects `iac` and `lint-tf`. Even with the orc part selected, its map (`changed-tests.sh:117-127`) picks a test for an outside-orc path only when a test names that file's basename (`keys`, `:79-99`), and the test names its step (`STEP=030-cloud-run-hub`, `:26`), never a `.tf` file: the map prints `ignore ... outside csi-spl-orc, no orc test names it` (`:126`). The iac side already has the mirror of this map (`check-pre-push-cross.func.sh`, `_PPX_MAP`: iac tests that read orc files); the orc side has none. | Twice on trunk in 12 hours (source 2): `ad950c0e8` (SPL-6132, `feat(iac)`, adds `google_project_iam_member.hub_cloudtranslate_user` to `030-cloud-run-hub/03-runtime-sa.tf`), red in 3 runs until `4a1c86baa`; `4baf28e8f` (SPL-6152, `chore(iac)`, new `030-cloud-run-hub/08-hub-self-sign.tf`), red in 3 runs until `c7c2247b6`. Both fixes say "master red at <sha>" in their subject. **Live exposure:** the queued brief `hand-sat-c001-s123-l3w-translate-env-cnf-030.md` (ask 82ce3159, queue 14/14 at 12:41Z) edits step 030 (its line 21). Re-measured here: rc01 below, RED 3 of 3 on `e1ee705d8`, and RED on each red-making sha's own gate code (`ad950c0e8`, `4baf28e8f`, n=1 each). | `csi-spl-iac/src/bash/run/check-pre-push.func.sh:222-238` (`_pp_paths`, the `orc` row `:232`) and `:1351-1357` (the part selection loop); `csi-spl-orc/src/bash/tests/changed-tests.sh:79-99` (`keys`) and `:117-127` (the outside-orc branch); the tests `csi-spl-iac/src/bash/tests/check-pre-push.tst.sh` and `csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh`; doc `csi-spl-doc/doc/md/pre-push-gate.md`. Read only: `tf-030-import-existing-cloud-run.tst.sh`, `check-pre-push-cross.func.sh` (the iac-side model). | `bash /var/spool-hub/dispatch/b35-red-controls/rc01.sh e1ee705d8` (section 3.2) -> `rc01 part: got=no want=yes` / `rc01 test: got=no want=yes` / `rc01 ctrl: got=yes/yes want=yes/yes` / `rc01 sha=e1ee705d8 src=ad950c0e8 tf=csi-spl-iac/src/terraform/030-cloud-run-hub/03-runtime-sa.tf wrong=2`, exit 1, n=3 (12:39Z) | `check-pre-push.func.sh`, `changed-tests.sh`, their two tests and `pre-push-gate.md` only. A push whose change set holds a file under `csi-spl-iac/src/terraform/030-cloud-run-hub/` selects the orc part (`part`), and the orc map then runs `tf-030-import-existing-cloud-run.tst.sh` (`test`); an orc-only change selects both as today (`ctrl`). The lane chooses the shape: a small orc-side map of the orc tests that read iac terraform (the iac part's `_PPX_MAP` is the model), or a key in `keys` for a step dir. Either way it covers the five orc tests that read `csi-spl-iac/src/terraform` today (`git grep -l -E 'csi-spl-iac/src/terraform\|/src/terraform/' e1ee705d8 -- csi-spl-orc/src/bash/tests csi-spl-orc/src/bash/features/*/tests` -> `check-fleet-rules-drift.tst.sh`, `check-hub-image-regress.tst.sh`, `tf-030-import-existing-cloud-run.tst.sh`, `tf-import-existing.tst.sh`, `tf-plan-ref.tst.sh`), or says per test why it needs no row. No other part's selection changes, and the iac part still runs. The fast tier's time for an iac-only push grows by those tests only: measure it (n>=3) and write it in the commit body. Rulebook R9 applies (this row changes a gate): `PRE_PUSH_TIER=full`, and once with every `PRE_PUSH_*` unset. The suite: rc01's three cases as cases of the two tests, `part` and `test` red on `e1ee705d8`. Commit body: rc01 on the fix -> exit 0, on `e1ee705d8` -> exit 1. Docs: `pre-push-gate.md` says which iac paths select the orc part. | sat or `<box2>` (no pin) | claude | claude waiver seat, fresh session, tree only, unless `do_spl_box_pick` picks grok when the row is queued | `simple_coding` | 1 |

### 3.1 Files (R1) and batches

- **Batch 1:** row 01 alone.
- **Test column (R2), row 01:** `git grep -l -E 'changed-tests\.sh' e1ee705d8 -- '*.tst.sh' '*/tests/*.sh'` -> `csi-spl-iac/src/bash/tests/check-pre-push-recheck-narrow.tst.sh`, `check-pre-push.tst.sh`, `csi-spl-orc/src/bash/tests/local-hub-e2e.tst.sh`, `od-pool-stub.inc.sh`, `run-all-tests-changed.tst.sh`, `run-all-tests.sh`. `git grep -l -E '_pp_paths\|PRE_PUSH_PLAN' e1ee705d8 -- '*.tst.sh'` -> `check-pre-push-commit-links.tst.sh`, `check-pre-push-lang-review.tst.sh`, `check-pre-push-override.tst.sh`, `check-pre-push-owner-orders.tst.sh`, `check-pre-push-stale-tree.tst.sh`, `check-pre-push-timeout-red-trunk.tst.sh`, `check-pre-push.tst.sh`, `cnf-tenant-host-entry.tst.sh` (all `csi-spl-iac/src/bash/tests`). The scope guard `check-pre-push-scope.tst.sh` (named in `check-pre-push-cross.func.sh`'s header). The five orc tests that read iac terraform (row 01's fix scope). Also `rc01.sh`.
- **Off limits** for the row lane: every live and queued lane's files (below); `tf-030-import-existing-cloud-run.tst.sh` and the step-030 terraform (read only: the queued l3w lane edits step 030); round 34's row files (`spl-spawn-enqueue.func.sh`, `spl-spawn-queue.tst.sh`, the hub store and rdb).
- **How the files were checked (2026-11-21, sat):**
  - 12:41:05Z `lane-map.sh --check csi-spl-iac/src/bash/run/check-pre-push.func.sh,csi-spl-orc/src/bash/tests/changed-tests.sh,csi-spl-iac/src/bash/tests/check-pre-push.tst.sh,csi-spl-orc/src/bash/tests/run-all-tests-changed.tst.sh,csi-spl-doc/doc/md/pre-push-gate.md,csi-spl-doc/doc/md/bug-round-35-plan.md --agent c-838` -> `WARN no live lane lists` them, exit 4: 13 live lanes record no files, all 13 on `<box2>` (c-146, c-461, c-463, c-562, c-579, c-740, c-745, c-749, c-806, c-807, c-812, c-924, c-927). The `<box2>` half is asked of the holder (section 8).
  - 12:41:17Z, sat's worktrees (`git worktree list`, every one): `git diff --name-only origin/master...HEAD` plus the `git status --porcelain` paths, matched against `check-pre-push\.func\.sh\|changed-tests\.sh\|check-pre-push\.tst\.sh\|run-all-tests-changed\.tst\.sh\|pre-push-gate\.md` -> 1 hit, stale: `m-780` (HEAD `dd394eb87`, 11:33Z; m-780 is in `registry.retired.tsv`, not in `registry.tsv`), whose branch carries rewritten copies of commits already on master (SPL-6174, b34-plan, r83-plan), not a change of its own to `pre-push-gate.md`.
  - 12:41Z `sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub ENV=prd ./run -a do_spl_spawn_queue` -> `14 queued, 0 placing`. Each queued brief, `grep -lE 'check-pre-push\.func\|changed-tests\.sh\|check-pre-push\.tst\|run-all-tests-changed\|pre-push-gate\.md\|terraform/030'` -> 1 hit, `hand-sat-c001-s123-l3w-translate-env-cnf-030.md`, on `terraform/030` only (it edits step 030, no row file). The holder's R3 check (rulebook 2.3) reads the queued briefs again when the row is queued.
- **Slug b35 is unused as a round id** (sat, 12:34:49Z, on `24722b498`): `git log origin/master --since="$W" --oneline -E --grep='\(b35-'` -> 0. `git ls-remote origin 'refs/heads/review/b35-*' 'refs/heads/wip/*b35*' 'refs/heads/*-b35-*'` -> nothing. `ls /var/spool-hub/dispatch/briefs \| grep -E 'b35\|bug-round-35'` -> the planner's and the panel seat's briefs and one false match (`c002-b3fb351c-ui-view-rethink.md`: `b35` inside a topic id), 0 row briefs. `git worktree list \| grep -E 'b35-[0-9]{2}\|bug-round-35'` -> this planner's only (`c-838-c002-bug-round-35-planner`). The `<box2>` half is asked of the holder (section 8).

### 3.2 Red control run on `e1ee705d8`

**Row 01** is `/var/spool-hub/dispatch/b35-red-controls/rc01.sh` on sat (3008 B, `sha256sum` first 12 hex `d8e9d1fd6fca`). It is printed below so a seat on `<box2>` can rebuild it. It makes a throwaway `git clone --shared` of the checkout it runs from, checks out the sha, appends one comment line to the step-030 file that the red-making commit changed, commits it there, and asks that tree's own gate which parts it selects (`PRE_PUSH_PLAN=1`: it prints the plan and exits 0, nothing runs) and its own orc map which tests it runs. No network, no push, nothing installed; needs bash and git.

| row | command | output | who |
|---|---|---|---|
| 01 | `bash rc01.sh e1ee705d8`, from a checkout, n=3 (12:39Z; each about 5 s) | RED in 3 of 3, the same output each time: `plan(tf): PRE_PUSH_PLAN mode=fast tier=fast parts=hygiene stale-tree owner-orders commit-links lint-tf lint-trufflehog lint-gitleaks iac` / `rc01 part: got=no want=yes` / `rc01 test: got=no want=yes` / `plan(orc): PRE_PUSH_PLAN mode=fast tier=fast parts=hygiene stale-tree owner-orders commit-links lint-syntax lint-shellcheck lint-trufflehog lint-gitleaks lint-sigpipe orc iac-cross` / `rc01 ctrl: got=yes/yes want=yes/yes` / `rc01 sha=e1ee705d8 src=ad950c0e8 tf=csi-spl-iac/src/terraform/030-cloud-run-hub/03-runtime-sa.tf wrong=2`, exit 1. On the red-making shas' own gate code: `bash rc01.sh ad950c0e8 ad950c0e8` -> `wrong=2` (`03-runtime-sa.tf`), `bash rc01.sh 4baf28e8f 4baf28e8f` -> `wrong=2` (`08-hub-self-sign.tf`), n=1 each. What it shows: a step-030 change runs `iac` and `lint-tf` but not the orc part, and the orc map would not run the guarding test for it even if asked; an orc-only change to the importer selects both (the control). | editor c-838 |

There is no green half at plan time: the fix has two shapes (row 01), either the lane's. `part` and `test` must turn `yes` and `ctrl` must stay; the RED-then-GREEN proof is the row lane's commit body (C2).

`rc01.sh`, as run:

```bash
#!/usr/bin/env bash
# rc01.sh <sha> [<step-030 sha>]: b35-01 red control. On <sha>'s gate code,
# asks the pre-push gate which parts it selects (PRE_PUSH_PLAN=1, nothing is
# run) for a push whose only change is a step-030 terraform file, and asks
# the orc test map (changed-tests.sh) which orc tests that change selects.
# The file is the one <step-030 sha> changed (default ad950c0e8, SPL-6132,
# which turned wf 10 'orc: hermetic action tests 2/4' red on
# tf-030-import-existing-cloud-run.tst.sh); the change is a one-line comment
# appended to it in a throwaway clone (selection reads paths, not content).
#   part : the plan lists the orc part             (RED: it does not)
#   test : the orc map runs tf-030-import-existing-cloud-run.tst.sh
#          for that path                           (RED: it does not)
#   ctrl : an orc-only change (the importer script) selects the orc part
#          and the test (control: holds on every sha)
# A temp clone (git clone --shared), no network, no push, nothing installed.
set -uo pipefail
sha="${1:?usage: rc01.sh <sha> [<step-030 sha>]}"; src="${2:-ad950c0e8}"
full="$(git rev-parse "$sha^{commit}")" || exit 2
srcf="$(git rev-parse "$src^{commit}")" || exit 2
top="$(git rev-parse --show-toplevel)"
T="$(mktemp -d)"; trap 'rm -rf -- "$T"' EXIT
git clone -q --shared --no-checkout "$top" "$T/r" || exit 2
git -C "$T/r" -c advice.detachedHead=false checkout -q "$full" || exit 2
tf="$(git -C "$T/r" diff --name-only "$srcf^" "$srcf" -- csi-spl-iac/src/terraform/030-cloud-run-hub | head -1)"
[[ -n "$tf" ]] || { echo "rc01: $src changes no step-030 file"; exit 2; }
plan() {  # <path to change> -> the selected parts
  git -C "$T/r" checkout -q "$full" -- . && git -C "$T/r" reset -q --hard "$full"
  echo '# rc01' >>"$T/r/$1"
  git -C "$T/r" -c user.name=rc -c user.email=rc@example.com commit -qam rc01 || return 2
  (cd "$T/r/csi-spl-iac" && env -u SPOOL_ROOT PRE_PUSH_PLAN=1 PRE_PUSH_TREE="$T/r" PRE_PUSH_BASE="$full" \
    PRE_PUSH_LOG="$T/pp.log" PRE_PUSH_CACHE="$T/pp.green" PRE_PUSH_PIDFILE="$T/pp.pid" PRE_PUSH_NO_CACHE=1 \
    ./run -a do_check_pre_push 2>&1)
}
map() {  # <path> -> run lines of the orc map
  (cd "$T/r/csi-spl-orc" && env ORC_TEST_BASE="$full" ORC_TEST_FILES="$1" bash src/bash/tests/changed-tests.sh 2>/dev/null)
}
bad=0
chk() { echo "rc01 $1: got=$2 want=$3"; [[ "$2" == "$3" ]] || bad=$((bad + 1)); }
has_orc() { grep 'PRE_PUSH_PLAN' <<<"$1" | grep -qE '[ =]orc( |$)' && echo yes || echo no; }
has_t() { grep -q 'tf-030-import-existing-cloud-run.tst.sh' <<<"$1" && echo yes || echo no; }
P="$(plan "$tf")"; echo "$P" | grep 'PRE_PUSH_PLAN' | sed 's/^/  plan(tf): /'
chk part "$(has_orc "$P")" yes
chk test "$(has_t "$(map "$tf")")" yes
imp=csi-spl-orc/src/bash/scripts/tf-030-import-existing-cloud-run.sh
P2="$(plan "$imp")"; echo "$P2" | grep 'PRE_PUSH_PLAN' | sed 's/^/  plan(orc): /'
chk ctrl "$(has_orc "$P2")/$(has_t "$(map "$imp")")" yes/yes
echo "rc01 sha=${full:0:9} src=${srcf:0:9} tf=$tf wrong=$bad"
(( bad == 0 ))
```

No fix was written in the repo: the change belongs to the row lane, with its own tests.

---

## 4. Round 34's inputs and R7 notes, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| b34-01, b34-02 | `git log origin/master --since="$W" --oneline -E --grep='\(b34-0[12]-'` (12:44Z) | 0 | **Building** (c-809@sat, c-811@sat); not served, not this round's. |
| The R7 notes of b34-01 and b34-02 | `spool tail --task dispatch-bug-r34` (12:36Z) | 0 review lines on either row | **None yet.** They feed round 36. |
| b33-01 N1: the card text never compared | round 34 section 4 | not re-read | **Not a bug on this tree** (round 34). Carried. |
| The done-claim `job` label | sat `/var/csi/csi-spl/done-claim-check/cron.log` (47010 lines, 12:37Z): `grep -ciE 'job [0-9a-f]{7}'` -> 0 | 0 alerts | **Not a row**: the condition did not occur. Carried. |
| The AltGr picker; the blog switcher's Enter | source 1 | no owner word | **No rule it breaks and no owner word.** Carried. |
| `blog.test.mjs:329` alone | not re-run (a WUI e2e needs a bundle and Chrome) | - | **Not a row this round.** Carried. |
| `test-agent-name-shape.sh:89` if seen red | source 2 | not among the report's reds | **Not a row.** |
| The orc/iac suites as the agent OS user, if seen red | no new report since round 34 | - | **Not reproduced.** Carried. |
| `gcp-billing-invoices.tst.sh` `download iframe`; `workspace-doc-preamble.test.mjs` at their 3rd sightings | source 2 | 0, and 1 (the same run 44832401773) in 100 runs | **Not a row**: no new sighting. |
| The `tasks <hex>` / `forward <hex>` / `multicast <hex>` forms | not re-queried | no report | **Not a row.** Carried. |
| b29-01 N1 on `<box2>` | not read here: `<box2>` | no `differs` reported | **Not a row.** Carried. |
| The overlay mount that outlives its `/tmp` worktree | its control needs root | - | **Not a row this round.** Carried. |
| `<box2>`'s 8 dashless `/tmp` trees once b30-02's knob is on | not re-read | - | **Not a row.** Carried. |
| The lease vendor order writer | sat, 12:37Z: `grep -n LEASE_VENDOR_ORDER /var/spool-hub/dispatch/lease.conf` -> `12:LEASE_VENDOR_ORDER=claude,agy,claude2`; mtime 04:35Z | not reverted on sat since | **Not a row.** No writer named. Carried. |
| The topic loop's `!inserted` branch; the card read's hub path | round 34 section 4 | untested | **Test-shaped.** Carried. |
| The trailing-newline briefs (b34-02's exposure) | sat 12:37Z: 26 briefs in `/var/spool-hub/dispatch/briefs` end without a newline (4 `reflection-*` files not readable as the agent user) | 26, as round 34 | **b34-02's**, building. |

---

## 5. The holder's candidates, re-measured; not a row this round

The candidates file has 110 lines (12:43Z); round 34 read it at 101, its panel (N1) at 106 and 110. Every entry up to SPL-6174 keeps round 34's verdict (its section 5). The entries from SPL-6174 on:

| candidate | command | result |
|---|---|---|
| SPL-6174 links t1 topic `3e2c61b1` (c-744, n=1): "the commit-links part cannot see a cross-workspace discussion" | `python3 -c 'import uuid; print(uuid.uuid5(uuid.NAMESPACE_URL, "spool-task:dispatch-c36682ea"))'` -> `3e2c61b1-219e-5811-81a4-4fe82287ca30`: the link is the relay hash of the task `dispatch-c36682ea` (spec 153 3.11), not a discussion. The commit-links answer already flags such a key (`relay_hash_only`, `hub/release_links.go:189-192,244-249`, SPL-5126). The issue's links were **not read**: `spool issue get` needs hub mode, and the hub MCP refused this seat (`from_not_announced`, 12:3xZ). | **Not a row this round**: no red control without the issue's links and the path that wrote them. Asked of the holder (section 8, ask 4); a round 36 input. |
| N4 c-791: the gct check covers only `csi-spl-wui/i18n/locales/*.json`, not blog posts or help pages | the rule's text against `do_spl_lang_review_gct` (not re-read) | a check that does not exist yet | **Feature-shaped**, not a defect of code that exists. |
| `spl-lane-mix.func.sh` and its test still say "agy has the final word"; `workspace-rules.md:34`, spec 176's cite, the wf 10 job name ("new locale text carries its agy language review", seen in the CI report) | text | stale words | **Refactor / doc-shaped.** |
| ro.json: one word for topic and theme | - | needs a language decision | **Not a row**: a language decision first, then an i18n row. |

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes (section 3.1) | their lanes | None lists a row file on sat (lane map 12:41:05Z, worktrees and queue 12:41Z). The `<box2>` half: asked (section 8). |
| The two step-030 reds | SPL-6132 (`4a1c86baa`), SPL-6152 (`c7c2247b6`) | Fixed, green since 11:54Z. Row 01 fixes the gate gap, not the reds. |
| Step 030's terraform | the queued l3w lane (ask 82ce3159) | Row 01 reads it only. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 5 sources (source 3 not run); 100 CI runs (2 orc reds of one shape, 1 e2e sighting); 0 R7 notes of round 34; 14 round 34 inputs; the candidates file's 4 entries from SPL-6174 on; 1 red control (n=3 on `e1ee705d8`, n=1 on each red-making sha); sat's `lease.conf`, the done-claim log and the briefs' trailing newlines |
| first inputs for round 36 | the R7 notes of b34-01 and b34-02; SPL-6174's link to the relay hash `3e2c61b1` once the issue's links and their writer are read; the other parts of the pre-push gate (does any other part's test read files of a part that does not select it? row 01 covers orc tests that read iac terraform only); and every item round 34 carried (section 4) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-838@sat (claude, `specs_and_docs`).
- **Panel:** the mistral seat (ask `c002-bug-round-35-mistral-panel-seat`). Row 01 has no WUI file, so a mistral seat may sit (developer guide 5.1). It reviews the plan only; it writes no row code, and pushes with `PUSH_BRANCH=review/c002-bug-round-35-mistral-seat`.
- **Asked of the holder:**
  1. The `<box2>` half of R3: in each live `<box2>` worktree, `git diff --name-only origin/master...HEAD` plus the `git status --porcelain` paths, matched against `check-pre-push.func.sh`, `changed-tests.sh`, `check-pre-push.tst.sh`, `run-all-tests-changed.tst.sh` and `pre-push-gate.md`.
  2. The `<box2>` half of the slug proof: `ls /var/spool-hub/dispatch/briefs \| grep -E 'b35-[0-9]{2}\|bug-round-35'` and `git worktree list \| grep -cE 'b35-[0-9]{2}\|bug-round-35'`.
  3. Whether a second row from the holder's own list belongs here (aim at 2, rulebook 5.1); none of this plan's sources gave one.
  4. SPL-6174's discussion links (`spool issue get --ref SPL-6174`, hub mode), and which action linked `3e2c61b1`.
- **Row reviewer (R7):** row 01: the claude waiver seat, fresh session, tree only. `cd csi-spl-orc && sudo -u <PUSH_USER> env SPOOL_ROOT=/var/spool-hub BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (12:43:48Z) -> `pick=hold reason=waiting: grok weekly >= 95% or unknown on sat, <box2> [sat unknown (no reading); <box2> unknown (no reading)]: queue the lane, spawn nothing`. No mistral backup: row 01 is `simple_coding`, a coding kind mistral does not take, as main or backup. An absent seat gets a replacement claude waiver seat (rulebook 2.7.3).
- **Review history:**
  - 2026-11-21 12:4xZ: v0.1, pushed to `review/c002-bug-round-35-planner`: one row.

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-838@sat | v0.1 |
| Panel | the mistral seat | asked |
| Holder | c-002@sat | asked |
