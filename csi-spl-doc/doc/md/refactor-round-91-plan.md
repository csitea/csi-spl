# Refactoring round 91 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6282  
Topic: de9e8968-7305-41d9-b131-e1670daf14af  
Discussion: de9e8968-7305-41d9-b131-e1670daf14af (t1 #refactoring, "Refactor round 91", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r91**, plan `refactor-round-91-plan.md`, rows `r91-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 90 ([refactor-round-90-plan.md](refactor-round-90-plan.md))
is closed: both rows landed (r90-01 `d205601a4`, r90-02 `ad95fef21`; close record
`447095af7`). The perf floor (rulebook 4.4), measured by the holder on `1b49782a0`: perf
29, refactor 102, 5 x 29 = 145 >= 131, floor met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r90-02: a
function body that exists twice under two names loses its second copy, and its caller
calls the first, loaded by a `declare -F` guard inside the calling function when the
file is sourced alone.
**Row 01:** `do_tf_import_existing` keeps `_tf_import_oap`, a byte-identical copy of
`tf-plan-ref.func.sh`'s `_tf_plan_ref_oap` (the ORG / APP resolver of the tf-tasks
naming pair); the copy goes. **Row 02:** `do_spl_search_calendar_probe` (SPL-6251, made
from the doc probe) keeps `spl_search_calendar_probe_check`, a byte-identical copy of
`spl_search_doc_probe_check`; the copy goes. The rows share no file: both are batch 1.

**Status: v1.0, signed; round closed (section 8).** The panel (m-548, mistral) passed v0.1 `3eb6298f8` with no W;
N1..N5 are notes only (seat file `csi-spl-doc/doc/md/refactor-round-91/seat-mistral.md`).
Rows run by night (rulebook 1.4). Editor: **c-547** (claude).

**One sha:** every count is measured on **`1b49782a0`** (`origin/master` at
2026-11-23T06:06Z), n=1 per command unless stated. Reads are on that sha with
`git show` / `git grep`. The tests of 1.5 ran in detached scratch worktrees of that sha
(not committed, removed after v1.0): "base" unmodified, "head1" = base with row 01
applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's shape; each red and
guard control (1.5) was built in one of those trees and restored after its run. Queue,
lane map, brief and branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-23T06:06:04Z, n=1, after `git fetch --prune origin`:

- **Window: W=2026-11-22T21:43:20+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r90-plan'`: `447095af7`, the
  r90 close record (as the brief says).
- `git log origin/master --since="$W" --oneline -E --grep='\(r91-'` -> **0**; over all
  history -> **0**.
- `git ls-remote origin 'refs/heads/review/r91-*' 'refs/heads/*-r91-*' 'refs/heads/*refactor-round-91*' 'refs/heads/wip/*r91*'`
  -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r91|refactor-round-91'` -> this plan's
  brief and the panel seat's (`c002-refactor-round-91-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-91`
  -> 0: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) r90 section 7:**
  - `spool-install/steps/claude-memory.inc.sh` `spool_install_memory_slug`: **served**.
    `git grep -c spool_install_memory_slug 1b49782a0 -- csi-spl-orc` -> 0; the file's
    `:8-10` load the one helper `spl_claude_project_slug` (r89-01 `afd3bf8e3`).
  - `ndf_link` / `ndp_link` (byte-identical, 4-line body): measured further, left out
    (section 7: the pin-and-mask test runs red-control copies of the run file from its
    temp dir, where a `dirname BASH_SOURCE` load finds no sibling).
  - `spl-vendor-terms-check.func.sh:32`, `_po_to` / `_lc_alert_to`: unchanged, left out
    for r90's reasons. Re-read of `_po_to` / `_lc_alert_to` on `1b49782a0`: they also
    differ in the redirection order of the lease read (`<file 2>/dev/null` vs
    `2>/dev/null <file`): a missing lease prints a shell error in one and not the
    other, so one copy changes stderr (section 7).
  - Every other r90 section 7 item: unchanged since W, stays out for its reason there.
- **(b) R7 and panel notes:** r90-01's R7 line (g-660) and r90-02's (g-653) carry no N
  note (`git log -1 --format=%B d205601a4`, `ad95fef21`: the `review:` line names only
  the release-note WARN). The r90 panel's N1-N4 (`refactor-round-90/seat-mistral.md`)
  are process notes, no row.
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  114 lines, read 06:07Z): its refactor-shaped items are the ones r90 1.2 (c) lists,
  each served or accounted for there (literal `/var` paths, `spl-desk-reply.sh` kinds,
  the `spl-lane-mix.func.sh` agy words, `_ppe_keys`, the `!inserted` test). No new
  refactor-shaped item.
- **(d) spec 011 tasks:** `git log origin/master --since="$W" --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks are those of r90
  section 7.
- **(e) A fresh scan for byte-identical function bodies** (this round's own input): over
  the tracked `*.sh` of `csi-spl-orc/src/bash`, `csi-spl-orc/lib`, `csi-spl-iac/src/bash`,
  `csi-spl-utl/src/bash`, tests left out, each `name() {` ... `}` body (2+ lines,
  whitespace-trimmed, its own name masked) hashed and grouped. Leaving out the copies of
  `run.sh` and `print-help.func.sh` (one framework, r86 7), 14 groups. Two are this
  round's rows (1.3, 1.4); the other 12 are in section 7.

### 1.3 Row 01's site: `_tf_import_oap` goes

`orc:` = `csi-spl-orc/`. On `1b49782a0`:

- `orc:src/bash/run/tf-import-existing.func.sh:105-111`: the 3-line comment and the
  4-line `_tf_import_oap`, after the blank `:104`; called twice, `:54-55`
  (`org=` / `app=` in `do_tf_import_existing`).
- `orc:src/bash/run/tf-plan-ref.func.sh:117-122`: `_tf_plan_ref_oap`, called at `:57-58`.
  Its body (`:120-121`) and `tf-import-existing.func.sh:109-110` are **byte-identical**:
  `APP_PATH="$2" ORG='' APP='' bash -c 'source "$0"; do_resolve_oap "$1"; echo "${!1}"'`
  and `"$3/lib/bash/funcs/resolve-oap.func.sh" "$1"`
  (`git grep -n 'do_resolve_oap "\$1"; echo' 1b49782a0 -- ':!*.md'` -> those 2 lines).
- `git grep -nE '_tf_import_oap|_tf_plan_ref_oap' 1b49782a0 -- ':!*.md'` -> the 8 lines
  above only; no test names either.
- Who loads `tf-import-existing.func.sh`: `./run` (the lazy loader) and its test, which
  sources the real file alone (`tf-import-existing.tst.sh:100`, `:157`).
  `tf-plan-ref.func.sh` has no top-level code (functions only) and defines
  `do_tf_plan_ref` and `_tf_plan_ref_*`: no stub of `tf-import-existing.tst.sh`
  (which stubs `docker` on `PATH` and `do_log`), so the load replaces none.

Shape (built as head1 of 1.5):
- `tf-import-existing.func.sh:54-55` become 3 lines: the guard
  `declare -F _tf_plan_ref_oap >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/tf-plan-ref.func.sh"`,
  then `org=` / `app=` calling `_tf_plan_ref_oap`; `:104-111` go. 111 -> 104 lines.
- `orc:src/bash/tests/tf-import-existing.tst.sh` gains case 12 (header and body, before
  the summary): the file defines no `_tf_import_oap()` and holds no `do_resolve_oap`,
  and it calls `_tf_plan_ref_oap ORG`. 163 -> 173. Cases 4-10 already source the action
  alone, and case 6 asserts `ORG=csi APP=spl` on every exec: they are the guard's proof.

**Behaviour:** the function the action now calls has the deleted body byte for byte,
with the same 3 arguments; the column (1.5) is equal on base and head1 but for case 12.

### 1.4 Row 02's site: `spl_search_calendar_probe_check` goes

On `1b49782a0`:

- `orc:src/bash/run/spl-search-calendar-probe.func.sh:47-52`: the 2-line comment and the
  4-line `spl_search_calendar_probe_check`, after the blank `:46`; called once at `:25`
  (in `do_spl_search_calendar_probe`). The file came from the doc probe (SPL-6251,
  `1ce4797b6`, 2026-11-22T19:31:52Z): `diff` of the two files differs only in the
  header, the names and the log words.
- `orc:src/bash/run/spl-search-doc-probe.func.sh:47-52`: `spl_search_doc_probe_check`,
  called at `:25`. The two bodies (`:50-51` each) are **byte-identical** (`diff` of the
  two files shows no hunk at `:50-51`, n=1): the `ENV` dev / prd refusal and the
  `TENANT_ID` slug refusal, same messages.
- `git grep -nE 'spl_search_(calendar|doc)_probe_check' 1b49782a0 -- ':!*.md'` -> the 4
  lines above only; no test names either.
- Who loads the calendar probe: `./run` and its test, which sources the real file alone
  (`spl-search-calendar-probe.tst.sh:127-131`, `chk`). `spl-search-doc-probe.func.sh`
  has no top-level code and defines only `do_spl_search_doc_probe` and
  `spl_search_doc_probe_check`; the `chk` stubs (`do_log`, `spl_dry_run`,
  `do_require_bin`, `do_spl_cloud_cnf`, `spl_cnf_api_fqdn`) are none of them.

Shape (built as head2 of 1.5):
- `spl-search-calendar-probe.func.sh:25` becomes 2 lines: the guard
  `declare -F spl_search_doc_probe_check >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-search-doc-probe.func.sh"`,
  then `spl_search_doc_probe_check "$tenant" || return 1`; `:46-52` go. 52 -> 46 lines.
- `orc:src/bash/tests/spl-search-calendar-probe.tst.sh` gains (2 header lines, one check
  before the summary): the file holds no `spl_search_calendar_probe_check()` and no
  `FATAL TENANT_ID` line, and calls `spl_search_doc_probe_check "$tenant"`. 142 -> 151.
  Its existing knobs check (the action sourced alone refuses `ENV=qa` and
  `TENANT_ID='T 1'`) is the guard's proof.

**Behaviour:** the step the action now calls has the deleted body byte for byte; the
refusal messages and return codes are unchanged (the knobs check passes on both).

### 1.5 Before and on the rows' heads

2026-11-23T06:09:41Z-06:10:38Z (the column) and 06:10:51Z-06:11:0xZ (controls), n=1, as
the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset,
`timeout 900` each; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines
`grep -ciE '^ *(not ok|fail)'`. "=" means the head equals base: same rc, pass and fail
counts.

| suite | row | base rc / pass / fail | head |
|---|---|---|---|
| `orc:src/bash/tests/tf-import-existing.tst.sh` | 01 | 0 / 29 / 0 | 0 / 30 / 0 (case 12 adds 1) |
| `orc:src/bash/tests/tf-plan-ref.tst.sh` | 01 | 0 / 47 / 0 | = |
| `orc:src/bash/tests/spl-search-calendar-probe.tst.sh` | 02 | 0 / 6 / 0 | 0 / 7 / 0 (adds 1) |
| `orc:src/bash/tests/spl-search-doc-probe.tst.sh` | 02 | 0 / 6 / 0 | = |
| `orc:src/bash/tests/search-speed-probe.tst.sh` | 02 | 0 / 12 / 0 | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = (both heads) |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = (both heads) |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = (both heads) |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = (both heads) |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = (both heads) |

Each head also ran the other row's suites: equal to base. `shellcheck -S warning -x` on
each row's two files, base and head: rc 0, no findings (n=1 each).

**Red controls** (n=1 each):
- Row 01: head1's `tf-import-existing.tst.sh` on base: rc 1,
  `FAIL: 12. own ORG/APP resolver left: 108:_tf_import_oap() {`; head1: rc 0.
- Row 01's guard: head1 with the `declare -F` line deleted: rc 1, 8 fail lines, e.g.
  `FAIL: 040-cloud-sql-postgres dev: rc=1 .../tf-import-existing.func.sh: line 54: _tf_plan_ref_oap: command not found`.
- Row 02: head2's `spl-search-calendar-probe.tst.sh` on base: rc 1,
  `FAIL: own knobs check left, or no call of spl_search_doc_probe_check: 49:spl_search_calendar_probe_check() {`;
  head2: rc 0.
- Row 02's guard: head2 with the `declare -F` line deleted: rc 1,
  `FAIL: the action's knobs: [.../spl-search-calendar-probe.func.sh: line 25: spl_search_doc_probe_check: command not found] ...`.

The tests that name the sites (R2): `git grep -lE` over the tests for
`tf-import-existing|tf-plan-ref|_tf_import_oap|_tf_plan_ref_oap` -> `tf-import-existing.tst.sh`,
`tf-plan-ref.tst.sh` and `orc-shard-weights.txt` (no line needed: no new file); for
`spl-search-calendar-probe|spl-search-doc-probe|spl_search_(calendar|doc)_probe_check`
-> the two probe suites and `orc-shard-weights.txt`; `search-speed-probe.tst.sh` is
added as the third probe of the family. Plus the loader and name gates of the table.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r91-01-orc-tf-oap-resolver)` | one fact, one copy (developer guide 2.2.4) | the 040 import tool keeps a byte-identical copy of tf-plan-ref's ORG / APP resolver (1.3) | `orc:src/bash/run/tf-import-existing.func.sh:54-55,104-111`<br>`orc:src/bash/tests/tf-import-existing.tst.sh` (header, case 12) | definitions of the resolver body 2 -> 1 | 1.3's shape. **Red control:** the head's test on the parent FAILs case 12 (1.5), then GREEN; the guard control (the `declare -F` line deleted: cases 6-10 fail); outputs in the body. **Behaviour:** the column passes on parent and head with the same counts but case 12. Tests: `tf-import-existing.tst.sh`, `tf-plan-ref.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r91-02-orc-search-probe-check)` | one fact, one copy (developer guide 2.2.4) | the calendar probe keeps a byte-identical copy of the doc probe's knobs check (1.4) | `orc:src/bash/run/spl-search-calendar-probe.func.sh:25,46-52`<br>`orc:src/bash/tests/spl-search-calendar-probe.tst.sh` (header, 1 check) | definitions of the check body 2 -> 1 | 1.4's shape. **Red control:** the head's test on the parent FAILs (1.5), then GREEN; the guard control (the `declare -F` line deleted: the knobs check fails); outputs in the body. **Behaviour:** equal bodies; the other checks equal on parent and head. Tests: `spl-search-calendar-probe.tst.sh`, `spl-search-doc-probe.tst.sh`, `search-speed-probe.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body comparison, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r91-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r91-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a copy and points its caller at the other; no output, exit
code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: the import
  tool and its test; row 02: the calendar probe and its test).
- No row edits `tf-plan-ref.func.sh` or its test, `spl-search-doc-probe.func.sh` or its
  test, `spl-search-speed-probe.func.sh`, `search-calendar-probe.py`,
  `lib/bash/funcs/resolve-oap.func.sh`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (4): `orc:src/bash/run/tf-import-existing.func.sh`,
`orc:src/bash/tests/tf-import-existing.tst.sh`,
`orc:src/bash/run/spl-search-calendar-probe.func.sh`,
`orc:src/bash/tests/spl-search-calendar-probe.tst.sh`; and the two keepers they load,
`tf-plan-ref.func.sh` and `spl-search-doc-probe.func.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-547`, one call per
  path, n=1: the import tool, its test and `tf-plan-ref.func.sh` at
  2026-11-23T06:08:01Z, the calendar probe, its test and `spl-search-doc-probe.func.sh`
  at 06:13:35Z: **exit 4 on all 6** ("no live lane lists <path>, but 5 live lane(s)
  record no files"). The `unknown:` lanes, all on the other box: a-942 (spec 154 B11
  i18n locale files) and four `*-rotate` seats (c-146, c-499, c-924, c-927: the private-
  channel seats and the SPL-6242 WUI avatar, as the brief names them). No lane is reported as
  owning any of the 6; none of those scopes is an orc run file.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 06:11:26Z): 1 queued,
  0 placing: the spec 154 B11 i18n re-place on claude. It names no row path. Share line:
  refactor 2 of 9 known live lanes, 22% (band 10-20%: OVER); last 24 h 12% (band 20-30%:
  UNDER).
- **Briefs on this box** changed in the last 24 h (95) naming a row file or function
  (`grep -lE 'tf-import-existing|tf-plan-ref|_tf_import_oap|_tf_plan_ref_oap|spl-search-calendar-probe|spl-search-doc-probe|spl_search_(calendar|doc)_probe_check'`,
  06:11:14Z): **0**.
- **Remote branches committed in the last 24 h** (10 besides master after
  `fetch --prune`, 06:11:14Z): `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths>`
  -> **0 hits**.
- **Commits in the last 24 h** on those 6 paths (`git log origin/master --since=2026-11-22T06:10Z`)
  -> 1: `1ce4797b6` (SPL-6251, the calendar probe itself), landed with its hub and WUI
  commits (`aafacf21a`, `1fa66048e`); no SPL-6251 work is queued or on a branch (the
  brief and branch reads above).
- **Live lanes named in the brief:** spec 154 B18 SPL-6278 (contacts sync GET and the
  WUI settings switch: hub and WUI) and its reviewer; spec 154 B12 SPL-6280 (help
  `people.md`) and its reviewer; spec 154 B11 (i18n locale files); SPL-6242 (WUI
  avatar); the private-channel seats: none on a row path.

## 3. Per row: what the lane does

- **r91-01:** `do_tf_import_existing` resolves ORG / APP through `_tf_plan_ref_oap`, the
  one copy, and loads it when its file is sourced alone; case 12 of
  `tf-import-existing.tst.sh` proves the copy is gone, cases 6-10 that the guard loads
  the resolver.
- **r91-02:** `do_spl_search_calendar_probe` refuses bad knobs through
  `spl_search_doc_probe_check`, the one copy, and loads it when sourced alone; its test
  proves the copy is gone, and its knobs check that the sourced-alone run still refuses.

## 4. Panel and reviewers (R7)

- Editor: c-547 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the queued mistral seat `c002-refactor-round-91-mistral-panel-seat`,
  placed as m-548 (holder c-002, msg a0db6899). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-23T06:11:50Z printed
  `pick=<box> reason=<box> is the first box in order below its low mark (35% < 70%)`,
  grok weekly 57% on both boxes: **a grok R7 seat per row**. The rows run by night
  (rulebook 1.4); the holder re-runs the pick when it places them, and a hold then gives
  the row a **claude waiver seat** (1a7c70da), as r90's section 4 says. Not a mistral
  code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r91-01 | `c002-r91-01-orc-tf-oap-resolver` | `refactor(r91-01-orc-tf-oap-resolver, SPL-<row issue>): ...` | `review/r91-01` | 1 |
| r91-02 | `c002-r91-02-orc-search-probe-check` | `refactor(r91-02-orc-search-probe-check, SPL-<row issue>): ...` | `review/r91-02` | 1 |

**r91-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/tf-import-existing.func.sh` (`:54-55` become the guard and
the two calls, `:104-111` go) and `csi-spl-orc/src/bash/tests/tf-import-existing.tst.sh`
(header and case 12). NOT `tf-plan-ref.func.sh` or its test, NOT
`lib/bash/funcs/resolve-oap.func.sh`. Do: plan section 2 row 01 verbatim, 1.3's shape;
the red control (the head's test on the parent) RED then GREEN in the body; the guard
control (the `declare -F` line deleted: cases 6-10 fail). Gates: the row's tests
(section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 2 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r91-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-search-calendar-probe.func.sh` (`:25` becomes the guard
and the call, `:46-52` go) and `csi-spl-orc/src/bash/tests/spl-search-calendar-probe.tst.sh`
(header and the 1 check). NOT `spl-search-doc-probe.func.sh` or its test, NOT
`spl-search-speed-probe.func.sh` (its check has 2 more lines, section 7) or
`search-calendar-probe.py`. Do: plan section 2 row 02 verbatim, 1.4's shape; the red
control (the head's test on the parent) RED then GREEN in the body; the guard control
(the `declare -F` line deleted: the knobs check fails). Gates: the row's tests
(section 2), `shellcheck -S warning -x` on the 2 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| definitions of the ORG / APP resolver body (1.3) | 2 on `1b49782a0` -> 1 after row 01 |
| definitions of the probe knobs check body (1.4) | 2 -> 1 after row 02 |
| lines (`git diff --stat` of each head) | row 01: 2 files +13 -10; row 02: 2 files +12 -9 |
| measured on | `1b49782a0`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `ndf_link` / `ndp_link` (`net-dns-fast-failover.func.sh:71`, `net-dns-pin-and-mask.func.sh:49`, 4-line body, byte-identical) | `net-dns-pin-and-mask.tst.sh` runs red-control copies of the run file from its temp dir (`$T/red1..3.func.sh`, `:157-168`), where a `dirname BASH_SOURCE` load finds no sibling: the row must also change those controls, a shape no row has measured | 1.2 (a); `sed -n 70,95p`, `150,171p` of the test |
| `ghr_in` / `ghrm_in` / `oss_runner_in` (`gh-runner-add.func.sh:112`, `gh-runner-remove.func.sh:43`, `oss-runners-move.func.sh:40`, 2-line body, 3 copies) | the same red-copy shape: `gh-runner-add.tst.sh:247-252` writes copies to `$T/run/`; root runner actions | 1.2 (e) |
| `spl_asks_dur` / `spl_fleet_dur` (`spl-asks-tick.func.sh:479`, `spl-dispatch-lease.func.sh:1731`) | either direction sources a 535- or 3088-line run file from the other, and 7 suites name `spl_asks_*` functions; a lib helper is a new file, not measured | 1.2 (e) |
| `spl_search_speed_probe_check` (`spl-search-speed-probe.func.sh:43`) | its first 2 lines are row 02's body, then 2 more checks; a shared prefix needs another shape | 1.4 |
| the other `TENANT_ID must be a tenant slug` lines | a pattern inside each action, not a function; over the 5-site cap | `git grep -n 'TENANT_ID must be a tenant slug' 1b49782a0 -- csi-spl-orc/src/bash/run` -> 21 lines, row 02's 2 among them |
| `do_gcp_modify_project_apis_disable` / `do_gcp_project_apis_disable` (iac, 12 lines, equal but the name) | two named destructive GCP actions: removing or merging one changes the action list | 1.2 (e) |
| `_spl_rebox_copy` / `_spl_rebox_verify` (`spl-desk-rebox.func.sh:128,232`) | not the same body: each calls its own `_run` | 1.2 (e) |
| `spl_uplink_trim` / `ext_api_trim`, `spl_brx_gh_auth` / `ghrh_gh_auth` | orc and utl, no source edge between the modules | 1.2 (e) |
| `spl_secrets_none_get` / `spl_self_host_env_get`; `tf_get` (2 scripts); `asks_peers_on` / `send_to_peers_on`; `_bgs_q` / `_bpi_q`; the 7 `_sec_*_need` | secret-class; standalone scripts; iac box actions not measured further; over the 5-site cap | 1.2 (e), r89 7 |
| `spl-vendor-terms-check.func.sh:32`, `_po_to` / `_lc_alert_to` | a value such as `-n` (r90 7); the redirection order differs, so one copy changes stderr on a missing lease (1.2 (a)) | r90 7; read on `1b49782a0` |
| every other r90 section 7 item | unchanged since W, its reason there | r90 7 |

## 8. Changes

- v0.1 (c-547): the rows and every read on `1b49782a0`; both heads built in scratch
  worktrees; the column of 1.5 run on base and both heads (equal, the new checks added);
  the red and guard controls RED; R3 (2.2) and R7 (section 4) checked.
- v1.0 (c-547): the panel seat m-548 (mistral) PASS on `3eb6298f8`, no W, N1..N5 notes
  (seat file on `review/c002-refactor-round-91-mistral-seat`, `a6253cb68`). Its review
  line: `do_spl_review_line_check` rc 0, `DOCS-ONLY 3eb6298f8d4f` (2026-11-23T06:30:29Z,
  on the log's box). Text unchanged but the status line and sections 8 and 9.
- Round closed (c-547), no version bump: the 2 rows landed, read on `origin/master`
  `85f0e60fc` (2026-11-23T11:59Z, n=1 each):
  - r91-01 `b2edf8c7d` (SPL-6303, committed 2026-11-23T11:44:00Z; row seat c-107):
    R7 g-117 grok **PASS** on `06d04cd46`; `git patch-id --stable` `2655fecb5690` on
    both. CI on `b2edf8c7d`: 10 (2 runs), 15, 25, 26, 40, 64, 67 **success** (12 skipped).
  - r91-02 `85f0e60fc` (SPL-6304, committed 11:53:23Z; row seat c-110): R7 g-122
    grok **PASS** on `4e9dd63df`; patch-id `dd48666190ed` on both. CI on `85f0e60fc`:
    10, 15, 21, 25, 26, 64, 67 **success** (12 skipped).
  - `merge-base --is-ancestor <row> origin/master` rc 0 for both; holder c-002 ACCEPTED
    each (msgs d8582cdf, dfcaa735). **R7 vendor:** both
    seats grok (section 4; queued by the holder c-002, placed on the other box at
    11:31Z and 11:44Z); no claude waiver seat was needed. Definitions of the ORG / APP resolver body 2 -> 1 (row 01's case 12),
    of the probe knobs check body 2 -> 1 (row 02's test), as each row's commit records.
    The rows' diffs: row 01 2 files +14 -10, row 02 2 files +12 -8 (section 6 planned
    +13 -10 and +12 -9; each commit gives its test's line count).
  - Panel notes, folded: N1 (the seat's own heads differ by a test line, controls
    equal) and N2 (base unmoved through the review) need nothing more; both rows
    re-measured on `031b2b04e` and found the sites unmoved. N3 (lane map exit 4, stale
    `review/search-qto-docs`): neither row commit touches a path outside its brief's
    Files (`git show --stat`, 2 files each). N5 (grok pick): held, both
    seats grok. **N4, for the next planner:** the `spl-lane-mix.func.sh` agy words
    (`needs_agy_review`, "agy has the final word") are a doc / rule item now that
    SPL-6174 landed (4 commits on 2026-11-21, `c081de61a` .. `63ff3e425`; the seat's
    `986ddca84` is an SPL-6086 commit, `git log -1 986ddca84`); pick it up explicitly,
    not through r90 section 7.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-547 (claude): v0.1, v1.0, close record.
- Panel reviewer seat: m-548 (mistral, `c002-refactor-round-91-mistral-panel-seat`):
  **PASS** on v0.1 (`3eb6298f8`), no W, notes N1-N5. Seat file
  `refactor-round-91/seat-mistral.md` (section 8).
- Row R7 seats: section 4; both grok: g-117 (r91-01), g-122 (r91-02) (section 8, round
  closed).
