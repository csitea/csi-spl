# Pre-push gate — fast tier and lint parts

> Generated from qto doc `82ec98e2-5ad7-4561-bfc2-58c0856483f0`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

The reference for what `./run -a do_check_pre_push_lint` (and the lint leg of
the pre-push hook, `./run -a do_check_pre_push`) runs. The rule itself lives in
the repo [CLAUDE.md](../../../CLAUDE.md): run the cheap gate for the tree you
touched, before you push.

<a id="ws-doc-8fe59b6f-cef9-4409-8118-54818c89ff00"></a>
## 1. The hook's FAST tier

The pre-push HOOK runs `do_check_pre_push` in its FAST tier (CLE-77824,
owner 2026-10-01; it had grown to 16 min for iac and >10 min for api, so
pushes race-lost trunk for hours). It runs only the parts the push touches
(`origin/master...HEAD`), re-uses a part's green verdict while the paths that
part reads are unchanged (a rebase over other lanes' commits re-runs
nothing), FAILS on a missing tool instead of WARNing, and writes one
`PART <part> PASS|PASS-cached|WARN-pre-existing trunk=<sha>|FAIL|SKIP-untouched <secs>`
line per part to `~/.cache/csi-spl/pre-push.log`. A run that passed every
part on a clean tree records it in `pre-push.tree.pass` (key: `HEAD^{tree}`,
parts, tier, merge-base, the gate's own code); the hook then logs
`PART tree PASS-tree` and re-runs nothing on that tree. An override, a
lint-only run or a WARN-pre-existing pass never records one. Moved to CI only, because
each costs minutes and workflow 10 (and the 20 deploy gate) already runs it
on every push and fails on a skip: api `go test -race` (plain `go test`
stays), `build-stripped`, `hub-pg` (~384 s), `hub-gcs`; iac tests whose
header says `# pre-push-tier: slow` (terraform validate, tpl-gen renders).

<a id="ws-doc-4a16087d-2c47-4e27-829f-2ce3d0027f1c"></a>
### 1.1 Scope and verdict cache

- **Scope** is this push's own commits: `origin/master...HEAD` (from the
  merge-base), plus the working tree. Commits other lanes landed on trunk
  never select a part, before or after the rebase.
- **The blog part** (spec 111 4.4) runs when the push touches
  `csi-spl-doc/blog/` or the check itself: `do_spl_blog_check` (csi-spl-orc)
  on the post files this push adds or changes, plus the commit shape of
  `origin/master..HEAD`. With a post file it reads the release-note ban list
  through the per-env SA and fails closed when that list is unreadable or
  empty. On the trunk worktree nothing has changed, so a refused post is never
  waived as WARN-pre-existing.
- **What the wui part reads** outside `csi-spl-wui` is taken from
  `tests/unit/*.mjs` and `src/node/**/*.mjs`. A `<dir>/...` literal counts
  when it names a FILE in the tree, when it names a directory on a line
  that reads it (`join(REPO, '.github/workflows', wf)`), or when it carries
  a template. A template becomes a glob: `csi-spl-cnf/csi-spl/${env}.env.json`
  is `csi-spl-cnf/csi-spl/*.env.json`, not the whole directory. A directory
  named only as fixture data or in a message is not an input. On 2026-10-04
  the `csi-spl-doc/specs` fixture in `docs.test.mjs` made every spec
  `tasks.md` tick select the 3..5 min wui part and miss its cache, and 4
  lanes lost the trunk ref lock to it within an hour. Print the list:
  `bash -c '. csi-spl-iac/src/bash/run/check-pre-push.func.sh; _pp_wui_external .'`.
- **The wui-e2e part** (spec 133 action 7) runs the browser e2e files a
  WUI change maps to: an edited test itself, a helper's importers, and the
  tests that name a testid (or a page's route) of the changed file or of the
  files that use it, never through the layouts. First each changed source
  file's best test, then the tests that name the changed files' own
  testids (`data-test` too), then the score (SPL-3612); at most
  `PRE_PUSH_E2E_MAX` files (6) summing to `PRE_PUSH_E2E_BUDGET` CI seconds
  (240); the rest print as left to CI. A change to a layout, `app.vue` or
  `main.css` also scores the tests by the shell's `data-*` state attributes
  it names (`data-mobile-level`), at weight 9 (SPL-4139): a shell change
  still cannot run all 31 data-mobile-level tests within the cap; the 4
  tests that went red after 46afd70ba stay CI-only; panel 3.4 is only partly
  fixed. The part also checks the bundle it builds against
  `perf-budgets.json`, as wf 10 does (SPL-4129). The mock bundle is cached
  by the WUI tree without e2e contents: measured 2026-10-12 on the first
  box, 152 s cold (113 s build), 31 s warm, n=1 each, for 2 files. Print a
  selection:
  `WUI_E2E_RANGE=origin/master..HEAD ./run -a do_check_pre_push_e2e`.
  `PRE_PUSH_E2E=0` turns it off.
- **The orc part**, fast tier, runs the orc `*.tst.sh` that name a touched
  file or a function it defines, plus the always-run list
  (`run-all-tests.sh --changed`; the map is
  `csi-spl-orc/src/bash/tests/changed-tests.sh`, the list its
  `ORC_TEST_ALWAYS`). When the map answers `full` (a touched orc file that no
  test names), the whole suite is left to CI workflow 10 or
  `PRE_PUSH_TIER=full`, and the fast tier still runs the always-run list and
  prints it (`the fast tier still runs the always-run list: ...`); an empty
  list prints that no orc test runs (SPL-5607). Before it, a `full` plan ran
  no orc test: 33 of 150 orc commits (22%), and whole-tree guards such as
  `run-eager-files.tst.sh` reached trunk red
  ([ci-failures-50](ci-failures-50-2026-11-15.md) T2).
- **The orc-features part** (spec 133 F1) runs wf 10's orc feature tests
  (`features/run-ci-tests.sh`) for the features a csi-spl-orc change maps
  to: a file under `features/<f>/` selects `<f>`, a file directly under
  `features/` selects all of them, and any other orc file selects the
  features whose `tests/test-*.sh` name its basename or stem as a whole
  word. Before it, a change there made the orc map fall back to `full`,
  which the fast tier leaves to CI. The orc map
  (`csi-spl-orc/src/bash/tests/changed-tests.sh`) therefore ignores a
  feature test file no orc test names (`features/<f>/tests/...`) instead
  of answering `full`, so the orc part still runs what the rest of the
  change selects, and `run-eager-files.tst.sh` (3 s, it names no file) is
  on its always-run list with `require-cloud-env.tst.sh` (SPL-5606: the
  feature test of 035dc1501 forced `full`, so `lane-restart.tst.sh`, which
  went red on trunk, ran only in CI). spawn-agents (80 files) took 85 s on
  the first box at load 15.7, n=1; the budget is the table rows
  `orc_features_fast` and `orc_features_full` (section 1.4), raised by
  `PRE_PUSH_FEATURES_TIMEOUT`. Print a selection:
  `FEATURES_RANGE=origin/master..HEAD ./run -a do_check_pre_push_features`.
  `PRE_PUSH_FEATURES=0` turns it off. A feature test the selection cannot
  read fails closed: the plan names `ERROR orc-features` and the part runs
  every feature, so the unreadable test goes red instead of being skipped
  (SPL-5669); a path no test names still selects nothing.
- **The iac-cross part** runs the csi-spl-iac tests that read files of
  other parts, when a push touches those files but not the iac part's own
  paths (the whole iac suite runs them then). Each test has a row in
  `_PPX_MAP` (`csi-spl-iac/src/bash/run/check-pre-push-cross.func.sh`)
  naming what it reads; an orc file selects `comment-refs-exist`, the
  `gcp-*` scans and the satellite tests, a doc/help file selects
  `help-connect-agent`, and so on. Three rows read the whole tree
  (`domain-single-source`, `no-key-material-in-tree`,
  `gcloud-account-pinned`): they run on every such push, about 2 s.
  Before it, 16b39bb9f and 947ec0844 each changed only an orc file and
  its test, passed the gate, and turned wf 10's iac job red on
  `comment-refs-exist`. The key is the selected tests, their runner and
  the paths their rows name. A new iac test that reads another part's
  tree without a row fails `check-pre-push-scope.tst.sh` (case 18). Print
  a selection: `CROSS_RANGE=origin/master...HEAD ./run -a do_check_pre_push_cross`.
  The cnf, the WUI copy or the hub copy of the per-kind vendor split
  selects `agent-split-one-source` (under 1 s): both compiled copies must
  equal cnf `env.box.agent_split_by_kind` (SPL-4876, after e696477ab).
  `PRE_PUSH_CROSS=0` turns it off.
- **The cache key is content**: the git trees and blobs of what the part
  reads, plus the tier and the gate version. No commit sha and no base sha,
  so a re-push after a rebase that brought in only files the part does not
  read takes seconds. wui also keys on `node -v` and `pnpm -v`. lint-migration
  keys on the whole migration dir at HEAD and on the base, because its
  prefix rule reads both. Keyed on the touched files alone, a rebase over
  another lane's same-numbered migration re-used the old green.

- **Commit messages are swept too** (SPL-5613). csi-spl is public, and a
  push of any branch publishes its commit messages. `do_check_dist_hygiene`
  reads tracked files only, so on 2026-11-14 a wip push published a hidden
  workspace slug in a commit body with every gate green.
  `do_check_commit_msg_hygiene` (csi-spl-iac) writes each message as
  `<sha>.msg` and runs the same Sweep step of `10_ci-quality.yml` over them:
  one pattern list, no cnf allowances. A hit names `<sha>.msg:<line>` and the
  pattern label, never the matched text. Two places run it:
  - the `hygiene` part, over `PRE_PUSH_BASE..HEAD`. The tree-pass record keys
    on those messages, so a reword re-runs the gate.
  - the hook itself, uncached, over exactly what each pushed ref adds:
    `<remote sha>..<local sha>`, and for a new ref the commits not on
    `<remote>/master`. It runs before the poisoned-config guard, the wip
    skip and the override, so neither `SPL_PREPUSH_OVERRIDE=1` nor a
    wip-only push skips it. The tree that runs it is the first of the hook's
    cwd, `show-toplevel` and the repo's main checkout that has the
    action, so a `core.worktree` in the common config, even
    one pointing at another directory, does not skip it either. A tree with
    none of them (not the spool repo) is not swept.
  A refused watchdog wip push (`do_spl_lane_wip_push`) keeps the work local.
  It sends ONE blocker to the lane and the orchestrator, naming the sha:line
  and the pattern, on task `wip-hygiene-<id>`. The same hits are not sent
  again. To fix it, reword the commit (`git commit --amend` or
  `git rebase -i`). No CI job reads commit messages, and by the time CI runs,
  the push is already public.

<a id="ws-doc-72c4e586-63ed-4500-b316-5d48f5713b75"></a>
### 1.2 The override

It is used only on the owner's go for that one push, never an agent's
([fleet rules index](fleet-rules-index.md) section 2, "never force-push
master"): a refused push is fetch, rebase onto `origin/master`, re-test and
push again, and the hook's refusal says so.

`SPL_PREPUSH_OVERRIDE=1 git push` skips the slow parts but still runs
`hygiene` and `lint-migration` (`PRE_PUSH_ONLY=override`, seconds,
`PRE_PUSH_LINT=0` cannot drop them) and refuses the push when one fails.
On 2026-10-04 an override that skipped everything landed a duplicate
migration 0119. Only a poisoned shared git config (`core.worktree` in the
common config), which makes the gate read the wrong tree, skips them too
(audited) so whoever fixes it can push the fix. The commit-message sweep
(section 1.1) runs before that guard: it reads each message by sha and does
not take its tree from `show-toplevel` alone, so a poisoned config that points
`core.worktree` at the pushing repo or at another directory does not skip it.

<a id="ws-doc-0c7adbf7-0d0b-408b-be5a-fd5b40ff37da"></a>
### 1.3 Pre-existing on trunk: same failures, not the same exit code

A part that fails is re-run on `origin/master`, and it WARNs
(`WARN-pre-existing`, push allowed) only when **every** failing item on your
tree also fails on trunk. The gate compares failure signatures, not exit
codes: each part's output becomes a set of normalised items (`--- FAIL:`
test names, `go-pkg`, `gofmt` files, `file: message` diagnostics from vet,
tsc, shellcheck and hygiene with line:col dropped, bash `FAIL:` /
`FAILED: <file>` lines, TAP / node / playwright titles, the lint parts'
`SYNTAX` / `LOCKFILE` / `GO MOD` lines), with the tree root, `/tmp` paths,
hex ids and durations stripped. An item trunk does not have FAILs the push
and is logged `NEW on your tree: <items>`, beside `pre-existing: <items>`.
A part whose output names no item FAILs too (fail closed). On 2026-10-05
c-304's new gofmt and `TestCleanCodeGate` failures passed as
"pre-existing" behind an unrelated trunk red, because both trees merely
exited non-zero. A suite that stops at its first failing step (the api
suite is `set -e`) can still hide a later new failure behind that step.
The wui-e2e re-run on trunk runs only the push's e2e files that trunk has:
one INFO line names the ones the push adds, which have no baseline and stay
NEW if they fail (SPL-5345; the runner used to die "file(s) not found" on
them, and every e2e red read NEW).
A `perf-*.sh` budget is report-only in the local gate too, as in CI
(`run-ci-tests.sh`): its section of the orc-features output, from
`=== perf, reported, not gating:` to its `PASS` / `OVER BUDGET` line (CI
prefixes that line with `::warning::`), yields no item (SPL-5330). A run
killed by the part's timeout prints no closing line; the runner's
`UNFINISHED` and the part's `FAILED:` lines then end the section and count.
See `_pp_sig` in `csi-spl-iac/src/bash/run/check-pre-push.func.sh`.

<a id="ws-doc-caf371ff-0217-4092-b7c8-5f2bdc81e685"></a>
### 1.4 The part budgets: one cnf table

Every part runs under a budget in seconds, and every budget is a row of ONE
cnf table, `env.prepush.part_budget_s` in
`csi-spl-cnf/csi-spl/all.env.yaml` (SPL-5574; tpl-gen renders it into
`<env>.env.json`). No budget is a literal in code: `_pp_budget` in
`csi-spl-iac/src/bash/run/check-pre-push.func.sh` reads the table once per
gate run, and `csi-spl-iac/src/bash/tests/check-pre-push-budget-table.tst.sh`
fails a part that carries its own number. A part's row is `<part>_<tier>`,
else `<part>`, else `default` (`<part>` is the part function's name after
`_pp_part_`, e.g. `wui_e2e`, `lint_gosec`). A row with a `<row>_cap` is
load-scaled: the row times the box load per cpu (`load1 / nproc`, read once
per run) when that is over 1, never above the cap
(`PRE_PUSH_<ROW>_CAP`, e.g. `PRE_PUSH_API_FULL_CAP`, wins over it).

Each row is the measured p95 times 1.5, rounded up to 10 s, of the part's
last 50 runs that PASSed on that tier:

`cd csi-spl-iac && ./run -a do_report_pre_push_part_times`

It reads the gate's PART lines (`PRE_PUSH_TIMES_LOGS`, a space-separated
list of logs, one per box user; default the caller's
`~/.cache/csi-spl/pre-push.log`; `PRE_PUSH_TIMES_N`, default 50) and prints
per part and tier n, p50, p95, max, how many runs in that window TIMED OUT,
and the budget. A TIMED OUT run's real time is not in the log, so p95 is a
floor where that count is not 0. The table's comment holds the measurement
the rows came from; re-measure and update the rows there, never in code.
`default` (300 s) is kept above p95 times 1.5 of every part that reads it.

One rule sets every part's budget, on both tiers (`_pp_part_var` and
`_pp_budget`, SPL-5238): the part's own variable, when set, wins; else
`PRE_PUSH_PART_TIMEOUT`; else the part's row in the table. The own variables are
`PRE_PUSH_API_FULL_TIMEOUT`, `PRE_PUSH_IAC_FULL_TIMEOUT` and
`PRE_PUSH_ORC_FULL_TIMEOUT` (full tier only), `PRE_PUSH_WUI_TIMEOUT`,
`PRE_PUSH_E2E_TIMEOUT` (wui-e2e) and `PRE_PUSH_FEATURES_TIMEOUT`
(orc-features); every other part has none. Before SPL-5238 the wui and
wui-e2e parts ignored `PRE_PUSH_PART_TIMEOUT`: a push with 1500 still TIMED
OUT at 420 s and 600 s (c-463, n=1); the wui-e2e part's own `timeout` now
reads `_pp_budget` too (`check-pre-push-e2e.func.sh`). The rule cuts both
ways: a variable you set can also lower a budget, so
`PRE_PUSH_PART_TIMEOUT=100` gives wui 100 s instead of its row.
A part that runs out logs
`TIMED OUT after <n>s (<why>)`: the why names the variable that set the
budget, or, for a default budget, the default and the variable that raises
it (for a load-scaled one also the base, the load it read and the cap).
A part that TIMED OUT (rc 124 or 137) on your tree is never compared by
signature (SPL-5588): its output stops wherever the budget ran out, so it is
FAILed as "not proven your break; re-run it, or raise its timeout budget".
Its verdict reads `trunk=not-checked timed-out-not-compared`, with no `new=`
count: the part is not re-run on trunk and no base tree is built (p13-01,
SPL-5779). The verdict never depended on trunk, so that re-check was time
with no effect: 1,011 s and 2,708 s after the timeout (n=2, 2026-11-16). To
know whether trunk is red too, run the part on trunk by hand.
Before SPL-5588, only a green trunk got the timed-out verdict; on a red trunk the cut-off
run went to the signature compare, and one HEAD (5b647ab99, box sat,
2026-11-14) read `WARN-pre-existing` once and `new=1` 20 min later (n=2).
A test's planted control prints no `FAIL` line either: a killed unit run has
no runner summary, so every printed `FAIL` counts
(`auth-i18n-keys.test.mjs` now runs its control silently).
A lint part has no own variable and runs under that same timeout (SPL-5529): the budget is `PRE_PUSH_PART_TIMEOUT` when set, otherwise its table row (`lint_<scanner>_<tier>`, else `default`), a hang returns 124 or 137 so the gate logs `TIMED OUT` and the part's process group, including a scanner child, is killed, and because `PRE_PUSH_PART_TIMEOUT` also binds every other part with no more specific variable (full-tier orc, api and iac) it must not be set to cap a full-tier orc run (raise that with `PRE_PUSH_ORC_FULL_TIMEOUT`); the full-tier `lint-gosec` has its own row (`lint_gosec_full`).

A process a part leaves behind (a test's `setsid` child, a test daemon that
escaped its cleanup) can no longer hold the hook past the part's budget
(SPL-3907). Such an orphan kept the part's output pipe open, so the hook
waited forever: 2h10m and 65 min lost on 2026-10-27 (n=2). Once the part
returns, its output gets `PRE_PUSH_ORPHAN_GRACE` seconds (default 5) to
drain; every process still holding the pipe is then sent TERM, KILL after
the same grace, and the log names each one: `WARN pre-push: orphan pid <pid>
(<command>) still held the part's output pipe ...`. That line points at the
test that leaks a process; fix the test, the hook only cleans up after it.
The orc runner hands a test no fd beyond its own stdout and stderr.

<a id="ws-doc-2a614fe9-783d-4d85-bc3f-8d6843822bcf"></a>
## 2. Lint parts

**Lint parts** (CLE-77829, owner 2026-10-01: "why cannot they be ran via
shell actions locally before someone pushes?!"). The hook runs each GitHub
scanner on the files the push TOUCHES, through the same `do_sec_*` action,
binary version (read from the workflow's pin), config, severity and
baseline as CI, so a local PASS is a CI PASS for those files. A file the
push does not touch is never scanned, so its old finding cannot block you.
Tools: `cd csi-spl-iac && ./run -a do_install_lint_tools` (sha-checked
against the workflow pins; `LINT_TOOLS_SYSTEM=1` also copies them
root-owned into `/usr/local/bin` for every user). A FAIL prints the exact
command that reproduces it.

| part | CI | checks | tier |
|---|---|---|---|
| `stale-tree` | — | each outgoing non-merge commit: a path set back to a blob it held before one of its last 40 commits (not the parent's) counts, and so does a path it deletes that another commit (not outgoing, not citing the commit's own SPL-n) added or changed within the last 40 commits; renames (git `-M`) and adds never count. 3 or more -> REFUSED; a counted path whose current content came from another lane's commit of the last 24 h refuses ALONE. Each path is named with the commit it would undo. Exempt: a subject starting `Revert` or containing `restore`; a body line `Undoes: <sha>` drops the paths of that one commit (r6-05, after 8bb97690e set 26 paths back; SPL-2253, after m-260's stale copy would have deleted 3 files of other lanes, which the 3-path count missed). Every tier and mode, not the override; never cached. Alone: `STALE_TREE_RANGE=<a>..<b> ./run -a do_check_pre_push_stale_tree` | hook |
| `wui-lang-review` | 10 (`wui-lang-review`) | each outgoing non-merge commit that touches `csi-spl-wui/i18n/locales/*.json` and adds a key or changes a value (`lang-review-keys.py` compares the file with its parent) carries a body or trailer line `Lang-review: a-NNN <msg id>`: the agy seat that reviewed the new text and its message id (SPL-5551, csitea weekly item 11: 15 language-fix commits followed a land, e.g. 15151a0e8, 8ad692de1). An agy review (`a-NNN`) is the rule. A Claude review (`c-NNN`) stands in only with the owner's waiver message id on the same line, `Lang-review: c-NNN <msg id> waiver <owner msg id>` (8+ hex each, SPL-5767), and the agy review still follows; the first case is the owner's answer B (t1 028ac340, msg 3a71dac1) for SPL-5706 and SPL-5707. A bare `c-NNN` line, a waiver with no id and any other seat prefix do not count. Without it the part fails with one line per commit naming the first key and how to get the review (`/agy-spawn`, `LANE_MIX_KIND=i18n`). Exempt: a commit that only removes keys; an en.json-only change of keys listed under `keys` of `csi-spl-wui/i18n/i18n-lang-review-exempt.json` (typo fixes); a landed commit listed by its full sha under `commits` there, which turns CI green again without rewriting history. The rule it checks, agy has the final word on multilingual text, lives in the fleet `CLAUDE.md` part `20-spawn-an-agent.md` ([fleet rules index](fleet-rules-index.md)). Selected when the push touches the locales, every tier and mode, not the override; never cached; the tree-pass key carries the outgoing commit messages. CI checks every commit since the commit that added the exempt list. Alone: `LANG_REVIEW_RANGE=origin/master..HEAD ./run -a do_check_pre_push_lang_review` | hook |
| `lint-syntax` | — | `bash -n` (.sh, `#!..sh` scripts), YAML/JSON/TOML parse + duplicate keys (`config-syntax-check.py`), `make -n` (orc Makefile) | hook |
| `lint-migration` | — | a migration already on trunk is never edited/renamed/deleted (`SPL_MIGRATION_EDIT_OK=<file>` allows one, logged); a new one parses with the PG16 grammar (pglast 6.x). It runs in `PRE_PUSH_MODE=full` too, on the migrations that differ from the base (SPL-5379). A migration renamed or moved OUT of the dir counts by its old path: the change list is `git diff --no-renames`, so every part that reads that list sees a rename as a delete + add, and a push with any `csi-spl-cnf/csi-spl/` path runs the `cnf` part, next to `iac` when the push is not cnf-only (SPL-5409). With an unknown base, full mode logs `WARN pre-push: cannot diff against '<base>'` and lint-migration checks none, never a silent `SKIP-untouched` (fast mode widens to full with the same WARN) | hook |
| `lint-compose` | — | `docker compose config -q --no-interpolate` | hook |
| `lint-gitleaks` | 15 | `do_sec_scan` secrets, `.gitleaks.toml`, over the PUSHED commits only | hook |
| `lint-py` | — | touched `.py` compile + ruff 0.16.9 `E9,F` + a zero-baseline security subset; python heredocs in touched `.sh`/`.yml` compile | hook |
| `lint-tf` | — | touched `.tf`: `terraform fmt -check` (cnf's `terraform_version`); touched `.tfvars`: HCL parse. tflint / validate / trivy / render parity stay CI (wf10/70) + `PRE_PUSH_TIER=full` | hook |
| `lint-wui-syntax` | — | per-file Vue SFC compile (script + template) and TS/JS parse: the template error class typecheck and `nuxt generate` pass | hook |
| `lint-wui-lock` | — | `pnpm install --frozen-lockfile --lockfile-only` when `package.json`/lock change | hook |
| `lint-shellcheck` | 67 | `do_sec_shellcheck` -S error, iac/orc/cnf bash trees | hook |
| `lint-actionlint` | 85 | `do_sec_actionlint`, with a control proving its shellcheck leg ran | hook |
| `lint-hadolint` | 66 | `do_sec_hadolint` vs `.hadolint.yaml` | hook |
| `lint-eslint` | 63 | `do_sec_eslint` vs `.eslint-security-baseline.txt` | hook |
| `lint-trufflehog` | 64 | `do_sec_trufflehog` --only-verified, every touched file | hook |
| `lint-mdlinks` | — | relative links in touched `.md`, and in the `.md` that link to a deleted/renamed path | hook |
| `lint-typos` | — | typos-cli 1.50.3 + root `_typos.toml`, ADDED lines only; WARN, never blocks (a real word goes in `_typos.toml`) | hook |
| `release-note` | — | every commit in the pushed range carries the six release-note trailers or a special form ([release-notes.md](../help/release-notes.md)); WARN, never blocks, until spec 065 L11; prints `RELEASE_NOTE_CHECK ... commits=<n> warn=<n>`; alone: `./run -a do_check_release_note` | hook |
| `lint-semgrep` | 61 | `do_sec_semgrep` vs `.semgrep-baseline.txt` on the touched hub `.go` / WUI src files (~11 s; whole scope 152 s) | hook |
| `lint-gomod` | — | `go mod tidy -diff` (offline) when `go.mod`/`go.sum` change | hook |
| `lint-sigpipe` | — | touched `.sh` under pipefail (it sets it, or is a `*.func.sh` run by `./run`): no early-exit consumer (`\| grep -q`, `\| grep -m`, `\| head`) after a producer -- the producer dies of SIGPIPE (141) and the pipeline reads false. Fix: `grep ... >/dev/null`, `sed -n 1p`, a here-string; a reviewed safe site carries `# sigpipe-ok: <why>` (`sigpipe-lint.sh --list-optouts` lists them) | hook |
| `lint-tmp-path` | — | touched e2e `.mjs`, `*.tst.sh` and Go `_test.go`: a fixed `/tmp/<name>` or `/var/tmp/<name>` write (a quoted path, a redirect, or an assignment). A per-run dir is `mkdtemp`, `mktemp -d`, `t.TempDir` or `SHOT_DIR`. Counts in `.tmp-path-baseline.txt`; a new one fails (`tmp-path-lint.py`) | hook |
| `lint-checkov` | 65 | the action over its whole scope (65 s) | `PRE_PUSH_TIER=full` + CI |
| `lint-gosec` | 62 | `do_sec_gosec` on the hub packages the push changes (`SEC_GOSEC_PKGS`, SPL-5787): the dir of each changed `.go` under `csi-spl-api/src/go/spool-hub-api/`, a deleted file's dir while it still holds a `.go`; the gate compares only the `.gosec-baseline.txt` lines of the files in those packages. `./...` (>300 s) when `go.mod`/`go.sum`, `sec-gosec.func.sh`, `.gosec-baseline.txt` or `62_gosec.yml` change, in `PRE_PUSH_MODE=full`, in the weekly scan and in CI wf 62. A finding that a change in one package makes gosec report in an unchanged package is found by wf 62 after the push | `PRE_PUSH_TIER=full` + CI |
| CodeQL / DAST | 60 / 68 | need the whole repo / a live host | CI only |

**Weekly full scan** (Friday 21:00 box time, the night of
[spec 166](../../specs/166-orchestrator-daily-rhythm/spec.md) row B7; owner
2026-10-01 had Friday 17:00): every one
of those scanners over the WHOLE scope, plus checkov, gosec, semgrep,
govulncheck, trivy, OSV, gitleaks history and pnpm audit, for csi-spl and
csi-web: `./run -a do_check_weekly_full_scan` (DRY_RUN=1 prints the plan).
The report is `~/.cache/csi-spl/weekly-scan/<date>.md`, and a short summary
goes to #spool-hub-ops as OPS-01. The cron line is
`./run -a do_install_weekly_full_scan_cron` (DRY_RUN=1 prints the crontab
diff; exact end-of-line tag `# csi-spl:weekly-full-scan`). GitHub keeps a
weekly schedule only for CodeQL (60) and DAST (68).

A change to a scanner's own action, config, baseline or workflow re-runs it
over its whole CI scope. Rollback without a revert: `PRE_PUSH_LINT=0 git push`
(logged, every lint part SKIPPED; the CI scanners still run after the push).
