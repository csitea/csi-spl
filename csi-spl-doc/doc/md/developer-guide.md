# Developer guide: how a change reaches master

> Generated from qto doc `c65bbfbd-bc33-4ac6-9d66-dc36a71bf948`; edit it there. Workspace `system`. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

For every coder of this repository, human or agent. It describes the branching
and deployment strategy as it is, and the rules that keep it safe. It changes
none of it. Each rule keeps its one home (see the
[fleet rules index](fleet-rules-index.md)); this page explains and points.

Owner, 2026-10-10: "we should have a Developer guide which explains those
rules for both human and agent coders" (msg d1753612), and it "explains the
branching and deployment strategy of ours, WHICH HAS WORKED for the last 4500
commits" (msg b7a94362).

<a id="ws-doc-55d1e5dd-1e05-43c4-8576-4ce394469e26"></a>
## 1. The strategy, as it is

<a id="ws-doc-2cc9f10c-63ad-4369-9e35-f23397bd2aa9"></a>
### 1.1 Trunk: everyone pushes to master

There is one long-lived branch, `master`. A change is a small commit, rebased
onto the current `origin/master` and pushed straight to it:
`git push origin HEAD:master`. The fleet opens no pull requests; a lane's
local branch and worktree are scratch space. They stay for 24 hours after the
lane closes, so a fix after the push still finds them, and then the disk guard
removes them ([the disk guard](#ws-doc-c01f7fd2-30bb-4e7b-b4f5-d7dfa1d6d2b9)).
Outside contributors use a fork and a pull request instead
([CONTRIBUTING.md](../../../CONTRIBUTING.md)).

It has carried the project so far, measured 2026-10-10:

- `git rev-list --count origin/master` -> 4951 commits.
- `git log --merges --oneline origin/master | wc -l` -> 1 merge commit: the
  history is linear, every change rebased.

<a id="ws-doc-bf972106-c2b1-4609-ba02-188f5b5a6728"></a>
### 1.2 CI deploys dev and prd on the push

A push to master runs the gate (`.github/workflows/10_ci-quality.yml`) and,
when their inputs changed, the deploys: the hub
(`20_hub-build-deploy.yml`) and the web UI (`30_wui-build-deploy.yml`), both
to `dev` and `prd` (`grep -n "wanted=(dev prd)"` on each file -> one line).
Nobody deploys by hand on the normal path. A change is done when it is
deployed in both environments:
`cd csi-spl-orc && ENV=<dev|prd> ./run -a do_check_deploy_lag`.

<a id="ws-doc-a726a3d7-1ae3-4ac5-8327-a6f0b49b4f4d"></a>
### 1.3 The version is minted, never edited

Every hub and web UI deploy mints its commit's version with
`do_release_version` (`csi-spl-orc/src/bash/run/release-version.func.sh`): a
`v<X.Y.Z>` git tag one step past the highest, claimed by pushing the tag. Never
roll the version by hand; the repo [CLAUDE.md](../../../CLAUDE.md) says when
the floor (`.version`) is raised.

<a id="ws-doc-5b498980-0673-45f3-8a2f-366c1f258249"></a>
### 1.4 Every change rides an issue

Agreed in [spec 135](../../specs/135-work-process/spec.md) v1.0 (owner
HUM-10, t1 5ea2e615, Q1-Q8 decided). Discussions are for talk; the issue
holds the condensed record of what is decided, done or being done, and links
to the discussion instead of repeating it (owner msg f2c24a7b). The branch
model of 1.1-1.3 does not change (Q5); the issue rides on it:

- **One issue per taken discussion**, filed in `eval` by the dispatch holder
  from its first answer; an evaluation or an answer to the owner is an
  `answer`-labelled issue; acks and chatter file none (Q1).
- **A question to the owner files no issue**: it stays a line in the
  discussion, and the issue it holds up goes `blocked` + `needs-owner`
  (`do_spl_issue_needs_owner`) until the owner answers (Q2).
- **The description starts with the source link and the restart card**
  (`Source: /t/<uuid>`, then key, scope, test, last citing sha, next step);
  the key is posted back in the topic (Q4, spec 135 section 7).
- **Cite the key** in the landing commit's subject scope,
  `feat(<area>, SPL-n): ...`, or in a `Closes: SPL-n` trailer. Only a
  `fix|feat|perf|refactor` subject or that trailer closes; `Refs:` and bare
  mentions link without closing.
- **Done is automatic**: the closer (`do_spl_issue_close_landed`, every 5 min)
  sets `done` when the citing commit lands on master (Q3). A docs-only push
  gets no deploy and no tag; its issue is done on the land.
- **The key is enforced at the lane's exit**: `/exit-clean` refuses a `wip`
  issue with no landed citing commit and no end reason, and the fleet's key
  rate is measured weekly (Q6). A lane that stops without landing ends its
  issue with a reason (`LANE_ISSUE_OP=end`).
- **`qas` only when a human asks for a review**; nothing enters it
  automatically (Q7).

The rule for lanes, with its commands: [lane issue and docs](lane-issue-and-docs.md).
Who does which step: [fleet roles](SPEC-spool-fleet-roles.md) section 1.3.

<a id="ws-doc-5396f07f-c552-4cc4-a2e1-f4d29d060d43"></a>
## 2. Coding standards

The rules every coder of this repository follows, human or agent (owner
HUM-10, t1 2402f33e, msgs ad01a506 and 477b0565; plan
`csi-spl-doc/doc/md/coding-standards-panel-plan.md` v1.1). Each rule says
what it requires and what enforces it: a gate (a test, a lint part, a hook,
an action that refuses) or `review only` when nothing in code checks it yet.

- A list that lives in code (the lint parts, the clean code ceilings, the
  i18n baselines) is not retyped here: the rule names the file that holds it.
- Paths are repo-relative, so the text reads the same wherever it is copied.
- This section is the one home of the coding standards. The spec-kit
  constitution (`csi-spl-doc/.specify/memory/constitution.md`) takes it by
  export only (`do_spl_export_constitution_coding_standards`, plan rows 02
  and 06), never by hand. Edit it in the Qto doc.

<a id="ws-doc-d55c5aa0-9bde-43f8-8ca0-ba8dd6e5c7c7"></a>
### 2.1 Core engineering principles

<a id="ws-doc-3b0d1be9-a3a8-4714-98ed-17dd99cdf0dc"></a>
#### 2.1.1 Truth first

Verify every statement before you make it: run the command, read the file,
check `origin/master` or the served build. What you did not verify, you say
you did not. Never report done before it is true. The rule's text:
`csi-spl-orc/src/bash/features/spawn-agents/assets/seed-truth-rule.txt`,
rendered into every agent seed.

Enforced by: review only (`spawn-agents/tests/test-seed-truth-first.sh`
proves every seed carries the rule, not that it is kept).

<a id="ws-doc-e5f6d770-86a8-46fd-97a6-5b02690d2f55"></a>
#### 2.1.2 Stay in your own lane

Do your brief and only your brief. Before you edit a path outside it, check
it against every live lane on every machine:
`csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check <paths> --agent <id>`
(exit 3 names the owning lane; exit 4 = a lane that recorded no files: ask
it first; exit 5 = `LOCAL-ONLY:` the hub did not answer, other machines
unread: not free, ask c-001). A finding outside your lane goes to the
orchestrator; fix it yourself only when it blocks your own tests and nobody
owns it, in a separate narrow commit.

Enforced by: `lane-map.sh --check` (exit 3 / 4 / 5); review.

<a id="ws-doc-ec77f12a-df1d-42cc-a309-6d9e563b67a9"></a>
#### 2.1.3 Done means deployed on dev and prd

A push to master deploys dev and prd ([CI deploys](#ws-doc-bf972106-c2b1-4609-ba02-188f5b5a6728)).
A change is done when it is on master and served in both:
`cd csi-spl-orc && ENV=<dev|prd> ./run -a do_check_deploy_lag`.

Enforced by: `do_check_deploy_lag`; the CI deploy workflows
(`.github/workflows/20_hub-build-deploy.yml`, `30_wui-build-deploy.yml`).

<a id="ws-doc-8d16c0eb-efaa-4bae-bbfc-32381b16893c"></a>
#### 2.1.4 Dev always equals or leads prd

Infrastructure and code reach dev first and are proven there; a prd apply
waits until dev has no pending change for that step
(`csi-spl-doc/doc/md/fleet-rules-index.md` section 2).

Enforced by: `csi-spl-iac/src/bash/run/check-dev-leads-prd.func.sh` (a
pending dev plan refuses the prd apply, exit 3); cron `do_check_env_order`
(`csi-spl-orc/src/bash/run/check-env-order.func.sh`).

<a id="ws-doc-b509498f-4990-4ad8-8115-9ecc0f82d42d"></a>
#### 2.1.5 Measure first for a speed-up

A speed-up starts with a measurement of the real waiting, and lands with a
counting or timing test that guards it
(`csi-spl-doc/doc/md/lesson-speed-up-measure-first.md`).

Enforced by: review only.

<a id="ws-doc-01a57fd6-a620-4de4-ad04-9413e66d561f"></a>
### 2.2 Code structure and clean code limits

<a id="ws-doc-50d05a54-fd19-4488-bb86-2f0db161ee34"></a>
#### 2.2.1 Small functions: 80 lines

A function is at most 80 lines in Go, TypeScript / Vue and Bash. A function
already over it is listed with its ceiling in the gate's own list, which may
only shrink; a new long one fails.

Enforced by: `csi-spl-api/src/go/spool-hub-api/internal/cleancode/cleancode_test.go`
(`maxFuncLines`), `csi-spl-wui/tests/unit/cleancode.test.mjs` (`MAX_LINES`),
`csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` (`MAX_LINES`, `LONG`).

<a id="ws-doc-86d17eb3-3950-48f6-96e7-b98d77bf5b78"></a>
#### 2.2.2 Nesting depth and parameters

Nesting depth at most 4; at most 8 parameters in Go and 6 in TypeScript /
Vue (pass a struct or an object instead). Bash has a line cap only.

Enforced by: `cleancode_test.go` (`maxDepth`, `maxParams`) and
`cleancode.test.mjs` (`MAX_DEPTH`, `MAX_PARAMS`).

<a id="ws-doc-1f4f276c-4f3e-4a7e-ad30-3bd4ff5e4c60"></a>
#### 2.2.3 Name the columns, never SELECT *

A query names the columns it reads; `SELECT * FROM` is refused in the hub's
Go code, so a new column is not dragged through every read.

Enforced by: `cleancode_test.go` (`TestCleanCodeGate`).

<a id="ws-doc-0ba77603-447f-41bb-8ab7-efff615e335f"></a>
#### 2.2.4 Folded helpers exist once

A helper the hub needs in many places lives in one package and is called
from there: a UUID is minted by `internal/uid`, a JSON answer is written by
`wire.WriteJSON` / `wire.WriteError` (`internal/wire/http.go`). The pattern
may appear only in its home file.

Enforced by: `cleancode_test.go` (its `folded` list).

<a id="ws-doc-fe424e2f-f0b4-455e-bb0c-2de81ccfe26c"></a>
### 2.3 Architecture, paths and environment

<a id="ws-doc-8d3c1039-1ae0-4848-8b42-c11827426ef4"></a>
#### 2.3.1 Canonical path layout

A sub-project lives at `${BASE_PATH}/${ORG}/${APP}/${APP}-${PROJ_KIND}`
(kinds `api`, `wui`, `iac`, `cnf`, `utl`, `orc`, `dat`, `doc`). A script
derives its paths from where it sits in the tree, never from a box path.

Enforced by: `csi-spl-iac/src/bash/tests/no-box-path-source.tst.sh`.

<a id="ws-doc-8dc0d812-b124-4417-9005-1b9bc2920385"></a>
#### 2.3.2 Fail fast, no default host

An external URL, host, bucket or account is read from an env var or the
cnf, and a shell action fails fast when a required one is missing
(`: "${VAR:?VAR must be set}"`). No literal domain or host in code: read
`BASE_DOMAIN` or the cnf.

Enforced by: review only.

<a id="ws-doc-242aec08-c700-404b-bc4b-af19b7441827"></a>
#### 2.3.3 The cnf is the single source of truth

Runtime configuration is authored in `csi-spl-cnf/csi-spl/<env>.env.yaml`
(and `all.env.yaml`), never hard-coded. Its generated twins (`*.tfvars`, the
rendered files) are re-rendered in the same commit:
`cd csi-spl-iac && ENV=<env> ./run -a do_tpl_gen`, then
`git diff --exit-code`.

Enforced by: the tfvars parity check of the `iac-suite` CI job
(a fresh tpl-gen render).

<a id="ws-doc-5c533000-3c58-45f9-a9d7-66227bcc4958"></a>
### 2.4 Shell scripting and run actions

<a id="ws-doc-aa56a2a5-c664-47a7-86aa-29672081def6"></a>
#### 2.4.1 Named actions

Operator behaviour is a Bash function `do_<verb>_<noun>` in
`src/bash/run/<verb>-<noun>.func.sh` of its sub-project, run as
`./run -a do_<verb>_<noun>`. Infra actions live in `csi-spl-iac`, local
orchestration in `csi-spl-orc`, box upkeep and disk actions in `csi-spl-utl`.
Nothing in the infrastructure runs ad hoc.

Enforced by: the `./run` action loader (an action it cannot find does not
run); review.

<a id="ws-doc-bf499098-8f45-46f1-907f-c684bd0681a1"></a>
#### 2.4.2 Header tags

Each action opens with its header comment: `@description`, one `@param`
per env var it reads (required or optional, with its default) and at least
one `@example`.

Enforced by: review only.

<a id="ws-doc-252415a0-f93b-44a4-a7ca-f8fe6c78b3ef"></a>
#### 2.4.3 Bash that fails safely

Scripts run under `set -uo pipefail` where they pipe; a function returns a
code instead of exiting the caller's shell; a pipeline with an early-exit
consumer under pipefail is marked or rewritten.

Enforced by: `lint-shellcheck` and `lint-sigpipe` of the pre-push lint
suite (`csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh`).

<a id="ws-doc-e43649ce-ff07-41d6-9054-2c933a6dc78d"></a>
#### 2.4.4 Packages and processes

A box package is installed only through
`cd csi-spl-iac && BOX_PKG=<pkg> BOX_PKG_REASON="<why>" AGENT_ID=<id> ./run -a do_box_pkg_install`,
which records it. A process is stopped by its own pid or its stop action,
never by `pkill -f`, `killall` or a computed pid list.

Enforced by: `do_box_pkg_install` (its record,
`csi-spl-iac/src/bash/tests/box-pkg-install.tst.sh`); the kill guard
`csi-spl-orc/src/bash/features/spawn-agents/lib/kill-target-guard.inc.sh`.

<a id="ws-doc-41fb6bf6-bffa-4c81-ad04-25fbc0f88662"></a>
#### 2.4.5 An action lands with its test

A new infra action ships with its test in the same commit; a one-off
command you would type once becomes a named action plus its test, then runs
through that action.

Enforced by: review only.

<a id="ws-doc-548688a5-69de-49b0-ace4-27ffc4c44728"></a>
### 2.5 Public distribution hygiene

<a id="ws-doc-948b3e6b-b74b-4648-b109-871860597483"></a>
#### 2.5.1 Csitea is the only organisation

The repository is public and org-neutral: `csi`, `csitea`, `csitea.net`
are the only organisation tags. No other company, bank, customer or vendor
name, and no host of another environment; use a placeholder such as
`<ORG>` or `example.com`.

Enforced by: `cd csi-spl-iac && ./run -a do_check_dist_hygiene`; the CI
job `distribution-hygiene` (`.github/workflows/10_ci-quality.yml`).

<a id="ws-doc-da770470-1b54-408d-b86a-b2e02fa72b18"></a>
#### 2.5.2 No personal names, users or boxes

No personal name (write `FirstName LastName`), no literal OS user name, no
box or host name and no `/home/<user>` path in code, comments, docs,
examples or config defaults; resolve per-user state from `$HOME` or an env
var.

Enforced by: `do_check_dist_hygiene`.

<a id="ws-doc-461b4cc7-832a-4278-a704-45c0bebb1e68"></a>
#### 2.5.3 Git authorship is the carve-out

Commit metadata carries the author's real identity (the repo `CLAUDE.md`
"Commits:" line) and is not covered by the bans above; it never ships in
the distribution.

Enforced by: `do_spl_push_master` (author and committer, `--no-mailmap`).

<a id="ws-doc-db6f8e62-d9cd-4ba9-ba68-a275250b0394"></a>
### 2.6 Security, secrets and cloud access

<a id="ws-doc-039abee1-826d-45e6-906c-dbbbab337e33"></a>
#### 2.6.1 Service accounts, keys outside git

Every GCP call runs as the environment's service account, from its key
`$HOME/.gcp/.csi/key-csi-spl-<env>.json` (minted out of band, mode 600);
never as the owner account. No key in git, in terraform state or in a log.

Enforced by: `csi-spl-iac/src/bash/tests/gcloud-account-pinned.tst.sh`.

<a id="ws-doc-785936c8-dfe7-4a69-8fde-44ae229afd0f"></a>
#### 2.6.2 No secrets in code

No credential, private key, token or signed URL in a file or a commit.

Enforced by: `lint-gitleaks` and `lint-trufflehog` of the pre-push lint
suite; their CI jobs.

<a id="ws-doc-4782e7e4-5b60-4a37-936d-ce41ca0276f9"></a>
#### 2.6.3 Every gcloud call is pinned

Every `gcloud` call carries `--account`, or runs under a throwaway
`CLOUDSDK_CONFIG`; nothing writes the box's shared gcloud config.

Enforced by: `gcloud-account-pinned.tst.sh`.

<a id="ws-doc-2ad10f3e-1c43-4f77-a0b6-f5c5758be060"></a>
#### 2.6.4 Every tenant table has RLS

Every tenant table carries a Row-Level Security policy, and the hub's
queries run inside the tenant scope; a statement without a tenant reads
no tenant row.

Enforced by: `TestRLSCoversEveryTenantTable` and `TestRLSControl`
(`csi-spl-api/src/go/spool-hub-api/internal/store/rls_test.go`),
`rls_failclosed_test.go`.

<a id="ws-doc-139e6622-c552-4b91-a728-a375037f3489"></a>
#### 2.6.5 Terraform in its container, GCP changes with the owner's go

Terraform runs only in the tf-runner container
(`cd csi-spl-orc && ENV=<env> STEP=<step> make do-tf-plan`), never on the
host. Nothing mutates GCP (a project, a billing link, an IAM change, an
apply) without the owner's explicit go for that call.

Enforced by: the make / tf-runner path (`do_tf_init`); review only for the
owner's go.

<a id="ws-doc-1702f1e0-0d24-402b-b987-9dcdac37d74e"></a>
### 2.7 UI text, typography and i18n

<a id="ws-doc-81b2e9e6-9150-4d75-8bc6-3a3bd0a0f116"></a>
#### 2.7.1 UI text is a translation key

Every user-visible string in the web UI is rendered with `t('key')` /
`$t('key')`, attributes and dialog messages included; never words in a
template or the code. How to add one: [UI text](#ws-doc-e52c5c39-28e6-4013-bcec-45a2d85de037).

Enforced by: `csi-spl-wui/tests/unit/i18n-no-raw-text.test.mjs` (a ratchet,
baseline `csi-spl-wui/i18n/i18n-raw-text-baseline.json`).

<a id="ws-doc-b5201c16-ffa5-478d-a345-a5dc0a87931b"></a>
#### 2.7.2 Every locale has every key

A key added to `csi-spl-wui/i18n/locales/en.json` is added, in that
language, to every other locale file.

Enforced by: `csi-spl-wui/tests/unit/i18n-parity.test.mjs`.

<a id="ws-doc-1134c90d-4b43-4380-8904-bde0b3bcea17"></a>
#### 2.7.3 The untranslated count only falls

A value left identical to English counts against its locale's baseline; a
change may lower the baseline, never raise it.

Enforced by: `csi-spl-wui/tests/unit/i18n-untranslated.test.mjs` (baseline
`csi-spl-wui/i18n/i18n-untranslated-baseline.json`).

<a id="ws-doc-f7722208-f0d4-4063-96a4-caabd800fb3d"></a>
#### 2.7.4 Typography, focus ring, proof in Chrome

Font sizes are `rem` on the canonical scale and focus uses the one focus
ring token. A UI change is proven in Chrome (`pnpm run test:e2e`);
typecheck alone does not drive a browser.

Enforced by: `csi-spl-wui/tests/unit/font-size.test.mjs`,
`csi-spl-wui/tests/unit/focus-tokens.test.mjs`; the `wui-e2e` job of
`.github/workflows/10_ci-quality.yml`.

<a id="ws-doc-dc2404f6-86de-469e-a85d-90c8f6bf6135"></a>
### 2.8 Lint and quality gates

<a id="ws-doc-c6079adc-e9e1-4cdb-877d-b694006a56d4"></a>
#### 2.8.1 The pre-push lint suite

The files you touch pass the fast lint parts before you push:
`cd csi-spl-iac && ./run -a do_check_pre_push_lint` (the parts and their
tools: `csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh`; `lint-typos`
warns only). The whole gate: [pre-push gate](#ws-doc-0661156a-470d-4ca9-9b3e-32382192c22c).

Enforced by: `do_check_pre_push` in the installed pre-push hook; the CI
scanner jobs.

<a id="ws-doc-be948915-a11c-4f55-b0cb-16eed6da9c35"></a>
#### 2.8.2 The slow scanners

`lint-checkov` (terraform) and `lint-gosec` are too slow for the hook: they
run in CI and in `PRE_PUSH_TIER=full`.

Enforced by: their CI jobs; `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.

<a id="ws-doc-2db333fb-83df-4d90-a646-102a443af71d"></a>
#### 2.8.3 Migrations are forward-only

A migration already on master is never edited, renamed or deleted; a new
one continues the head (`<head+1>_<name>.sql` in
`csi-spl-rdb/src/sql/postgres/spool-hub/`) and parses with the PostgreSQL 16
grammar. A store or migration change runs `PRE_PUSH_TIER=full`.

Enforced by: `lint-migration`; the hub refuses a changed migration sha256
at deploy.

<a id="ws-doc-3f669947-a9b9-4895-a56d-b88ff4fd5eab"></a>
### 2.9 Git trunk workflow

<a id="ws-doc-13962bb6-29a1-4b0e-831b-268d659dd9ae"></a>
#### 2.9.1 Small commits, explicit pathspecs

One topic per commit. Stage named paths with `git add <path>...`, then
`git commit` with no pathspec; never `git add -A` or `git commit -a`.
Detail: [small commits](#ws-doc-51a57ac2-8a91-4bd2-a936-43181f4e0221).

Enforced by: review only.

<a id="ws-doc-680d9077-d618-4fe5-85a5-fadaa59077d5"></a>
#### 2.9.2 The executable bit is staged too

A new executable needs both `chmod +x <path>` and
`git add --chmod=+x <path>`. A mode-only change you did not make is reset,
never staged.

Enforced by: review only.

<a id="ws-doc-5e37af85-7acc-4b41-af1d-52de5debf141"></a>
#### 2.9.3 Rebase, re-test, push in the background

Fetch, rebase onto `origin/master`, re-run the tests of what you touched,
then push; an agent pushes with `cd csi-spl-orc && AGENT_ID=<id> ./run -a do_spl_push_master`
and polls it. A refused push means someone landed first: rebase again.
Detail: [rebase](#ws-doc-fe2e4a35-68b4-448f-8645-c1d6c567c6ea).

Enforced by: `do_spl_push_master`; the pre-push hook.

<a id="ws-doc-6f3d108f-ba35-4bae-a467-dd3b573dd398"></a>
#### 2.9.4 Never force-push or delete master

No `--force`, `--force-with-lease` or `+ref` push to master and no delete
without the owner's approval of that one push, and `SPL_PREPUSH_OVERRIDE`
is never a way through. Detail: [force-push](#ws-doc-f0217fb8-6313-42f2-835c-881b59531456).

Enforced by: the GitHub ruleset `master-no-force`; the pre-push hook
(`csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push`).

<a id="ws-doc-98b93e5d-23ed-4aa0-b75b-e7ddb9f3e6d8"></a>
#### 2.9.5 Real identity, no AI trailers

Author and committer are the address on the repo `CLAUDE.md` "Commits:"
line, passed to the rebase too. No `Co-Authored-By:`, `Generated with …`
or session-link trailer. Detail: [identity](#ws-doc-ad549934-e5e4-4674-9d4e-f60f6872858f).

Enforced by: `do_spl_push_master` (the identity); review only (the
trailers).

<a id="ws-doc-fab1ad75-9824-41d4-bef9-05218240f42b"></a>
### 2.10 Spec-driven and issue-driven delivery

<a id="ws-doc-048a870e-035c-447b-af09-86301dfc618e"></a>
#### 2.10.1 Every change rides an issue

A change cites its issue key in the commit subject scope
(`feat(<area>, SPL-n): ...`) or a `Closes: SPL-n` trailer; a lane's issue
names its epic and its git spec. Detail: [issues](#ws-doc-5b498980-0673-45f3-8a2f-366c1f258249).

Enforced by: the closer `csi-spl-orc/src/bash/scripts/issue-close-landed.py`;
`/exit-clean` refuses a `wip` issue with no landed commit and no end reason;
`do_spl_spawn_enqueue` refuses a brief with no `Epic:` and `Spec:` line.

<a id="ws-doc-a8df108e-0389-4750-b1e6-0da616006b02"></a>
#### 2.10.2 Behaviour changes carry their docs

A commit that changes behaviour (code under `csi-spl-api`, `-orc`, `-iac`
or `-wui`) lands with its `csi-spl-doc/` change, or its message carries
`Docs: none (<why>)` (`csi-spl-doc/doc/md/lane-issue-and-docs.md`).

Enforced by: `csi-spl-orc/src/bash/features/spawn-agents/scripts/kill-your-self-report.sh --gate`.

<a id="ws-doc-44379642-76b7-4629-a7bb-b82003877298"></a>
### 2.11 Agent messaging

<a id="ws-doc-951c38d2-ac0a-4712-93fc-fba5cde0627e"></a>
#### 2.11.1 One protocol for every vendor

Every agent, whatever its vendor, talks through the same `spool` verbs and
the same v:1 JSON message; no per-vendor endpoint or field.

Enforced by: the strict message parser (`csi-spl-api/src/go/spool-hub-api/internal/msg`,
an unknown field is refused).

<a id="ws-doc-4c0e921b-5bd8-4057-9f1f-c4d525abc0e3"></a>
#### 2.11.2 Agent ids

An agent id is a vendor letter, a dash and three digits:
`[acgmq]-[0-9]{3}` (`SPOOL_AGENT_ID_NEW_RX` in
`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh`).

Enforced by: `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift`
(fact 1).

<a id="ws-doc-9a1068f6-fdcc-4706-9c03-c11e1f66863b"></a>
### 2.12 Testing standards

<a id="ws-doc-2a96ce2a-4981-4adc-b441-b3bbc8acb12f"></a>
#### 2.12.1 Every gate has a red control

A new test or gate ships with its red control: seen RED on the planted
defect, then GREEN, both outputs in the commit body. A control that would
turn master red runs on a throwaway branch
(`csi-spl-doc/doc/md/rounds-rulebook.md`, C2).

Enforced by: review (`do_spl_review_line_check` proves the reviewer ran the
named tests).

<a id="ws-doc-73b5b4b1-0ef3-40de-a872-4b493690b559"></a>
#### 2.12.2 Per-run temp dirs

A test writes only under its own temp dir (`mktemp -d`, `$TMPDIR`), never a
fixed `/tmp/<name>` path.

Enforced by: `lint-tmp-path` (`.tmp-path-baseline.txt` may only shrink).

<a id="ws-doc-81bf0484-592a-4ba7-bd75-e03b65c13088"></a>
#### 2.12.3 Never the live spool root

A test runs on its own `SPOOL_ROOT`; under `SPOOL_TEST=1` the live root is
refused.

Enforced by: the guard in `spool-env.inc.sh`,
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-test-guard.sh`.

<a id="ws-doc-7e212f26-5e19-4cb6-9db8-4731435fa313"></a>
#### 2.12.4 Store tests run on PostgreSQL

A store, hub or auth change is tested on real PostgreSQL, not only on the
mock store: `PRE_PUSH_TIER=full ./run -a do_check_pre_push`.

Enforced by: `PRE_PUSH_TIER=full`; the `hub-pg` CI job.

<a id="ws-doc-80530761-5964-430c-9821-2af15cb6c545"></a>
#### 2.12.5 Go coverage floors hold

A Go package's coverage never falls below its floor in
`csi-spl-api/src/bash/tests/go-coverage-floor.txt`.

Enforced by: `csi-spl-api/src/bash/tests/run-all-tests.sh` (its coverage
check).

<a id="ws-doc-20330bb9-8141-4b8b-a183-49bb1fa89485"></a>
## 3. The rules for a change

<a id="ws-doc-51a57ac2-8a91-4bd2-a936-43181f4e0221"></a>
### 3.1 Small commits, explicit pathspecs

- One topic per commit; the message says why.
- Stage named paths: `git add <path>...`, then `git commit` with no pathspec.
  Never `git add -A` or `git commit -a`: in a shared tree they sweep up other
  people's work. Why the pathspec goes on the `add`:
  [lane integration rules](lane-integration-rules.md) section 1.1.
- Push each commit soon: a change held back while trunk moves becomes a
  rebase nobody can resolve (same page, section 1.3).
- Stop a process by its own pid or its `./run` stop action: the pre-tool
  kill guard (`csi-spl-orc/src/bash/features/spawn-agents/lib/kill-target-guard.inc.sh`,
  SPL-2583) refuses a kill of pid 0 or 1, a process group, tmux, cron,
  systemd, sshd, another agent, a computed target list, `killall` and `pkill -f`.

<a id="ws-doc-fe2e4a35-68b4-448f-8645-c1d6c567c6ea"></a>
### 3.2 Rebase onto the others' work, re-test, then push

Before EVERY push:

1. `git fetch origin master`
2. `git rebase origin/master`: your commits go on top of what others landed.
3. Re-run the tests of what you touched (repo [CLAUDE.md](../../../CLAUDE.md),
   "Run the cheap gate for the tree you touched").
4. `git push origin HEAD:master`

A refused push means someone landed first: go back to step 1. A push has
landed when `git merge-base --is-ancestor HEAD origin/master` holds after a
fresh fetch, not when the push printed `HEAD -> master`
([lane integration rules](lane-integration-rules.md) section 3.1).

<a id="ws-doc-0661156a-470d-4ca9-9b3e-32382192c22c"></a>
### 3.3 The pre-push gate

`cd csi-spl-iac && ./run -a do_check_pre_push` runs before every push; the
installed pre-push hook runs it for you. Its tiers and parts:
[pre-push gate](pre-push-gate.md). Touching the store or a migration:
`PRE_PUSH_TIER=full`.

<a id="ws-doc-e52c5c39-28e6-4013-bcec-45a2d85de037"></a>
### 3.4 UI text is a translation key, never a literal

Owner HUM-10, t1 9f867807 (msg 1f583d2a): "no hardcoding in the UI for text
which should be part of the translation set." To add a string to the web UI:

1. Add its key to `csi-spl-wui/i18n/locales/en.json` and the same key, in
   that language, to every other locale file there (`i18n-parity.test.mjs`
   refuses a missing key).
2. Render it with `t('key')` / `$t('key')`, also in a `title`,
   `placeholder`, `aria-label`, `alt` or `label` attribute and in a
   `confirm()` / `alert()` / `prompt()` message. Never write the words
   into the template or the code.

Two unit tests hold it, both ratchets: a count may fall, never rise
(SPL-2267, counting code `csi-spl-wui/src/node/i18n/i18n-gates.mjs`):

| gate | counts | baseline |
|---|---|---|
| `tests/unit/i18n-untranslated.test.mjs` | per locale, values identical to en.json that hold a 3+ letter word once `{placeholders}` and URLs are removed, minus `i18n/i18n-keep-english.json` (brand names and codes, each with its reason) | `i18n/i18n-untranslated-baseline.json` |
| `tests/unit/i18n-no-raw-text.test.mjs` | per file under `src/`, hard-coded user-visible text: template text, the static attributes above, literal dialog messages | `i18n/i18n-raw-text-baseline.json` |

Re-measure with `node src/node/i18n/i18n-gates.mjs untranslated` or `raw`
(`raw --list` prints each file's count and examples). A change that lowers
a count may lower its baseline in the same commit; raising one is never the
fix.

<a id="ws-doc-ad549934-e5e4-4674-9d4e-f60f6872858f"></a>
### 3.5 Identity, no AI trailers

Commits carry the author's real identity, the address on the repo
[CLAUDE.md](../../../CLAUDE.md) "Commits:" line, as author and as committer
(a rebase re-stamps the committer, so pass the identity to it too). No
`Co-Authored-By:`, `Generated with …` or session-link trailer. The why:
[lane integration rules](lane-integration-rules.md) section 5.

<a id="ws-doc-f0217fb8-6313-42f2-835c-881b59531456"></a>
## 4. Never force-push or delete master

A force-push (`--force`, `--force-with-lease`, `+ref`) replaces the commits
others landed with yours; deleting master removes everyone's. Neither is how a
change lands, and `SPL_PREPUSH_OVERRIDE` is never a way through a refused push.

The rule, final wording (owner msgs 1ca01c83, 3e095a04):

> No agent force-pushes to master without the owner's explicit approval of
> that one push; even then the owner decides who does it, often by hand. Ask
> and wait; never treat an approval as permission to go ahead alone.

Its one home is `NO_FORCE` in
`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`,
rendered into every agent's seed; its history and cases are in section 3.2 of
the [lane integration rules](lane-integration-rules.md).

The why, the owner (msg 097f9de3): "Everyone respects the work of the others.
We are team and not a bunch of selfish cawboys".

<a id="ws-doc-92d9d053-6961-40d4-9560-9e13a706185b"></a>
## 5. What enforces it

Live on master on 2026-10-10, each checked by the command shown:

| layer | what it refuses | where |
|---|---|---|
| GitHub ruleset `master-no-force` | a non-fast-forward push and a deletion of master, for everyone, no bypass actor | `gh api repos/csitea/csi-spl/rulesets/24832017` -> `enforcement: active`, rules `deletion` + `non_fast_forward`, `bypass_actors: []`; managed by `do_spl_gh_master_ruleset` (`csi-spl-iac/src/bash/run/spl-gh-master-ruleset.func.sh`, e900d9f04); lifting it is the owner's, by hand |
| pre-push hook | a non-fast-forward push or delete of master, `SPL_PREPUSH_OVERRIDE` included | `csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push` (3e082c94c), test `spawn-agents/tests/test-pre-push-non-ff.sh` |
| shared command matcher | every forbidden push form in a shell command, for the harness guards to call | `csi-spl-orc/src/bash/features/spawn-agents/lib/force-push-guard.inc.sh` (f6a7da70f), test `csi-spl-orc/src/bash/tests/force-push-guard.tst.sh` |
| agent seed rule | states the rule to every agent type (c-, g-, a-, q-, m-) | `NO_FORCE` in `spawn-core.inc.sh` (6bdd3c436), test `spawn-agents/tests/test-seed-no-force-push.sh` |
| pre-push hook | a push to master by a coder with no ack of this guide ([confirm](#ws-doc-f8bc29a6-cc41-4f84-90a2-4c3a816a102f)), `SPL_PREPUSH_OVERRIDE` included | `dga_check` in `csi-spl-orc/src/bash/features/spawn-agents/lib/dev-guide-ack.inc.sh`, test `spawn-agents/tests/test-pre-push-dev-guide.sh` |

Not yet live: the harness hooks that call the shared matcher before a command
runs (`git grep -l force-push-guard origin/master` -> the matcher and its test
only). Until they land, the ruleset and the pre-push hook are the layers that
stop a forbidden push.

<a id="ws-doc-87e80942-e405-4f54-9dc6-d7d229c7010b"></a>
### 5.1 UI work and the vendor re-test

Owner HUM-10, t1 b61851fb (2026-10-16): of 5 mistral lanes on WUI and orc
work that night, none finished cleanly (a self-close before the push landed,
a text "screenshot", trimmed tests and a stale copy, two red gates, a
force-push try). So a lane whose brief or paths target `csi-spl-wui/` never
goes to mistral, as main or backup: `do_spl_lane_mix` (`LANE_MIX_BRIEF`,
`LANE_MIX_PATHS`) and the spawn placer give it to claude, else grok. Docs and
other work still may go to mistral.

The switch is cnf `env.box.agent_split.mistral_ui_allowed` (false). Only the
re-test flips it, never a hand edit:

1. `cd csi-spl-orc && RETEST_NONCE=<nonce> ./run -a do_spl_vendor_ui_retest`
   prints three small WUI tasks with known answers; one mistral lane each.
2. Each lane passes only when its commit changes only its task's file and
   holds the known answer, landed through `do_spl_push_master`, every CI run
   is green, it is served on dev and prd, and it got an ACCEPTED from another
   agent before it closed.
3. `RETEST_CMD=verdict RETEST_NONCE=<nonce> RETEST_RESULTS=<file> DRY_RUN=0
   ./run -a do_spl_vendor_ui_retest` checks all of it in code: 3/3 writes
   `true`, anything less writes `false`. Commit the cnf like any change.

<a id="ws-doc-382bde59-778b-4ad4-9688-4dbe962170c2"></a>
## 6. Where the rest is

- Every fleet rule and its one home: [fleet rules index](fleet-rules-index.md).
- The why of each seed rule: [lane integration rules](lane-integration-rules.md).
- Repo rules (environments, service accounts, terraform, gates):
  [CLAUDE.md](../../../CLAUDE.md).
- Outside contributors: [CONTRIBUTING.md](../../../CONTRIBUTING.md).

<a id="ws-doc-f8bc29a6-cc41-4f84-90a2-4c3a816a102f"></a>
## 7. Confirm you have read this guide

Owner, 2026-10-10 (msg 56d7073e): every new coding person or agent "must
agree that they have read" this guide. After reading it, confirm it once, as
the OS user you push with:

`cd csi-spl-orc && ./run -a do_dev_guide_ack`

On a terminal it shows the guide and asks; an agent passes its id and the
confirmation: `AGENT_ID=<id> DEV_GUIDE_ACK=yes ./run -a do_dev_guide_ack`
(STEP 0 of every agent seed). It records one line, who and this guide's git
blob sha, in your ack store under `$XDG_STATE_HOME` (default
`$HOME/.local/state`) or `$DEV_GUIDE_ACK_FILE`.

- The pre-push hook refuses a push to master without an ack for the guide
  the push carries, and prints the command above.
- **A material change is any change to this file's blob**
  (`git rev-parse HEAD:csi-spl-doc/doc/md/developer-guide.md`): it asks
  every coder to read and confirm again. Batch small fixes into one commit.
- Work trees created before 2026-10-11T00:00Z pass without an ack until
  the guide first changes after that time, so the rollout stopped no one
  already working.

<a id="ws-doc-c01f7fd2-30bb-4e7b-b4f5-d7dfa1d6d2b9"></a>
## 8 The disk guard

A lane's worktree is not removed when the lane ends (owner, t1 37349c9b msg ec060ebc): a fix after the push still finds it. The code:

- `csi-spl-orc/src/bash/features/spawn-agents/scripts/workdir-register.sh` writes the table, `$SPOOL_ROOT/workdirs.tsv`, one row per directory: path, kind (`worktree`, `scratch` or `var-tmp`), agent, box, branch, finished_at. `agent-id-retire.sh` (steps 7 to 9) calls it when a lane's window closes, in place of removing anything. `next-agent-id.sh` (rule 6) never hands out an id that a row names.
- `csi-spl-utl/src/bash/scripts/workdir-sweep.sh`, run as `cd csi-spl-utl && ./run -a do_sweep_workdirs`, removes a listed directory after 24 hours (6 at 8% free or less). The box disk sweep (`csi-spl-orc/src/bash/scripts/box-disk-sweep.sh`) runs it as its `workdirs` step.
- Tests: `csi-spl-orc/src/bash/tests/workdir-sweep.tst.sh` (the table and the sweep), `spawn-agents/tests/test-agent-id-retire-worktree.sh` and `test-lane-scratch-reap.sh` (the retire lists, the sweep removes 25 hours later).

Every new disk action lives in `csi-spl-utl` (owner, msg 177ce9f3: "a shell action which could also be run manually"), runs by hand as `cd csi-spl-utl && ./run -a do_<verb>_<noun>`, is a dry run unless `DRY_RUN=0`, and runs from cron through the same command. To add a rule: a check in `workdir-sweep.sh` that sets the KEEP reason, a case in `workdir-sweep.tst.sh` with a red control (the same row without the condition is removed), and a line in the operations and maintenance guide's sweep section.
