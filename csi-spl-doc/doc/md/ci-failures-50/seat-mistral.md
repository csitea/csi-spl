# CI failures 50 — seat mistral (m-201@sat)

Verdict on `62397a34ce67260efd00c18fe00ac0c0e6bb5b8e` (v0.1 of
`csi-spl-doc/doc/md/ci-failures-50-2026-11-15.md`, branch
`review/ci-failures-50-panel`): **PASS** — no blocking defect. Notes N1..N8
below; none changes a row, a rank, a file or a control of section 7.

Reviewed 2026-11-15 by m-201@sat (mistral), doc review only. The branch had
moved by fetch time: `git fetch origin review/ci-failures-50-panel && git
rev-parse FETCH_HEAD` -> `fc4e2718ef2870e30bd91f851861a351e65296c7` (v0.2,
grok seat folded). v0.1 was read at `62397a34c` as the brief names it; v0.2
is signed in section 9 (second commit on this branch). Every claim below
carries the command run and what it printed; tree for git claims:
`git fetch origin master` -> `origin/master` `a6dd716b351a0dc95389adc028b469e84d89b604`
(the doc's own tree `01cac6fce` is an ancestor: `git merge-base --is-ancestor
01cac6fce origin/master` -> exit 0).

## 1. The window

`gh run list --branch master --status failure --limit 100 --json
databaseId,createdAt,workflowName,headSha,event` -> 100 rows; filtered to
`createdAt <= 2026-11-15T10:27:30Z` (the doc's stated end, fetched ~12:30Z),
newest 50 taken:

- count = 50; newest `43704165906 2026-11-15T10:27:30Z`, oldest
  `43548126862 2026-11-14T02:46:25Z` -> window 2026-11-14T02:46Z ..
  2026-11-15T10:27Z = 31 h 41 min = 1.32 days. Matches the doc.
- event split: `awk '{print $5}' | sort | uniq -c` -> 31 push, 19 schedule.
  Matches.
- distinct head shas: 28. Matches.
- per workflow: wf 10 gate 30, wf 15 sec 10, wf 00 lag 5, wf 20 hub 4,
  wf 13 next image 1. Matches.

Six run ids sampled with `gh run view <id> --json conclusion,headSha,name,createdAt`:

| run | printed | doc row |
|---|---|---|
| 43596303051 | failure, 9d6043eae, wf 20, 2026-11-14T12:44:40Z | F5 "inside D1's run 43596303051"; D1 first red 12:44Z |
| 43596302891 | failure, 9d6043eae, wf 10, 2026-11-14T12:44:40Z | D1 wf 10 push |
| 43548126862 | failure, 8c39ee3ef, wf 15, 2026-11-14T02:46:25Z | oldest of the window |
| 43704165906 | failure, 100cbbff2, wf 10, 2026-11-15T10:27:30Z | newest of the window |
| 43680713852 | failure, 26128ed71, wf 10, 2026-11-15T05:21:14Z | D4 first red 05:21Z |
| 43632676279 | failure, b8b10b8e1, wf 10, 2026-11-14T19:32:48Z | D5 first red 19:32Z |

All six match their rows. The failure-rate table also reproduces, but only
for the 50-run window, not for the command printed in its header — see N1.

## 2. Root-cause classes

Break rows (cause commit vs first red sha, `git log` around it):

- D1: first red sha `9d6043eae` = the named cause. Runs on it: 43596302891,
  43596303051, 43596394566, all failure. Parent `aa48d077b`:
  `gh run list --commit <full> --limit 20` -> no runs. First green
  2026-11-14T18:23:51Z on fix `9a96747b3` (run 43626368359, success) ->
  12:44:40Z..18:23:51Z = 5 h 39 min. Matches.
- D5: first red sha `b8b10b8e1` = the named cause. Parent `f81bc444...`:
  runs success/skipped, none failure. Matches.
- D4: first red sha `26128ed71` (run 43680713852, 05:21:14Z); named cause
  `d6bcf4309` is its ancestor (`git merge-base --is-ancestor d6bcf4309
  26128ed71` -> YES) with 3 docs commits between (`git log --oneline
  d6bcf4309..26128ed71` -> 26128ed71, 1ff69545a, 1f14bce2e). The wf 10 run
  on `d6bcf4309` itself (43680212480, 05:14:25Z) was cancelled. First green
  06:36:21Z on fix `92212bc75` -> 1 h 15 min. Matches the row's times; the
  cause is not literally the first red sha's own change — see N2.
- D7 (extra): first red `d99a6febb` (43662660943, 01:20:51Z); cause
  `035dc1501` is its ancestor, one commit between; first green 01:52:27Z on
  `93291ea93` -> 32 min. Matches.
- D6 (extra): first red sha `4d90d24d7` = tip of the named range
  `5eff7c9df..4d90d24d7`. Matches.

All nine fix commits exist and name their issues: `git show -s --format='%h %s'`
on 9a96747b3, 92212bc75, 7c18fda7d, f86a52d7b, 93291ea93, 7ae1ba7ad,
a286fea4d, 605ac7d6b, dcd2df6c5 -> e.g. `9a96747b3 fix(api, SPL-5513): order
hours export HUM-<n> member ids numerically`.

Flake rows (later green on an unchanged relevant tree):

- F2: `gh run list --commit cb2bf460f... --workflow 10_ci-quality.yml` ->
  failure 03:28:48Z (43551836712), success 03:45:06Z (43553221401) — same
  sha, 16 min 18 s later. `--commit 100cbbff2...` -> failure 10:27:30Z
  (43704165906), success 10:45:10Z (43705585751) — same sha, 17 min 40 s
  later. The doc says "17..18 min later" for each; the first is 16 min 18 s
  — see N3 (v0.2 already carries both exact delays).
- F1: red 23:24:50Z on `48125658a` (43653115686) -> next wf 10 run
  23:36:53Z success on `5815e76c5`; red 10:01:40Z on `dbea8ac1f`
  (43702056126) -> next 10:08:48Z success on `28fdf1e42`. Between each red
  sha and its green sha exactly one commit, neither touching the hub
  marketing-meta code (`git log --oneline 48125658a..5815e76c5` ->
  `5815e76c5 test(orc, SPL-5539): ...`; `dbea8ac1f..28fdf1e42` ->
  `28fdf1e42 fix(api, SPL-5581): relay rig ...`). "Green on the next run"
  holds.
- F4: schedule red 18:45:21Z on `9a96747b3` (43628359772); the push run on
  the same sha 18:23:51Z (43626368359) was success. Matches.

Counts: 28 + 10 + 7 + 5 + 0 = 50; the doc's own sum line
14+5+10+5+2+2+3+2+2+2+2+1 = 50. Area counts 18+5+8+7+12 = 50. All match.

## 3. Themes and smells: cited file:line on origin/master

Each read with `git show origin/master:<file> | sed -n '<N>p'`:

- S1 `csi-spl-api/src/bash/tests/hub-pg.tst.sh:186-195` -> the comment
  "SEQUENTIAL groups ... on the one store database" / "on the one hub
  database"; `:206` -> `store_groups() {`; `:216` -> `hub_groups() {`.
  Matches.
- S1 `internal/hub/marketing_meta_dispatch.go:133` ->
  `stuck, err := st.StuckMarketingPosts(...)`; `:141` ->
  `chs, err := st.MetaMarketingChannels(ctx)`. Matches.
- S1 `internal/hub/marketing_meta_followups_test.go:91` ->
  `if r := e.sweep(); r.Published != 1 || ...`; `:183` -> `r.Failed != 1`.
  Matches.
- S1 `internal/store/cost_read_test.go:228-229` -> the CONTROL lines wanting
  `len(control.Parts) != 2`. Matches.
- S2 `csi-spl-orc/src/bash/tests/changed-tests.sh:40` ->
  `always="${ORC_TEST_ALWAYS-require-cloud-env.tst.sh}"`. Matches.
- S2 `csi-spl-iac/src/bash/run/check-pre-push.func.sh:645-647` ->
  `if grep -q '^full' ...; echo "pre-push orc: ... left to CI workflow 10
  ..."; args=()`. Matches. Drift check (SPL-5574 `682af9225` is on master and
  did touch this file, 24+/7-): lines 645-647 are byte-identical at
  `01cac6fce` and at `origin/master` — no drift at the cited lines; the
  change is the budget plumbing elsewhere in the file.
- S3 `check-pre-push-lint-timeout.tst.sh:62` at `cc0a51eeb` ->
  `cp "$(command -v sleep)" "$LINT_TO_DIR/go"`. Matches.
  `git show origin/master:csi-spl-iac/src/bash/run/check-pre-push-lint.func.sh
  | grep -c sleep` -> 2. Matches.
  `git grep -nE '(cp|ln -s?f?)[^|;#]*(command -v sleep|/bin/sleep|which sleep)'
  origin/master -- '*.sh' | wc -l` -> 0. Matches.
- S4/T5: `git show d6bcf4309:.github/workflows/10_ci-quality.yml | grep -n
  do_check_wui_lang_review` -> line 1902 `run: ./run -a
  do_check_wui_lang_review`; `git grep -l do_check_wui_lang_review d6bcf4309`
  -> the workflow and `csi-spl-iac/src/bash/run/check-pre-push-lang-review.func.sh`.
  Matches. Today: 54 `./run -a do_*` names in `.github/workflows`, mapped to
  `<name>.func.sh` under any `src/bash/run/` -> 0 unmapped. Matches.
- S5 `csi-spl-wui/tests/e2e/docs.test.mjs:88-91` -> `page()` waits
  `data-page === want && md-block[data-rendered=true]`, timeout 15000;
  `:454` -> the assert passes only `await h1(o).catch(...)` as the note.
  Matches.
- T6 `internal/hub/fanout_encode_bench_test.go:126-129` -> the comment with
  the -race spread -87..+117, n=200. Matches.

Measured claims re-run: `git log --oneline origin/master | grep -c '(ci100-'`
-> 8; `grep -cE '\(ci-0[1-5]-'` -> 5; osv-scanner.toml carries 4
`ignoreUntil = 2026-11-27` (GHSA-vjh5, -xfq5, -jjm6, -gcqx) and 4
`2026-11-30` (GHSA-g3hv, -3g3m, -648h, -mjrq), and 5 of the 8 reasons end
"Real fix: nuxt 4 migration"; `git grep -il 'nuxt 4 migration' origin/master
-- csi-spl-doc | wc -l` -> 0. All match.

T2 map spot checks (today's `changed-tests.sh`, unchanged since 01cac6fce:
`git diff --stat 01cac6fce origin/master -- .../changed-tests.sh` -> empty):
`ORC_TEST_BASE=<c>~1 ORC_TEST_FILES="$(git show --name-only --format= <c>)"
bash csi-spl-orc/src/bash/tests/changed-tests.sh` ->
- b8b10b8e1: `full  no test names .../spawn-agents/tests/test-pre-push-hook.sh`
- 035dc1501: `full  no test names .../test-seed-channel-rules.sh`
- 5eff7c9df: 77 `run` lines, `grep -c run-eager-files` -> 0
All match the doc's table. The 150-commit loop on `01cac6fce`
(`git log --format=%h -150 01cac6fce -- csi-spl-orc`) -> full = 33 of 150 =
22%. Matches. Of those 33, 17 touch a `features/spawn-agents/tests/*` file,
not 16 — see N4.

T7: of the 30 wf 10 reds, 12 are schedule runs; each of the 12 has a prior
push run on the same sha (`gh run list --commit <sha> --workflow
10_ci-quality.yml` per run): 10 with the push red, 2 green (9a96747b3,
c48e6b323). Matches "12 of the 30 ... for 10 of them the push run was
already red; for F3 and F4 it was green".

Section 6: `gh run list --commit fd3b0c647... --workflow 10_ci-quality.yml`
-> 43709704275 2026-11-15T11:35:57Z push success, 43710431710 11:45:12Z
schedule success. Matches.

D3 first red: `gh run list --workflow 15_sec-deps-secrets.yml --created
'>=2026-11-13T22:00:00Z'` -> first failure 43519585459 2026-11-13T22:28:43Z
on b2ea39665. Matches 11-13 22:28Z.

## 4. The ranked fix list

- Urgency formula stated (U = reds/week x jobs/red, wf 20 red adds 2 held
  deploys, cascade counts toward its cause) and applied consistently:
  recomputed every row from its own inputs — T1 21/1.32x7=111.4,
  39/21=1.86, U=207; T2 37.1, 16/7=2.29, U=85; T4 53.0, 1.00, U=53; T3 10.6,
  6/2=3.00, U=32; T5 26.5, 1.00, U=27; S5 10.6, U=11; F3 U=11; F4 5.3, U=5.
  All match; ranks descend. (Job counts 39/16 are the editor's extract; not
  rebuilt — v0.2 says so in section 5.)
- R1: rulebook R1 (`csi-spl-doc/doc/md/rounds-rulebook.md` section 2.1) says
  "No file path may appear in two actions of the same batch. Shared files
  ... strictly serialised across batches". The doc's header "no file in two
  rows of a batch" matches; row 8 shares `hub-pg.tst.sh` with row 4 but is
  batch 2. Consistent.
- Each row names its files, a red control and a kind (bug / refactor /
  spec / gate). Row 5 is the doc row and says "none (doc row)" with the
  2026-11-27 date as the control — disclosed, not hidden.
- No row changes a workflow (row 7 adds a test that reads
  `.github/workflows`); no row is a mistral coding or testing row (no row
  names a vendor; kinds are bug/refactor/spec/gate).

## 5. Measured vs unchecked

Unmeasured items say "unchecked" in the doc: F2's mechanism, F5's cause,
T4's pnpm-audit leg ("Believed not; unchecked"), T5's full grep ("unchecked
in full"), section 8 Q3/Q4. Section 1 openly says the raw rows are in the
editor's scratch, not in git. Consistent with the rule.

## 6. Distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`INFO distribution-hygiene: clean over the tracked tree of
/opt/csi/csi-spl-wt/m-201`. Clean.

## 7. Defects

No blocking defect (W). The doc's section 7 can be queued as ranked.

## 8. Notes

- N1 (citation): the section 1 rate-table header prints the command
  `gh run list --workflow <file> --branch master --limit 400 --created
  '>=2026-11-13T00:00:00Z'`, but that command does not reproduce the table
  (it gives wf 10 39 failure / 148 success / 31 cancelled up to 12:30Z). The
  table's numbers reproduce exactly for the 50-run window
  2026-11-14T02:46:25Z..2026-11-15T10:27:30Z (wf 10 30/64/23 -> 32%, wf 15
  10/78 -> 11%, wf 00 5/27 -> 16%, wf 20 4/14 -> 22%, wf 13 1/1 -> 50% n=2).
  Values right, printed command wrong — swap the command for the window.
- N2 (citation): D3 says "advisory published 11-13 18:11Z (`git show -s
  dcd2df6c5`)", but `git show -s dcd2df6c5` prints the commit date
  2026-11-14T10:05:35+02:00 (author 2026-11-13T23:06:47Z). The value is true:
  `gh api /advisories/GHSA-mjrq-cffv-q4qc --jq .published_at` ->
  `2026-11-13T18:11:49Z`. Swap the cited command for the advisory API.
- N3 (number): F2's "each green on the same sha 17..18 min later" — measured
  16 min 18 s and 17 min 40 s. v0.2 already carries both exact delays.
- N4 (number): "16 of those 33" full-answering commits touch a
  `features/spawn-agents/tests/*` file — re-measured 17 of 33 (list of the 17
  printed by the loop). Headline 33/150 = 22% is exact.
- N5 (definition): the class definition says the cause commit is "the first
  red sha's own change"; for D4, D6, D7 the named cause is an ancestor of the
  first red sha (1-3 commits between, the cause's own push run cancelled).
  The causes are right (verified above); v0.2 folds this as the section 2
  note.
- N6 (not re-measured): the 73 failed jobs (55 red + 18 fail-fast stops) and
  the `ubuntu-26.04` image on 73 of 73 were spot-checked only: run
  43596302891's jobs show `hub: Postgres gate, pg coverage floor` failure
  beside successes (D1's signature), run 43548126862's single job
  `sec: govulncheck, pnpm audit, gitleaks, trivy` failure. The full 73-job
  extract stays with the editor's scratch, as the doc says.
- N7 (not re-checked): the vendor-of-cause table (section 2.1) is read from
  each lane's R7 brief `Author:` line; not re-derived here.
- N8: the branch moved to v0.2 (`fc4e2718e`) before this seat read it; v0.1
  was reviewed at `62397a34c` as the brief names, v0.2 signed in section 9.

## 9. v0.2 sign-off

Signed in the second commit on this branch: verdict on
`fc4e2718ef2870e30bd91f851861a351e65296c7` (v0.2).
