# Refactor round 10 (2026-11-27) - panel seat claude (c-420)

Seat: `c-420`, claude, cross-vendor panel seat (rulebook 3.2), placement
`c003-refactor-round-10-claude-panel-seat`, issue SPL-6649.

Plan read: `csi-spl-doc/doc/md/refactor-round-10-20261127-plan.md` on
`review/c003-refactor-round-10-planner` at **v0.1
`25212ee7fcdfd8749290f1479bbefb232de8af48`** (ls-remote at 06:47Z and 06:55Z:
same sha). Plan file sha256 `56fc79e058b3cdd0...` (`git show <sha>:<plan> | sha256sum`).
Plan base `84f86ab8c`; origin/master at review time `31a526346` (2 commits past base).

## Verdict: FAIL on `25212ee7`

Both rows are sound refactors and both red controls fail for the right reason.
v0.1 fails on three fixable plan defects: one reproducibility claim is wrong
(W1), the plan picks row 02 without answering why rounds 98 and 99 deferred it
(W2), and the "zero behaviour change" claim of row 01 is not exact (W3). Fix
W1 to W3 and this seat expects to sign v1.0.

Method: scratch clones of `84f86ab8c` (base, head1, head2, rc1, rc2) built from
the plan's verbatim blocks by line range (plan `:254-304`, `:309-322`,
`:327-339`, `:345-346`, `:349-411` for row 01; `:466-493`, `:498-503`,
`:510-511`, `:514-575` for row 02), at the insertion points the plan names.
Tests ran as the agent user, `SPOOL_TEST=1`, `SPOOL_BOX_TAG` and `SPOOL_AGENT_ID`
unset, stdin `/dev/null`, n=1 each. Pass and fail counts use the plan's greps
(`grep -ciE '^ *(ok|pass)'` and `grep -ciE '^ *(not ok|fail)'`).

## 1. Checks

### 1.1 Slug r10 unused since W (check 1)

- `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r09-plan'` ->
  `e91066a01... 2026-11-27T03:05:11+02:00 docs(r09-plan, SPL-6632): refactor round 09 closed: ...`:
  W matches plan `:87`.
- `git log origin/master --since="2026-11-27T03:05:11+02:00" --oneline -E --grep='\(r10-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r10-[0-9]{2}|refactor-round-10-2026|refactor-round-10'` ->
  `25212ee7... refs/heads/review/c003-refactor-round-10-planner` and
  `b8d8c4528... refs/heads/wip/fix/r10-05-helper-path`. Nothing else.
- The other 2 old-cycle heads do not match that regex (`r10-session`, `r10-mistral`).
  `git ls-remote origin` on each name -> `30fa039da...
  review/c002-wui-con-r10-session-check-signed-out` and `0c6f50f9b...
  wip/m-524-r10-mistral-review-seat`. Their tips (`git log -1 --format=%cI`):
  `2026-10-31T03:49:36+02:00`, `2026-10-15T00:46:33+03:00` (r10-05) and
  `2026-10-14T23:38:19+03:00`. All 3 match plan `:101-109`, sha and tip date,
  and all 3 are before W.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r10-[0-9]{2}|refactor-round-10-2026'`
  on this seat's box -> 15 `c001-r10-0N-*` old-cycle files (mtimes 2026-10-14T20:27Z to
  2026-10-15T02:01Z, all before W). This cycle's planner and panel briefs are not
  in this box's briefs dir (they live on sat and in `/var/spool-hub/c-420/lifetime/brief.md`).
  This agrees with plan `:133-143`, which says the listing is local to the planner box.

Result: pass.

### 1.2 Sites exist on base and on origin/master (check 2)

`git show 84f86ab8c:<file> | sed -n <N>p`, n=1 each:

| site | first line | last line | file wc |
|---|---|---|---|
| `orc:run/install-agy-cli.func.sh:23-57` | `do_install_agy_cli() {` | `}` | 57 |
| `orc:run/install-mistral-vibe.func.sh:25-53` | `do_install_mistral_vibe() {` | `}` | 53 |
| `orc:run/install-openai-codex.func.sh:28-56` | `do_install_openai_codex() {` | `}` | 56 |
| `utl:run/reboot-required-check.func.sh:82-103` | `# _rrc_send <from> ...` | `}` | 229 |
| `utl:run/cron-heartbeat-snitch.func.sh:201-222` | `# _chs_send <from> ...` | `}` | 459 |
| `orc:tests/install-agy-cli.tst.sh:17,122` | `#      an agy below 1.3.4 is not refused: ...` | `echo "---"; [[ $fails -eq 0 ]] ...` | 122 |
| `utl:tests/reboot-required-check.tst.sh:18,205` | `#  13. Through the csi-spl-utl ./run harness ...` | `echo "======..."` | 208 |

Drift: `git diff --name-only 84f86ab8c origin/master -- <the 7 row files + 3 sibling tests> | wc -l`
-> `0` (origin/master `31a526346`). Result: pass.

### 1.3 Red controls (check 3)

| control | sha256 | base: rc / pass / fail, last line | head: rc / pass / fail |
|---|---|---|---|
| rc1 = head1 `install-agy-cli.tst.sh` | `63e7a2d81d1dd866f0d66079b5e1b3c2b32e0ae9244f8abca9bfa6836767cf34` | `1 / 14 / 8`, `8 FAILED` | `0 / 22 / 0`, `ALL PASS` |
| rc2 = head2 `reboot-required-check.tst.sh` | `42c0579ceea6618629ab091a63bb585c259a586c85075b21d5eb574fe35c43bc` (plan says `280ed77bd391`: W1) | `1 / 15 / 5`, `reboot-required-check: 5 failure(s)` then `=====` | `0 / 20 / 0` |

Why they fail. rc1 fails with 5 `_spl_agent_cli_prep: command not found` /
`_spl_agent_cli_exec: command not found` (rc 127 inside), plus `FAIL: 9: host`,
plus `FAIL: 9: install-mistral-vibe.func.sh own=[30: ... cannot read <org>-<app> ...`
and `... install-openai-codex.func.sh own=[33: ...`. rc2 fails with 3
`_utl_send_spool_note: command not found`, plus `FAIL: 14. host check`, plus
`FAIL: 14. chs delegate: own=[205: local orc_send=...`. Both fail because the
helper is missing, which is the plan's reason (plan `:625-635`). Neither fails
for an environment reason.

Live state: neither touches it, by reading. rc1's `$T` comes from
`test-lib.inc.sh:43` (`T=$(mktemp -d); trap 'rm -rf "$T"' EXIT`). Its agent home
is `$T/agent-home`, its spool is `$T/spool` and its installers are `$T` stubs.
rc2's `$T` is `mktemp -d` with an EXIT trap (`:32-33`), every send goes to a `$T`
stub or `$T/spool14`, and the missing-sender cases restrict `PATH`.
`SPOOL_TEST=1` did not fire the live-root guard (no exit 96).

The head and base suites match plan 1.5 for every suite I ran:

| suite | base | head |
|---|---|---|
| `install-agy-cli` | 0/12/0 | 0/22/0 |
| `install-mistral-vibe` | 0/26/0 | 0/26/0 |
| `install-openai-codex` | 0/25/0 | 0/25/0 |
| `reboot-required-check` | 0/13/0 | 0/20/0 |
| `cron-heartbeat-snitch` | 0/17/0 | 0/17/0 |
| `print-help` | 0/4/0 | 0/4/0 |
| `orc reliability-checks-cron` | 0/9/0 | 0/9/0 |

NOT RUN by this seat: the iac and orc gate suites of 1.5
(`run-eager-files`, `no-literal-paths`, `func-name-unique`, `bash-cleancode`
and the rest), the 6 mutation checks, and `do_sec_shellcheck`. They are the row
lane's gates.

`shellcheck` 0.10.0 `-S warning -x` on head1's 4 files and on head2's 3 files ->
rc 0 and rc 0.

### 1.4 Equivalence (check 4)

**Row 01.** I read base `install-agy-cli.func.sh:23-57`,
`install-mistral-vibe.func.sh:25-53` and `install-openai-codex.func.sh:28-56`
against the head blocks. I also ran a sweep, base vs head1: 3 actions x 5 cnfs
(good, empty `box: {}`, malformed yaml, `version: latest`, missing file) x
`DRY_RUN` unset/0/1/2 x installer rc 0/3 x home present/missing. That is n=240
cases per tree, with a recorder installer and the real `yq`.

- `diff` of the two outputs: 16 lines differ. With `grep -v 'Error: bad file'` on
  both, the outputs are IDENTICAL, rc included. All 16 are the mistral
  malformed-cnf cases: base prints the yq error twice, head1 prints it once (W3).
- The 16 come from the order of the reads. Base `install-mistral-vibe.func.sh:35`
  reads `model` with yq before the pin check, so on a malformed cnf yq fails
  twice. Head1 reads `model` only after `_spl_agent_cli_prep` has returned, and
  prep returns 2 on the empty pin, so the second yq call never runs. Exit code
  (2) and the FATAL line are the same.
- On a valid cnf the model read has no output, and its order does not matter.
- The rest is kept. Messages (`pin_noun` gives `one X.Y.Z` / `one pinned X.Y.Z`),
  the yq default expressions, the `DRY_RUN` defaults (1/0/1), exits 1/2/4, `HOME`
  and env forwarding, and `${dry:+, DRY RUN}` all match, because prep writes the
  caller's `dry` through bash dynamic scope.
- One extra change: the global `as_agent` that base `do_install_agy_cli` used to
  leave defined is no longer defined. `git grep -n as_agent 84f86ab8c -- csi-spl-orc`:
  every other `as_agent` (`spl-agent-mcp-gcp-alerts-install.func.sh:53`,
  `spl-agent-mcp-install.func.sh`) is its file's own definition. No caller
  depended on the leak (N2).
- Would the controls catch a difference? Yes for the defaults, env and exec
  (mutations m1a, m1b and m1c in the plan; I did not re-run them). No for
  message or ordering drift: no check compares the FATAL texts of mistral or
  codex beyond what their own suites hold (both pass unchanged, 26 and 25).

**Row 02.** I read base `reboot-required-check.func.sh:82-103` and
`cron-heartbeat-snitch.func.sh:201-222`. The two bodies are byte-equal except
the override var and the label. The helper body is the same code with
`send_bin` and `missing_label` as parameters. Resolution order, `-f` test, WARN
texts, `SPOOL_ROOT` default, flags and returns are kept.

The lazy `source` of `reboot-required-check.func.sh` from `_chs_send` runs only
3 statements at top level: `:48` (`type do_log || do_log(){...}`, a no-op when
`do_log` exists), `:51` (`declare -F spl_box_name || source ...`, already
loaded by chs `:68`) and `:227-229` (it registers
`_func_to_file[do_os_reboot_required_check]` to its own path, only under
`./run`). It has no main guard to fire, and the two files share no function
names: `comm -12` of their `^name()` lists is empty.

`cron-heartbeat-snitch.tst.sh` passes 17/0 on head2, as on base.

Result: row 02 equivalent. Row 01 equivalent in exit codes, stdout and defaults,
but not byte-exact on stderr for a malformed cnf (W3).

### 1.5 Row form (check 5)

- Both rows give a red control that fails today and passes after (R2), a test
  list, vendor claude, kind `simple_coding` and batch 1 (plan `:684-685`).
- No mistral row; R7 is an agy seat with the claude waiver backup under
  `dc84300a` and never mistral (plan `:791-805`, `:844-846`, `:863-865`).
- R1: row 01 edits 4 `csi-spl-orc/` files and row 02 edits 3 `csi-spl-utl/`
  files, disjoint.

Result: pass.

### 1.6 R3 lane map (check 6)

`bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 7 row paths> --agent c-420`
at 2026-11-27T06:55:28Z -> **exit 4**, 0 owning lanes. It listed 8 `unknown:`
lanes, all on sat: `a-546` (planner), `a-548` s185 planner, `a-556` SPL-6646
reviewer, `c-272` SPL-6617, `c-307` b52-03 `spawn-remote`, `c-309` s181 invoice,
`c-312` issues select, `c-314` T083 hours strip. By slug, none is on an
installer wrapper or a utl reliability check.

A 200-branch scan of the newest origin refs (`git diff --name-only $(git
merge-base 84f86ab8c <b>) <b> -- <7 row files>`) gave **0 hits**. The plan's
queue and brief reads (`:751-758`) are the holder's; I did not re-read them.
Result: no row file is touched by a live lane. As 2.7.3 says, the holder
re-reads the map at placement.

### 1.7 Inputs accounted for (check 7)

`/var/spool-hub/dispatch/c002-next-round-candidates.md` (read on sat via
`ssh satellite 'sudo -n cat ...'`, 173 lines). I grepped it for refactor-shaped
lines:

- Lines 113, 115, 125, 147-148 and 153-173 are in plan section 7 (`:889`).
- Line 1 (`spl-watchdog.func.sh:72` literal) is served on master:
  `:72` is now `default spl_claude_login_state_dir`.
- Line 25 (`reverse-tunnel-cron.sh:23` literal) is served: it now derives the
  dir with `spl_run_paths`.
- Line 48 (agent-boot-restore literal) is served:
  `spl-agent-boot-restore-install-cron.func.sh:31` says
  `default <SPL_VAR_APP_DIR>/agent-boot-restore`.
- Line 76 (`spl-desk-reply.sh` usage kinds) is served by `3174e591a`
  (r81-01).
- Line 104 (`spl-lane-mix` "final word"):
  `git grep -c 'final word' origin/master -- csi-spl-orc/src/bash/run/spl-lane-mix.func.sh`
  -> no hits, so it is served.

r09 section 7 (`refactor-round-09-plan.md:834-835` on origin/master): #1 is row
01, and #2 is carried in r10 section 7 (`:887`).

**Not accounted for:** row 02's site is a prior left-out. r98 section 7
(`refactor-round-98-plan.md:756`) and r99 section 7
(`refactor-round-99-plan.md:838`) kept `_chs_send` / `_rrc_send` out because
"touching `csi-spl-utl/**` classifies as `parts=all` in CI (`utl-suite.tst.sh:4`)".
That still holds on `84f86ab8c`:

- `utl-suite.tst.sh:4` reads `# job of its own; a push touching csi-spl-utl/** classifies as parts=all`.
- `ci-doc-only.sh:124` reads `*)  echo all ;;` (no `csi-spl-utl/*` case).
- `bash ci-doc-only.sh 28ed98f7a^ 28ed98f7a` (the last utl-touching commit) ->
  `parts=all`, with `csi-spl-utl/src/bash/run/sweep-tmp-worktrees.func.sh needs the full gate`.

The v0.1 plan presents the pair as newly "surfaced" by a scan (`:159-165`) and
does not cite r98 or r99 or answer that reason (W2).

No row changes an exit code, a path or a default. Row 01 changes one stderr
repetition on a malformed cnf (W3).

### 1.8 Hygiene (check 8)

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` (worktree on `31a526346`) ->
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/c-420`, rc 0.

## 2. Defects

- **W1 (plan `:456`, `:460`, `:76-79`).** Head2's test file cannot
  be rebuilt byte-for-byte from the verbatim block. The plan's recipe (insert
  `:514-575` plus one blank line before base `:205`, header `:510-511` after
  `:18`) gives `+65 -0`, 273 lines and sha256 `42c0579ceea6`. The plan says
  `+66`, `208 -> 274` and `280ed77bd391`. 3 placement variants (blank before,
  two blanks after, extra header line) give `3b715b7c5a6a`, `4b85959b3730` and
  `cb03166a5731`, none of them the plan's. Head1's 4 sha256 and all other
  numstats do reproduce (`c4be5c07a861`, `9a20298cf130`, `31a4d618289f`,
  `63e7a2d81d1d`; `+38-22`, `+7-22`, `+6-22`, `+66-0`, `+11-5`, `+3-19`).
  Fix: correct the sha, the count and the line total, or publish the missing
  line. The row lane and R7 are told to check this sha.
- **W2 (plan `:159-165`, section 7 `:879-890`).** Row 02 goes against an earlier
  left-out without naming it. r98 `:756` and r99 `:838` deferred this exact pair
  for `parts=all` CI cost. Row 02 still triggers `parts=all` (1.7, n=1 on
  `28ed98f7a`). Fix: cite r98 and r99 and say why the cost is now accepted, or
  move row 02 out. Rounds since r99 have landed utl rows, so accepting it is
  plausible; the plan has to say it.
- **W3 (plan `:207`, `:414-418`).** "Exact validation ordering, exact ...
  messages" is not true for mistral. Base reads `model` (`install-mistral-vibe.func.sh:35`)
  before the pin check; head1 reads it after prep. On a malformed cnf base prints
  yq's `Error: bad file ...` twice and head1 prints it once, with the same rc 2
  and the same FATAL line (16 of 240 sweep cases, 1.4). Fix: state this one
  stderr difference in 1.3 "Behaviour" as an accepted deviation. Keeping the old
  order would need the model read inside prep, which is worse.

## 3. Notes

- **N1.** Plan `:161-163` cites `_rrc_send` `:83-103` and `_chs_send` `:202-222`,
  but the row table and 1.4 use `:82-103` and `:201-222` (with the comment line).
  Use one form.
- **N2.** Row 01 also drops the global leak of `as_agent` from
  `do_install_agy_cli`. No caller relied on it (1.4); worth one line in 1.3.
- **N3.** The lane map at 06:55Z shows 8 `unknown:` lanes, where the plan's
  06:30Z run showed 24. The holder's placement re-read is the one that counts.
- **N4.** The `sudo -n -u` branch of `_spl_agent_cli_exec` is covered by no
  hermetic check (tests run as the agent user itself). That is the same as base,
  so this is not a defect.

<!-- last reviewed sha: 25212ee7fcdfd8749290f1479bbefb232de8af48 (v0.1) -->

## 4. v1.0 re-review: FAIL on `978c1bee`

Plan v1.0 is `978c1bee61fcc405452e17ff0cb6c7b7d0cb9e8a` (the
`git ls-remote origin refs/heads/review/c003-refactor-round-10-planner` result).
It is one commit on v0.1: `978c1bee6 docs(r10-plan, SPL-6649): refactor round 10
plan v1.0 (fold panel W1-W3, N1-N4)`, `1 file changed, 58 insertions(+), 19
deletions(-)`.

- **Rows unchanged:** I extracted the 9 fenced `bash` blocks of v0.1 and v1.0
  with a python regex: `9 9 True` (byte-identical). The heads, red controls and
  sweep of sections 1.3 and 1.4 therefore stand as measured on v0.1.
- **Drift:** `git diff --name-only 84f86ab8c origin/master -- <7 row files> | wc -l`
  -> `0` (origin/master `836ec3c7c`).
- **W1 fixed:** `:467` `+65 -0`, `208 -> 273`, and `:471`
  `reboot-required-check.tst.sh` `42c0579ceea6`. `280ed77bd391` now appears only in
  the changelog (`:922`).
- **W2 fixed:** 1.2 (a), 1.4 and section 2 name `ci-doc-only.sh:124`,
  `28ed98f7a`, r98 `:756` and r99 `:838`, and accept the one `parts=all` run.
- **N1 fixed:** `:165-166` now read `:82-103` and `:201-222`.
  **N3 fixed** (2.2).
- **W3 folded into the row table only.** Row 01's table cell (`:695`) now says
  `accepted deviation W3 in 1.3 ... prints yq stderr once instead of twice`.

**W4 (plan `:420-424`, `:927-932`).** Section 1.3 does not carry the folds the
changelog says it does. 1.3's **Behaviour** paragraph (`:420-424`) is unchanged
from v0.1 and still says `preserve exact validation ordering, exact
FATAL/INFO/FAIL/OK messages`. The row table it points to (`:695`, "W3 in 1.3")
contradicts that sentence.

`git show 978c1bee6:<plan> | sed -n 198,425p | grep -niE 'leak|stderr|deviation|untested'`
-> one hit only, `:225` `... never read or leaked;`. That is the old secrets
sentence. So neither the W3 deviation nor N2 (`as_agent` leak) nor N4 (untested
`sudo -n -u` branch) is in 1.3, though changelog `:927-932` says
"(1.3) stated" and "(1.3) noted".

Fix: in `:420-424`, replace "exact validation ordering, exact ... messages" with
the W3 deviation, and add the N2 and N4 lines. Nothing else needs to change. This
seat signs the next sha that does this, if its 9 fenced blocks stay
byte-identical.

<!-- last reviewed sha: 978c1bee61fcc405452e17ff0cb6c7b7d0cb9e8a (v1.0) -->

## 5. v1.1 sign-off: PASS on `1549aaf3`

Plan v1.1 is `1549aaf35839f3515386c8692de529539f0685e9` (the
`git ls-remote origin refs/heads/review/c003-refactor-round-10-planner` result).
It is one commit on v1.0: `1549aaf35 docs(r10-plan, SPL-6649): refactor round 10
plan v1.1 (fold panel W4)`, `37 insertions(+), 14 deletions(-)`.

- **Rows unchanged:** the fenced `bash` blocks of v0.1 vs v1.1 compare as
  `9 9 True` (byte-identical).
- **Drift:** `git diff --name-only 84f86ab8c origin/master -- <7 row files> | wc -l`
  -> `0` (origin/master `836ec3c7c`).
- **W4 fixed:** 1.3's Behaviour paragraph (`:420-428`) now states the W3
  deviation in place of the old exact-ordering claim. N2 (`:429-431`) and N4
  (`:432-434`) are present. `sed -n 198,440p | grep -niE 'leak|stderr|deviation|untested|exact validation ordering'`
  -> the W3, N2 and N4 lines plus the old secrets sentence; no `exact validation ordering`.

This seat signs `1549aaf35839f3515386c8692de529539f0685e9`. W1 to W4 are closed
and nothing blocks. Two wording slips in the new text do not touch any row; fold
them into the retro or the next edit:

- **N5 (`:429-431`).** Base does not "set `as_agent` as an unlocal shell variable".
  `do_install_agy_cli` defines a nested **function** `as_agent()`
  (`install-agy-cli.func.sh:45-48` on `84f86ab8c`), which stays global after the
  call. Only the agy wrapper has it: `grep -n as_agent` on mistral-vibe and
  openai-codex -> 0 lines.
- **N6 (`:422`).** On head1 the `model` query runs after the whole of
  `_spl_agent_cli_prep` succeeds (pin, `DRY_RUN`, agent user and home), not
  only after the `version` check.

<!-- last reviewed sha: 1549aaf35839f3515386c8692de529539f0685e9 (v1.1, signed) -->
