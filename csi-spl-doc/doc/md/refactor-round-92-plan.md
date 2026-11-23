# Refactoring round 92 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6306  
Topic: e6110b64-35f7-4e54-bb54-4c5d0bb308b7  
Discussion: e6110b64-35f7-4e54-bb54-4c5d0bb308b7 (t1 #refactoring, "Refactor round 92", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r92**, plan `refactor-round-92-plan.md`, rows `r92-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 91 ([refactor-round-91-plan.md](refactor-round-91-plan.md))
is served: both rows landed (r91-01 `b2edf8c7d`, r91-02 `85f0e60fc`; its close record
`bce008e61` landed at 12:28:53Z, after this plan's window read, 1.1). The perf floor
(rulebook 4.4), measured by the holder c-002 on `7024772b1`: perf 29, refactor 104,
5 x 29 = 145 >= 133, floor met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the shape of r91: a
function body that exists twice under two names loses its second copy, and its caller
calls the first, loaded by a `declare -F` guard inside the calling function when the
file is sourced alone.
**Row 01:** `spl_search_speed_probe_check` opens with 2 lines byte-identical to the
body of `spl_search_doc_probe_check` (the ENV and TENANT_ID refusals), the shared
prefix r91 section 7 left out; those 2 lines become one call of the doc probe's check,
and the 2 checks of its own (PROBE_N, PROBE_TERMS) stay. **Row 02:** `do_box_go_switch`
(SPL-2739, made after `do_box_pkg_install`) keeps `_bgs_sudo` and `_bgs_q`, each
byte-identical to `_bpi_sudo` and `_bpi_q` of `box-pkg-install.func.sh` but for the
name; the copies go and the action calls box-pkg-install's. The rows share no file:
both are batch 1.

**Status: v1.0, signed.** The panel (m-650, mistral) passed v0.1 `eba675d07` with no W;
N1..N5 are notes only (seat file `csi-spl-doc/doc/md/refactor-round-92/seat-mistral.md`,
branch `review/c002-refactor-round-92-mistral-seat`). Rows run by night (rulebook 1.4).
Editor: **c-648** (claude).

**One sha:** every count is measured on **`7024772b1`** (`origin/master` at
2026-11-23T12:24Z), n=1 per command unless stated. `origin/master` then moved to
`bce008e61` (the r91 close record): `git diff --stat 7024772b1 bce008e61` touches only
`refactor-round-91-plan.md`, none of this plan's paths, so every site read stands.
Reads are on `7024772b1` with `git show` / `git grep`. The tests of 1.5 ran in detached
scratch worktrees of that sha (not committed, removed after v1.0): "base" unmodified,
"head1" = base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied
in 1.4's shape; each red and guard control (1.5) was built in one of those trees and
restored after its run. Queue, lane map, brief and branch reads are live state and
carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-23T12:24:09Z, n=1, after `git fetch --prune origin`:

- **Window: W=2026-11-23T08:56:59+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r91-plan'`: `b31854815`
  (`docs(r91-plan, SPL-6282): refactor round 91 seat mistral signs v1.0`), read once at
  the start as 5.3 says. c-547's r91 close record `bce008e61`
  (2026-11-23T14:28:53+02:00) landed after this read; the window stays the recorded one.
- `git log origin/master --since="$W" --oneline -E --grep='\(r92-'` -> **0**; over all
  history -> **0**. Re-read at 12:3xZ since `bce008e61`'s date: also **0**.
- `git ls-remote origin 'refs/heads/review/r92-*' 'refs/heads/*-r92-*' 'refs/heads/*refactor-round-92*' 'refs/heads/wip/*r92*'`
  -> nothing (12:24Z and again 12:3xZ).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r92|refactor-round-92'` -> this plan's
  brief and the panel seat's (`c002-refactor-round-92-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-92`
  -> 0: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) r91 section 7:**
  - `spl_search_speed_probe_check` (`spl-search-speed-probe.func.sh:43`): its first 2
    lines are the doc probe check's body; r91 left it out because "a shared prefix
    needs another shape". This round measures that shape: **row 01** (1.3).
  - `ndf_link` / `ndp_link`: re-measured in the other direction too, left out
    (section 7): `net-dns-fast-failover.tst.sh:194-202` also runs red-control copies
    of its run file from `$T/red.func.sh`, so neither file can load the other.
  - Every other r91 section 7 item: unchanged since W
    (`git diff --stat b31854815 7024772b1 -- <its paths>` -> empty), stays out for its
    reason there; `_bgs_q` / `_bpi_q` is measured further here (e).
- **(b) R7 and panel notes:** r91-01's R7 line (g-117) and r91-02's (g-122) carry no N
  note (`spool tail --task 241be5d2-...` and `--task 8d7e1601-...`: each `review:` line
  names its runs and the release-note WARN only). The r91 panel's notes
  (`refactor-round-91/seat-mistral.md`): N1-N3 and N5 are process notes, no row. **N4**
  (the `spl-lane-mix.func.sh` agy words), which the seat and the r91 close record ask
  the next planner to pick up explicitly: measured, not a refactor row (section 7: it
  changes printed output and a pinned fleet fact).
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  114 lines, last written 2026-11-22T04:01Z, read 12:2xZ): no item added since r91 read
  it (06:07Z); its refactor-shaped items are the ones r90 1.2 (c) and r91 1.2 (c) list,
  each served or accounted for there; the agy words item is N4 above.
- **(d) spec 011 tasks:** `git log origin/master --since="$W" --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks (T001-T008 deferred
  by the owner, T018-T021, T023, T027, T034) are each wider than one row.
- **(e) A fresh scan for byte-identical function bodies** over the tracked `*.sh` of
  `csi-spl-orc/src/bash`, `csi-spl-orc/lib`, `csi-spl-iac/src/bash`,
  `csi-spl-utl/src/bash`, tests left out, each `name() {` ... `}` body
  whitespace-trimmed, its own name masked, hashed and grouped, copies of `run.sh` and
  `print-help.func.sh` left out (one framework, r86 7). Bodies of 2+ lines: **11 groups**
  on `7024772b1` (13 on `1b49782a0`; the 2 r91 rows are gone), every one in r91
  section 7. Bodies of 1 line of 40+ characters: 3 groups, `_bgs_sudo` / `_bpi_sudo`
  among them. `_bgs_q` / `_bpi_q` (2 lines, "iac box actions not measured further" in
  r89 / r91 7) and `_bgs_sudo` / `_bpi_sudo` are measured here as **row 02** (1.4).

### 1.3 Row 01's site: the speed probe's own ENV / TENANT_ID lines go

`orc:` = `csi-spl-orc/`. On `7024772b1`:

- `orc:src/bash/run/spl-search-speed-probe.func.sh:41-48`: the 2-line comment and
  `spl_search_speed_probe_check` (`:43`), called once at `:25` (in
  `do_spl_search_speed_probe`). Its body `:44-47`: `:44` the ENV dev / prd refusal,
  `:45` the TENANT_ID slug refusal, `:46` PROBE_N 1..50, `:47` PROBE_TERMS.
- `orc:src/bash/run/spl-search-doc-probe.func.sh:47-52`: `spl_search_doc_probe_check`
  (`:49`), body `:50-51`. `:44-45` of the speed probe and `:50-51` of the doc probe are
  **byte-identical** (`diff` of the two line pairs: no hunk, n=1); same messages.
- `git grep -nE 'spl_search_(speed|doc)_probe_check' 7024772b1 -- ':!*.md'` -> the
  definitions and calls above, the calendar probe's guard and call
  (`spl-search-calendar-probe.func.sh:25-26`, r91-02) and the tests: the speed probe's
  `chk` (`search-speed-probe.tst.sh:109`) calls `spl_search_speed_probe_check` directly
  after sourcing the real file alone; so the guard goes inside the check, not in
  `do_spl_search_speed_probe`.
- Who loads the speed probe: `./run` (the lazy loader) and its test
  (`search-speed-probe.tst.sh:109`, `$HERE/../run/...`, no copy in a temp dir).
  `spl-search-doc-probe.func.sh` has no top-level code and defines only
  `do_spl_search_doc_probe` and `spl_search_doc_probe_check`; the `chk` stub
  (`do_log`) is neither.

Shape (built as head1 of 1.5):
- `spl-search-speed-probe.func.sh:42` (the comment) becomes 2 lines that say the ENV /
  TENANT_ID refusals are the doc probe's check, its one copy; `:44-45` become 2 lines:
  the guard
  `declare -F spl_search_doc_probe_check >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-search-doc-probe.func.sh"`,
  then `spl_search_doc_probe_check "$1" || return 1`. `:46-47` unchanged. 48 -> 49 lines.
- `orc:src/bash/tests/search-speed-probe.tst.sh` gains (header 1 line, one check after
  the knobs loop, 12 lines): the file holds no `FATAL ENV must be dev or prd` and no
  `FATAL TENANT_ID must be a tenant slug` line, it calls
  `spl_search_doc_probe_check "$1"`, and `chk stg t1 5 archive` / `chk prd T1 5 archive`
  still print those two FATAL lines word for word. 118 -> 130.
- head1's files, sha256 (12 chars): func `471fd4c00d32`, test `13e048014cb1`.

**Behaviour:** the step the check now calls has the deleted lines byte for byte, with
the same `$1`; the 2 own checks after it are untouched. Refusal messages and the return
code are unchanged: the knobs checks of the test pass on base and head1 (1.5).

### 1.4 Row 02's site: `_bgs_sudo` and `_bgs_q` go

`iac:` = `csi-spl-iac/`. On `7024772b1`:

- `iac:src/bash/run/box-go-switch.func.sh:45-55`: the 1-line comment and the 3-line
  `_bgs_sudo` (`:46`), a blank, the 1-line comment and the 4-line `_bgs_q` (`:51`), a
  blank. Called on 13 lines: `_bgs_q` at `:114-116`, `:123-125`; `_bgs_sudo` at `:151`,
  `:161`, `:164`, `:213`, `:220`, `:223`, `:225` (`git grep -cE '_bgs_(q|sudo)\b'` -> 17
  lines: 2 definitions, 2 comments, 13 calls).
- `iac:src/bash/run/box-pkg-install.func.sh:43-52`: `_bpi_sudo` (`:44`) and `_bpi_q`
  (`:49`) with their comments. `box-go-switch.func.sh:45-54` with `_bgs_` read as
  `_bpi_` is **byte-identical** to `box-pkg-install.func.sh:43-52`
  (`diff <(sed -n 43,52p pkg) <(sed -n 45,54p go | sed s/_bgs_/_bpi_/g)` -> no hunk,
  n=1). `box-go-switch.func.sh` came after (`01d485a0c` 2026-10-20, SPL-2739;
  box-pkg-install `c099630c3` 2026-10-17, SPL-2341).
- `git grep -nE '\b_b(gs|pi)_(q|sudo)\(\)' 7024772b1 -- ':!*.md'` -> the 4 definitions
  only. No test names `_bgs_*`; `box-pkg-install.tst.sh:235,244-245` match
  `_bpi_journal` / `_bpi_send` / `_bpi_real` lines in its own red copies, not the two
  helpers.
- Who loads `box-go-switch.func.sh`: `./run` and its test, which sources the real file
  alone (`box-go-switch.tst.sh:24` `FUNC` default, `:108`, `:175`, `:218`); every helper
  call runs inside `do_box_go_switch` (`:233`), so the guard goes there, after the
  `local` at `:240`. `box-pkg-install.func.sh`'s only top-level code is `:41`, the same
  guarded `spl_box_name` load as `box-go-switch.func.sh:43`; it defines
  `do_box_pkg_install` and `_bpi_*` only, none a name `box-go-switch.func.sh` defines
  (`func-name-unique.tst.sh` equal on head2).

Shape (built as head2 of 1.5):
- `box-go-switch.func.sh:45-55` go; after `:240` 2 lines: a comment and the guard
  `declare -F _bpi_q >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/box-pkg-install.func.sh"`;
  the 13 call lines say `_bpi_q` / `_bpi_sudo`. 255 -> 246 lines.
- `iac:src/bash/tests/box-go-switch.tst.sh` gains case 7 (3 header lines, 8 lines before
  the summary): the action holds no `_bgs_sudo` / `_bgs_q`, box-pkg-install defines
  `_bpi_q()`, and the action builds its re-run line with `_bpi_q "$GO_VERSION"`.
  225 -> 236. Cases 1, 2 and 5 already source the action alone and assert the quoted
  ROLLBACK and re-run lines (`:133`, `:149`): they are the guard's proof.
- head2's files, sha256 (12 chars): func `b893bb332eea`, test `93bd4453b8f3`.
- A note for the row and its reviewer: a red control of this row is built in a
  worktree of the tree, never as a copy of `box-go-switch.func.sh` in a temp dir: the
  guard loads its sibling by `dirname BASH_SOURCE`.

**Behaviour:** the helpers the action now calls have the deleted bodies byte for byte
with the same arguments; the test's output on head2 equals base's line for line but
case 7's PASS line (`diff` of the two logs: `11a12`, n=1).

### 1.5 Before and on the rows' heads

2026-11-23T12:28:57Z-12:30:10Z (the column) and 12:30:40Z-12:30:47Z (controls), n=1, as
the push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset,
`timeout 900` each; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines
`grep -ciE '^ *(not ok|fail)'`. "=" means the head equals base: same rc, pass and fail
counts.

| suite | row | base rc / pass / fail | head |
|---|---|---|---|
| `orc:src/bash/tests/search-speed-probe.tst.sh` | 01 | 0 / 12 / 0 | 0 / 13 / 0 (the check adds 1) |
| `orc:src/bash/tests/spl-search-doc-probe.tst.sh` | 01 | 0 / 6 / 0 | = |
| `orc:src/bash/tests/spl-search-calendar-probe.tst.sh` | 01 | 0 / 7 / 0 | = |
| `iac:src/bash/tests/box-go-switch.tst.sh` | 02 | 0 / 11 / 0 | 0 / 12 / 0 (case 7 adds 1) |
| `iac:src/bash/tests/box-pkg-install.tst.sh` | 02 | 0 / 18 / 0 | = |
| `iac:src/bash/tests/no-box-path-source.tst.sh` | 02 | 0 / 10 / 0 | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = (both heads) |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = (both heads) |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = (both heads) |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = (both heads) |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = (both heads) |

Each head also ran the other row's suites: equal to base. `shellcheck -S warning -x` on
each row's two files, base and head: rc 0, no findings (n=1 each).

**Red controls** (n=1 each):
- Row 01: head1's `search-speed-probe.tst.sh` on base: rc 1, 1 fail,
  `FAIL: own ENV / TENANT_ID check left, or no call of spl_search_doc_probe_check: [44:  [[ "${ENV:-}" == dev || ...`;
  head1: rc 0, 0 fail.
- Row 01's guard: head1 with the `declare -F` line deleted: rc 1, 2 fail,
  `FAIL: a well-formed call was refused` and the one-copy check
  (`.../spl-search-speed-probe.func.sh: line 45: spl_search_doc_probe_check: command not found`).
  The 5 bad-knob checks stay green there (a missing function also returns non-zero):
  the new check's FATAL-text half is what makes the guard visible beyond the one
  well-formed call.
- Row 02: head2's `box-go-switch.tst.sh` on base: rc 1, 1 fail,
  `FAIL: 7. own sudo / quote helper left, or no call of _bpi_q: 45:# _bgs_sudo <cmd...>: ...`;
  head2: rc 0, 0 fail.
- Row 02's guard: head2 with the `declare -F` line deleted: rc 1, 4 fail
  (`1. plain directory`, `2. symlink`, `5. DRY_RUN unset`, `5. DRY_RUN=1`), e.g.
  `.../box-go-switch.func.sh: line 140: _bpi_sudo: command not found`.

The tests that name the sites (R2): `git grep -lE` over the tree for
`spl-search-speed-probe|search-speed-probe|spl_search_speed_probe_check` ->
`search-speed-probe.tst.sh` and `orc-shard-weights.txt` (no line needed: no new file);
the doc and calendar probe suites are added as the probe family, as r91-02 did. For
`box-go-switch|do_box_go_switch|_bgs_|_bpi_(q|sudo)` -> `box-go-switch.tst.sh` and a
comment in `iac:src/terraform/060-gcp-vm-satellite/roles/02_os_binaries/defaults/main.yml:3`
(names the action, unchanged); `box-pkg-install.tst.sh` is added as the keeper's suite.
Plus the loader, path and name gates of the table.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r92-01-orc-speed-probe-check)` | one fact, one copy (developer guide 2.2.4) | the speed probe's knobs check opens with a byte-identical copy of the doc probe's ENV / TENANT_ID check (1.3) | `orc:src/bash/run/spl-search-speed-probe.func.sh:42,44-45`<br>`orc:src/bash/tests/search-speed-probe.tst.sh` (header, 1 check) | copies of the 2-line ENV / TENANT_ID refusal in the probes 2 -> 1 | 1.3's shape. **Red control:** the head's test on the parent FAILs (1.5), then GREEN; the guard control (the `declare -F` line deleted: 2 checks fail); outputs in the body. **Behaviour:** the column passes on parent and head with the same counts but the new check. Tests: `search-speed-probe.tst.sh`, `spl-search-doc-probe.tst.sh`, `spl-search-calendar-probe.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r92-02-iac-box-go-switch-helpers)` | one fact, one copy (developer guide 2.2.4) | the Go switch keeps byte-identical copies of box-pkg-install's sudo and quote helpers (1.4) | `iac:src/bash/run/box-go-switch.func.sh:45-55,114-125,151-164,213-225,240`<br>`iac:src/bash/tests/box-go-switch.tst.sh` (header, case 7) | definitions of each helper body 2 -> 1 (2 helpers) | 1.4's shape. **Red control:** the head's test on the parent FAILs case 7 (1.5), then GREEN; the guard control (the `declare -F` line deleted: cases 1, 2, 5 fail); outputs in the body. **Behaviour:** the test's output equals the parent's but case 7. Tests: `iac:.../box-go-switch.tst.sh`, `iac:.../box-pkg-install.tst.sh`, `iac:.../no-box-path-source.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body comparison, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r92-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r92-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a copy and points its caller at the other; no output, exit
code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: the speed
  probe and its test, orc; row 02: the Go switch and its test, iac).
- No row edits `spl-search-doc-probe.func.sh` or its test,
  `spl-search-calendar-probe.func.sh` or its test, `search-speed-probe.py`,
  `box-pkg-install.func.sh` or its test, `box-pkg-flag.func.sh`,
  `orc-shard-weights.txt`, any `run.sh`, `csi-spl-cnf/`, terraform (the role default
  comment included), `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (4): `orc:src/bash/run/spl-search-speed-probe.func.sh`,
`orc:src/bash/tests/search-speed-probe.tst.sh`,
`iac:src/bash/run/box-go-switch.func.sh`, `iac:src/bash/tests/box-go-switch.tst.sh`;
and the two keepers they load, `spl-search-doc-probe.func.sh` and
`box-pkg-install.func.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-648`, one call per
  path, n=1, 2026-11-23T12:31:15Z-12:31:36Z: **exit 4 on all 6** ("no live lane lists
  <path>, but 7 live lane(s) record no files"). The `unknown:` lanes, all on the other
  box: the private-channel seats c-029, c-041, c-146, c-924, c-927 (`*-rotate`), the
  seat c-086 the brief names, and the blog lane c-102 (SPL-6302,
  `csi-spl-doc/blog/posts/en/2026-11-23-discussion-loops.md`), as the brief names them.
  No lane is reported as owning any of the 6; none of those scopes is an orc or iac run
  file.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 12:31:43Z): 1
  queued, 0 placing: `c002-b40-wip-issues-reread` (bug, b40 section 5, re-read wip
  issues). It names no row path. Share line: refactor 3 of 14 known live lanes, 21%
  (band 10-20%: OVER); last 24 h 13% (band 20-30%: UNDER).
- **Briefs on this box** changed in the last 24 h (107) naming a row file or function
  (`grep -lE 'spl-search-speed-probe|search-speed-probe|spl_search_speed_probe_check|box-go-switch|do_box_go_switch|_bgs_|_bpi_(q|sudo)'`,
  12:32:18Z): **1**, `c002-r91-02-orc-search-probe-check.md`, which names the speed
  probe as off limits for r91-02 (landed `85f0e60fc`, ACCEPTED).
- **Remote branches committed in the last 24 h** (12 besides master after
  `fetch --prune`, 12:32Z): `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths>`
  -> **0 hits**.
- **Commits in the last 24 h** on those 6 paths (`git log origin/master --since=2026-11-22T12:30Z`)
  -> **0**.
- **Live lanes and rows named in the brief:** SPL-6301 c-626 (costs vendor share and
  prefix route) and its reviewer g-133; costs month range c-624; blog SPL-6302 c-102 and
  g-125; bug round 41 planner c-136 (SPL-6305) and its rows (none queued at 12:31Z); the
  r91 editor c-547 (its close record `bce008e61` touches only the r91 plan); bug round
  40 editor c-591; the private-channel seats; the seat c-086: none on a row path (the
  lane map and the queue above).

## 3. Per row: what the lane does

- **r92-01:** `spl_search_speed_probe_check` refuses a bad ENV or TENANT_ID through
  `spl_search_doc_probe_check`, the one copy, and loads it when its file is sourced
  alone; its own PROBE_N and PROBE_TERMS checks stay. The new check of
  `search-speed-probe.tst.sh` proves the copy is gone and the two FATAL lines read the
  same; its knobs checks that the sourced-alone check still refuses.
- **r92-02:** `do_box_go_switch` runs as root and quotes its re-run and rollback lines
  through `_bpi_sudo` / `_bpi_q`, the one copy, loaded when its file is sourced alone;
  case 7 of `box-go-switch.tst.sh` proves the copies are gone, cases 1, 2 and 5 that the
  guard loads them.

## 4. Panel and reviewers (R7)

- Editor: c-648 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the queued mistral seat `c002-refactor-round-92-mistral-panel-seat`.
  The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-23T12:32:24Z printed
  `pick=<box> reason=every box is at or above its high mark; <box> is the least past its band`,
  grok weekly 63% on both boxes: **a grok R7 seat per row**. The rows run by night
  (rulebook 1.4); the holder re-runs the pick when it places them, and a hold then gives
  the row a **claude waiver seat** (1a7c70da), as r90's and r91's section 4 say. Not a
  mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r92-01 | `c002-r92-01-orc-speed-probe-check` | `refactor(r92-01-orc-speed-probe-check, SPL-<row issue>): ...` | `review/r92-01` | 1 |
| r92-02 | `c002-r92-02-iac-box-go-switch-helpers` | `refactor(r92-02-iac-box-go-switch-helpers, SPL-<row issue>): ...` | `review/r92-02` | 1 |

**r92-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-search-speed-probe.func.sh` (`:42` the comment, `:44-45`
become the guard and the call) and `csi-spl-orc/src/bash/tests/search-speed-probe.tst.sh`
(header and the 1 check). NOT `spl-search-doc-probe.func.sh` or its test, NOT
`spl-search-calendar-probe.func.sh` or its test, NOT `search-speed-probe.py`. Do: plan
section 2 row 01 verbatim, 1.3's shape; the red control (the head's test on the
parent) RED then GREEN in the body; the guard control (the `declare -F` line deleted:
2 checks fail). Gates: the row's tests (section 2, `SPOOL_TEST=1`, in the worktree),
`shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

**r92-02 brief, Files: ONLY**
`csi-spl-iac/src/bash/run/box-go-switch.func.sh` (`:45-55` go, the guard after `:240`,
the 13 call lines renamed) and `csi-spl-iac/src/bash/tests/box-go-switch.tst.sh`
(header and case 7). NOT `box-pkg-install.func.sh` or its test, NOT
`box-pkg-flag.func.sh`, NOT the terraform role default that names the action. Do: plan
section 2 row 02 verbatim, 1.4's shape; the red control (the head's test on the parent)
RED then GREEN in the body; the guard control (the `declare -F` line deleted: cases 1,
2 and 5 fail), built in a worktree, not a temp-dir copy (1.4). Gates: the row's tests
(section 2), `shellcheck -S warning -x` on the 2 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| copies of the 2-line ENV / TENANT_ID refusal in the search probes (1.3) | 2 on `7024772b1` (doc, speed; the calendar probe already calls the doc's) -> 1 after row 01 |
| definitions of the sudo and quote helper bodies (1.4) | 2 each on `7024772b1` -> 1 each after row 02 |
| lines (`git diff --numstat` of each head) | row 01: func +4 -3, test +13 -1; row 02: func +15 -24, test +11 -0 |
| measured on | `7024772b1`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `spl-lane-mix.func.sh` agy words (`:46`, `:136-138`, `:392`, `:401-402`; r91 panel N4) | not a refactor: `:138` and `:402` are printed output (`_LM_CHOICE_WHY`) and `:401` the flag value, all three asserted by `spl-lane-mix.tst.sh:471-477` (case 8); and the fleet pin `<!-- fleet-pin language-rule-final: agy -->` (`20-spawn-an-agent.md:38`) still names agy, so the words follow a rule decision the drift check pins. To the orchestrator as its own ask (this plan's result), not a row | `git grep -nE 'needs_agy_review\|waits for an agy review\|agy has the final word' 7024772b1 -- ':!*.md'` -> 6 lines in the run file, 5 in its test |
| `ndf_link` / `ndp_link` (`net-dns-fast-failover.func.sh:71`, `net-dns-pin-and-mask.func.sh:49`) | both tests run red-control copies of their run file from a temp dir (`net-dns-pin-and-mask.tst.sh:157-168`; `net-dns-fast-failover.tst.sh:194-202`, `sed ... > "$T/red.func.sh"`), so a `dirname BASH_SOURCE` load finds no sibling in either direction; `net-dns-pin-and-mask.func.sh` also sets `NDP_*` globals at top level | 1.2 (a) |
| `_lc_deps` / `_spl_box_leave_deps` (1-line dep loaders) | each loads `spool-env.inc.sh` relative to its own file; merging one into the other only moves the load | 1.2 (e) |
| `do_db_login_ensure_gcp` / `do_db_login_rotate_gcp` (`spl-db-roles.func.sh:288,301`, same 1-line body, one file) | named actions of the DB login, secret-class (owner DSN secret) | 1.2 (e) |
| every r91 section 7 item not named above (`ghr_in` family, `spl_asks_dur` / `spl_fleet_dur`, the `TENANT_ID` slug lines, the GCP apis-disable pair, `_spl_rebox_*`, the orc / utl pairs, the secret-class and standalone-script groups, `spl-vendor-terms-check.func.sh:32`, `_po_to` / `_lc_alert_to`) | unchanged since W, its reason there | r91 7; 1.2 (a) |

## 8. Changes

- v0.1 (c-648): the rows and every read on `7024772b1`; both heads built in scratch
  worktrees; the column of 1.5 run on base and both heads (equal, the new checks
  added); the red and guard controls RED; R3 (2.2) and R7 (section 4) checked.
- v1.0 (c-648): the panel seat m-650 (mistral) PASS on `eba675d07`, no W, notes N1..N5
  (msgs 1a79e28e, af2cd2a1; seat file `refactor-round-92/seat-mistral.md` on
  `review/c002-refactor-round-92-mistral-seat`, `4c43f4646`). Its review line:
  `do_spl_review_line_check` rc 0, `DOCS-ONLY eba675d07b46` (2026-11-23T13:13:09Z, on
  the log's box; the holder c-002 also rc 0). N2: `origin/master` moved `7024772b1` ->
  `bce008e61` during the review, `git diff --name-only` on the 6 row paths empty, so every
  site stands. N5: a grok R7 seat per row (pick 69% < 70%, grok weekly 63-64%), the
  claude waiver seat only if the pick holds at placement; never mistral. Text unchanged
  but the status line and sections 8 and 9.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-648 (claude): v0.1, v1.0.
- Panel reviewer seat: m-650 (mistral, `c002-refactor-round-92-mistral-panel-seat`):
  **PASS** on v0.1 (`eba675d07`), no W, notes N1-N5. Seat file
  `refactor-round-92/seat-mistral.md` (section 8).
- Row R7 seats: section 4.
