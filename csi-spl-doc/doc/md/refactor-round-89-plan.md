# Refactoring round 89 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6259  
Topic: 5dd2fc41-f492-41c9-8e1a-5dc252873f26  
Discussion: 5dd2fc41-f492-41c9-8e1a-5dc252873f26 (t1 #refactoring, "Refactor round 89", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r89**, plan `refactor-round-89-plan.md`, rows `r89-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 88 ([refactor-round-88-plan.md](refactor-round-88-plan.md))
is closed: both rows landed (r88-01 `90522d802`, r88-02 `e2dea23a9`; close record
`14d41508b`). The perf floor (rulebook 4.4), measured by the holder on `a42b13034`: perf
29, refactor 109, 5 x 29 = 145 >= 138, floor met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4): a function body that
exists twice under two names loses its second copy, and its callers use the first.
**Row 01** serves r88 section 7's "a later row may": the spool-install steps' own copy of
Claude Code's project slug rule (`spool_install_memory_slug`) goes, and its two callers
use r88-01's `spl_claude_project_slug`. **Row 02**: `do_spl_issue_stale_sweep` keeps a
private copy of the `lease.conf` key reader that 5 other actions already take from
`spl-owner-digest-post.func.sh`; the copy goes. The rows share no file: both are batch 1.

**Status: v0.1, for the panel.** Editor: **c-285** (claude).

**One sha:** every count is measured on **`94e5690a2`** (`origin/master` at
2026-11-22T14:47Z), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. The tests of 1.5 were run in three detached scratch worktrees
of that sha (not committed, removed after v0.1): "base" unmodified, "head1" = base with
row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's shape. Each
red control puts only the head's test file into base. Queue, lane map, brief and branch
reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-22T15:03Z, n=1, after `git fetch --prune origin`:

- **Window: W=2026-11-22T16:32:03+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r88-plan'`: `14d41508b`, the
  r88 close record (as the brief says).
- `git log origin/master --since="$W" --oneline -E --grep='\(r89-'` -> **0**; over all
  history -> **0**.
- `git ls-remote origin 'refs/heads/review/r89-*' 'refs/heads/*-r89-*' 'refs/heads/*refactor-round-89*' 'refs/heads/wip/*r89*'`
  -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r89|refactor-round-89'` -> this plan's
  brief and the panel seat's (`c002-refactor-round-89-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-89`
  -> 0: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) r88 section 7:**
  - `spool-install/steps/claude-memory.inc.sh:9` (`spool_install_memory_slug`): still
    there; **row 01** (1.3). r88's reason ("adds a spool-install -> orc lib source
    edge") re-read: `install.sh:194` already sets `ORC="$(cd "$_here/../../../.." && pwd)"`
    and runs orc code from it (`:1100` `y1_mcp_bot "$ORC/src/bash/features/mcp-bot"`), and
    the satellite playbook runs `install.sh` from the repo checkout
    (`060-gcp-vm-satellite/roles/08_spool_harness/tasks/main.yml:108`, `:136`), so the
    orc tree is always beside the steps.
  - The slug rule over the orc / iac / utl / root `src` trees, tests left out
    (`git grep -nE "s/\[\^A-Za-z0-9\]/-/g|\[\^(A-Za-z0-9|a-zA-Z0-9)\]/-"`) -> 7 lines:
    the helper (`lib/bash/funcs/spl-claude-project-slug.func.sh:10`), `claude-memory.inc.sh:9`,
    `spl-dispatch-lease.func.sh:2385` (section 7), and 4 parameter-expansion forms
    (section 7: they differ from the helper on a path with a newline).
  - Every other r88 section 7 item stays out for its reason there (section 7).
- **(b) R7 and panel notes:** r88-01 (g-468) and r88-02 (g-261) R7 lines carry no N note
  (`git log -1 --format=%B 90522d802`, `e2dea23a9`); the r88 panel's N1-N5
  (`refactor-round-88/seat-mistral.md:206-222`) name process points, no row.
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  114 lines, read 14:5xZ), its refactor-shaped items:
  - `reverse-tunnel-cron.sh`, `LOGIN_STATE_DIR`, the agent-boot-restore dir, the
    `spl-desk-reply.sh` kinds: served (r88 1.2 (c)); unchanged.
  - `10_ci-quality.yml:444-445` comment (p18-02 N1): served (`:445-446` now say "only
    about 96 MB of it is left").
  - `spl-uplink-probe.func.sh:14-15` (SPL-5828 N1): served (`:14-18` now name the rc 1
    config fault).
  - `spl-lane-mix.func.sh` agy words (`:46`, `:136-138`, `:392-402`): SPL-6174 has landed
    (`4d95cd4c3`), but the words are the action's output and flag (`needs_agy_review`),
    asserted by its test, and the fleet rule text still names agy: behaviour and a rule
    decision, not a refactor (section 7).
  - the e2e selector `_ppe_keys`, the `!inserted` loop-fire test: a gate-design item and
    a test row, not this round's.
- **(d) spec 011 tasks:** `git log origin/master --since="$W" --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks are those of r88
  section 7.
- **(e) A body scan for further copies** (this plan's own input): every top-level bash
  function of the orc / iac / utl `src/bash` and `lib` trees (tests and `run.sh` left
  out), bodies of 3+ non-comment lines compared whitespace-normalised: 10 sets of equal
  bodies under different names in different files. One is **row 02** (1.4); the other 9
  stay out for their reasons (section 7).

### 1.3 Row 01's sites: the spool-install slug copy goes

`orc:` = `csi-spl-orc/`, `steps/` = `orc:src/bash/features/spool-install/steps/`. On
`94e5690a2`:

- `steps/claude-memory.inc.sh:8-9`: the comment and
  `spool_install_memory_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }`; the
  header `:3-5` calls the file "the claude memory repo and its project slug, the one
  copy".
- Its callers: `steps/y18-grok-memory.sh:57` and `steps/y20-agy-memory.sh:254`
  (`memdir="$home/.claude/projects/$(spool_install_memory_slug "$repo")/memory"`).
  `git grep -n spool_install_memory_slug` -> those 3 lines and two plan docs (r87, r88)
  only.
- The helper: `orc:lib/bash/funcs/spl-claude-project-slug.func.sh:10`,
  `spl_claude_project_slug() { printf '%s' "$1" | sed 's/[^A-Za-z0-9]/-/g'; }`. **The two
  bodies are byte-identical** (the text after `()` compared, n=1).
- Who loads the inc: Y18 (`:28`) and Y20 (`:52`) source it from their own dir; the
  steps are sourced by `install.sh` and by their tests
  (`spool-install/tests/test-y18-grok-memory.sh`, `test-y20-agy-memory.sh`, run also
  through the orc wrappers `spool-install-y18-grok-memory.tst.sh`,
  `spool-install-y20-agy-memory.tst.sh`). Nothing preloads `lib/bash/funcs` there, so the
  inc loads the helper itself, with r88-01's guard.

Shape (built as head1 of 1.5):
- `claude-memory.inc.sh`: the header says the file holds the memory repo, the one copy,
  and loads the slug helper; `:8-9` become the comment
  `# The claude project slug of an absolute path (/opt/x/y-z -> -opt-x-y-z):` /
  `# spl_claude_project_slug, the orc's one copy (r88-01).` and
  `declare -F spl_claude_project_slug >/dev/null || . "$(dirname "${BASH_SOURCE[0]}")/../../../../../lib/bash/funcs/spl-claude-project-slug.func.sh"`.
  20 -> 21 lines.
- `y18-grok-memory.sh:57`, `y20-agy-memory.sh:254`: `spool_install_memory_slug` ->
  `spl_claude_project_slug`. Line counts unchanged.
- `orc:src/bash/tests/spl-claude-project-slug.tst.sh` (r88's test) gains case 4: the
  files of `steps/` spell no copy (`grep -lF 's/[^A-Za-z0-9]/-/g'` -> none), and
  `claude-memory.inc.sh` sourced alone maps `/srv/acme/acme-app-wt/c-170` to
  `-srv-acme-acme-app-wt-c-170`. 43 -> 52 lines.
- Not edited: `test-y18-grok-memory.sh` case 9 (`grep -lE 'git-common-dir|s/...'` over the
  steps still finds `claude-memory.inc.sh` alone, by its `git-common-dir`).

**Behaviour:** the deleted body equals the helper's byte for byte, so every slug Y18 and
Y20 compute is the same; the row's column (1.5) is equal on base and head1.

### 1.4 Row 02's site: the stale sweep's lease.conf reader

On `94e5690a2`:

- `orc:src/bash/run/spl-issue-stale-sweep.func.sh:71-75`: `spl_stale_lease_conf`
  (`local v`; `v="$(sed -n "s/^$2=//p" "$1/dispatch/lease.conf" 2>/dev/null | tail -1)"`;
  `echo "${v:-$3}"`), called at `:54-55` (`LEASE_ENV`, `LEASE_TENANT`).
- `orc:src/bash/run/spl-owner-digest-post.func.sh:161-166`:
  `# spl_owner_digest_lease_conf <root> <key> <default>: a value of lease.conf.` and the
  same 4-line body. **Byte-identical** (`sed -n 72,75p` vs `sed -n 163,166p`, n=1). It
  is already the reader of 5 actions: owner digest `:52-53`, `spl-reflection-gather.func.sh:88-89`,
  `spl-topic-archive-suggest.func.sh:84-85,89,138`, `spl-topic-prio-sync.func.sh:49-50`,
  `spl-zombie-topics.func.sh:65-66,291` (`git grep -n spl_owner_digest_lease_conf`).
- `git grep -n spl_stale_lease_conf` -> the 3 lines above only.
- Who loads the sweep: `./run` (the lazy loader finds a function by name) and its test
  `spl-issue-stale-sweep.tst.sh`, which sources the file ALONE (`:74`,
  `source "$FUNC"`) with its seams stubbed after it; the test's `lease.conf`
  (`:35`, `LEASE_ENV=dev`, `LEASE_TENANT=t1`) is what case 1's writes carry. So the sweep
  loads the owner digest file itself, with the guard two of the five callers already use
  (`spl-topic-prio-sync.func.sh:36-37`, `spl-zombie-topics.func.sh:54-55`), placed
  inside the action as r88-01 did, so the file gains no top-level code (the lazy loader
  keeps it lazy; `run-eager-files.tst.sh`). `spl-owner-digest-post.func.sh` defines only
  `do_spl_owner_digest_post`, `spl_owner_digest_{run,render,box,lease_conf}`: none of the
  stale test's seams (`:72-80`), so the load replaces no stub.

Shape (built as head2 of 1.5):
- `spl-issue-stale-sweep.func.sh`: after `:53` the line
  `declare -F spl_owner_digest_lease_conf >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-owner-digest-post.func.sh"`;
  `:54-55` call `spl_owner_digest_lease_conf`; `:71-75` and the blank line after go.
  152 -> 147 lines.
- `orc:src/bash/tests/spl-issue-stale-sweep.tst.sh` gains case 10: the file has no
  `sed -n ... dispatch/lease.conf` line and no `spl_stale_lease_conf()`, and reads
  `LEASE_TENANT` through `spl_owner_digest_lease_conf`; the header lists it. 195 -> 204.

**Behaviour:** the reader the sweep now calls has the deleted body byte for byte; cases
1-9 (whose writes carry `dev` and `t1` from the fixture `lease.conf`) are equal on base
and head2.

### 1.5 Before and on the rows' heads

2026-11-22T15:04:37Z-15:04:52Z, n=1, as the push user, `SPOOL_TEST=1` with
`SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900` each; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "=" means the head
equals base: same rc, pass and fail counts.

| suite | row | base rc / pass / fail | head |
|---|---|---|---|
| `orc:src/bash/tests/spl-claude-project-slug.tst.sh` | 01 | 0 / 4 / 0 | 0 / 6 / 0 (case 4 adds 2) |
| `orc:.../spool-install/tests/test-y18-grok-memory.sh` | 01 | 0 / 13 / 0 | = |
| `orc:.../spool-install/tests/test-y20-agy-memory.sh` | 01 | 0 / 68 / 0 (2 live agy checks not run) | = |
| `orc:.../spool-install/tests/test-agy-rules-always-on.sh` | 01 | 0 / 14 / 0 | = |
| `orc:src/bash/tests/spool-install-y18-grok-memory.tst.sh` | 01 | 0 / 13 / 0 | = |
| `orc:src/bash/tests/spool-install-y20-agy-memory.tst.sh` | 01 | 0 / 68 / 0 | = |
| `orc:src/bash/tests/spl-issue-stale-sweep.tst.sh` | 02 | 0 / 32 / 0 | 0 / 34 / 0 (case 10 adds 2) |
| `orc:src/bash/tests/spl-owner-digest.tst.sh` | 02 | 0 / 45 / 0 | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 02 | 0 / 14 / 0 | = |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 02 | 0 / 15 / 0 | = |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 02 | 0 / 30 / 0 | = |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = (both heads) |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01 | 0 / 15 / 0 | = |

`shellcheck -S warning -x` on each row's files, base and head: rc 0, no findings (n=1
each).

**Red controls** (n=1 each):
- Row 01: head1's `spl-claude-project-slug.tst.sh` on base: rc 1, `2 FAILED`: case 4
  `want no copy in the steps, got 'claude-memory.inc.sh '` and
  `claude-memory.inc.sh sourced alone: ... spl_claude_project_slug: command not found`;
  head1: rc 0, `ALL PASS`.
- Row 01's guard: head1 with the `declare -F` line deleted from `claude-memory.inc.sh`:
  the slug test fails case 4 (`command not found`), and `test-y18-grok-memory.sh` fails
  its dry run, install, late-fact and re-run cases (`y18-grok-memory.sh: line 57:
  spl_claude_project_slug: command not found`).
- Row 02: head2's `spl-issue-stale-sweep.tst.sh` on base: `2 FAILED`: case 10
  `the sweep still reads lease.conf itself: 71:spl_stale_lease_conf() { 73: ...` and
  `LEASE_TENANT is not read through spl_owner_digest_lease_conf`; head2:
  `all passed`, rc 0.
- Row 02's guard: head2 with the `declare -F` line deleted: case 1 fails
  (`spl-issue-stale-sweep.func.sh: line 54: spl_owner_digest_lease_conf: command not
  found`, no write).

The tests that name the sites (R2): `git grep -lE` over the tests for
`claude-memory|y18-grok-memory|y20-agy-memory|spool_install_memory|spl-claude-project-slug|spl_claude_project_slug`
-> the 6 suites of row 01 above (and `orc-shard-weights.txt`, which needs no line: no
new file); for
`spl-issue-stale-sweep|spl_stale_|do_spl_issue_stale_sweep|spl_owner_digest_lease_conf|spl-owner-digest-post`
-> `spl-issue-stale-sweep.tst.sh`, `spl-owner-digest.tst.sh`. Plus the loader and name
gates of the table.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r89-01-orc-install-memory-slug-helper)` | one fact, one copy (developer guide 2.2.4) | the spool-install steps keep their own copy of Claude Code's project slug rule, byte-identical to r88-01's helper (1.3) | `orc:src/bash/features/spool-install/steps/claude-memory.inc.sh:3-5,8-9`<br>`.../steps/y18-grok-memory.sh:57`<br>`.../steps/y20-agy-memory.sh:254`<br>`orc:src/bash/tests/spl-claude-project-slug.tst.sh` (case 4) | function copies of the rule 2 -> 1 | 1.3's shape. **Red control:** the head's test on the parent FAILs case 4 (1.5), then GREEN; outputs in the body. **Behaviour:** equal bodies; the row's column passes on parent and head with the same counts. Tests: `spl-claude-project-slug.tst.sh`, `test-y18-grok-memory.sh`, `test-y20-agy-memory.sh`, `test-agy-rules-always-on.sh`, `spool-install-y18-grok-memory.tst.sh`, `spool-install-y20-agy-memory.tst.sh`, `func-name-unique.tst.sh`, `bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r89-02-orc-stale-sweep-lease-conf-reader)` | one fact, one copy (developer guide 2.2.4) | the stale sweep keeps a private copy of the `lease.conf` reader 5 actions take from the owner digest (1.4) | `orc:src/bash/run/spl-issue-stale-sweep.func.sh:53-55,71-76`<br>`orc:src/bash/tests/spl-issue-stale-sweep.tst.sh` (header, case 10) | copies of the reader 2 -> 1 | 1.4's shape. **Red control:** the head's test on the parent FAILs case 10 (1.5), then GREEN; outputs in the body. **Behaviour:** equal bodies; cases 1-9 equal on parent and head. Tests: `spl-issue-stale-sweep.tst.sh`, `spl-owner-digest.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `func-name-unique.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the
`git grep -n` of the function names, the body comparison, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r89-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r89-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a copy and points its callers at the other; no output, exit
code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: 3 spool-install
  steps and r88's slug test; row 02: the stale sweep and its test).
- No row edits `spl-owner-digest-post.func.sh` or any of its other callers,
  `spl-claude-project-slug.func.sh` (r88-01's helper), `spl-dispatch-lease.func.sh`,
  `install.sh`, any spool-install test, `test-lib.inc.sh`, `orc-shard-weights.txt`, any
  `run.sh`, `spawn-agents/` (spec 184 row L2's `spawn-core.inc.sh`, section 7),
  `csi-spl-cnf/`, terraform, `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (6): `steps/claude-memory.inc.sh`, `steps/y18-grok-memory.sh`,
`steps/y20-agy-memory.sh`, `orc:src/bash/tests/spl-claude-project-slug.tst.sh`,
`orc:src/bash/run/spl-issue-stale-sweep.func.sh`,
`orc:src/bash/tests/spl-issue-stale-sweep.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-285`, one call per
  path, 2026-11-22T14:58:22Z (row 01's 4) and 15:02:04Z (row 02's 2), n=1: **exit 4 on
  all 6** ("no live lane lists <path>, but 9 live lane(s) record no files"). The
  `unknown:` lanes, all on the other box: c-495 (SPL-6250 gcal removed member, landed
  `94e5690a2`), c-496 (search type:calendar), c-499 (SPL-6242 WUI avatar), c-806 (SPL-6182
  native auth: hub auth, store, `cmd/spool` tests) and five `*-rotate` seats. No lane
  is reported as owning any of the 6.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 14:58:53Z): this
  round's mistral panel seat (placing), the held spec 154 rows B16, B17, B18, B12, B11
  (contacts, hub / WUI / i18n) and the SPL-6257 grok reviewer. SPL-6257's lane (c-271)
  edits `spawn-agents/lib/lane-issue.inc.sh`, its test and `lane-issue-and-docs.md`
  (its brief). None names a row path. Share line: refactor 1 of 17 known live lanes, 5%
  (band 10-20%: UNDER); last 24 h refactor 13% (band 20-30%: UNDER).
- **Briefs on this box** changed in the last 24 h (129) naming a row file or function
  (`grep -lE 'claude-memory\.inc|spool_install_memory_slug|y18-grok-memory|y20-agy-memory|spl-claude-project-slug|spl-issue-stale-sweep|spl_stale_lease_conf|spl_owner_digest_lease_conf'`,
  15:07:43Z): 8: the r87-02 and r88 row and reviewer briefs (landed rounds, 6), the bug
  round 38 planner's (r87-02 in its 04:4xZ stay-off list) and this one. None live.
- **Remote branches committed in the last 24 h** (20 besides master after
  `fetch --prune`, 15:03:01Z): `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths and spl-owner-digest-post.func.sh>`
  -> **0 hits**.
- **Commits in the last 24 h** on those paths (`git log origin/master --since=2026-11-21T15:00Z`)
  -> 3: `a42fff43c` (r87-02), `90522d802` (r88-01), `e2dea23a9` (r88-02), all landed
  rounds.
- **Live lanes named in the brief:** SPL-6182 c-806 (hub auth + store); SPL-6257 c-271
  (above); step 030 c-273, spec 123 L3w c-033 and SPL-6252 c-246 (step 030 / cnf); spec
  154 B8 c-249 and B10 c-250 (contacts, WUI palette) and the held B rows; calendar
  sharing c-252; SPL-6250 c-495; SPL-6242 c-499; search c-496; the review seats and the
  private-channel seats: none on a row path.

## 3. Per row: what the lane does

- **r89-01:** the spool-install steps lose their own copy of the claude project slug
  rule; `claude-memory.inc.sh` loads r88-01's `spl_claude_project_slug`, which Y18 and
  Y20 call; `spl-claude-project-slug.tst.sh` case 4 proves no copy is left in the steps
  and the inc loads the helper sourced alone.
- **r89-02:** `do_spl_issue_stale_sweep` reads `lease.conf` through
  `spl_owner_digest_lease_conf`, as 5 other actions do, and loads it when sourced
  alone; `spl-issue-stale-sweep.tst.sh` case 10 proves the private copy is gone.

## 4. Panel and reviewers (R7)

- Editor: c-285 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the queued mistral seat `c002-refactor-round-89-mistral-panel-seat`.
  The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-22T15:05:32Z printed
  `pick=hold reason=no box with a sample is below its overflow mark (200% of its high)`,
  both boxes `full` on load (211% and 307% of their band), grok weekly 39% on both:
  the hold is load, not quota, so **a grok R7 seat per row**. The rows run by night
  (rulebook 1.4); the holder re-runs the pick when it places them, and a hold then gives
  the row a **claude waiver seat** (1a7c70da), as r88's section 4 says. Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r89-01 | `c002-r89-01-orc-install-memory-slug-helper` | `refactor(r89-01-orc-install-memory-slug-helper, SPL-<row issue>): ...` | `review/r89-01` | 1 |
| r89-02 | `c002-r89-02-orc-stale-sweep-lease-conf-reader` | `refactor(r89-02-orc-stale-sweep-lease-conf-reader, SPL-<row issue>): ...` | `review/r89-02` | 1 |

**r89-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/features/spool-install/steps/claude-memory.inc.sh` (`:3-5` the
header, `:8-9` the copy becomes the comment and the guarded load),
`.../steps/y18-grok-memory.sh` (`:57`), `.../steps/y20-agy-memory.sh` (`:254`) and
`csi-spl-orc/src/bash/tests/spl-claude-project-slug.tst.sh` (header and case 4). NOT
`csi-spl-orc/lib/bash/funcs/spl-claude-project-slug.func.sh`, `install.sh`, any
spool-install test (`test-y18-grok-memory.sh` case 9 stays as it is),
`spl-dispatch-lease.func.sh`, the parameter-expansion scripts of section 7. Do: plan
section 2 row 01 verbatim, 1.3's shape; the red control (the head's test on the parent)
RED then GREEN in the body; the guard control (the `declare -F` line deleted: case 4 and
`test-y18-grok-memory.sh` fail). Gates: the row's tests (section 2, `SPOOL_TEST=1`, in
the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r89-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-issue-stale-sweep.func.sh` (the guard after `:53`, the
calls `:54-55`, `:71-76` go) and `csi-spl-orc/src/bash/tests/spl-issue-stale-sweep.tst.sh`
(header and case 10). NOT `spl-owner-digest-post.func.sh` or any of its other callers
(`spl-reflection-gather`, `spl-topic-archive-suggest`, `spl-topic-prio-sync`,
`spl-zombie-topics`), NOT the inline `LEASE_ORCH` reads of section 7. Do: plan section 2
row 02 verbatim, 1.4's shape; the red control (the head's test on the parent) RED then
GREEN in the body; the guard control (the `declare -F` line deleted: case 1 fails).
Gates: the row's tests (section 2), `shellcheck -S warning -x` on the 2 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| function copies of the claude project slug rule in orc bash (`grep -rlF 's/[^A-Za-z0-9]/-/g'` over `lib`, `src/bash/run`, `spool-install/steps`) | 3 files on `94e5690a2` (helper, `claude-memory.inc.sh`, `spl-dispatch-lease.func.sh`) -> 2 after row 01 |
| definitions of the `lease.conf` key reader body (1.2 (e)) | 2 -> 1 after row 02 |
| lines (`git diff --stat` of each head) | row 01: 4 files +17 -7; row 02: 2 files +12 -8 |
| measured on | `94e5690a2`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-dispatch-lease.func.sh:2385` | the slug sits inside a `bash -c` string run as the agent user; a shell function does not cross it | r88 7 |
| the parameter-expansion slug `${X//[^A-Za-z0-9]/-}` (`spawn-agents/scripts/lane-scratch-reap.sh:63`, `lane-test-server-reap.sh:134,163`, `orc:src/bash/scripts/spl-session-prune.sh:229`) | not the same function: on a path with a newline the `sed` helper keeps the newline (`$'-a\nb'`), the expansion makes it a dash (`-a-b`), n=1; pointing them at the helper changes output. Standalone scripts, no source edge | 1.2 (a); the probe `x=$'/a\nb'` |
| the inline `LEASE_ORCH` reads of `lease.conf` (`spl-agent-login-check.func.sh:525`, `spl-push-orphan-check.func.sh:187`, `spl-vendor-terms-check.func.sh:32`, `scripts/cron-no-stack.sh:58`, `scripts/reliability-check-cron.sh:72`) | one `sed` inside a larger line each, 5 files (3 run, 2 standalone scripts); `spl-agent-login-check.func.sh` is sourced alone by 5 files. A later row may point the 3 run files at the reader | `git grep -nE "sed -n ['\"]s/\^...=//p['\"] ...dispatch/lease\.conf"` |
| `spawn_rename_how` in `spawn-agy.sh:21`, `spawn-grok.sh:21`, `spawn-qwen.sh:32` (the same 4 lines but the vendor word) | a shared copy belongs in `spawn-core.inc.sh`, a file of spec 184 row L2 (unlanded, `spec.md:288`); after L2 lands, a later row may | spec 184 section 6 |
| the other 1.2 (e) sets: `spl_secrets_none_get` / `spl_self_host_env_get`; `spl_uplink_trim` / `ext_api_trim`; `spl_brx_gh_auth` / `ghrh_gh_auth`; `tf_get`; `_print_help_actions` (orc / utl) | secret-class; two modules (orc / utl, three sets); a script run alone in the tf-runner container (r85 7) | r87 7, r85 7 |
| 1.2 (e): `ndf_link` / `ndp_link` (`net-dns-fast-failover`, `net-dns-pin-and-mask`, 4 lines); `spl_issue_brc_one` / `spl_issue_oq_one` (3 lines); `asks_peers_on` / `send_to_peers_on` (3 lines, two standalone scripts); the 7 `_sec_*_need` of `iac:src/bash/run/sec-*.func.sh` | candidates for later rows, not measured further in v0.1 (box network actions; the 7 `_sec_*` copies are over the 5-site cap) | 1.2 (e) |
| `spl-lane-mix.func.sh` agy words and flag | the action's output and flag, asserted by its test; the fleet rule text still names agy: behaviour and a rule decision | 1.2 (c) |
| the agent-id regex literal, `as_root` / `as_owner`, the per-script message helpers, `say` / `check_tools`; the r86 Go set | r85 / r86 section 7, unchanged | r86 7 |
| `parse-metadata.func.sh` `${1:?}` lines, terraform `-input=false`, dropped rc | bug rows | r84 7 |
| `topic_loop_fire.go` `!inserted`, `spl-spawn-place-argmax.tst.sh:181-212`, the e2e selector `_ppe_keys` | test rows, a gate-design item | r83 7; candidates file |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred, an open owner decision, behaviour, or the full sweep; unchanged since W | 1.2 (d) |

## 8. Changes

- v0.1 (c-285): the rows and every read on `94e5690a2`; both heads built in scratch
  worktrees; the column of 1.5 run on base and both heads (equal, the new cases added);
  the red and guard controls RED; R3 (2.2) and R7 (section 4) checked.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-285 (claude): v0.1.
- Panel reviewer seat: the queued mistral seat
  (`c002-refactor-round-89-mistral-panel-seat`): pending.
- Row R7 seats: section 4.
