# Pre-push gate — fast tier and lint parts

> Generated from qto doc `82ec98e2-5ad7-4561-bfc2-58c0856483f0`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

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
  files that use it, never through the layouts. Best score first, at most
  `PRE_PUSH_E2E_MAX` files (6) summing to `PRE_PUSH_E2E_BUDGET` CI seconds
  (240); the rest print as left to CI. The mock bundle is cached by the WUI
  tree without e2e contents: measured 2026-10-12 on the first box, 152 s
  cold (113 s build), 31 s warm, n=1 each, for 2 files. Print a selection:
  `WUI_E2E_RANGE=origin/master..HEAD ./run -a do_check_pre_push_e2e`.
  `PRE_PUSH_E2E=0` turns it off.
- **The orc-features part** (spec 133 F1) runs wf 10's orc feature tests
  (`features/run-ci-tests.sh`) for the features a csi-spl-orc change maps
  to: a file under `features/<f>/` selects `<f>`, a file directly under
  `features/` selects all of them, and any other orc file selects the
  features whose `tests/test-*.sh` name its basename or stem as a whole
  word. Before it, a change there made the orc map fall back to `full`,
  which the fast tier leaves to CI. spawn-agents (80 files) took 85 s on
  the first box at load 15.7, n=1; the budget is `PRE_PUSH_FEATURES_TIMEOUT`
  (300 s). Print a selection:
  `FEATURES_RANGE=origin/master..HEAD ./run -a do_check_pre_push_features`.
  `PRE_PUSH_FEATURES=0` turns it off.
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
  `PRE_PUSH_CROSS=0` turns it off.
- **The cache key is content**: the git trees and blobs of what the part
  reads, plus the tier and the gate version. No commit sha and no base sha,
  so a re-push after a rebase that brought in only files the part does not
  read takes seconds. wui also keys on `node -v` and `pnpm -v`. lint-migration
  keys on the whole migration dir at HEAD and on the base, because its
  prefix rule reads both. Keyed on the touched files alone, a rebase over
  another lane's same-numbered migration re-used the old green.

<a id="ws-doc-72c4e586-63ed-4500-b316-5d48f5713b75"></a>
### 1.2 The override

`SPL_PREPUSH_OVERRIDE=1 git push` skips the slow parts but still runs
`hygiene` and `lint-migration` (`PRE_PUSH_ONLY=override`, seconds,
`PRE_PUSH_LINT=0` cannot drop them) and refuses the push when one fails.
On 2026-10-04 an override that skipped everything landed a duplicate
migration 0119. Only a poisoned shared git config (`core.worktree` in the
common config), which makes the gate read the wrong tree, skips them too
(audited) so whoever fixes it can push the fix.

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
See `_pp_sig` in `csi-spl-iac/src/bash/run/check-pre-push.func.sh`.

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
| `lint-syntax` | — | `bash -n` (.sh, `#!..sh` scripts), YAML/JSON/TOML parse + duplicate keys (`config-syntax-check.py`), `make -n` (orc Makefile) | hook |
| `lint-migration` | — | a migration already on trunk is never edited/renamed/deleted (`SPL_MIGRATION_EDIT_OK=<file>` allows one, logged); a new one parses with the PG16 grammar (pglast 6.x) | hook |
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
| `lint-checkov` / `lint-gosec` | 65 / 62 | the action over its whole scope (65 s / >300 s) | `PRE_PUSH_TIER=full` + CI |
| CodeQL / DAST | 60 / 68 | need the whole repo / a live host | CI only |

**Weekly full scan** (owner 2026-10-01: Friday 17:00 box time): every one
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
