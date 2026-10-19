# Coding standards panel - claude reviewer seat

Plan: [coding-standards-panel-plan.md](../coding-standards-panel-plan.md)
Reviewed version: **v0.1** at `ea33f0ed268e33029d0feef89b4cd0a357c64abe`
(inventory baseline `4453459bbde498b0c88c2a9fcf899e37acc28889`), named by
the editor in msg 44be05a2.
Seat: claude reviewer (lane c-337, issue SPL-2538, epic SPL-2402).

Verdict on v0.1: **CHANGE**. The direction is right: one home in the
developer guide, the constitution filled by export, and a drift fact. What
needs to change:

- the export slices on a heading that Qto renumbers;
- two build rows have no red control;
- one row is not a build row;
- the batch order breaks a dependency;
- eight binding coding rules are missing from the inventory.

Every command below ran in a checkout of the reviewed sha, from the repo root.

## 1. Inventory rows re-checked (9 of 22)

| row | claim | command -> output | verdict |
|---|---|---|---|
| 02 | `constitution.md:38` calls the WUI a "lightweight task and thread viewer" | `sed -n 38p csi-spl-doc/.specify/memory/constitution.md` -> ``- `csi-spl-wui` — human web UI: lightweight task and thread viewer web app.`` | agree |
| 07 | `plan-template.md:46` still says `csi-rel-cnf` | `grep -n csi-rel-cnf csi-spl-doc/.specify/templates/plan-template.md` -> `46:` (1 hit) | agree |
| 08 | the constitution still names a retired "relay SA key" | `grep -n relay csi-spl-doc/.specify/memory/constitution.md` -> lines 40 and 117 | agree. Line 40 ("the relay bucket + SA") is a second stale site; add it |
| 09 | `constitution.md:127` lists `CLE-*`/`GRK-*`/`AGY-*`, but the grammar is `[acgmq]-[0-9]{3}` | `sed -n 127p` -> ``Every AI agent on a box — `CLE-*` (Claude), `GRK-*` (Grok), `AGY-*` ``; `grep -n SPOOL_AGENT_ID_NEW_RX= csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh` -> `100:SPOOL_AGENT_ID_NEW_RX='[acgmq]-[0-9]{3}'` | agree, but the gate column is wrong. Fact 1 does NOT read the constitution: `_frd_sources` in `check-fleet-rules-drift.func.sh` lists CLAUDE.md, fleet-roles, fleet-rules-index, lane-integration-rules, how-to-post, two scripts and the claude-md fragments, and nothing under `.specify/`. That is why the stale ids pass today |
| 10 | 80 lines, depth 4 and params (Go 8, WUI 6) across Bash, Go and WUI; missing from every rule doc | Go `cleancode_test.go:18-20` -> `maxFuncLines = 80`, `maxDepth = 4`, `maxParams = 8`; WUI `cleancode.test.mjs:27-29` -> 80 / 4 / 6; `grep -ci depth csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh` -> `0`; `grep -ci 'clean.code\|cleancode'` on CLAUDE.md, developer-guide.md, constitution.md -> 0, 0, 0 | change. The gap is real, but Bash has a line cap only (`MAX_LINES=80` plus a `LONG` ceiling list), with no depth or parameter cap. `SELECT *` and the folded singletons are Go-only. The section must say per language what is measured |
| 12 | 18 fast lint parts | the `@description` part list in `check-pre-push-lint.func.sh:9-48` names 19: syntax, migration, compose, gitleaks, py, tf, wui-syntax, wui-lock, shellcheck, actionlint, hadolint, eslint, trufflehog, mdlinks, typos, semgrep, gomod, sigpipe, tmp-path | change: there are 19, and `lint-typos` is WARN only. Better still, do not copy the list into the guide (see 3.4) |
| 15 | `NO_FORCE` at `spawn-core.inc.sh:282` | `grep -n '^NO_FORCE=' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh` -> `282:` | agree |
| 16 | `constitution.md:186` "contradicts" the real identity | `sed -n 185,189p` -> the placeholder is used "in shippable examples — the real name and address live only in git metadata and the zip-excluded `CLAUDE.md`, the authorised carve-out" | reject the "contradiction". This line states the hygiene carve-out correctly, so keep it. At most, point to the CLAUDE.md "Commits:" line, which drift fact 7 (`_frd_commit_address`) already pins |
| 21 | `SEED_BOX_PKG` at `spawn-core.inc.sh:287` | `grep -n '^SEED_BOX_PKG=' csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh` -> `287:` | agree |

Several line counts in section 1 are wrong, most by one line. Measured with
`git show 4453459bb:<f> | wc -l`:

| file | measured | plan says |
|---|---|---|
| constitution | 217 | 218 |
| developer-guide | 270 | 271 |
| CLAUDE.md | 152 | 153 |
| AGENTS.md | **11** | 17 |
| fleet-rules-index | 78 | 79 |

These are cosmetic; fix them in v1.0.

The constitution's own version number is inconsistent, and row 06 must
resolve it. `sed -n 215,217p constitution.md` -> the body says
`**Version**: 0.2.0` and the footer says `version: 0.2.1`. The brief calls it
v0.1.0.

## 2. Coding rules the inventory missed

Each of these binds a coding agent today and has a gate or a written owner
rule. None of them is in the 22 rows.

| # | rule | home today (checked) | gate |
|---|---|---|---|
| M1 | Every tenant table carries an RLS policy, and queries run inside the tenant scope | `csi-spl-api/src/go/spool-hub-api/internal/store/rls.go` | `TestRLSCoversEveryTenantTable` (`rls_test.go:76`), `TestRLSControl` (`:111`), `rls_failclosed_test.go` |
| M2 | An applied migration is never edited, renamed or deleted; a new one continues the head (head+1) and parses on PG16 | `check-pre-push-lint.func.sh:12-17` (`lint-migration`) | `lint-migration`; `PRE_PUSH_TIER=full` for store or migration changes |
| M3 | Every infra step is a named `./run` action **plus its test in the same commit**; nothing ad hoc | `CLAUDE.md:47-63` | review. Inventory row 04 covers the naming only, not "plus its test" |
| M4 | Terraform runs only in the tf-runner container. Nothing mutates GCP (create, billing, IAM, apply) without the owner's go | `CLAUDE.md:66-71` | the `do_tf_init` path; the owner's go |
| M5 | Every gate or test ships with a red control (seen RED, then GREEN). A control that must turn trunk red runs on a throwaway branch | `rounds-rulebook.md:100` (C2), `CLAUDE.md:118` | review evidence (`do_spl_review_line_check`) |
| M6 | A speed-up starts with a measurement and lands with a counting test | `CLAUDE.md:125`, `lesson-speed-up-measure-first.md` | review |
| M7 | The Go coverage floor per package may not fall | `csi-spl-api/src/bash/tests/go-coverage-floor.txt` | wf 20 coverage step |
| M8 | WUI font sizes are in rem on the five levels, with one focus-ring colour. A WUI change is proven in Chrome (`test:e2e`); typecheck alone is not proof | `CLAUDE.md` gate table (wui rows) | `font-size.test.mjs`, `focus-tokens.test.mjs`, e2e |

Two more rules are fleet conduct rather than code. The guide should point to
them, not copy them:

- Never `pkill -f` or `killall` on a pattern (`STOP_RULE`,
  `spawn-core.inc.sh:526`).
- No literal domain or host; read `BASE_DOMAIN` (seed deploy-gate (c);
  constitution Principle II already covers it).

The outline also has no subsection for tests. Two test rules belong there:
tests write only under a per-run temp dir (`lint-tmp-path`), and tests refuse
the live spool root (the `SPOOL_TEST` guard). I propose **2.12 Tests: red
control, per-run temp dir, no live spool, Postgres for the store**.

## 3. Export design (section 3 of the plan)

### 3.1 One home: agree, with the chain made explicit

The chain has two derived copies, each with its own drift check:

1. Qto `c65bbfbd` -> `developer-guide.md`, written by
   `do_spl_doctree_export_md` and checked by `check-qto-doc-drift`.
2. `developer-guide.md` -> the constitution block, written by the new action
   and checked by drift fact 8.

That is still one home. Agree. The guide should also say which copy a coder
may edit: only the Qto doc.

### 3.2 Slicing on a heading text: change

The plan slices from `## 2. Coding standards` up to the next `## 3.`. Qto
renumbers headings whenever a section is inserted above them, and the plan
itself proposes renumbering sections 2-7. A heading match therefore breaks
silently on the first reorder.

Every exported heading carries a stable node anchor
(`grep -c '^<a id="ws-doc-' csi-spl-doc/doc/md/developer-guide.md` -> 17).
Slice by the section's node id (`ws-doc-<uuid>`) and stop at the next anchor
of the same heading level. Keep that id in one place, the export action, and
have the drift fact read it from there.

### 3.3 One extractor, not two

Rows 02 and 04 each extract the section. Two extractors are two copies of
the rule for where the section ends. The drift fact should call the action
with `DRY_RUN=1` (exit 1 on a diff) instead of slicing again.

### 3.4 State rules, point at lists

A list that already has its own source in code (the 19 lint parts, the
clean-code limits, the i18n baselines) must not be retyped in the guide.
A retyped copy will drift from the code, and no fact would catch it. The
guide states the rule and names the gate file; the numbers stay in the gate.

One exception: the guide may quote the limits 80/4/8/6 only if fact 8 (or a
new fact 9) checks them against `cleancode_test.go` and `cleancode.test.mjs`.

### 3.5 Governance and versioning: missing

`constitution.md:209-212` requires every amendment to bump the version and
`Last Amended` date and to re-run `/speckit-analyze`. An automated export
changes the constitution whenever the guide changes, so the plan must choose
one of two options:

- the export action bumps the patch version and the date itself; or
- row 06 amends Governance to exempt the exported block.

I recommend the first: the action writes the version, and the drift fact
ignores only that line.

### 3.6 Ack churn

Section 6 of the guide makes every coder re-ack after any change to the
guide's blob. Row 01 is such a change. Rows 07 and 08 must therefore not
touch the guide. Row 01 should say this and land all guide text in ONE
commit.

### 3.7 spec-kit references

`plan-template.md:43-50` checks "I. Paths", "II. Env", "VI. Cnf-only" and
"V. Hygiene" by Roman numeral. Replacing Principles I-VIII with the export
block breaks those references, and every spec's "Constitution Check" that
cites them. There are two fixes:

- keep the Roman-numbered principle headings inside the exported section; or
- land row 09 in the same batch as row 06, not in batch 1.

## 4. Build rows

| row | verdict | evidence / change |
|---|---|---|
| 01 Qto section | change | The target is missing; make it measurable. Every rule in the new section names its gate file or says "review only", and a `grep -c` of the "Enforced by" lines equals the number of rules. Red control: `check-qto-doc-drift` exits 1 with the md edited by hand and 0 after the export. Record the slice id (3.2) in the commit body |
| 02 export action | change | Merge with row 03: an action without its test is what M3 forbids. Red control: a planted second copy of the end anchor, or a missing begin marker, makes the action exit non-zero without writing |
| 03 export test | merge into 02 | as above |
| 04 drift fact 8 | change | Call row 02's action with `DRY_RUN=1` (3.3). Also add `csi-spl-doc/.specify/memory/constitution.md` to `_frd_sources`, so fact 1 catches the stale `CLE-*` ids (inventory row 09). Merge with row 05 |
| 05 drift test | merge into 04 | The red control as written is good (a mismatch exits 1, a sync exits 0). Add a third case: a stale `CLE-*` in the constitution fails fact 1 |
| 06 sync constitution | agree, with 3.5 | Target: `do_check_fleet_rules_drift` exits 0 with 8 facts. Set the version as in 3.5, and also fix line 40 ("relay bucket") |
| 07 CLAUDE.md pointers | change | Keep the cheap-gate table in CLAUDE.md. It is the one file every claude agent loads unasked, and drift fact 7 reads its "Commits:" line (`_frd_commit_address`). Replace prose rules with links, but keep the table and the Commits line. Target: the `grep -c` of the moved rules in CLAUDE.md drops by the number moved, and fact 7 stays OK |
| 08 fleet rules index | agree | It depends on row 01's final anchor, so batch 2 is right |
| 09 plan-template | change batch | It depends on the final section numbering (3.7). Move it to batch 3 with row 06, out of batch 1 |
| 10 re-ack + full pre-push | reject as a build row | The ack is per coder, and `test-pre-push-dev-guide.sh` needs no edit for a new blob. Running the full gate is every row's duty, not a row of its own. Use the freed slot for the M1-M8 text if row 01 cannot hold it, or drop the row |

With 02+03 and 04+05 merged and row 10 dropped, 7 rows remain. The panel may
use the freed slots, up to 10 rows in all.

R1 check on the v0.1 batches: batch 1 holds both row 01 (the guide) and row
09 (the template), and row 09 depends on row 01's numbering. Move row 09 to
batch 3.

## 5. Sign-off

My verdict on v0.1 is CHANGE (sections 1-4). I will sign v1.0 when it does
all of the following:

- folds in 3.2, 3.3 and 3.5;
- gives rows 02 and 04 their red controls;
- keeps the cheap-gate table in CLAUDE.md (row 07);
- drops row 10;
- lists M1-M8 in the inventory, each adopted or rejected with a reason.

| version | sha | verdict |
|---|---|---|
| v0.1 | `ea33f0ed268e33029d0feef89b4cd0a357c64abe` | CHANGE |
| v1.0 | pending | pending |
