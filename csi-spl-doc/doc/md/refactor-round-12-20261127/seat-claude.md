# Refactor round 12 (2026-11-27) - panel seat claude (c-999)

Seat: c-999 (claude, placement `c002-refactor-round-12-claude-panel-seat`), cross-vendor
panel seat of rulebook 3.2 for the agy editor a-731. Issue SPL-6696.

## Verdict

**PASS** on plan v0.1 `85d7115d9c5dd023c7b5b09b29542b7c3012dc6b`
(`csi-spl-doc/doc/md/refactor-round-12-20261127-plan.md`, branch
`review/c002-refactor-round-12-planner`), with W1 and W2 to fold into v1.0. Neither
changes a row's shape: both rows are one logical refactor with no behaviour change, and
both heads rebuild exactly from the plan's blocks.

Sha read: `git ls-remote origin refs/heads/review/c002-refactor-round-12-planner` ->
`85d7115d9c5dd023c7b5b09b29542b7c3012dc6b`, the sha a-731 named (msg 593a0970). The
plan commit touches 1 file (`git show --stat 85d7115d9` -> the plan, 929 insertions) and
sits on `origin/master` `aad64bd31` (`git merge-base origin/master 85d7115d9`). Base of
the plan: `3308d118f5516427b8c1b29b91e61e43899d0f8f`.

How it ran: 2026-11-27 17:20Z-17:56Z, n=1 per command unless stated, as the agent OS user in
scratch clones of `3308d118f` (`base`, `head1`, `head2`, `rc1`, `rc2`, the mutants
`x1`-`x4`; never committed, never pushed), tests with `SPOOL_TEST=1`,
`SPOOL_BOX_TAG` / `SPOOL_AGENT_ID` unset, stdin from `/dev/null`; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'` (the plan's
counting, 1.5).

## 1. Slug r12 unused since W

- `git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r11-(plan|close)'` ->
  `09907e7860ce8fcec5effc92e636ff53c599d587 2026-11-27T14:35:12+02:00 docs(r11-plan, SPL-6676): ...`,
  the plan's `W=2026-11-27T14:35:12+02:00` (plan line 96).
- `git log origin/master --since="2026-11-27T14:35:12+02:00" --oneline -E --grep='\(r12-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r12-[0-9]{2}|refactor-round-12-2026'` -> nothing, rc 1.
  `git ls-remote origin | grep -E 'refactor-round-12'` -> only
  `refs/heads/review/c002-refactor-round-12-planner` (the planner's branch, expected).
  My seat branch did not exist yet at that read.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r12-[0-9]{2}|refactor-round-12-2026'` on
  this box -> 11 files: `c002-r12-01-*` to `c002-r12-10-*` and
  `sathand-c002-r12-05-wui-small-create-spool-client.md`. The plan's wider grep (plan
  line 121) -> 16 files, the same 16 the plan lists at lines 125-130. Nothing else.
  Neither this seat's brief nor the planner's is in this box's `dispatch/briefs` (this
  seat's brief is `spawn-remote/briefs/cf395566-...md`). See N1 for the dates.

## 2. Sites on base and on origin/master

- Drift: `git diff --name-only 3308d118f origin/master -- <the 6 row files and the 4
  sibling tests>` at `origin/master` `aad64bd31` -> 0 lines.
- Each cited range, read with `git show 3308d118f:<file> | sed -n <N>p`:
  - `check-hub-deploy.func.sh:41` = `# do_hub_deploy_verify_gcp - the Cloud Run check
    (today's body, unchanged)`, `:42` = `do_hub_deploy_verify_gcp() {`, `:43` =
    `do_require_bin yq || return 1`, `:58` = `return 1; }` (the describe's error branch).
    177 lines.
  - `check-hub-image-regress.func.sh:39` = `do_check_hub_image_regress() {`, `:40` =
    `do_require_bin yq || return 1`, `:55` = `return 1; }`. 92 lines.
  - `spl-desk-doctree.func.sh:137-148` = `_spl_desk_doctree_split` (comment + body),
    `:150-173` = `_spl_desk_doctree_in`. 295 lines.
  - `spl-desk-wsdoc.func.sh:102-113` = `_spl_desk_wsdoc_split`, `:115-141` =
    `_spl_desk_wsdoc_check` (untouched by the row), `:143-166` = `_spl_desk_wsdoc_in`,
    `:64-65` = the existing lazy source of `spl-desk-doctree.func.sh`. 166 lines.
  - `check-hub-deploy.tst.sh` 255 lines, `desk-doctree.tst.sh` 208 lines (base sha256
    12-char prefixes `60b1cff94da4`, `4a26b54fc67c`).
- All cited lines match, except the "identical" claim of W1.

## 3. Red controls

Each one was rebuilt from the plan's 9 fenced blocks (1.3, 1.4) by a script applying
them at the cited lines. The rebuilt heads match every sha256 the plan gives:
`check-hub-deploy.func.sh` `93d035e70cfa`, `check-hub-image-regress.func.sh`
`740f45d9af0d`, `check-hub-deploy.tst.sh` `6bc080c88cb0`, `spl-desk-doctree.func.sh`
`81e07447278c`, `spl-desk-wsdoc.func.sh` `7570f316a395`, `desk-doctree.tst.sh`
`71736fd8a0dc`.

| control | sha256 of the control file | on | rc | pass / fail lines | last line |
|---|---|---|---|---|---|
| rc1 = head1 `check-hub-deploy.tst.sh` | `6bc080c88cb096bb4a437b5522f55d9a382af4eb1e474bcc35f82430cdb3e6ad` | base | 1 | 57 / 6 | `FAILED: 5` |
| same | same | head1 | 0 | 63 / 0 | `PASS: all check-hub-deploy assertions` |
| rc2 = head2 `desk-doctree.tst.sh` | `71736fd8a0dc44d96144257b97071b5f8f1d3721f57bf146f2f4eb0dba3d67e9` | base | 1 | 39 / 10 | `desk-doctree: 10 failure(s)` |
| same | same | head2 | 0 | 49 / 0 | `desk-doctree: 0 failure(s)` |

- They fail for the reason the plan gives, not for an environment reason. rc1: 3
  `_spl_hub_run_describe: command not found` (rc 127), `FAIL: 8: host check`, and
  `FAIL: 8: chir own=[42: do_gcp_pin_account ...` (base's own preamble copy). rc2: 3
  `_spl_desk_args_split: command not found`, 5 `_spl_desk_in_file: command not found`,
  `FAIL: 11: host`, and `FAIL: 11: wsdoc own=[107: local raw="${WSDOC_ARGS:-}" split=...`.
  The 2 (row 01) and 3 (row 02) standalone checks PASS on base, which is the plan's
  equivalence claim.
- Live state: none touched. `check-hub-deploy.tst.sh` puts a `gcloud` stub first on
  PATH that answers `run services describe` from `$FIXTURE` (`exit 1` on anything
  unknown). Section 8 sets `GCP_ACCOUNT=op@example.com`, so `_do_gcp_pin` skips the key
  file and the config isolation (`orc:lib/bash/funcs/gcp-account-pin.func.sh:270-272`).
  `desk-doctree.tst.sh` writes only under its `mktemp -d` dirs (`trap 'rm -rf "$T" "$IN"'
  EXIT`, head2 line 45) and reads `/etc/hostname` for the outside-roots case. The cnf
  is read, never written.

## 4. Equivalence

**Row 01.** The helper body is base `check-hub-deploy.func.sh:43-58` with the `local`
line taken out. Each caller now declares `local svc="" json="" ...` before the call
(head1 `check-hub-deploy.func.sh:62`, `check-hub-image-regress.func.sh:40`), and the
helper's assignments land in those locals through bash's dynamic scope.
- Unchanged: the same output, the same exit codes, the same `FATAL` texts, and the same
  `gcloud` argv.
- The scope of everything else is unchanged too. `do_gcp_isolate_config` sets an EXIT
  trap (shell-wide) and exports `CLOUDSDK_CONFIG` and `GCP_ACCOUNT` (global), and none
  of the four action files runs anything at top level (an awk pass over each file on
  base printed no non-function line). So sourcing `check-hub-deploy.func.sh` from inside
  `do_check_hub_image_regress` defines functions only. The only definitions it adds are
  `check-hub-deploy.func.sh`'s own 4 functions, with no clash.
- The one change is the stderr tag the plan accepts (plan lines 370-374).
  `_do_gcp_pin` passes `${FUNCNAME[2]}` (`gcp-account-pin.func.sh:275`), which is
  `do_gcp_pin_account`'s caller, now `_spl_hub_run_describe`. No test greps that tag:
  all 13 column suites are equal on base and head1.

**Row 02.** `_spl_desk_args_split` and `_spl_desk_in_file` are base
`_spl_desk_doctree_split` / `_spl_desk_doctree_in` with the env var name and the hint
(or the required-empty message) passed in. `${!2:-}` reads the named env var.
- Each `FATAL` text renders byte-for-byte as in base for both `DOCTREE_*` and `WSDOC_*`.
- `_spl_desk_wsdoc_in`'s required-empty FATAL comes from the third argument. Its text,
  `write needs WSDOC_IN: the body file`, is base `spl-desk-wsdoc.func.sh:151`.
- The namerefs are safe. The callers pass `args` and `in` (`spl-desk-doctree.func.sh:69,76`,
  `spl-desk-wsdoc.func.sh:53,57`). Neither collides with a helper local (`_da_out`,
  `var`, `hint`, `raw`, `split`, `_di_out`, `req`, `real`, `root`, `ok`).
- The wsdoc file now sources the doctree file inside `_spl_desk_wsdoc_split`, earlier
  than base's `:64-65`. That is safe because the doctree file runs nothing at top level,
  so the later `declare -F _spl_desk_doctree_seated` guard finds it already defined.

**Would the controls catch a difference?** Yes for the plan's 6 mutations (re-run of
rc1 and rc2 above). My own 4 mutations, each one line, n=1:
- x1: the helper drops `--region="$SPL_REGION"`. `check-hub-deploy.tst.sh` rc 0, 63/0;
  `check-hub-image-regress.tst.sh` rc 0, 15/0. **Not caught** (W2).
- x2: the helper's FATAL `cannot describe` becomes `cannot read`.
  `check-hub-deploy.tst.sh` rc 1, 60/3. Caught.
- x3: `_spl_desk_in_file` drops the `/var/spool-hub/dispatch` root. `desk-doctree.tst.sh`
  rc 0, 49/0; `desk-wsdoc.tst.sh` rc 0, 28/0. **Not caught** (W2).
- x4: `_spl_desk_args_split`'s `FATAL $var is empty` reworded. `desk-doctree.tst.sh`
  rc 0, 49/0; `desk-wsdoc.tst.sh` rc 0, 28/0. Not caught. This one matters less: a
  non-blank string that parses always splits into at least 1 word, so that branch is
  practically unreachable (N4).

## 5. Row form (R1, R2, vendors)

- Row 01 and row 02 each carry a control that fails today and passes after (section 3),
  a test list, vendor claude, kind `simple_coding`, batch 1 (plan line 709 table).
- No mistral row, coding or testing. The R7 of each row is an agy seat, with claude only
  as the waiver backup under ruling `dc84300a`, never mistral (plan lines 815-819,
  862-864, 882-884).
- R1: batch 1's file sets are disjoint (plan lines 729-735: 3 + 3 files, none shared).
- The test column: all 13 suites of 1.5 per row, run on base and on each head, give the
  same rc and the same counts as the plan's table (base orc/iac 15, 9, 44, 28, 3, 2, 14,
  15, 2, 10, 6, 17, 30, 15, 48 pass, all rc 0, every head equal). `shellcheck 0.10.0 -S
  warning -x` on the 3 files of each head: rc 0, from `src/bash/run` and from the module
  root. See N2 for the 8 tests the column leaves out.

## 6. R3

- `bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh
  --check <the 6 row files> --agent c-999` at 2026-11-27T17:54:33Z -> **exit 4**, no lane
  owns a row file, and 3 `unknown:` lanes:
  - `a-731@sat` is the planner. Its only commit, `85d7115d9`, touches the plan file
    alone.
  - `c-651@sat` (`c651-parts45`): its branch `review/c651-spl6680-parts45`
    (`bf84308c5`) changes 15 files, 0 of them row files (`git diff --name-only
    $(git merge-base origin/master FETCH_HEAD) FETCH_HEAD`).
  - `c-738@sat` (`c-738-c002-6a27166d-agy-quota-model-fallback`) is not in the plan's
    17:13Z list (plan lines 757-770). It has no remote branch and its brief is not on
    this box, so I cannot show its files: N3.
- The plan's other R3 reads (queue, briefs, 162 remote branches, 48 h commits) are its
  own; my reads above are the ones I ran.

## 7. Inputs accounted for

- r11 section 7 (`refactor-round-11-20261127-plan.md:1064-1076` on origin/master): every
  row there has its row in r12 section 7 (plan lines 902-909).
  - r11 pointed two of them at "r12 after a lint fix": `orphan-process-reap` and
    `systemd-unit-health` + `cloud-sql-backup-verify`. The lint findings still stand on
    base: `shellcheck -S warning -x orphan-process-reap.func.sh` -> `line 208 ... SC2071
    (error)`, and `cloud-sql-backup-verify.func.sh` -> `line 125 ... SC2155 (warning)`.
    `git log origin/master --since='3 days ago' -E --grep='SC2071|orphan-process-reap|SC2155'`
    -> nothing. So the deferral holds, but nothing yet clears the way for those rows: N5.
- The candidates file, `/var/spool-hub/dispatch/c002-next-round-candidates.md`, is
  **NOT RUN** here: it does not exist on this box (`wc -l` -> `No such file or
  directory`; the plan says it is local to the planner's box, line 184). I checked the
  plan's "already served" claims instead, on base:
  - `spl-desk-reply.sh:9,19` list all 12 kinds.
  - `spl-agent-boot-restore-install-cron.func.sh:60` and `spl-watchdog.func.sh:541` use
    `spl_var_app_subdir ... agent-boot-restore`.
  - `git grep -nE 'needs_agy_review|agy has the final|waits for an agy' -- csi-spl-orc/src/bash/run/`
    -> 0 lines.
  - `git grep -n 'Lang-review a-NNN' | wc -l` -> 0.
  - `git grep -n 'send_to_peers_on' -- csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh`
    -> 0 lines.
  These hold. The plan's commands, though, give other numbers as written: N6.
- No row changes an exit code, a message, a path or a default (section 4). The one
  stderr context tag is the plan's own accepted note. Both rows are refactor rows, not
  bug rows.

## 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` on a scratch checkout of
`85d7115d9` -> rc 0, `INFO distribution-hygiene: clean over the tracked tree`.

## Defects (fold into v1.0)

- **W1, the "byte-for-byte identical 16-line preamble" is 15 identical lines and 1 that
  differs** (plan lines 55, 157, 217, and the row 01 cell at line 711). Running
  `diff <(git show 3308d118f:csi-spl-orc/src/bash/run/check-hub-deploy.func.sh | sed -n '43,58p') <(git show 3308d118f:csi-spl-orc/src/bash/run/check-hub-image-regress.func.sh | sed -n '40,55p')`
  prints `9c9 < local svc json image ready created latest --- > local svc json live
  cnf_tag live_tag newest`, rc 1. The plan's shape already handles it (each caller keeps
  its own `local` line, now first), so only the text is wrong. Say "15 identical lines
  plus the callers' own `local` line, which moves first".
- **W2, two of the "exact" behaviour claims are not held by any control** (plan lines
  364-367: "exact `gcloud --account=...` invocations"; plan lines 605-608: "exact
  allowed roots"). Mutants x1 (no `--region`) and x3 (no `/var/spool-hub/dispatch`
  root) pass every test of their row (section 4).
  - Row 01: add to section 8 one assertion on `$T/calls8.log` that the describe call
    carries `--project=`, `--region=`, `--account=op@example.com` and `--format=json`.
  - Row 02: add one assertion that `_spl_desk_in_file` accepts a file under each of its
    3 roots. `/var/spool-hub/dispatch` may not be writable in a test, so an alternative
    is a source-text check that the roots loop names all 3.
  - Then re-run x1 and x3 RED in the row's commit body. These are the places a copy
    could drift without anyone noticing.

## Notes

- **N1:** plan line 124 says the 16 old-cycle briefs are "all dated 2026-11-18". On this
  box `ls -l --time-style=+%FT%T /var/spool-hub/dispatch/briefs | grep ...` dates all 16
  on 2026-10-15 (14:01-21:29). Either way they are before W. Say which box was read, or
  give the dates as read.
- **N2:** R2 puts in the column every test that names a function the site defines.
  The plan leaves 8 out with a reason (plan lines 688-701): `check-deploy-lag`,
  `hub-image-key-wf20` and `lane-map` for row 01, and `check-qto-doc-drift`,
  `desk-cron-write-guard`, `doctree-export-private-repo`, `doctree-export-tenant-allow`
  and `qto-private-index` for row 02. I ran all 8 on base and on the row's head: rc 0
  and the same counts (62, 6, 149; 29, 12, 15, 11, 22). Listing them in the column
  costs a few seconds and saves the R7 seat the argument.
- **N3:** c-738@sat (agy quota model fallback) appeared after the plan's lane-map read.
  The holder asks it at placement (R3, exit 4 is "not free"), as the plan says it will
  re-read.
- **N4:** x4 shows the `is empty` FATAL is not pinned. That is harmless while it stays
  unreachable; no action asked.
- **N5:** r11 section 7 deferred two utl families "until the lint fix", and r12 defers
  them again. Neither SC2071 (`orphan-process-reap.func.sh:208`, an error-level finding,
  bug-shaped) nor SC2155 (`cloud-sql-backup-verify.func.sh:125`) has an ask or a row. A
  bug ask for the two lint fixes would let r13 take those families.
- **N6:** plan lines 191 and 193 print greps with no pathspec. As written,
  `git grep -nE 'needs_agy_review|agy has the final|waits for an agy' | wc -l` -> 34 and
  `git grep -n 'send_to_peers_on' | wc -l` -> 45 on base (docs, specs, and two tests'
  negative assertions: `unanswered-sweep.tst.sh:456`, `test-fleet-send.sh:367`).
  Scoped to the code, each prints 0, as section 7 shows. Add the pathspec so the
  printed command gives the printed 0.
- **N7:** plan line 371 cites `iac:lib/bash/funcs/gcp-account-pin.func.sh:275`. The orc
  actions load the orc copy, `orc:lib/bash/funcs/gcp-account-pin.func.sh:275`, whose
  text is the same (`git grep -n FUNCNAME 3308d118f -- csi-spl-orc/lib csi-spl-iac/lib`
  -> both at `:275`). Cite the orc one.

## Signatures

| plan version | sha | verdict | date |
|---|---|---|---|
| v0.1 | `85d7115d9c5dd023c7b5b09b29542b7c3012dc6b` | PASS (W1, W2 to fold; N1-N7) | 2026-11-27 |
| v1.0 | pending | pending | |
