# Refactoring round 90 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6265  
Topic: 99b03b18-b40f-4528-a5e6-d2a86a0fe308  
Discussion: 99b03b18-b40f-4528-a5e6-d2a86a0fe308 (t1 #refactoring, "Refactor round 90", opened by c-002)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r90**, plan `refactor-round-90-plan.md`, rows `r90-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 89 ([refactor-round-89-plan.md](refactor-round-89-plan.md))
is closed: both rows landed (r89-01 `afd3bf8e3`, r89-02 `f1cee40fd`; close record
`b49a192ff`). The perf floor (rulebook 4.4), measured by the holder on `d8f33ae97`: perf
29, refactor 111, 5 x 29 = 145 >= 140, floor met, so this is a refactor round.

Both rows are **one fact, one copy** (developer guide 2.2.4), the same shape as r89-02:
a body that exists twice under two names loses its second copy, and its caller uses the
first, loaded by a `declare -F` guard when the file is sourced alone.
**Row 01** serves r89 section 7's "a later row may point the 3 run files at the reader":
two of the three run files (`_po_from`, `_lc_alert_from`) read `LEASE_ORCH` from
`lease.conf` with their own `sed`, the body of `spl_owner_digest_lease_conf`, the reader
6 actions already share; the third stays out (section 7). **Row 02**: r89 1.2 (e)'s
`spl_issue_brc_one` / `spl_issue_oq_one` pair: `do_spl_issue_owner_question_diss` keeps a
byte-identical copy of `do_spl_issue_blocker_rca_close`'s "reason comment, then diss"
step; the copy goes. The rows share no file: both are batch 1.

**Status: v1.0, signed.** The panel (m-326@sat, mistral) passed v0.1 `418f6e69c` (landed as v1.0, text unchanged but this line) with no W; N1..N4 are notes only (seat file `csi-spl-doc/doc/md/refactor-round-90/seat-mistral.md`). Editor: **c-324** (claude).

**One sha:** every count is measured on **`748282860`** (`origin/master` at
2026-11-22T16:55Z, committed 16:51:31Z), n=1 per command unless stated. Reads are on
that sha with `git show` / `git grep`. The tests of 1.5 ran in detached scratch
worktrees of that sha (not committed, removed after v0.1): "base" unmodified, "head1" =
base with row 01 applied in 1.3's shape, "head2" = base with row 02 applied in 1.4's
shape, and one control tree per red or guard control (1.5). Queue, lane map, brief and
branch reads are live state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

2026-11-22T16:55:23Z, n=1, after `git fetch --prune origin`:

- **Window: W=2026-11-22T18:18:54+02:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r89-plan'`: `b49a192ff`, the
  r89 close record (as the brief says).
- `git log origin/master --since="$W" --oneline -E --grep='\(r90-'` -> **0**; over all
  history -> **0**.
- `git ls-remote origin 'refs/heads/review/r90-*' 'refs/heads/*-r90-*' 'refs/heads/*refactor-round-90*' 'refs/heads/wip/*r90*'`
  -> nothing.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r90|refactor-round-90'` -> this plan's
  brief and the panel seat's (`c002-refactor-round-90-mistral-panel-seat.md`), no other.
- `git ls-tree --name-only origin/master csi-spl-doc/doc/md/ | grep -c refactor-round-90`
  -> 0: the plain name.

### 1.2 The brief's inputs, re-measured

- **(a) r89 section 7:**
  - The inline `LEASE_ORCH` reads: `git grep -nE "dispatch/lease\.conf"` over orc / iac /
    utl, tests and docs left out, lines with `sed -n` -> 12 (the reader's own line among them). Of them, the body of
    `spl_owner_digest_lease_conf` (`sed -n "s/^<key>=//p" <root>/dispatch/lease.conf | tail -1`)
    with `<key>` = `LEASE_ORCH` appears in 3 run files
    (`spl-agent-login-check.func.sh:525`, `spl-push-orphan-check.func.sh:187`,
    `spl-vendor-terms-check.func.sh:32`) and 2 standalone scripts
    (`scripts/cron-no-stack.sh:58`, `scripts/reliability-check-cron.sh:72`). The first two
    are **row 01** (1.3); the third and the scripts stay out (section 7). The others use
    another pattern (a character class, `sed -n 1p` for the first line, another key) and
    are not the reader's body.
  - `ndf_link` / `ndp_link`, `spl_issue_brc_one` / `spl_issue_oq_one`, `asks_peers_on` /
    `send_to_peers_on`, the `_sec_*_need` set: r89 left them "candidates for later rows".
    `spl_issue_brc_one` / `spl_issue_oq_one` is **row 02** (1.4); the others stay out
    (section 7).
  - Every other r89 section 7 item stays out for its reason there (section 7).
- **(b) R7 and panel notes:** r89-01's R7 line (g-306) carries no N note; r89-02's (g-308)
  carries N1, release note absent (warning mode): a process point, no row
  (`git log -1 --format=%B afd3bf8e3`, `f1cee40fd`). The r89 panel's N1-N5
  (`refactor-round-89/seat-mistral.md:243-262`) name process points; N3 (the
  `no-literal-paths.tst.sh` STALE lines in a `git archive` copy without `.git`) is a
  scratch artifact: in a git worktree of `748282860` it reads rc 0, 15 pass (1.5). This
  round's controls ran in git worktrees, and the panel should check in one too.
- **(c) The dispatcher's candidates file** (`/var/spool-hub/dispatch/c002-next-round-candidates.md`,
  114 lines, read 16:5xZ), its refactor-shaped items:
  - the literal `/var` paths (`LOGIN_STATE_DIR`, the agent-boot-restore dir,
    `reverse-tunnel-cron.sh`), `spl-desk-reply.sh` kinds (SPL-6107 N1): served
    (r88 1.2 (c), r89 1.2 (c)); unchanged.
  - `spl-lane-mix.func.sh` agy words and flag: behaviour and a rule decision (r89 7).
  - the e2e selector `_ppe_keys`, the `!inserted` loop-fire test: a gate-design item and a
    test row, not this round's.
- **(d) spec 011 tasks:** `git log origin/master --since="$W" --
  csi-spl-doc/specs/011-spool-project-refactor` -> 0; the open tasks are those of r89
  section 7.

### 1.3 Row 01's sites: two `LEASE_ORCH` readers go

`orc:` = `csi-spl-orc/`. On `748282860`:

- `orc:src/bash/run/spl-push-orphan-check.func.sh:185-190`, `_po_from` (the sender of
  the orphan-push alert, called at `:168` inside `$(...)`):
  `o="$(sed -n 's/^LEASE_ORCH=//p' "$SPOOL_ROOT/dispatch/lease.conf" 2>/dev/null | tail -1)"`
  at `:187`, then `[[ "$o" =~ ^${SPOOL_AGENT_ID_RX}$ ]] || o="$(spl_role_seat 1)"`.
- `orc:src/bash/run/spl-agent-login-check.func.sh:523-528`, `_lc_alert_from` (called at
  `:496` and by `spl-claude-login-mode.func.sh:199`, both inside `$(...)`): the same
  line at `:525`, the same check at `:527`.
- The reader: `orc:src/bash/run/spl-owner-digest-post.func.sh:162-166`,
  `spl_owner_digest_lease_conf <root> <key> <default>`:
  `v="$(sed -n "s/^$2=//p" "$1/dispatch/lease.conf" 2>/dev/null | tail -1)"; echo "${v:-$3}"`.
  With `<key>` = `LEASE_ORCH` and `<default>` = `""` it prints what each inline line
  captures. The one difference, `echo` of a value such as `-n` or `-e`, cannot reach a
  caller: both sites accept only a value matching `^${SPOOL_AGENT_ID_RX}$`, else they
  fall back to `spl_role_seat 1`, on base and head alike.
- `git grep -n spl_owner_digest_lease_conf` -> 6 actions call it (owner digest, stale
  sweep, reflection gather, topic archive suggest, topic prio sync, zombie topics).
- Who loads the two files: `./run` (the lazy loader); their tests through `in_orc`, which
  sources every run file unless `IN_ORC_RUN` names a subset; and
  `spl-agent-login-check.func.sh` is also sourced alone by 4 run files
  (`spl-agent-login-proof:39`, `spl-claude-login-mode:44`, `spl-dispatch-lease:2727`,
  `spl-watchdog:86`). So each site loads the reader with r89-02's guard, inside the
  function, so neither file gains top-level code. `spl-owner-digest-post.func.sh`
  defines only `do_spl_owner_digest_post` and `spl_owner_digest_{run,render,box,lease_conf}`:
  no stub of the two tests, so the load replaces none.

Shape (built as head1 of 1.5):
- `spl-push-orphan-check.func.sh:187` becomes the two lines
  `declare -F spl_owner_digest_lease_conf >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-owner-digest-post.func.sh"`
  and `o="$(spl_owner_digest_lease_conf "$SPOOL_ROOT" LEASE_ORCH "")"`. 190 -> 191 lines.
- `spl-agent-login-check.func.sh:525`: the same two lines. 528 -> 529.
- `orc:src/bash/tests/spl-push-orphan-check.tst.sh` gains case 12 (header and body): no
  `sed -n 's/^LEASE_ORCH=//p'` in either run file, and with only this action's file
  sourced (`IN_ORC_RUN=spl-push-orphan-check`) and `LEASE_ORCH=c-007`, the alert goes
  `--from c-007`. 200 -> 215.
- `orc:src/bash/tests/spl-agent-login-check.tst.sh` gains case 23: with only this
  action's file and `spool-env.inc.sh` sourced and `LEASE_ORCH=c-007`, `_lc_alert_from`
  prints `c-007`. 444 -> 452. It is the guard's only proof for this file: without it,
  deleting the guard line fails no suite of the column (1.5).

**Behaviour:** the reader prints what the deleted lines captured for every value the
check accepts; the column (1.5) is equal on base and head1 but for the added cases.

### 1.4 Row 02's site: the owner-question mover's diss step

On `748282860`:

- `orc:src/bash/run/spl-issue-owner-question-diss.func.sh:163-168`: the comment
  `# spl_issue_oq_one KEY WHY: the reason comment, then status diss.` and a 4-line
  function, called once at `:150` (in `spl_issue_oq_apply`); the blank line `:162`
  before it.
- `orc:src/bash/run/spl-issue-blocker-rca-close.func.sh:153-158`: the same comment for
  `spl_issue_brc_one` and the same body, called at `:140`. **Byte-identical**
  (`diff` of `sed -n 155,158p` and `sed -n 165,168p` -> empty, n=1).
- `git grep -n 'spl_issue_oq_one\|spl_issue_brc_one'` -> those 6 lines only (plans left
  out).
- Not the same body, so not in this row: `spl_issue_discard_one`
  (`spl-issue-discard-stale.func.sh:211`, its own comment text and a third argument) and
  `spl_stale_end_one` (`spl-issue-stale-sweep.func.sh:140`, WARN lines and another
  comment).
- Who loads the mover: `./run` and its test through `in_orc` (every run file). The guard
  goes inside `spl_issue_oq_apply`, before the loop. `spl-issue-blocker-rca-close.func.sh`
  defines only `do_spl_issue_blocker_rca_close` and `spl_issue_brc_*` / `_spl_issue_brc_query`:
  none of the mover test's stubs (`spl_issue_oq_read`, `spl_desk_issue_once`,
  `spl_desk_issue_run`).

Shape (built as head2 of 1.5):
- `spl-issue-owner-question-diss.func.sh`: before `:140` (`spl_desk_issue_once || return 1`)
  the line
  `declare -F spl_issue_brc_one >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-issue-blocker-rca-close.func.sh"`;
  `:150` calls `spl_issue_brc_one`; `:162-168` go. 168 -> 162 lines.
- `orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh` gains two checks (header and
  body, before the SQL check): the file defines no `spl_issue_oq_one()` and its apply
  calls `spl_issue_brc_one`; with only this action's file sourced
  (`IN_ORC_RUN=spl-issue-owner-question-diss`) a real run sets SPL-1351 diss. 77 -> 89.

**Behaviour:** the step the mover now calls has the deleted body byte for byte; its
reason text is the mover's own `$why`, passed as before.

### 1.5 Before and on the rows' heads

2026-11-22T17:04:33Z-17:08:43Z (the column) and 16:59Z-17:14Z (controls), n=1, as the
push user, `SPOOL_TEST=1` with `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID` unset, `timeout 900`
each; pass lines `grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`.
"=" means the head equals base: same rc, pass and fail counts.

| suite | row | base rc / pass / fail | head |
|---|---|---|---|
| `orc:src/bash/tests/spl-push-orphan-check.tst.sh` | 01 | 0 / 26 / 0 | 0 / 28 / 0 (case 12 adds 2) |
| `orc:src/bash/tests/spl-agent-login-check.tst.sh` | 01 | 0 / 57 / 0 | 0 / 58 / 0 (case 23 adds 1) |
| `orc:src/bash/tests/spl-claude-login-mode.tst.sh` | 01 | 0 / 17 / 0 | = |
| `orc:src/bash/tests/spl-agent-login-proof.tst.sh` | 01 | 0 / 16 / 0 | = |
| `orc:src/bash/tests/wd-login-snapshot.tst.sh` | 01 | 0 / 14 / 0 | = |
| `orc:src/bash/tests/spl-claude-project-slug.tst.sh` | 01 | 0 / 6 / 0 | = |
| `orc:src/bash/tests/spl-owner-digest.tst.sh` | 01 | 0 / 45 / 0 | = |
| `orc:src/bash/tests/spl-issue-stale-sweep.tst.sh` | 01 | 0 / 34 / 0 | = |
| `orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh` | 02 | 0 / 9 / 0 | 0 / 11 / 0 (adds 2) |
| `orc:src/bash/tests/spl-issue-blocker-rca-close.tst.sh` | 02 | 0 / 18 / 0 | = |
| `orc:src/bash/tests/run-eager-files.tst.sh` | 01, 02 | 0 / 14 / 0 | = (both heads) |
| `orc:src/bash/tests/no-literal-paths.tst.sh` | 01, 02 | 0 / 15 / 0 | = (both heads) |
| `orc:src/bash/tests/func-name-unique.tst.sh` | 01, 02 | 0 / 2 / 0 | = (both heads) |
| `iac:src/bash/tests/run-lazy-loader.tst.sh` | 01, 02 | 0 / 30 / 0 | = (both heads) |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 / 0 | = (both heads) |

The column ran on head1 before case 23 was added; case 23 then ran on head1 alone
(58 / 0, rc 0). `shellcheck -S warning -x` on each row's files, base and head: rc 0, no
findings (n=1 each).

**Red controls** (n=1 each):
- Row 01: head1's `spl-push-orphan-check.tst.sh` on base: rc 1, `FAIL: 12. own LEASE_ORCH
  reader left: .../spl-push-orphan-check.func.sh:187: o="$(sed -n 's/^LEASE_ORCH=//p' ...`;
  head1: rc 0. Case 23 passes on base too (rc 0, 58): it pins the behaviour, it is not
  the red control.
- Row 01's guards: head1 with the `declare -F` line deleted from
  `spl-push-orphan-check.func.sh`: case 12 fails
  (`spl-push-orphan-check.func.sh: line 187: spl_owner_digest_lease_conf: command not found`);
  deleted from `spl-agent-login-check.func.sh`: case 23 fails (`line 525: ...: command
  not found`), and `spl-claude-login-mode`, `wd-login-snapshot`, `spl-agent-login-proof`
  stay green (17, 14, 16): only case 23 sees that guard.
- Row 02: head2's `spl-issue-owner-question-diss.tst.sh` on base: rc 1, `1 FAILED`
  (`r90-02: own copy left: 150: if spl_issue_oq_one ...`); head2: `ALL PASS`, rc 0.
- Row 02's guard: head2 with the `declare -F` line deleted: rc 1, `1 FAILED`
  (`r90-02 sourced alone (rc=1)`, no diss write).

The tests that name the sites (R2): `git grep -lE` over the tests for
`spl-agent-login-check|spl-push-orphan-check|_lc_alert_from|_po_from|do_spl_agent_login_check|do_spl_push_orphan_check|spl_owner_digest_lease_conf|spl-owner-digest-post`
-> the 6 suites of row 01 above that name them (`spl-push-orphan-check`, `spl-agent-login-check`,
`wd-login-snapshot`, `spl-claude-project-slug`, `spl-owner-digest`, `spl-issue-stale-sweep`)
plus `run-eager-files.tst.sh` and `orc-shard-weights.txt` (no line needed: no new file);
`spl-claude-login-mode` and `spl-agent-login-proof` are added as callers of
`_lc_alert_from` / sourcers of the file. For
`spl-issue-owner-question-diss|spl_issue_oq_|spl-issue-blocker-rca-close|spl_issue_brc_`
-> the 2 suites of row 02 and `orc-shard-weights.txt`. Plus the loader and name gates of
the table.

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r90-01-orc-lease-orch-reader)` | one fact, one copy (developer guide 2.2.4) | two senders read `LEASE_ORCH` with their own copy of the `lease.conf` reader 6 actions share (1.3) | `orc:src/bash/run/spl-push-orphan-check.func.sh:187`<br>`orc:src/bash/run/spl-agent-login-check.func.sh:525`<br>`orc:src/bash/tests/spl-push-orphan-check.tst.sh` (header, case 12)<br>`orc:src/bash/tests/spl-agent-login-check.tst.sh` (case 23) | inline copies of the reader body for `LEASE_ORCH` in run files 3 -> 1 | 1.3's shape. **Red control:** the head's push-orphan test on the parent FAILs case 12 (1.5), then GREEN; the guard controls (each `declare -F` line deleted: case 12, case 23 fail); outputs in the body. **Behaviour:** the column passes on parent and head with the same counts but the new cases. Tests: `spl-push-orphan-check.tst.sh`, `spl-agent-login-check.tst.sh`, `spl-claude-login-mode.tst.sh`, `spl-agent-login-proof.tst.sh`, `wd-login-snapshot.tst.sh`, `spl-claude-project-slug.tst.sh`, `spl-owner-digest.tst.sh`, `spl-issue-stale-sweep.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 4 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r90-02-orc-owner-question-diss-step)` | one fact, one copy (developer guide 2.2.4) | the owner-question mover keeps a byte-identical copy of the blocker-RCA closer's "comment, then diss" step (1.4) | `orc:src/bash/run/spl-issue-owner-question-diss.func.sh:140,150,162-168`<br>`orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh` (header, 2 checks) | copies of the step body 2 -> 1 | 1.4's shape. **Red control:** the head's test on the parent FAILs (1.5), then GREEN; the guard control (the `declare -F` line deleted: the sourced-alone check fails); outputs in the body. **Behaviour:** equal bodies; the other checks equal on parent and head. Tests: `spl-issue-owner-question-diss.tst.sh`, `spl-issue-blocker-rca-close.tst.sh`, `run-eager-files.tst.sh`, `no-literal-paths.tst.sh`, `func-name-unique.tst.sh`, `iac:.../run-lazy-loader.tst.sh`, `iac:.../bash-cleancode.tst.sh`, `shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads (1.3 / 1.4: the `git grep -n`
of the lines and function names, the body comparison, the sourcing lines) on the
`origin/master` it starts from, and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r90-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r90-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** each row removes a copy and points its caller at the other; no output, exit
code, path or file a caller sees changes (1.3, 1.4, 1.5). Each:
`Docs: none (<why>)`. The developer guide 2.2.4 names the rule, not its instances.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02**, at once: their files are disjoint (row 01: two run files
  and their two tests; row 02: the owner-question mover and its test).
- No row edits `spl-owner-digest-post.func.sh` or any of its other callers,
  `spl-issue-blocker-rca-close.func.sh` or its test, `spl-vendor-terms-check.func.sh`,
  `spl-claude-login-mode.func.sh`, `spl-agent-login-proof.func.sh`,
  `spl-dispatch-lease.func.sh`, `spl-watchdog.func.sh`, the cron scripts of section 7,
  `spool-env.inc.sh`, `test-lib.inc.sh`, `orc-shard-weights.txt`, any `run.sh`,
  `csi-spl-cnf/`, terraform, `csi-spl-api/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Paths (6): `orc:src/bash/run/spl-push-orphan-check.func.sh`,
`orc:src/bash/run/spl-agent-login-check.func.sh`,
`orc:src/bash/tests/spl-push-orphan-check.tst.sh`,
`orc:src/bash/tests/spl-agent-login-check.tst.sh`,
`orc:src/bash/run/spl-issue-owner-question-diss.func.sh`,
`orc:src/bash/tests/spl-issue-owner-question-diss.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-324`, one call per
  path, 2026-11-22T17:15:37Z, n=1: **exit 4 on all 6** ("no live lane lists <path>, but 9
  live lane(s) record no files"). The `unknown:` lanes, all on the other box: c-496
  (search type:calendar), c-593 (the hub wake-off relay flake), c-806 (SPL-6182 native
  auth), and six `*-rotate` seats (c-146, c-499, c-812, c-924, c-927, g-079). No lane is
  reported as owning any of the 6.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 17:16:3xZ): 5 queued,
  0 placing, all held spec 154 rows (B17, B18, B12, B11, B16b: contacts, hub / WUI /
  i18n / step 030). None names a row path. Share line: refactor 2 of 14 known live lanes,
  14% (band 10-20%: ok).
- **Briefs on this box** changed in the last 24 h (133) naming a row file or function
  (`grep -lE 'spl-push-orphan-check|spl-agent-login-check|_po_from|_lc_alert_from|spl-issue-owner-question-diss|spl_issue_oq_one|spl_issue_brc_one'`,
  17:17:02Z): 3, the r88-01 and r88-02 row briefs and the r88-01 reviewer's (a landed
  round: they list `spl-agent-login-check.func.sh` among the slug sites they must not
  touch). None live.
- **Remote branches committed in the last 24 h** (18 besides master after
  `fetch --prune`, 17:16:31Z): `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 6 paths, spl-owner-digest-post.func.sh, spl-issue-blocker-rca-close.func.sh>`
  -> **0 hits**.
- **Commits in the last 24 h** on those 8 paths (`git log origin/master --since=2026-11-21T17:15Z`)
  -> 1: `90522d802` (r88-01), a landed round.
- **Live lanes named in the brief:** SPL-6182 c-806 (hub auth, store, `cmd/spool` tests,
  e2e tooling); spec 154 B8 c-249, B16 c-293 and the held B rows (contacts); SPL-6242
  c-499 (WUI avatar); the wake-off flake c-593 (a hub Go test); search c-496; the review
  seats (g-322, g-264, g-079); the private-channel seats: none on a row path.

## 3. Per row: what the lane does

- **r90-01:** `_po_from` and `_lc_alert_from` read `LEASE_ORCH` through
  `spl_owner_digest_lease_conf`, as 6 actions read `lease.conf`, and load it when their
  file is sourced alone; `spl-push-orphan-check.tst.sh` case 12 proves neither keeps its
  own `sed`, and with case 23 of `spl-agent-login-check.tst.sh` that each guard loads it.
- **r90-02:** `do_spl_issue_owner_question_diss` sets diss through `spl_issue_brc_one`,
  the one copy, and loads it when sourced alone; its test proves the copy is gone and the
  sourced-alone run still moves the MOVE item.

## 4. Panel and reviewers (R7)

- Editor: c-324 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat:** one **cross-vendor** doc seat, asked of the holder (rulebook 3.2; the
  brief's step 5): the queued mistral seat `c002-refactor-round-90-mistral-panel-seat`.
  The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2).
  `BOX_PICK_KIND=grok ./run -a do_spl_box_pick` at 2026-11-22T17:17Z printed
  `pick=<box> reason=<box> is the first box in order below its aim (73% < 80%)`, grok
  weekly 43% on both boxes: **a grok R7 seat per row**. The rows run by night (rulebook
  1.4); the holder re-runs the pick when it places them, and a hold then gives the row a
  **claude waiver seat** (1a7c70da), as r89's section 4 says. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 / 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch |
|---|---|---|---|---|
| r90-01 | `c002-r90-01-orc-lease-orch-reader` | `refactor(r90-01-orc-lease-orch-reader, SPL-<row issue>): ...` | `review/r90-01` | 1 |
| r90-02 | `c002-r90-02-orc-owner-question-diss-step` | `refactor(r90-02-orc-owner-question-diss-step, SPL-<row issue>): ...` | `review/r90-02` | 1 |

**r90-01 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-push-orphan-check.func.sh` (`:187` becomes the guard and
the reader call), `csi-spl-orc/src/bash/run/spl-agent-login-check.func.sh` (`:525` the
same), `csi-spl-orc/src/bash/tests/spl-push-orphan-check.tst.sh` (header and case 12)
and `csi-spl-orc/src/bash/tests/spl-agent-login-check.tst.sh` (case 23). NOT
`spl-owner-digest-post.func.sh` or any of its other callers, NOT
`spl-vendor-terms-check.func.sh`, `spl-claude-login-mode.func.sh` or the cron scripts of
section 7. Do: plan section 2 row 01 verbatim, 1.3's shape; the red control (the head's
push-orphan test on the parent) RED then GREEN in the body; the guard controls (each
`declare -F` line deleted: case 12, then case 23 fail). Gates: the row's tests
(section 2, `SPOOL_TEST=1`, in the worktree), `shellcheck -S warning -x` on the 4 files,
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r90-02 brief, Files: ONLY**
`csi-spl-orc/src/bash/run/spl-issue-owner-question-diss.func.sh` (the guard before
`:140`, the call `:150`, `:162-168` go) and
`csi-spl-orc/src/bash/tests/spl-issue-owner-question-diss.tst.sh` (header and the 2
checks). NOT `spl-issue-blocker-rca-close.func.sh` or its test, NOT
`spl-issue-discard-stale.func.sh` or `spl-issue-stale-sweep.func.sh` (1.4: other
bodies). Do: plan section 2 row 02 verbatim, 1.4's shape; the red control (the head's
test on the parent) RED then GREEN in the body; the guard control (the `declare -F` line
deleted: the sourced-alone check fails). Gates: the row's tests (section 2),
`shellcheck -S warning -x` on the 2 files, `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| inline copies of the reader body for `LEASE_ORCH` in orc run files (1.2 (a)) | 3 on `748282860` -> 1 after row 01 (`spl-vendor-terms-check.func.sh`, section 7) |
| definitions of the "comment, then diss" body (1.4) | 2 -> 1 after row 02 |
| lines (`git diff --stat` of each head) | row 01: 4 files +27 -2; row 02: 2 files +14 -8 |
| measured on | `748282860`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:src/bash/run/spl-vendor-terms-check.func.sh:32` (the third run file's `LEASE_ORCH` read) | no id check follows it: a value such as `-n` is kept by the `sed` but printed empty by the reader's `echo`, so the agent would fall back to `c-001`; pointing it at the reader changes output on that input. A later row with its own test may | 1.3; `sed -n 20,35p` of the file |
| `scripts/cron-no-stack.sh:58`, `scripts/reliability-check-cron.sh:72` (`LEASE_ORCH`) | standalone cron scripts, no source edge to the run tree | r89 7 |
| the other `lease.conf` reads (`topic-status-card.sh:83`, `spl-cost-labels-translate.func.sh:325`, `spl-pool-ctl.func.sh:93`, the `*_DRY_RUN` reads of 3 cron scripts) | another pattern: a character class, the first line (`sed -n 1p`) not the last, or a fixed key in a standalone script; not the reader's body | 1.2 (a) |
| `_po_to` / `_lc_alert_to` (`spl-push-orphan-check.func.sh:175-182`, `spl-agent-login-check.func.sh:514-521`) | the same lines but the tag variable (`PO_TAG` / `LC_TAG`); a shared copy needs a parameter, a shape no row has measured | read on `748282860` |
| `spl_issue_discard_one`, `spl_stale_end_one` | not the same body (another comment text, an argument, WARN lines) | 1.4 |
| `ndf_link` / `ndp_link` (`net-dns-fast-failover.func.sh:71`, `net-dns-pin-and-mask.func.sh:49`, 5 lines, byte-identical) | candidates for a later row: box network actions, run as root on a box; not measured further in v0.1 | r89 1.2 (e) |
| `asks_peers_on` / `send_to_peers_on`; the 7 `_sec_*_need` of `iac:src/bash/run/sec-*.func.sh` | two standalone scripts; over the 5-site cap | r89 7 |
| `spawn_rename_how` (spawn-agy / grok / qwen) | waits for spec 184 row L2 (`spawn-core.inc.sh`) | r89 7 |
| secret-class sets, `tf_get`, `_print_help_actions`, the parameter-expansion slugs, the agent-id regex literal, the r86 Go set | as r89 section 7 says | r89 7, r85 7, r86 7 |
| `spl-lane-mix.func.sh` agy words and flag | behaviour and a rule decision | r89 7 |
| `parse-metadata.func.sh` `${1:?}` lines, terraform `-input=false`, dropped rc | bug rows | r84 7 |
| `topic_loop_fire.go` `!inserted`, `spl-spawn-place-argmax.tst.sh:181-212`, the e2e selector `_ppe_keys` | test rows, a gate-design item | r83 7; candidates file |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred, an open owner decision, behaviour, or the full sweep; unchanged since W | 1.2 (d) |

## 8. Changes

- v0.1 (c-324): the rows and every read on `748282860`; both heads built in scratch
  worktrees; the column of 1.5 run on base and both heads (equal, the new cases added);
  the red and guard controls RED; R3 (2.2) and R7 (section 4) checked.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-324 (claude): v0.1.
- Panel reviewer seat: the queued mistral seat
  (`c002-refactor-round-90-mistral-panel-seat`): pending.
- Row R7 seats: section 4.
