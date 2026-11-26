# Bug round 51 - panel seat claude (c-052)

Seat: **c-052@sat** (claude, cross-vendor panel seat of rulebook 3.2; the editor is a-048@sat, agy).
Issue: SPL-6578. Plan: `csi-spl-doc/doc/md/bug-round-51-plan.md`.

## 1. Verdict on v0.1

**FAIL** on `366b5b8ef1fcc81a619cf247138f5d5a60a612fd` (v0.1, branch `review/c002-bug-round-51-planner`;
`git ls-remote origin refs/heads/review/c002-bug-round-51-planner` -> `366b5b8ef1fcc81a619cf247138f5d5a60a612fd`).

One defect (W1, row b51-01). Rows b51-02 and b51-03 are ready as written. Everything else checked
clean. Read on 2026-11-26 12:25Z..12:45Z, n=1 per command unless stated. Base `bf585dc99`;
`origin/master` at read time `8024dc0b5` (the plan commit's parent).

## 2. Checks, with the command and what it printed

### 2.1 Slug b51 free since `Window: W=2026-11-26T10:36:56+02:00`

- `git log origin/master --since="2026-11-26T10:36:56+02:00" --oneline -E --grep='\(b51-' | wc -l` -> `0`
- `git ls-remote origin | grep -E 'b51-[0-9]{2}|bug-round-51'` -> one line, the planner's branch
  `366b5b8ef... refs/heads/review/c002-bug-round-51-planner` (this seat's branch is pushed after this file).
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b51-[0-9]{2}|bug-round-51'` ->
  `c002-bug-round-51-claude-panel-seat.md`, `hand-sat-c002-bug-round-51-planner.md` (both expected).
- W itself: `git log -3 --format='%h %cI %s' -E --grep='^docs\(b50-plan' origin/master` ->
  `68d29f7cd 2026-11-26T14:05:07+02:00 ... records the round closed` first, then `fee404830 2026-11-26T10:36:56+02:00 ... v1.0`. See N1.

### 2.2 Sites exist on the base and on origin/master

- `git merge-base --is-ancestor bf585dc99 366b5b8ef` -> rc 0.
- `git diff --name-only bf585dc99 origin/master -- <5 row files + spl-lane-map.func.sh + apply-gh-runner-cpu-budget.func.sh + y8-vibe-agents.py> | wc -l` -> `0` (no drift).
- Every cited line read with `git show bf585dc99:<file> | sed -n <N>p`:
  - `y9-vendor-lane-rule.sh:94-109`: 94-96 the helper's comment, 97 `_y9_qwen_backup() {`, 102 `if (umask 077; set -C; cat <"$q" >"$cand") 2>/dev/null; then`, 107 the `no free backup name` echo. Match.
  - `y9-vendor-lane-rule.sh:65,66,79-80` (not cited by the plan; needed for W1): 65 `stage="$(mktemp -d "$HOME/.qwen/.y9-stage.XXXXXX")" || return 1`, 66 `[ -f "$q" ] && cp -p "$q" "$stage/QWEN.md"`, 79-80 `if [ -f "$q" ]; then bak="$(_y9_qwen_backup "$q")" || rc=1`.
  - `test-agy-qwen-fleet-rules.sh:78-80` (test 3, one backup is the old file), `:114-127` (test 8, all 99 names taken). Match.
  - `y8-vibe-agents.py:52-68` `backup_stamped`, `except FileExistsError: continue`. Match.
  - `apply-gh-runner-cpu-budget.tst.sh:279-284`, `:336-340`, `:421-425`: the three red controls; 424 `[[ "$(cat "$SYSD_LOG")" != *'CPUQuota=400%'* ]] &&` with no `$rc` check. Match.
  - `spl-lane-map.func.sh:72,74`: the `spl-box-ci.func.sh` and `spl-box-cordon.func.sh` relative `source` lines. Match. `apply-gh-runner-cpu-budget.func.sh:172` sources `spl-lane-map.func.sh` relative. Match.
  - `spl-review-go.func.sh:755` `CMD` names `do_(?:provision|tf_|gcp_|spl_desk_up|...)`; `:801` `_spl_review_go_owner_go() {`; `:803` `local fixed='do-provision|do-tf-apply|PROBE_PRD_GO|DRY_RUN=0|ENV=prd|service account key|/etc/'`; `:829` its closing `}` (29 lines). Match.
  - `spl-review-go.tst.sh:1414-1422`: case 34's loop ends at 1419, file ends at 1422 (`wc -l` -> 1422). Match.
  - Carried items' sites: `spool-live-ack.sh:101-103` (the 400/200 cap), `spool-agent-hook.sh:807-813` (`stop_denies`), `:139-140` (`EVENTS` with `PreInvocation`), `check-pre-push-lint.func.sh:618-643` (`_ppl_run_timed`), `taskcron/cron_test.go:209-229` (`TestRefusals`), `mcp/mcp_test.go:560-563`, `customer-box-role-set.tst.sh:160-165` (`CONTROL d6`). All match.

### 2.3 Red controls: read, hashed, run on the base in a scratch copy

The three scripts were extracted verbatim from the plan's section 4 fenced blocks.
`sha256sum` -> `d7b219da65c5549b4056fd45c14283929157824132c1a6042b6b2943422c2f07 rc01-b51.sh` (5473 B),
`4d2fb494754cb92a6c73d2e6d7b7cfd6f759f0f0969572135a1f5155db5ada55 rc02-b51.sh` (6087 B),
`a977907ee08f46912bc752601cd39c784b9094b2d76bcc3054563f1347a3ba52 rc03-b51.sh` (3595 B). Prefixes and sizes match the plan.

| run (n=1 each) | last line | exit |
|---|---|---|
| `bash rc01-b51.sh bf585dc99` | `rc01 exit 1` (A enoent `rc=1 false_nofree=1`, B readonly_dir `rc=1 false_nofree=1`, C `mode=600 content_ok=1`, D `20/20 passed`) | 1 |
| `bash rc01-b51.sh bf585dc99 fix-shape` | `rc01 exit 0` (A `[Errno 2]`, B `[Errno 13]`, C, D pass) | 0 |
| `bash rc02-b51.sh bf585dc99` | `rc02 exit 1` (A `rc=0 stderr_source_errs=6`, B `rc=0 (want !=0)`) | 1 |
| `bash rc02-b51.sh bf585dc99 fix-shape` | `rc02 exit 0` (A `stderr_source_errs=0`, B `rc=1`) | 0 |
| `bash rc03-b51.sh bf585dc99` | `rc03 exit 1` (5 `red_*` `rc=0 (want 1)`, 6 `ctrl_*` match) | 1 |
| `bash rc03-b51.sh bf585dc99 fix-shape` | `rc03 exit 0` (5 `red_*` `rc=1`, 6 `ctrl_*` match) | 0 |

- Each fails for the reason the plan gives, not for an environment reason (all run as a non-root
  user, so rc01's case B ran).
- Live state: none touched. Each script copies files out of the sha with `git archive` into `mktemp -d`
  and deletes it on EXIT. rc01 case C runs the entry with `HOME=<tmp>`. rc02 runs the test, which
  stubs `systemctl` and uses a fixture cgroup tree (`apply-gh-runner-cpu-budget.tst.sh:42`: "No real
  cgroup, systemd, crontab or sudo"). rc03 sets `SPOOL_ROOT=<tmp>/spool`.
- rc01 passes on its fix-shape, but it proves the helper-level defect in two states that the real
  caller never produces: see W1.

### 2.4 Each row's defect, read on the tree

- **b51-01: real, but the plan overstates it (W1).** The helper does hide every non-`EEXIST`
  error behind `2>/dev/null` and loops 99 times. But its only caller, `_y9_qwen`, reaches it only after
  `mktemp -d "$HOME/.qwen/..."` succeeded (:65) and only when `[ -f "$q" ]` (:79). I probed it through
  the real entry point, `spool_install_vendor_lane_rule`, with a temp `HOME` (`probe01.sh`, section 5):
  `bash probe01.sh bf585dc99` ->
  - `P1(readonly ~/.qwen): mktemp: failed to create directory via template '.../p1/.qwen/.y9-stage.XXXXXX': Permission denied rc=1`: the real error and no false line. The helper is never reached.
  - `P2(QWEN.md mode 000): cp: cannot open '.../p2/.qwen/QWEN.md' for reading: Permission denied spool-install: vibe-agents: .../QWEN.md: no free backup name for 20261126T122750Z: nothing replaced rc=1`: **the reachable false line**.
  - `P3(no QWEN.md): ... the fleet rule parts rendered rc=0`: no backup is taken, so ENOENT never reaches the helper.

  Fix scope: narrow (one helper and one test file); keeping it to 37 lines is fine.
- **b51-02: real, the account is right.** rc02 A counts 6 `No such file or directory` stderr lines on
  the base. Section 8 (`:423-425`) checks only that `CPUQuota=400%` is absent. A mutant that crashes
  in section 8 leaves `$SYSD_LOG` empty and passes (rc02 B `rc=0`). The fix scope is test-only and
  narrow, and mirrors b50-02 `86ac09501`. The control proves the defect and turns green on the
  fix-shape.
- **b51-03: real, the account is right.** `:803` lists only the hyphenated make targets. rc03's five
  `## Do` probes get `rc=0` on the base and `rc=1` with the fix-shape, while `## Never`, `## Why` and
  fenced controls stay `rc=0`. The fix is a one-line change to the `fixed` list plus a test case. The
  plan's "0 of 500 briefs flip" claim, re-checked: `ls -t /var/spool-hub/dispatch/briefs | grep -vE -- '-(reviewer|seat|planner)\.md$' | head -500 | xargs grep -lE 'do_provision|do_tf_apply|do_spl_desk_up'`
  -> 1 file (a hand-placed desk-seat brief for `<box2>`; its name is left out by the hygiene gate). `_spl_review_go_owner_go` on it gives
  `owner-go keyword 'ENV=prd'`, `rc=1` on the base AND `rc=1` with the fix-shape `fixed`: no flip. Confirmed.

### 2.5 Row form (R1, R2, R7, vendor, kind, batch)

- All three rows have a red control that fails on `bf585dc99` and passes on the fix-shape, a test
  column, vendor claude, kind `simple_coding` and batch 1. No mistral row. R7 is agy, or the
  claude waiver seat (N2). No reviewer is mistral.
- R1: row files are {y9-vendor-lane-rule.sh, test-agy-qwen-fleet-rules.sh}, {apply-gh-runner-cpu-budget.tst.sh}
  and {spl-review-go.func.sh, spl-review-go.tst.sh}: pairwise disjoint.
- R2: `git grep -lE '<site basename|function>' bf585dc99 -- '*test*' '*.tst.sh' '*tests/*'` ->
  - y9: `test-agy-qwen-fleet-rules.sh`, `test-agy-rules-always-on.sh`, `test-vibe-agents.sh`, `test-y14-agy-exit-rule.sh`. All four are in column 01.
  - `apply-gh-runner-cpu-budget.tst`: `setup-gh-runner-cpu-budget-cron.tst.sh` (in column 02) and `orc-shard-weights.txt` (not a test).
  - `spl-review-go.func|_spl_review_go_owner_go`: `spl-review-go.tst.sh` (in column 03).
  - Every column is complete.
- Baselines on `bf585dc99` (this worktree, HEAD `bf585dc9971c27c00b058e92786dbd629850e813`):
  - `bash csi-spl-orc/src/bash/features/spool-install/tests/test-agy-qwen-fleet-rules.sh` -> rc 0, `== y9 agy + qwen fleet rules: 20/20 passed`.
  - `bash csi-spl-orc/src/bash/tests/spl-accepted-close.tst.sh` -> rc 0, `spl-accepted-close: 0 failure(s)`.
  - `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` -> rc 0, `spl-review-go: 0 failure(s)` (7m43s).

### 2.6 R3

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <the 5 row files, comma-separated> --agent c-052`
at 12:30:51Z -> **exit 4**: `WARN no live lane lists <the 5 paths>, but 19 live lane(s) record no files: their scope is unknown, not free`.
The 19 `unknown:` lanes are all on `<box2>`: c-029, c-041, c-065, c-068, c-086, c-146, c-187, c-407, c-416, c-474, c-535, c-728, c-904, c-907, c-927, c-936, c-957, c-965, c-971.
On this box, `git worktree list --porcelain` covers 275 worktrees. For each, I checked
`git diff --name-only $(git merge-base origin/master <branch>) <branch> -- <5 row files>` and
`git -C <wt> diff --name-only HEAD -- <5 row files>`: **0 hits**.
The plan's R3 section (12:14:36Z, exit 4, 20 unknown, b50 and r06 lanes off these files) agrees. See N3.

### 2.7 Inputs accounted for

- The plan's sections 3.4 and 3.5 against b50's section 7 "first inputs for round 51" (`git show origin/master:csi-spl-doc/doc/md/bug-round-50-plan.md | grep '^| first inputs for round 51'`): every item is served, made a row or carried with a reason. Items: c-902 N5, a-909 N1/N2, the apply red control, a-826 N2, a-767 N2, a-823 N2, c-625, a-769 N1/N2, a-790 N1, a-911 N2, hours-minutes, c-708, a-683, a-490, a-480, the buffer budgets, `unknown_token`, hub dir mode, hermetic, testids, the `i18n` exempt file, and the SPL/b/r tails. a-826 N2 counts as served: `spool-live-ack.sh:101-103` holds the cap on the base.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md` (151 lines, modified 11:03:40Z, before the plan's 11:58Z read): `:147-148` is the `<box2>` process churn, a perf input, not a bug; `:150-151` is the r06-02 rc 4 on "Apply section 1.4's verbatim hunks", the shape b50-01 `3ce429f73` fixed. As the plan says.
- CI, re-checked: `gh run list --branch master --status failure --limit 40 --json ... | select(.createdAt >= "2026-11-26T08:36:56Z")` -> one run, `45792046781 2026-11-26T09:26:53Z 62 sec: gosec (Go SAST) 4fc040744`, as plan source 5 says.
- NOT RUN by me: the prd ERROR and WARNING log reads, alert incidents, the bug-issue query and `do_report_ci_gate`. They are prd reads that the editor ran and quoted (sources 1-4, 6, 8); a doc seat gains nothing by repeating them.
- No bug-shaped input is left neither served nor accounted for.
- Row count: 3 is the 5.1 cap (aim 2). All three are small, disjoint and come from named inputs, so 3 is justified. See N4.

### 2.8 Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> rc 0, `INFO distribution-hygiene: clean over the tracked tree` (with this file staged; a first run flagged one brief file name at :88, reworded).

## 3. Defects

- **W1 (b51-01: plan section 3.1 "What happens", red-control cases A and B, the planned test sections 9-10; and the rc01 header).**
  The plan says a read-only `~/.qwen` (`EACCES`/`EROFS`) and a missing `QWEN.md` (`ENOENT`) make
  `_y9_qwen_backup` spin and print the false `no free backup name` line. That only holds when the
  helper is called directly. Through its one caller, neither state reaches it: probe P1 shows `mktemp`
  failing first with the real error, and P3 shows no backup is taken (2.4). The state that does reach
  it is an **unreadable `QWEN.md`** in a writable `~/.qwen` (P2). There the false line follows `cp`'s
  own `Permission denied`. ENOSPC or EIO on the backup write would reach it too.

  As written, the row's new test section 10 would assert two things (fail on a missing parent, fail on
  a read-only dir) that the entry already handles on the base, or that would give rc 0. A test driven
  through `y9 "$H"`, as the suite's other cases are, would be green before the fix: no red control.

  **Fold:**
  1. Correct 3.1's account: reachable via an unreadable `QWEN.md` (and ENOSPC/EIO); the read-only dir and ENOENT cases are helper-level only.
  2. Add an entry-level case to `rc01-b51.sh` and to the row's test section 10: `QWEN.md` mode 000 under `spool_install_vendor_lane_rule` with `HOME=<tmp>`. It must exit non-zero, print no `no free backup name`, and leave `QWEN.md` unchanged. It is RED on the base (P2 above).
  3. Keep A and B only if they are labelled helper-level.

## 4. Notes

- **N1 (W moved after the read).** The b50 close record `68d29f7cd` (`docs(b50-plan, ...)`, 12:05:07Z)
  is now the newest `^docs\(b50-plan` commit. Rulebook 5.3 keeps the recorded W (`fee404830`, read
  11:58:58Z), and b51 is free under either W (2.1). Say so in the plan so a later reader does not
  re-derive W as `68d29f7cd`.
- **N2 (R7 waiver citation).** `1a7c70da` is the b26 waiver, "for this seat only"
  (`grep -n 1a7c70da csi-spl-doc/doc/md/bug-round-26-plan.md` -> `:13,15`, ruled by c-001 msg `41f53f3c`).
  The R7 fallback used in b45-b50 also cites c-001 `77ba5669` (`grep -ho 'claude waiver seat[^|]\{0,200\}' bug-round-4[5-9]-plan.md bug-round-50-plan.md`).
  Name the ruling that covers an R7 seat. Prefer agy for all three rows: they are claude-authored
  orc rows, not secret-class.
- **N3 (R3 at placement).** The exit 4 with 19 `unknown:` `<box2>` lanes is not "free". The holder
  re-runs `--check` at night placement, as the plan says. My local count is 0 of 275 worktrees.
- **N4 (row count).** 3 is the cap. After W1, b51-01's user-facing impact is a misleading second line
  after a real `cp` error, so it is the weakest of the three. Keeping it is justified because it closes
  a named input with a narrow fix. If the holder wants the 5.1 aim of 2, b51-01 is the one to move to
  round 52.
- **N5 (b51-03 prefix reach).** The new substrings also hold briefs naming `do_provision_firebase_dns`,
  `do_provision_firebase_dns_env`, `do_provision_spool_root`, `do_spl_desk_up_all`, `_boxes`, `_tenants`
  and `do_tf_apply_target`. That is 10 actions:
  `git grep -hoE '^(do_provision|do_tf_apply|do_spl_desk_up)[a-z_]*\(\)' bf585dc99 -- '*.func.sh' | sort | uniq -c`.
  The plan means this (3.3 names the families). Case 35 should name at least one `do_provision_*` and
  one `do_spl_desk_up_*` probe, so the prefix reach is pinned on purpose.

## 5. Probe used for W1

`probe01.sh` (sha256 `1060cefd30a1648c95f7d3c3246082d1aab7ae08dbca311de8c5abce69a8bddc`). It runs from
any checkout and touches only `mktemp -d`.

```bash
#!/usr/bin/env bash
# probe01.sh <sha>: reach _y9_qwen_backup through spool_install_vendor_lane_rule (temp HOME only)
set -uo pipefail
sha="$1"; tmp="$(mktemp -d)"; trap 'chmod -R u+rwx "$tmp" 2>/dev/null; rm -rf "$tmp"' EXIT
git archive "$sha" csi-spl-orc/src/bash/features/spool-install | tar -x -C "$tmp"
y9="$tmp/csi-spl-orc/src/bash/features/spool-install/steps/y9-vendor-lane-rule.sh"
run() { env HOME="$1" bash -c 'source "$1" && spool_install_vendor_lane_rule' _ "$y9" 2>&1; echo "rc=$?"; }
# P1 read-only ~/.qwen holding an old QWEN.md
mkdir -p "$tmp/p1/.qwen"; printf 'old\n' >"$tmp/p1/.qwen/QWEN.md"; chmod 0500 "$tmp/p1/.qwen"
echo "P1(readonly ~/.qwen): $(run "$tmp/p1" | tr '\n' ' ')"; chmod 0700 "$tmp/p1/.qwen"
# P2 unreadable QWEN.md (mode 000) in a writable ~/.qwen
mkdir -p "$tmp/p2/.qwen"; printf 'old\n' >"$tmp/p2/.qwen/QWEN.md"; chmod 000 "$tmp/p2/.qwen/QWEN.md"
echo "P2(QWEN.md mode 000): $(run "$tmp/p2" | tr '\n' ' ')"
# P3 no QWEN.md at all (ENOENT source)
mkdir -p "$tmp/p3/.qwen"
echo "P3(no QWEN.md): $(run "$tmp/p3" | tr '\n' ' ')"
```
