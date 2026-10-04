# Pre-push gate — fast tier and lint parts

The reference for what `./run -a do_check_pre_push_lint` (and the lint leg of
the pre-push hook, `./run -a do_check_pre_push`) runs. The rule itself lives in
the repo [CLAUDE.md](../../../CLAUDE.md): run the cheap gate for the tree you
touched, before you push.

## 1. The hook's FAST tier

The pre-push HOOK runs `do_check_pre_push` in its FAST tier (CLE-77824,
owner 2026-10-01; it had grown to 16 min for iac and >10 min for api, so
pushes race-lost trunk for hours). It runs only the parts the push touches
(`origin/master...HEAD`), re-uses a part's green verdict while the paths that
part reads are unchanged (a rebase over other lanes' commits re-runs
nothing), FAILS on a missing tool instead of WARNing, and writes one
`PART <part> PASS|PASS-cached|WARN-pre-existing trunk=<sha>|FAIL|SKIP-untouched <secs>`
line per part to `~/.cache/csi-spl/pre-push.log`. Moved to CI only, because
each costs minutes and workflow 10 (and the 20 deploy gate) already runs it
on every push and fails on a skip: api `go test -race` (plain `go test`
stays), `build-stripped`, `hub-pg` (~384 s), `hub-gcs`; iac tests whose
header says `# pre-push-tier: slow` (terraform validate, tpl-gen renders).

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
