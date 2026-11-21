# Refactoring round 80 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-6148  
Topic: 9b0361a2-703f-4f4c-bd3d-94a328e4f201  
Discussion: 9b0361a2-703f-4f4c-bd3d-94a328e4f201 (t1 #refactoring, "Refactor round 80", opener msg a1c513dd)  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 2026-11-18 (rulebook 5): small rounds, aim at 2 rows, at most 3; one number per
  kind, so this round is **r80**, plan `refactor-round-80-plan.md`, rows `r80-<NN>`.
- owner 10-17 (t1 b61851fb): no mistral coding or testing rows. **Vendor claude for
  every row.**
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1-R16, sections 3 and 5). The
  rulebook wins over this plan.

**What this round is.** Round 79 ([refactor-round-79-plan.md](refactor-round-79-plan.md))
is closed (`76eaf4ac6`, Closes: SPL-6126): r79-01 landed `75da57eb4` (SPL-6134), r79-02
`21a8e0296` + `f5256aa6b` (SPL-6137). No signed row is handed on: r80 is a fresh round.
The perf floor (rulebook 4.4), the holder's read on `76eaf4ac6`: `perf 29 refactor 108
perf-share 21.2% floor-met`, so this is a refactor round.

**Row 01** moves the unanswered-sweep cron installer's default log dir
(`spl-unanswered-sweep-install-cron.func.sh:57`) onto `spl_var_app_subdir`, the shape
r78-01 gave the desk-reconcile installer; r79 section 8's input 3. **Row 02** makes
`do_spl_merged_cnf` return 1 on an empty argument instead of exiting the caller's shell
(`spl-merged-cnf.func.sh:58`), the shape r78-02 gave `do_tf_log_open`; r79 section 7's
first candidate for r80, one file of the remaining `local x="${1:?...}"` lines.

**Status: v1.0**: panel seat m-691 (mistral) PASS on v0.1 `7329be641`, no W finding,
N1-N3 recorded (section 8); no row changes scope. m-691 PASS on v1.0 `d02aea0f8` too
(section 9). **Closed**: both rows landed, r80-01 `f886bfcdd`, r80-02 `5083f4cf9`
(section 8). Editor: **c-680** (claude).

**One sha:** every count is measured on **`07f34efeb`** (`origin/master`
07f34efebd7e7f1791795588df74510aa9d94395, committed 2026-11-21T07:05:15+02:00), n=1 per
command unless stated. Reads are on that sha with `git show` / `git grep` or on this
lane's worktree at that sha. **Every test named below was RUN**, not only read (r79's
plan miss, c-594 N1: a planner that clears a test of a row's change runs it on the row's
head): on a scratch copy of `07f34efeb` (`git archive`, as the push user,
`SPOOL_TEST=1`) with the row's change applied in 1.3's / 1.4's shape, and on an
unmodified copy for the "before" column (1.5). The scratch copies are measurement only;
nothing of them is committed. Queue, lane map, brief and worktree readings are live
state and carry their own time.

## 1. Baseline

### 1.1 Window and slug proof (rulebook 5.3)

- **Window: W=2026-11-21T06:01:47+01:00**, from
  `git log origin/master -1 --format=%cI -E --grep='^docs\(r79-plan'` -> commit
  `76eaf4ac6` "refactor round 79 plan records the round closed, rows 01-02 landed".
  Every later read of r80 uses this W.
- **`r80` is free** (2026-11-21T05:14:17Z, n=1):
  - `git log origin/master --since="$W" --oneline -E --grep='\(r80-'` -> **0**; the same
    grep over all history (no `--since`) -> **0**.
  - `git ls-remote origin 'refs/heads/review/r80-*' 'refs/heads/wip/*r80*' 'refs/heads/*-r80-*' 'refs/heads/*refactor-round-80*'`
    -> **nothing**. This planner's review branch is pushed after that read.
  - `grep -rlE 'r80-[0-9]{2}|refactor-round-80' <spool>/dispatch/briefs <spool>/spawn-remote/briefs`
    (as root) on this lane's box -> **2 files**: this planner's brief and the panel
    seat's (`c002-refactor-round-80-mistral-panel-seat.md`).
  - Control: the same log read with `(r79-` since W -> 1 line (`76eaf4ac6`), so the read
    sees a used id.
- **No `refactor-round-80*` file** exists under `csi-spl-doc/doc/md` on `07f34efeb`
  (`ls csi-spl-doc/doc/md | grep -c refactor-round-80` -> 0), so the plan takes the
  plain name (5.3 "Files").

### 1.2 The brief's inputs, re-measured

`orc:` = `csi-spl-orc/src/bash/`, `iac:` = `csi-spl-iac/`; `<mod> lib:` =
`<mod>/lib/bash/funcs/`.

| input | source | on `07f34efeb` | here |
|---|---|---|---|
| the other `local x="${1:?...}"` lines | r79 section 7 ("first candidate for r80"), r78 1.4 | `git grep -nE 'local [A-Za-z_]+="?\$\{[0-9]:\?'`: iac lib + `iac:src/bash/run` -> **15 lines in 7 files**; orc lib + `orc:run` -> **11 lines in 4 files** | **row 02** takes one file, `iac lib:spl-merged-cnf.func.sh:58`; the rest left out (section 7) |
| `orc:run/spl-unanswered-sweep-install-cron.func.sh:57` | r79 sections 7 and 8 (input 3) | still spelled; no live lane lists it (2.2) | **row 01** |
| `orc:scripts/spl-desk-reply.sh:9`, `:19` usage text | r79 section 7 (panel N1), section 8 (input 4); candidates "[refactor] SPL-6107 N1" | measured downstream (below): `task` is not a reply kind | left out (section 7), first candidate for r81 |
| c-594 N1 (r79 1.4's miss: `desk-up-all.tst.sh` case 7 is not refused before the `PRINT=1` block) | r79 section 8 (input 1) | a planner practice, not a code site | applied: every test of 1.3 and 1.4 was run on the row's head (1.5) |
| the rest of r79 section 7 | r79 section 7 | their reasons hold | left out (section 7) |
| the candidates file (`<spool>/dispatch/c002-next-round-candidates.md`, this box) | the brief | refactor-shaped items re-read below | nothing new taken |
| spec 011 tasks | the brief | 15 open (`grep -cE '^\s*- \[ \]' tasks.md`); `git log origin/master --since="$W" -- csi-spl-doc/specs/011-spool-project-refactor` -> 0 | left out (section 7), r65 to r79's reasons hold |

The candidates file's refactor-shaped items (its bug items are bug round 31's, SPL-6136):

| item | on `07f34efeb` | here |
|---|---|---|
| literal `/var` in `spl-watchdog.func.sh`, `spl-lane-rotate.func.sh` (r34 R7 N3) | served (r79 1.2, item 1) | nothing taken |
| `reverse-tunnel-cron.sh:23` literal (r63-01 R7 W1) | served (r79 1.2, item 2) | nothing taken |
| `wf10:444-445` disk-margin comment (p18-02 R7 N1) | served by r79-01 `75da57eb4` | nothing taken |
| agent-boot-restore dir (r69) | served (r70-01) | nothing taken |
| `spl-uplink-probe.func.sh:14-15` wording (r60-06 N1) | served (r79 1.2, item 5) | nothing taken |
| `tf-log-mask.func.sh:25` `${1:?}` (b12-02 N3) | served by r78-02 `ba7acd634` | nothing taken |
| "[refactor] SPL-6107 N1" `spl-desk-reply.sh:9,19` | measured below | left out (section 7) |
| `spl-spawn-place-argmax.tst.sh` section 9 guard cases (b30-01 R7 N1) | test-shaped | left out (section 7) |
| spec 182 L2 `!inserted` branch untested (SPL-6032 R7 N1) | test-shaped, hub Go | left out (section 7) |
| `ws-docs-head.mjs:28,60,62` synthetic click (SPL-6115 R7 W1) | WUI test hardening; WUI lanes live | left out (section 7) |

**`spl-desk-reply.sh`, measured downstream.** The script passes `DESK_KIND` to
`spool send --kind` unchecked (`:39`, `:52`, `:239`); its usage (`:9`) and env text
(`:19`) list `note|result|reject|blocker|msg`. The spool kinds are 13 (`SPOOL_KINDS`,
`orc:features/spawn-agents/lib/spool-env.inc.sh:138`:
`task|result|note|reject|blocker|msg|feature|bug|alert|question|idea|decision|docs`);
the reply action `do_spl_desk_reply` takes `note|result|reject|blocker|msg` plus the 7
note kinds (`orc:run/spl-desk-reply.func.sh:147-148`, SPL-6107 `d42a8c3de`), **not
`task`**. So the wording row is "the usage lists the reply action's 12 kinds", not "add
`task`". Left out: 2 rows taken (5.1).

### 1.3 Row 01's site: the unanswered-sweep installer's log dir

`orc:run/spl-unanswered-sweep-install-cron.func.sh` (102 lines; the function
`do_spl_unanswered_sweep_install_cron` is `:38-102`, 65 lines):

```text
:26  # @param SWEEP_CRON_LOG_DIR (optional) - default /var/<org>/<org>-<app>/unanswered-sweep
:50    SPL_ORG_APP="${SPL_ORG_APP:-$(basename "$PROJ_PATH")}"; SPL_ORG_APP="${SPL_ORG_APP%-orc}"
:57    logdir="${SWEEP_CRON_LOG_DIR:-/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/unanswered-sweep}"
```

`SPL_ORG_APP` stays (it names the crontab tag `:53` and the script path `:56`); only
the default log dir moves.

**The shape**, r78-01's for the desk-reconcile installer and
`spl-agent-boot-restore-install-cron.func.sh:57-61`'s:

```text
logdir="${SWEEP_CRON_LOG_DIR:-}"
if [[ -z "$logdir" ]]; then
  declare -F spl_var_app_subdir >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../../lib/bash/funcs/spl-run-paths.func.sh"
  spl_var_app_subdir logdir unanswered-sweep || { do_log "FATAL cannot derive the unanswered sweep log dir (no tree for spl_run_paths): set SWEEP_CRON_LOG_DIR"; return 1; }
fi
```

and `:26` reads `default <SPL_VAR_APP_DIR>/unanswered-sweep (spl_run_paths)`. The
function grows 65 -> 69 lines (cap 75, developer guide 2.2.1; `bash-cleancode.tst.sh`
passes on the row's head, 1.5).

**Same dir today, measured** (this lane's box, 2026-11-21T05:2xZ, n=1 per tree, as the
push user under `env -i PATH=/usr/bin:/bin`): for the main checkout, the desk-cron
checkout and this lane's worktree, the hand form (`SPL_ORG_APP` from the orc dir name)
and `spl_var_app_subdir d unanswered-sweep` (that tree's lib) print the same path:
**3 of 3 EQUAL** (`/var/<org>/<org>-<app>/unanswered-sweep`). The main and desk-cron
checkouts were read at their own heads, not at `07f34efeb`.

**The tests that pin or run the site**
(`git grep -lE 'spl-unanswered-sweep-install-cron|do_spl_unanswered_sweep_install_cron' -- '*tests/*'`
-> 4 files, plus the one that counts its path):

- `orc:tests/unanswered-sweep.tst.sh` (463 lines), section 10: its `cron()` helper
  always sets `SWEEP_CRON_LOG_DIR="$T/log"`, so no case reads the default today. The
  row adds one case after `:280`: a dry run `cron SWEEP_CRON_LOG_DIR= SPL_VAR_APP_DIR="$T/var"`
  prints a line holding `>> $T/var/unanswered-sweep/cron.out 2>&1 # csi-spl:unanswered-sweep`,
  and `$T/var` is not created.
- `orc:tests/no-literal-paths-spelled.baseline`: **17 lines in 15 files**; `:10` is
  `1 csi-spl-orc/src/bash/run/spl-unanswered-sweep-install-cron.func.sh`. The row drops
  it: **16 in 14**. Measured in this lane's worktree (row 01's two files copied in, then
  restored): site and baseline both changed -> `ALL PASS` (15); the site alone -> rc 1,
  `STALE baseline: ...spl-unanswered-sweep-install-cron.func.sh has none: drop its line`.
- `iac:src/bash/tests/satellite-ansible.tst.sh` (535 lines), `:270-272`: `n_sd` counts
  the distinct `/var/<var>/.../(desk-reconcile|unanswered-sweep|weekly-scan|backup|tenants)`
  paths in orc and iac `src/bash`. On `07f34efeb` it prints **4**:
  `/var/${SPL_ORG_APP%%-*}/$SPL_ORG_APP/unanswered-sweep` (this site),
  `/var/$org/$app/weekly-scan`, `/var/$ORG/$ORG-$APP/backup`,
  `/var/$org/$SPL_ORG_APP/tenants`. Row 01 removes the first: **4 -> 3**, and `:272`
  (`-ge 4`) FAILs (measured, 1.5) unless the floor moves to `-ge 3`. The `bad` half
  (`:270`) is unchanged.
- `orc:tests/dispatch-setup-check.tst.sh` (`:87` sets `SWEEP_CRON_LOG_DIR`; `:456` names
  the action in a hint) and `orc:tests/spl-box-deploy.tst.sh` (`:57` stubs the action):
  neither reads the default; both pass on the row's head (1.5).

### 1.4 Row 02's site: `do_spl_merged_cnf`

`iac lib:spl-merged-cnf.func.sh` (125 lines; `do_spl_merged_cnf` is `:57-125`, 69
lines), `:57-60`:

```text
:57  do_spl_merged_cnf() {
:58    local dir="${1:?cnf dir}" env="${2:?env}" out="${3:?out}"
:59    [[ -f "$dir/all.env.yaml" && -f "$dir/$env.env.yaml" ]] || {
:60      echo "do_spl_merged_cnf: missing $dir/all.env.yaml or $dir/$env.env.yaml" >&2; return 1; }
```

**What is wrong.** `${1:?}` with an empty or missing argument prints the message and
**exits** the non-interactive shell (developer guide 2.4.3: a function returns a code).
The function's own checks (`:59-60`, `:124`) return 1, and its callers expect that: 18
calls in `iac:src/bash/run` (`git grep -nE 'do_spl_merged_cnf ' -- csi-spl-iac/src/bash/run`),
16 of them `|| return 1` or `|| { ...; return 1; }` (e.g. `gcp-audit-iam.func.sh:33`,
`tpl-gen.func.sh:48`), 2 an `&&` / `if` (`put-github-app-key.func.sh:37`,
`rotate-github-app-key.func.sh:27`), all passing `"$ENV"` or `"${ENV}"`; 4 more in libs
and make (`iac lib:satellite.func.sh:36`, `orc lib:lde-cnf.func.sh:67`,
`orc lib:spl-cloud-cnf.func.sh:263`, `csi-spl-orc/src/make/spl-merged-cnf.func.mk:18`).
On an empty argument none of them reaches its `||`, `&&` or `else`. Measured on
`07f34efeb` (n=1 per form, `bash -c 'source <lib>; do_spl_merged_cnf <args>; echo "rc=$?"'`):
`"" dev X`, `D "" X`, `D dev ""` each print `line 58: <n>: <word>` and **no `rc=`
line**.

**The shape**, r78-02's:

```text
[[ -n "${1:-}" && -n "${2:-}" && -n "${3:-}" ]] || { echo "do_spl_merged_cnf: usage: do_spl_merged_cnf <cnf dir> <env> <out>" >&2; return 1; }
local dir="$1" env="$2" out="$3"
```

Every call with three non-empty arguments behaves as before. The function grows 69 ->
70 lines.

**The tests.** `git grep -lE 'do_spl_merged_cnf|spl-merged-cnf' -- '*tests/*'` -> **33
files** (26 iac, 6 orc, 1 cnf); all 33 were run on the row's head and the 6 nearest on
the parent (1.5). The new case goes into `iac:src/bash/tests/cnf-one-key-per-fact.tst.sh`
(81 lines; it sources the lib at `:20`, and its section 2 already checks a key the
function derives), before `:81`:

```text
# 4. an empty or missing argument returns 1 and says why; it never exits the caller's shell
for a in "|dev|$tmp/e1.yaml" "$CNF||$tmp/e2.yaml" "$CNF|dev|" "none"; do
  if [[ "$a" == none ]]; then r=$( (do_spl_merged_cnf 2>"$tmp/e.err"; echo "rc=$?") ); else
    IFS='|' read -r a1 a2 a3 <<<"$a"; r=$( (do_spl_merged_cnf "$a1" "$a2" "$a3" 2>"$tmp/e.err"; echo "rc=$?") ); fi
  [[ "$r" == rc=1 ]] && grep -q 'usage: do_spl_merged_cnf' "$tmp/e.err" && [[ ! -e "$tmp/e1.yaml" && ! -e "$tmp/e2.yaml" ]] &&
    pass "4. do_spl_merged_cnf '$a': returns 1, says why, writes nothing" || fail "4. '$a': out '$r', stderr '$(cat "$tmp/e.err")'"
done
```

(the lane may word it otherwise; the four forms and the three checks stay).

### 1.5 Before and on the row's head (scratch copies of `07f34efeb`)

2026-11-21T05:15Z-05:40Z, n=1, `SPOOL_TEST=1`, as the push user; pass lines
`grep -ciE '^ *(ok|pass)'`, fail lines `grep -ciE '^ *(not ok|fail)'`. "Head" = the
scratch copy with the row's change in 1.3's / 1.4's shape.

| suite | row | before rc / pass | head rc / pass / fail | note |
|---|---|---|---|---|
| `orc:tests/unanswered-sweep.tst.sh` | 01 | 0 / 70 | 0 / 71 / 0 | +1, the new case; with the parent's site it FAILs: `FAIL: 10. default log dir`, the line `>> /var/<org>/<org>-<app>/unanswered-sweep/cron.out`, `unanswered-sweep: 1 failure(s)`, rc 1 |
| `iac:src/bash/tests/satellite-ansible.tst.sh` | 01 | 0 / 96 | old floor: 1 / 94 / 2 (`FAIL: state dirs outside /var/<org>/<org>-<app>:` with `bad` empty, so `n_sd` 3 < 4); `-ge 3`: 0 / 96 / 0 (`3 paths`) | the floor follows the count |
| `orc:tests/dispatch-setup-check.tst.sh` | 01 | 0 / 95 | 0 / 95 / 0 | |
| `orc:tests/spl-box-deploy.tst.sh` | 01 | 0 / 36 | 0 / 36 / 0 | |
| `orc:tests/no-literal-paths.tst.sh` | 01 | 0 / 15 (worktree) | 0 / 15 (worktree, 1.3) | in a scratch copy outside `/opt/<org>` it reads 2 unrelated STALE lines (`spl-file-erase.func.sh`, `spl-m3-e2e.func.sh`) on the unmodified copy too: run it in the worktree |
| `iac:src/bash/tests/bash-cleancode.tst.sh` | 01, 02 | 0 / 15 | 0 / 15 / 0 (each row's head) | both functions stay under 75 lines |
| `iac:src/bash/tests/cnf-one-key-per-fact.tst.sh` | 02 | 0 / 10 | 0 / 14 / 0 | +4, section 4; with the parent's lib (its `source` line pointed at it) rc 1, 4 FAIL (`stderr '...spl-merged-cnf.func.sh: line 58: 1: cnf dir'`, `out ''`) |
| the other 32 files of 1.4's grep | 02 | not run on the parent | 29 rc 0, 0 fail (pass lines: auth-urls-from-fqdn 49, gcp-audit-wsdoc-buckets 31, gcp-gcal-connect-check 16, gcp-hub-instance-health 23, gcp-purge-prd-backups 17, gcp-purge-wsdoc-prefix 20, hub-auth-030 30, hub-box-locks-expected-030 4, hub-contacts-030 7, hub-desk-ack-defer-030 4, hub-file-streams-030 18, hub-gcal-030 14, hub-github-app-key-030 26, hub-marketing-facebook-030 9, hub-marketing-workspaces-030 4, hub-payment-030 11, hub-release-note-bans-030 11, hub-secret-versions-030 9, hub-vendor-keys-030 22, spl-kms-check 18, spl-vendor-key-grant-check 26, spl-vendor-key-pepper-put 13, tpl-gen-no-jq 3, hub-invite-email-send 17, lde-stack 48, release-note-link 19, spl-local-hub 50, spl-merged-cnf-json-write 4, wd-snapshot-cnf 8) | the 3 env-bound ones: next rows |
| `iac:src/bash/tests/tf-steps-render-and-validate.tst.sh` | 02 | 0 / 141 (with `TPL_GEN_DIR`) | without `TPL_GEN_DIR`: 1 / 138 / 2 (`no tpl-gen venv`: a scratch copy has no `tpl-gen/` sibling); with `TPL_GEN_DIR=<main checkout>/tpl-gen`: 0 / 141 / 0 | env-bound: run with `TPL_GEN_DIR` |
| `iac:src/bash/tests/tpl-gen-step-render-parity.tst.sh` | 02 | 0 / 10 (with `TPL_GEN_DIR`) | without: 1 / 6 / 1 (same reason); with `TPL_GEN_DIR`: 0 / 10 / 0 | env-bound: run with `TPL_GEN_DIR` |
| `csi-spl-cnf/src/bash/tests/conf-validator-exit-codes.tst.sh` | 02 | 2 / 0 (same reason) | 2 / 0 / 1 (`'python3' cannot import the validator's dependencies`); in `img-csi-spl-conf-validator:latest` the same (no venv in the image, the header's recipe mounts a host `.venv` this box lacks) | **NOT RUN** on this box: the lane records `NOT RUN conf-validator-exit-codes.tst.sh: <why>` unless its box has the venv; the test's header (`:31`) says the CI workflow pip-installs the deps |

## 2. The 2 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r80-01-orc-unanswered-sweep-log-dir-var-app-subdir)` | canonical paths (developer guide 2.3.1); folded helpers exist once (2.2.4) | the unanswered-sweep installer spells its default log dir by hand; the run lib derives the same dir, as both desk-reconcile sites do since r78-01 / r79-02 (1.3, 3 of 3) | `orc:run/spl-unanswered-sweep-install-cron.func.sh:26,57`<br>`orc:tests/no-literal-paths-spelled.baseline:10` (drop the line)<br>`iac:src/bash/tests/satellite-ansible.tst.sh:272` (floor 4 -> 3)<br>`orc:tests/unanswered-sweep.tst.sh:280` (+ one case after it) | 1 site | The site takes 1.3's shape. **Gate:** the spelled ratchet, baseline 15 -> **14** files (17 -> 16 lines). **New case** (1.3) in section 10. **Red control:** the new case on the parent's site prints the hand form and FAILs (1.5), then GREEN (71 pass); a dry run writes nothing. **`satellite-ansible.tst.sh`:** on head with the old floor it FAILs (`n_sd` 3), with `-ge 3` it passes (96); both in the body. **Behaviour:** 1.3's 3-tree same-dir proof re-run on the lane's start sha, in the body; with `SWEEP_CRON_LOG_DIR` set, section 10's existing cases pass unchanged. Tests: the 4 files of 1.3's grep (run each; `no-literal-paths.tst.sh` in the worktree, 1.5), `satellite-ansible.tst.sh`, `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. | either | claude | simple_coding | 1 |
| 02 `refactor(r80-02-iac-merged-cnf-returns)` | bash that fails safely: a function returns a code (developer guide 2.4.3) | `do_spl_merged_cnf`'s `${1:?}`, `${2:?}`, `${3:?}` exit the caller's shell on an empty argument, so its 16 `run/` callers' `\|\| return 1` never runs (1.4) | `iac lib:spl-merged-cnf.func.sh:58`<br>(+ one new section in `iac:src/bash/tests/cnf-one-key-per-fact.tst.sh`, before `:81`) | 1 site | The site takes 1.4's shape. **New section 4** (1.4): four forms (empty dir, empty env, empty out, no argument) each print `rc=1`, the usage on stderr, write nothing. **Red control:** the test against the parent's lib FAILs 4 assertions (stderr `line 58: 1: cnf dir`, no `rc=` line), then GREEN (14 pass); outputs in the body. **Behaviour:** the 33 test files of 1.4's grep, each as on the parent (1.5). Tests: those 33 (the env-bound ones as 1.5 says), `bash-cleancode.tst.sh`, `cd csi-spl-iac && ./run -a do_check_pre_push`. No GCP: the callers' tests stub it. | either | claude | simple_coding | 1 |

**Re-measure first:** each row lane re-runs its site reads, row 01's baseline count,
`n_sd` and same-dir proof, row 02's `rc=` forms, on the `origin/master` it starts from,
and says in its result if the sites or the counts moved.

**Subject** (R6 reads it): `<type>(r80-NN-<slug>, SPL-<row issue>): ...`; review branch
`review/r80-NN` (R7, 2.7.4; the line box-free in a commit body).

**Docs:** row 01's help is the action's own `@param` line (`:26`, changed by the row); no
`csi-spl-doc/` page outside the round plans names `SWEEP_CRON_LOG_DIR`
(`git grep -n SWEEP_CRON_LOG_DIR -- csi-spl-doc | grep -v round-` -> 0). Row 02 changes
only the empty-argument path, which no caller takes on purpose. Each:
`Docs: none (<why>)`.

### 2.1 Batches (R1, R16)

- **Batch 1: rows 01 and 02.** Their files are disjoint (an orc action, an orc test, the
  orc baseline and an iac test vs an iac lib and another iac test), so both place at
  once.
- No row edits `csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh`,
  `orc:scripts/unanswered-sweep-cron.sh`, `orc:tests/no-literal-paths.tst.sh`, any
  caller of `do_spl_merged_cnf`, the other `${1:?}` lines, `csi-spl-orc/src/make/`, a
  migration, `csi-spl-cnf/`, terraform, `csi-spl-utl/` or `csi-spl-wui/`.

### 2.2 Off every live lane, every queued row and every unlanded row (R3)

Row paths (6): `orc:run/spl-unanswered-sweep-install-cron.func.sh`,
`orc:tests/unanswered-sweep.tst.sh`, `orc:tests/no-literal-paths-spelled.baseline`,
`iac:src/bash/tests/satellite-ansible.tst.sh`, `iac lib:spl-merged-cnf.func.sh`,
`iac:src/bash/tests/cnf-one-key-per-fact.tst.sh`.

- **Lane map, every machine:** `lane-map.sh --check <path> --agent c-680`, one call per
  path, 2026-11-21T05:22:11Z, n=1: **exit 4 on all 6**, the same **19 `unknown:`
  lanes** each time, all on the other box (rotate seats; spec 123 P05 and L2; spec 033
  T025-T027; WUI lanes c-579, c-590, c-610; c-601; c-602; b31-01 c-612). No live lane
  lists a row path; by slug none is on an orc cron installer or the iac cnf merge. The
  holder re-checks before placing.
- **Spawn queue** (`cd csi-spl-orc && ./run -a do_spl_spawn_queue`, 05:22:34Z): **16
  queued, 0 placing**: spec 184 (6, held after SPL-6036), this round's mistral panel
  seat, b31-02 (`done-claim-sha256-prefix-words`), spec 033 T026, spec 123 L3-L7 (held),
  a qto doc media spec, a WUI notes lane. None names a row path by slug. Live share at
  that read: `refactor 3 10% (band 40-60%: UNDER)`, `phase night`; last 24 h
  `refactor 9% (band 20-30%: UNDER)`.
- **Briefs on this box** naming a row path (`grep -lE` of the 6 basenames over the 80
  newest files in `<spool>/dispatch/briefs`, 05:22Z): only landed rounds' briefs (r77,
  r78, r79, the b30 planner) and this one.
- **Remote branches committed in the last 24 h** (64 besides master, 05:22:59Z):
  `git diff --name-only $(git merge-base origin/master <b>) <b>` filtered for the 6
  basenames -> **3 hits**, none a live edit: `review/r79-02` (both its files equal
  master's: `git diff origin/<b> origin/master -- <f> | grep -c '^[-+][^-+]'` -> 0),
  `review/r78-01` and `review/c002-bug-round-30-mistral-seat` (each an older copy of the
  spelled baseline, 1 line off master: the line r79-02 dropped).
- **This box's lane worktrees** (174 besides this one, 05:23:15Z):
  `git -C <wt> diff --name-only origin/master...HEAD` and `git -C <wt> diff --name-only HEAD`,
  same filter -> **2 hits**, none live: `g-537-review` (HEAD `f0e5463e4` of 2026-10-28,
  an old review seat with no `registry.tsv` row) and `m-551` (b30's mistral seat, the
  older baseline copy). The other box's worktrees were not read by this lane.
- **Commits since W** on the row paths (`git log origin/master --since="$W" -- <paths>`)
  -> **0**.
- **Live lanes named in the brief** (05:0xZ): b31-01 (`spl-spawn-review-notify.func.sh`
  + test), b31-02 (`spl-done-claim-check.func.sh` + test, `done-claim-check.md`), spec
  181 B1 (rdb, hub), spec 123 L1 / L2 / P05 / P07 / L0 (terraform, cost, WUI), spec 143
  R1 (rdb, store), spec 033 T025 / T027 (WUI kinds, locales), the WUI lanes, the hub
  `wui.go` lane, spec 189, the release-tooling lane, the seats outside this repo: none on a row path by its listed
  files.

## 3. Per row: what the lane does

- **r80-01:** `do_spl_unanswered_sweep_install_cron` derives its default log dir with
  `spl_var_app_subdir`, its `@param` says so, its line leaves the spelled baseline,
  `satellite-ansible.tst.sh`'s floor follows the count, and section 10 gains the
  default-dir case.
- **r80-02:** `do_spl_merged_cnf` returns 1 with a usage line on an empty or missing
  argument; `cnf-one-key-per-fact.tst.sh` gains section 4.

## 4. Panel and reviewers (R7)

- Editor: c-680 (claude). The panel seat signs the plan sha (rulebook 3.2).
- **Panel seat: requested of the dispatch lease holder** (task `dispatch-refactor-r80`):
  one **cross-vendor** doc seat, the queued mistral seat
  `c002-refactor-round-80-mistral-panel-seat` (agy, the main vendor for plan reviews, is
  out until about 11-24). The seat reviews this plan only.
- **Row reviewers (code R7):** cross-vendor first (2.7.2). `BOX_PICK_KIND=grok
  ./run -a do_spl_box_pick` at 2026-11-21T05:24:02Z -> `pick=hold` (grok weekly 99% on
  both boxes), so each row takes a fresh **claude waiver seat** (1a7c70da), as r63 to
  r79. Not a mistral code R7.
- A row with no reviewer for 15 minutes reports a blocker (2.7.3).

## 5. Proposed row briefs

Each brief carries the plan row verbatim (R4), `Spec: csi-spl-doc/specs/011-spool-project-refactor`,
`Epic: SPL-2402`, a `Topic:` of its own row discussion if the holder opens one (rulebook
4.3), the sites and line numbers of 1.3 and 1.4, its R7 reviewer seat, and "re-measure
first".

| row | placement slug | subject | review branch | batch / after |
|---|---|---|---|---|
| r80-01 | `c002-r80-01-orc-unanswered-sweep-log-dir` | `refactor(r80-01-orc-unanswered-sweep-log-dir-var-app-subdir, SPL-<row issue>): ...` | `review/r80-01` | 1 |
| r80-02 | `c002-r80-02-iac-merged-cnf-returns` | `refactor(r80-02-iac-merged-cnf-returns, SPL-<row issue>): ...` | `review/r80-02` | 1 |

**r80-01 brief, Files: ONLY** `orc:run/spl-unanswered-sweep-install-cron.func.sh`
(`:26` the `@param` line, `:57` the log dir), `orc:tests/no-literal-paths-spelled.baseline`
(drop `:10`), `iac:src/bash/tests/satellite-ansible.tst.sh` (`:272`: `-ge 4` -> `-ge 3`;
`:270-271` unchanged) and `orc:tests/unanswered-sweep.tst.sh` (section 10, one case after
`:280`). NOT `csi-spl-orc/lib/bash/funcs/spl-run-paths.func.sh`, NOT
`orc:scripts/unanswered-sweep-cron.sh`, NOT `orc:tests/no-literal-paths.tst.sh`, NOT any
other line of the action. Do: plan section 2 row 01 verbatim, 1.3's shape; the red
controls (new case on the parent's site; `satellite-ansible.tst.sh` with the old floor on
head) RED then GREEN in the body; the 3-tree same-dir proof. Gates: the 4 test files of
1.3, `satellite-ansible.tst.sh`, `bash-cleancode.tst.sh` (`SPOOL_TEST=1`),
`cd csi-spl-iac && ./run -a do_check_pre_push`. `Docs: none (...)`. Kind
`simple_coding`, vendor claude.

**r80-02 brief, Files: ONLY** `iac lib:spl-merged-cnf.func.sh` (`:58`) and
`iac:src/bash/tests/cnf-one-key-per-fact.tst.sh` (new section 4 before `:81`). NOT any
caller of `do_spl_merged_cnf`, NOT the other `${1:?}` lines (section 7), NOT
`csi-spl-orc/src/make/spl-merged-cnf.func.mk`. Do: plan section 2 row 02 verbatim, 1.4's
shape; the red control (the test against the parent's lib) RED then GREEN in the body.
Gates: the 33 test files of 1.4 (each, rc and pass lines in the body; the env-bound ones
as 1.5 says), `bash-cleancode.tst.sh` (`SPOOL_TEST=1`), `cd csi-spl-iac && ./run -a do_check_pre_push`.
`Docs: none (...)`. Kind `simple_coding`, vendor claude.

## 6. Counts

| metric | n |
|---|---|
| rows | 2 (both `refactor`, both `simple_coding`) |
| vendor | claude 2 |
| batches | batch 1: rows 01 and 02 |
| spelled var-dir lines (`no-literal-paths-spelled.baseline`) | 17 in 15 files today -> 16 in 14 after row 01 |
| `satellite-ansible.tst.sh` `n_sd` | 4 today -> 3 after row 01 (floor `-ge 4` -> `-ge 3`) |
| `local x="${N:?...}"` lines, iac lib + `iac:src/bash/run` | 15 in 7 files today -> 14 in 6 after row 02 |
| measured on | `07f34efeb`; n=1 per command unless stated |

## 7. Left out, measured

| what | why | measured by |
|---|---|---|
| `orc:scripts/spl-desk-reply.sh:9`, `:19` usage text (r79 panel N1, SPL-6107 N1) | a wording row: list the reply action's 12 kinds (`task` is not one); 2 rows taken (5.1); **first candidate for r81** | 1.2 |
| the other `local x="${N:?...}"` lines: iac `gcp-account-pin.func.sh` (5, plus an inline `${1:?key}` at `:159`), `gcp-billing-cnf.func.sh` (2), `parse-metadata.func.sh` (4), `spl-cost-gcp.func.sh` (1), `tf-each-target.func.sh` (1), `validate-params.func.sh` (1); orc `gcp-account-pin.func.sh` (5), `parse-metadata.func.sh` (4), `validate-params.func.sh` (1), `spl-self-host-up.func.sh:317` (1) | one file per row; `gcp-account-pin.func.sh` is byte-identical in iac and orc, and `parse-metadata` / `validate-params` have copies in iac, orc and utl (blob reads: orc = utl for parse-metadata, iac = utl for validate-params), so each is a 2-3-copy row; `tf-each-target.func.sh:14` runs under `set -e` and `TARGET=${TARGET:?}` by design, so the practice does not fit it as is; `gcp-billing-cnf` and `spl-cost-gcp` sit beside the queued spec 123 cost lanes (L3-L7) | 1.2 |
| `spl-spawn-place-argmax.tst.sh` section 9 guard cases (b30-01 R7 N1) | a test row; the placer files sit beside b31's rows | candidates |
| spec 182 L2 `!inserted` branch untested (SPL-6032 R7 N1) | a hub Go test row | candidates |
| `ws-docs-head.mjs` synthetic click (SPL-6115 R7 W1) | WUI test hardening; WUI lanes live (2.2) | candidates |
| `terraform init` without `-input=false`; the desk hop's env forwarding | behaviour changes: bug rows (r78 section 7) | r78 1.2 |
| r77-01 N1 `check-ysg-box-deps.func.sh`; r77-02 N1 `SPL_*` exports | r78 section 7's reasons hold | r78 1.2 |
| the install guide's reverse-tunnel literal (`installation-and-configuration-guide.md:594`) | a Qto export: an ask to the holder | r78 1.2 |
| `spl-spool-refresh.func.sh:55`, `spl-wd-ensure.func.sh:194` | r76 to r79's reasons hold; still in the spelled baseline (`:9`, `:11`) | 1.3 |
| the iac / utl spelled lines; a gate over files outside the existing scope | r77 section 7's reasons hold | r77 1.3 |
| the 3 tenant-dir sites, `gcp-backup-env.func.sh` | secret-class work (the data rule), r73 to r79 | r77 1.3 |
| spec 011 T001-T008, T018-T021, T023, T027, T034 | owner-deferred (2026-09-19), an open owner decision, behaviour, or the full sweep; the spec folder unchanged since W | 1.2 |

## 8. Changes

- v0.1 (c-680): first draft. A fresh round: row 01 moves the unanswered-sweep
  installer's default log dir onto `spl_var_app_subdir` (same dir on this box's 3 tree
  kinds, 3 of 3), lowers the spelled baseline and moves `satellite-ansible.tst.sh`'s
  `n_sd` floor with the count; row 02 makes `do_spl_merged_cnf` return 1 on an empty
  argument. Every named test run on the row's head (1.5). Window W and the r80 slug
  proof recorded.
- v1.0 (c-680): the panel seat m-691 (mistral) PASS on v0.1
  `7329be64194f2eb72715b4b5f9f3f9e606afc2c4` (spool msg 3900b82c to the editor, task
  `dispatch-refactor-r80`; seat file `bc9b18189` on
  `review/c002-refactor-round-80-mistral-seat`, folded into this landing), no W finding. Its notes, none changing a
  row:
  - N1: row 02 changes only the empty or missing argument path (an exit becomes
    `return 1` plus a usage line), which no caller takes (18 calls in `iac:src/bash/run`,
    4 in libs and make, all with non-empty arguments): disclosed in 1.4 and pinned by
    section 4's control, as r78-02 was. Recorded; no change.
  - N2: counting conventions. The spelled baseline is 16 file lines (a comment and 15
    entries) by `wc -l`. This plan counts as the gate and r79 do: the sum of the entries'
    first column, `awk 'NR>1{n++; s+=$1} END{print n, s}'` on `07f34efeb` -> **15 entries,
    17 counted lines** (two entries count 2). Both conventions give the same row delta (one
    entry, one counted line, `:10`). `cnf-one-key-per-fact.tst.sh` "before 10" in 1.5
    counts 9 assertion PASS lines plus the final `PASS: all`. The red run prints 9 PASS
    and 4 FAIL, and no `PASS: all`. Green prints 14, the final line included.
  - N3: the lane map read 15 `unknown:` lanes at the seat's read against 19 at
    05:22:11Z, none on a row path by slug: the holder's re-check before placing is the
    one that counts.
- Round closed (c-680), no version bump: the 2 rows landed, r80-01 `f886bfcdd`
  (SPL-6156, R7 c-653 PASS on `23141fe5e`), r80-02 `5083f4cf9` (SPL-6158, R7 c-672
  PASS on `937bc49b8`); both R7 seats claude under waiver 1a7c70da (grok pick on hold).
  c-653's review line reads the new section 10 case RED on the parent's site (rc 1, 70
  pass) and GREEN on head (rc 0, 71 pass), the old `n_sd` floor RED on head, and the
  hand form equal to `spl_var_app_subdir` on 3 of 3 trees; c-672's reads section 4 of
  `cnf-one-key-per-fact.tst.sh` RED against the parent's lib (4 FAIL) and GREEN on head
  (14 PASS), and the merged cnf byte-identical parent vs head for dev, prd and lde.
  `merge-base --is-ancestor` rc 0 for both on `5083f4cf9`. On that sha (n=1 each,
  `SPOOL_TEST=1`): the spelled baseline **14 entries, 16 counted lines** (15 / 17 before,
  as planned); `satellite-ansible.tst.sh` floor `-ge 3`, rc 0, 96 pass;
  `unanswered-sweep.tst.sh` rc 0, 71 pass; `cnf-one-key-per-fact.tst.sh` rc 0, 14 pass;
  `bash-cleancode.tst.sh` rc 0, 15 pass; `no-literal-paths.tst.sh` (worktree) ALL PASS
  (15). Status line and sections 8 and 9 only.
  - **Count drift, no miss:** row 02's lane read `hub-payment-030.tst.sh` at 13 pass
    lines where 1.5 says 11. c-672's review line reads 11 + 1 SKIP without `TPL_GEN_DIR`
    and 13 with it, on head and on the parent alike: 1.5 counted the run without
    `TPL_GEN_DIR`. `conf-validator-exit-codes.tst.sh` stayed NOT RUN on this box, as 1.5
    said.
  - **First inputs for round 81:** section 7 as it stands, re-measured; the remaining
    `local x="${1:?...}"` lines (r78 1.4) less this round's one file, re-counted.

## 9. Consensus

The panel seat signs this plan (rulebook 3.2).

- Editor seat: c-680 (claude): v0.1, v1.0.
- Panel reviewer seat: **m-691 (mistral) PASS** on
  `7329be64194f2eb72715b4b5f9f3f9e606afc2c4` (spool msg 3900b82c; seat file `bc9b18189`
  on `review/c002-refactor-round-80-mistral-seat`, in
  `csi-spl-doc/doc/md/refactor-round-80/seat-mistral.md`), N1-N3 recorded. agy was
  unavailable (out until about 11-24), so mistral took the seat. The holder's
  review-line check on that line: rc 0 ("OK 4 of 4 ran: tests found in" the seat's
  session log; holder GO msg 4393fa3a, the GO given by hand because review-go held a
  plan panel line with no `Author:`, rc 3).
- Panel delta: **m-691 (mistral) PASS** on v1.0
  `d02aea0f88896cde76c1be07c3c43f6723505466` (seat file `b41ffd195` on
  `review/c002-refactor-round-80-mistral-seat`): v1.0 changes no row (`git diff
  7329be641 d02aea0f8` on the plan, 2 hunks: the status line and sections 8 and 9). The
  holder's review-line check on the resent line: rc 0 (holder note 06:35:10Z; the first
  line named another seat's log, rc 1, sent back).
- Row R7 seats: section 4.
- Closed: both rows landed (r80-01 `f886bfcdd`, R7 c-653 PASS; r80-02 `5083f4cf9`,
  R7 c-672 PASS). This close record carries `Closes: SPL-6148`.
