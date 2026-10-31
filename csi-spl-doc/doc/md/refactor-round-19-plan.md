# Refactoring round 19 - plan (8 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4528  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: this round
  gives 7 rows that can run at once (section 3.1).
- owner 10-17 (t1 b61851fb): no mistral coding rows; grok off (0d5b1e8a):
  **vendor claude for every row**.
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**No round 18 retro yet.** It is not due: round 18 rows 03, 04, 05 and 07 are
still open (`git log 5675aa1c3 -E --grep='r43-[0-9]{2}' --format='%h %s'` ->
3 commits: row 01 `b3fc696fd`, row 02 `606c5bb26`, row 06 `4dcb0f2ba`). This
plan takes the inputs of [retro 17](refactor-round-17-retro.md) section 7
that [round 18](refactor-round-18-plan.md) did not use, plus fresh
measurements (section 2). Why now: on the night of 2026-10-31 no refactor
row was queued beyond round 18's, and round 18 gives at most 2 at once
(dispatch holder c-002@sat, msg aca44267).

Round 19 focus: **every run action's header is one the `./run` loader can
read** (`@description` and `@example` inside the parsed header block), then a
gate that keeps it so; and **three Go packages' untested guards under test**.
Every row touches files that no other row, no round 18 row and no live lane
names, and no shared baseline file, so 7 of the 8 rows can run at once.

**Status: v0.1 DRAFT** (editor c-851; panel review pending).

Editor: **c-851** (claude). Panel reviewer: a fresh-session claude seat, placed
by the dispatch lease holder. Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`5675aa1c3`** (`origin/master`
5675aa1c3e33c0604f71f32f1f3e52a013daaa79, 2026-10-31), n=1 per command
unless stated. Go: go1.26.10.

## 1. How to read this

- **Slug prefix `r44`.** Round 18's plan reserved it (its section 1).
  `git log 5675aa1c3 --oneline --grep='r44-' | wc -l` -> 0, and no brief
  names it:
  `grep -rl 'r44-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0 (this box, 2026-10-31 ~22:40Z). The older `r19-*` brief names in
  `dispatch/briefs` are another series, not this round. The next cut would
  be `r45`, but `r45` already appears in another series' brief name
  (`ls /var/spool-hub/dispatch/briefs | grep -c r45` -> 1,
  `c002-api-err-r45-shutdown-drain.md`), so the next planner proves its
  prefix free the same way before taking it.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a gate change, a **red
  control**: the check fails on the bad input before the change and passes
  after.
- **Paths:** `iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`,
  `utl:` = `csi-spl-utl/`, `api:` = `csi-spl-api/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` = `src/bash/run/` and
  `t/` = `src/bash/tests/` of the sub-project named. Lines as of `5675aa1c3`.
- **Box:** the preferred box; the spawner's pick may move a row (no pin).
- **Vendor:** claude for every row (owner 10-17, grok off). **R7 reviewer:
  a fresh-session claude seat** per row, named by the dispatch holder at
  placement, under the same claude-only waiver rounds 17 and 18 ran on
  (retro 17, 4.1); each review line names the author's vendor too.
- **Subject** (R6 reads it): `<type>(r44-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or
  the action it defines
  (`git grep -l -F -e <basename> -e <do_name> 5675aa1c3 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row below.
- **The header the loader reads.** `do_parse_metadata`
  (`iac:lib/bash/funcs/parse-metadata.func.sh:14`, the same code in the orc
  and utl copies) starts the header only at a `#---` separator line (`:30`)
  and stops at the first non-comment line (`:33`). Tags above the
  separator, or after the first command, are not read: `./run` neither
  shows them nor checks their `@param (required)` (`do_validate_params`,
  `iac:lib/bash/funcs/validate-params.func.sh:12`, skips a file with no
  parsed metadata). "Has the tag" in this plan means
  **`do_parse_metadata <file>` prints a `description=` / `example=` line**,
  not that `grep` finds the word.
- **Header rows change comments only.** No `@param` is added (a
  `(required)` one would make `./run` refuse a call that works today); no
  code line moves. An `@example` of a terraform action names the tf-runner
  make target where one exists (`cd csi-spl-orc && ENV=dev STEP=<step> make do-tf-plan`;
  the targets: `grep -oE '^do-[a-z0-9-]+:' orc:src/make/tf-tasks.func.mk`,
  e.g. `do-provision`, `do-tf-apply-target`, `do-tf-state-list`; there is
  no `do-tf-apply`), never a host terraform run (repo `CLAUDE.md`).

## 2. Where the rows come from (measured on `5675aa1c3`)

| source | input | command on `5675aa1c3` | n | row / disposition |
|---|---|---|---|---|
| fresh | action files (a `do_*()` in `run/*.func.sh` of iac, orc, utl) with no `@description` or no `@example` anywhere in the file | `for f in <sub>/src/bash/run/*.func.sh; do grep -qE '^(function +)?do_[a-z0-9_]+ *\(\)' $f \|\| continue; grep -q '@description' $f; grep -q '@example' $f; done` | **20** files: iac 14 (all lack `@example`), utl 5 (lack `@description`), orc 1 (lacks `@description`) | **Rows 01-04** |
| fresh | the same files whose **parsed** header lacks a tag | the same loop with `do_parse_metadata $f \| grep -q '^description='` / `'^example='` | **73** files lack a parsed `example=` (iac 47, orc 21, utl 5), **61** a parsed `description=`; the 20 above are among them | the 20 in rows 01-04; the other 53 are the baseline of **Row 05**'s ratchet |
| fresh | of those, headers that declare a `(required)` `@param` | `grep -ciE '^# *@param .*\(required\)'` on the 73 | **9** files | **Left out** (section 6): making them visible turns on a refusal, a behaviour change |
| fresh | Go functions at 0% or under 50% in packages measured without Postgres | `cd go: && go test -count=1 -coverprofile=c.out ./...`, `go tool cover -func=c.out`; then `./internal/action/ ./internal/billing/ ./internal/keyexec/` again (n=2, same numbers) | `internal/action` 81.9% (floor 80.8): `Lane` 0.0, `Move` 0.0, `MoveMsg` 0.0, `Pin` 0.0, `checkRef` 42.9, `checkPeers` 28.6, `checkAnswers` 42.9; `internal/billing` 80.8% (floor 80.8): `ValidStatus` 0.0, `PeriodStart` 0.0; `internal/keyexec` 79.7% (floor 79.7): `Verdict.String` 0.0, `Lease.String` 0.0 | **Rows 06, 07, 08** |
| fresh | the `pg` packages (`internal/store` 47.5, `repodocs` 55.8, `auth` 80.4 without a DSN) | the same run | | **Left out:** their floors are measured with Postgres (`go-coverage-floor.txt`: `repodocs 90.7 pg`, `auth 82.9 pg`); the no-DSN number says nothing |
| retro 17 7.4 | `internal/keydesk` `logf` 50.0 | | | **Left out:** round 18 row 07 (`r43-07`) owns `internal/keydesk` |
| retro 17 7.5 | `cmd/spool` 77.8 vs 78.0 | the run above: 77.8 | 1 | **Left out:** the gap is in `hub.go`; live lane c-799 (`c002-api-err-r45-shutdown-drain`) works there |
| retro 17 7.6 | shims, unused exports, SFC size, tmp-path, eslint-security | `grep -v '^#' <baseline> \| grep -c .`: `.tmp-path-baseline.txt` 0, `.eslint-security-baseline.txt` 0 | 0 / 0 | **Left out:** nothing to lower |
| retro 17 7.7 | clean-code `LONG` / `wideFuncs` | briefs `c003-r41-0{1,2,3}-*.md` (2026-10-30) name `cleancode_test.go`, `cleancode.test.mjs`, `bash-cleancode.tst.sh` | 3 briefs | **Left out:** the three ratchet files stay with rows r41-01..03 (briefed, not on master, not queued) |
| retro 17 7.7 | `run.sh`, gosec G101 x4, semgrep x1, `internal/blob` 71.9%, shellcheck `-x` | `.gosec-baseline.txt` 4 rows, `.semgrep-baseline.txt` 1 row | | **Left out:** as retro 17 says (vendored, triaged false positives, needs a GCS fake, too slow) |
| fresh | WUI raw-text ratchet | `cd csi-spl-wui && node src/node/i18n/i18n-gates.mjs raw --list` | 14 in 12 files | **Left out:** each is a code or brand word (`USD`, `/search:`, `spool-hub`, `Csitea`, `YYYY-MM-DD HH:MM`), not translatable text |
| round 18 | shellcheck baseline, `go-coverage-floor.txt` | round 18 plan section 3 | | **Excluded:** every file a round 18 row names (brief rule) |

## 3. The 8 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r44-01-iac-header-example-gcp)` | an action's parsed header carries an `@example` | `./run` shows the example; these 5 have none (their `@description` is parsed: the separator is at `:3`) | `iac:run/divest.func.sh:4`<br>`iac:run/export-json-section-vars-as-tf-vars.func.sh:4`<br>`iac:run/gcp-002-delete-project-service-account.func.sh:5`<br>`iac:run/gcp-export-dns-settings.func.sh:6`<br>`iac:run/provision.func.sh:4` | 5 files | Add one `# @example ...` line inside each header block (above the closing `#---`): a real call with the env vars the function reads. Check: `source iac:lib/bash/funcs/parse-metadata.func.sh; do_parse_metadata <f> \| grep -c '^example='` -> 0 before, 1 after, per file. Tests: `orc:t/parse-metadata-nofork.tst.sh` (parses every `*.func.sh`), `orc:t/tf-runner-make-path.tst.sh`, `iac:t/export-json-section-vars-as-tf-vars.tst.sh`, `iac:t/gcp-key-path-no-eval.tst.sh`, `iac:t/tf-plugin-cache-shared.tst.sh`, `iac:t/gcp-002-delete-project-service-account.tst.sh`, `iac:t/return-not-exit-gcp.tst.sh`; for `provision`: `iac:t/bash-cleancode.tst.sh`, `comment-refs-exist.tst.sh`, `env-order-gate.tst.sh`, `gcp-alert-snooze.tst.sh`, `provision-052-entry-check.tst.sh`, `tf-apply-exit-status.tst.sh`, `wui-hosting-019-031.tst.sh`, `orc:t/check-env-order.tst.sh`, `lde-stack.tst.sh`, `lde-up.tst.sh`, `spool-permissions.tst.sh`, `stripe-endpoints-provision.tst.sh`, `tenant-host.tst.sh`. **Red control:** the check above reads 0 on the parent sha. | sat | claude | simple_coding | 1 |
| 02 `refactor(r44-02-iac-header-example-tf-apply)` | as row 01 | the same: 5 terraform actions without an `@example` | `iac:run/tf-apply.func.sh:4`<br>`iac:run/tf-apply-target.func.sh:4`<br>`iac:run/tf-destroy.func.sh:4`<br>`iac:run/tf-init.func.sh:4`<br>`iac:run/tf-new-step.func.sh:4` | 5 files | As row 01; each example is the tf-runner make target where `orc:src/make/tf-tasks.func.mk` has one (`do-provision` runs the apply, `do-tf-apply-target`, `do-tf-destroy-target`), else the `./run` call that make target runs **inside** the tf-runner. Tests: `orc:t/parse-metadata-nofork.tst.sh`; `iac:t/env-order-gate.tst.sh`, `provision-052-entry-check.tst.sh`, `satellite-ansible.tst.sh`, `tf-apply-destroy-quoted-paths.tst.sh`, `tf-apply-exit-status.tst.sh`, `tf-destroy-local-step-bucket.tst.sh`, `tf-destroy-target.tst.sh`, `gcp-tf-shared-bodies.tst.sh`, `tf-actions-tf-proj-after-init.tst.sh`, `tf-import-result-log.tst.sh`, `tf-init-project-key.tst.sh`, `tf-plugin-cache-shared.tst.sh`, `tf-state-actions.tst.sh`, `tf-state-remove-backup.tst.sh`, `tf-new-step.tst.sh`; `orc:t/check-env-order.tst.sh`, `tf-030-import-existing-cloud-run.tst.sh`. **Red control:** as row 01. | sat | claude | simple_coding | 1 |
| 03 `refactor(r44-03-iac-header-example-tf-state)` | as row 01, and a parsed `@description` for the one orc action without | 4 terraform actions without an `@example`; `do_spl_hub_run_metrics` has its tags in a comment the loader skips (no separator) | `iac:run/tf-plan.func.sh:4`<br>`iac:run/tf-state-list.func.sh:4`<br>`iac:run/tf-state-pull.func.sh:4`<br>`iac:run/tf-state-push.func.sh:4`<br>`orc:run/spl-hub-run-metrics.func.sh:2` | 5 files | As rows 01-02 for the 4 tf files. `spl-hub-run-metrics`: a `#---` line after the shebang, `# @description` on the existing first comment line, its `@param` and `@example` lines kept as they are, a closing `#---` above `:9`. Its one `@param` (`ENV, REQ_SINCE, REQ_MINUTES as do_spl_hub_request_minutes`) has no `(required)`, so `do_validate_params` refuses nothing new: the lane shows `do_parse_metadata <f> param` after the change and that no line holds `(required)`. Tests: `orc:t/parse-metadata-nofork.tst.sh`; `iac:t/env-order-gate.tst.sh`, `satellite-actions.tst.sh`, `tf-state-actions.tst.sh`; `orc:t/tf-plan-ref.tst.sh`, `tf-runner-make-path.tst.sh`, `tf-import-existing.tst.sh`, `canary-hub-deploy.tst.sh`, `spl-hub-load-test.tst.sh`, `spl-hub-request-minutes.tst.sh`. **Red control:** as row 01 (and `^description=` 0 -> 1 for the orc file). | sat | claude | simple_coding | 1 |
| 04 `refactor(r44-04-utl-header-parsed)` | the utl actions' header is one the loader reads | all 5 utl actions open with prose and no separator, so `./run` reads no `@description` and no `@example` for any of them | `utl:run/cron-heartbeat-snitch.func.sh:2`<br>`utl:run/docker-test-container-prune.func.sh:2`<br>`utl:run/docker-volume-prune.func.sh:2`<br>`utl:run/reboot-required-check.func.sh:2`<br>`utl:run/systemd-unit-health.func.sh:2` | 5 files | Per file: a `#---` line after the shebang, `# @description` + one sentence from the existing first lines, one `# @example` (the call the file's own prose or test uses), a closing `#---`; the existing prose stays below as a plain comment. No `@param` (none today: `grep -c '^# *@param'` -> 0 in each). Tests: `orc:t/parse-metadata-nofork.tst.sh`; `utl:t/cron-heartbeat-snitch.tst.sh`, `docker-test-container-prune.tst.sh`, `docker-volume-prune.tst.sh`, `reboot-required-check.tst.sh`, `systemd-unit-health.tst.sh`; `orc:t/reliability-checks-cron.tst.sh`, `box-name-from-cnf.tst.sh`; `iac:t/bash-cleancode.tst.sh` (names `reboot-required-check.func.sh`). **Red control:** as row 01, `^description=` and `^example=` 0 -> 1 per file. | sat | claude | simple_coding | 1 |
| 05 `test(r44-05-iac-action-header-tags-gate)` | a gate: every action's parsed header carries both tags, a ratchet for the rest | developer guide 2.4.2 says "Enforced by: review only"; 73 action files fail it today | `iac:t/action-header-tags.tst.sh` (new)<br>`iac:t/action-header-tags-baseline.txt` (new, 53 rows) | 73 -> 53 files | The test sources `iac:lib/bash/funcs/parse-metadata.func.sh`, walks `run/*.func.sh` of iac, orc and utl that define a `do_*()`, and fails on a file without `description=` or `example=` unless the baseline lists it; it also fails on a listed file that now has both (the list only shrinks, like `.shellcheck-warning-baseline.txt`). `iac:t/run-all-tests.sh` runs it (it runs every `*.tst.sh`). R9: run under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** in a `mktemp -d` tree, an action file without `@example` -> FAIL; a listed file given both tags -> FAIL; then the real tree -> PASS. Docs: the developer guide is a Qto export (`do_spl_doctree_export_md`); the lane sends the new "Enforced by" line for 2.4.2 to the dispatch holder and lands `Docs: none (<why>)`. | sat | claude | tests | 2 (after 01-04) |
| 06 `test(r44-06-api-action-hub-verb-refusals)` | the hub-mode verbs' refusals under test | `Lane` (`lane.go:37`), `Move` (`move.go:29`), `MoveMsg` (`move.go:66`), `Pin` (`pin.go:38`) are 0.0%: every refusal (no hub URL, bad fleet slug, bad task / msg uuid, empty channel, bad `--as`, non-HUM `--acting-for`, `--pubkey` xor `--revoke`) is untested | `go:internal/action/lane.go:37`<br>`go:internal/action/move.go:29,66`<br>`go:internal/action/pin.go:38`<br>`go:internal/action/hub_verb_refusals_test.go` (new) | 4 functions at 0.0 | Table tests per refusal, each asserting the error text; a success path only through an `httptest` hub that an existing test file of the package already builds (reuse it; define no helper whose name another test file of the package defines). `Pin` writes into a `t.TempDir()` pins dir. No floor change (section 6). Tests: `go test -count=1 -race -cover ./internal/action/`; `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (coverage part `ok`, floors unchanged). **Red control:** make `Move` accept an empty `--channel` -> a new case fails. | sat | claude | tests | 1 |
| 07 `test(r44-07-api-action-send-guards)` | the send guards under test | `checkRef` 42.9, `checkPeers` 28.6, `checkAnswers` 42.9: the hub-mode, uuid, `--to-box`, `--if-gen` and `--channel` refusals are not all exercised | `go:internal/action/action.go:209,228,243`<br>`go:internal/action/send_guards_test.go` (new) | 3 functions | One table per guard, every `case` arm; `checkPeers` also asserts `ToBox` becomes `msg.PeersToBox` on success. A different test file from row 06 (R1); helper names prefixed `sg` so the two files compile together. Tests: as row 06. **Red control:** drop the `in.ToBox != msg.PeersToBox` arm -> a new case fails. | sat | claude | tests | 1 |
| 08 `test(r44-08-api-billing-keyexec-helpers)` | small pure helpers under test, the key-hiding `String` first | `keyexec.Lease.String` (`desk.go:56`) keeps a vendor key out of every `%v` and log line, at 0.0; `Verdict.String` (`classify.go:38`), `billing.ValidStatus` (`billing.go:77`) and `PeriodStart` (`:97`) are 0.0 too | `go:internal/keyexec/desk.go:56`<br>`go:internal/keyexec/classify.go:38`<br>`go:internal/billing/billing.go:77,97`<br>`go:internal/keyexec/keyexec_test.go`<br>`go:internal/billing/billing_test.go` | 4 functions at 0.0 | `fmt.Sprintf("%v %+v %s", l, l, l)` on a `Lease` with a fake key holds `<VENDOR_KEY>` and never the key; both `Verdict` names; every `Status*` constant valid and `"x"` not; `PeriodStart` across a month end and from a non-UTC zone. Fake keys only, no key path. No floor change (section 6). Tests: `go test -count=1 -race -cover ./internal/keyexec/ ./internal/billing/`; `run-all-tests.sh`. **Red control:** `Lease.String` returning `l.Key` -> the new case fails. | sat | claude | tests | 1 |

### 3.1 Lanes and batches

Disjoint files in batch 1 (R1): **7 rows at once** (01, 02, 03, 04, 06, 07,
08). Rows 06 and 07 share a package but no file; each adds its own test
file. Row 05 follows once rows 01-04 have landed, so its baseline holds
exactly the files still failing (53 if all four land as planned; the lane
re-counts). Under the owner's "keep 2 row lanes in parallel" (686bc1a3) the
dispatch holder places two at a time from batch 1, and more when the band
allows.

No row touches a shared baseline file that exists today, `csi-spl-cnf/`, a
migration, a workflow or terraform code (rows 01-03 change comments in
terraform action files only).

### 3.2 Off every live lane and every round 18 row (R3)

- **Round 18:** `grep -cE '<the site basenames>' csi-spl-doc/doc/md/refactor-round-18-plan.md`
  -> 1: row 07's `keydesk.go`, which matches `desk.go` only as a substring
  (`internal/keydesk/keydesk.go`, not `internal/keyexec/desk.go`); round 18
  names no file of this round.
- **Live lanes:** `lane-map.sh --check <the 32 paths, comma separated> --agent c-851`
  (2026-10-31 ~22:45Z) -> **exit 4**: no live lane lists any of the paths,
  but 25 live lanes record no files. Their briefs were read with
  `grep -oE '<the site basenames>|billing|keyexec|internal/action|go-coverage-floor'`:
  0 hits for every one (on this box `/var/spool-hub/<id>/lifetime/brief.md`
  and `dispatch/briefs/`; on sat `dispatch/briefs/` and the seats'
  `lifetime/brief.md`), except c-849 (`r43-07`), which names
  `go-coverage-floor`: no row here touches that file. The rotate and
  restarted seats (c-613, c-765, c-769, c-804, c-807, c-826, c-862, c-864,
  c-866, c-934, c-988, g-585, g-602) are seat or review briefs on other
  subjects.
- **Spawn queue:** `./run -a do_spl_spawn_queue` -> 22 queued, 0 placing;
  the same grep over each queued brief (on this box, and on sat for those
  queued there) -> 0 for 21 of 22; the brief of
  one queued bug brief (a read-only DNS bug of this box, ask 75077182) was found on neither box
  (read-only DNS bug, **unchecked**).

## 4. Per row: what the lane does

- **01:** One `@example` in the parsed header of 5 iac actions.
- **02:** The same for 5 terraform apply / destroy / init / new-step actions.
- **03:** The same for 4 terraform plan / state actions, and a parsed header for `do_spl_hub_run_metrics`.
- **04:** A parsed header (`#---`, `@description`, `@example`) for the 5 utl actions.
- **05:** The gate test and its 53-row ratchet.
- **06:** Refusal tests for `Lane`, `Move`, `MoveMsg`, `Pin`.
- **07:** Tests for every arm of `checkRef`, `checkPeers`, `checkAnswers`.
- **08:** Tests for `Lease.String` (key hidden), `Verdict.String`, `ValidStatus`, `PeriodStart`.

## 5. Panel and reviewers (R7)

- Editor: c-851 (claude). Panel reviewer: a fresh-session claude seat, named
  by the dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a fresh-session claude seat per row (section 1); lines
  checked with `do_spl_review_line_check`. A row with no reviewer for 15
  minutes reports a blocker (2.7.3).
- **Panel point P1:** confirm `r44` (section 1).
- **Panel point P2:** rows 06-08 add tests but raise no floor, against the
  floor file's own note ("a lane that adds tests raises its package's line
  by hand in the same commit"), because `go-coverage-floor.txt` is named by
  round 18 rows 06 and 07 (brief rule: no round 18 file). The panel accepts
  that, or asks for one batch 2 row that raises the three floors to the n=3
  reading after `r43-07` lands.
- **Panel point P3:** row 05's gate reads the parsed header, so 53 files
  stay in its baseline, among them the 9 with an unchecked `(required)`
  `@param` (section 6). The panel confirms the ratchet, or asks for a
  grep-only gate (which would pass most of the 53 today and catch less).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| the other 53 action files whose header the loader does not read (73 - 20) | 5 sites per row would take 11 more rows; they enter row 05's ratchet, and later rounds cut it down | section 2 loop on `5675aa1c3` |
| 9 of those 53 declare a `(required)` `@param` the loader never checks: orc `spl-ask-ack`, `spl-ask-close`, `spl-ask-put`, `spl-lane-put`, `spl-spawn-enqueue`, `spl-spawn-group-put`, `spl-spawn-placed`; iac `gcp-project-delete`, `gcp-tail-logs` | making the header visible turns on `do_validate_params`, which would then refuse a call that runs today: a behaviour change with every caller checked, for a bug round, not a refactor row. **Input for the next bug round.** | `grep -ciE '^# *@param .*\(required\)'` on the 73 -> 9 files |
| raising the floors of `internal/action`, `billing`, `keyexec` after rows 06-08 | `go-coverage-floor.txt` is named by round 18 rows 06 and 07 (P2). **Input for round 20**, once `r43-07` has landed. | the floor file on `5675aa1c3`: `action 80.8`, `billing 80.8`, `keyexec 79.7` |
| `internal/keydesk` `logf` 50.0 | round 18 row 07 owns the package | retro 17 7.4 |
| `cmd/spool` 77.8 | the gap is in `hub.go`; live lane c-799 works there | `go tool cover -func` |
| `internal/store`, `repodocs`, `auth` low no-DSN numbers | their floors are measured with Postgres (`pg`) | `go-coverage-floor.txt` |
| clean-code `LONG` / `wideFuncs` / bash `LONG` | the three ratchet files are named by briefed rows r41-01..03 | briefs `c003-r41-0{1,2,3}-*.md` |
| WUI raw-text ratchet (14 in 12 files) | codes and brand words, not translatable text | `node src/node/i18n/i18n-gates.mjs raw --list` |
| gosec G101 x4, semgrep x1, `run.sh`, `internal/blob`, shellcheck `-x` | as retro 17 section 7.7 | the baselines on `5675aa1c3`: 4 and 1 rows |
| shellcheck WARNING baseline | round 18 Lane 1 (rows 03-05) still edits it | round 18 plan 3.1 |

## 7. Counts

| metric | n |
|---|---|
| rows | 8 (refactor 4, test 4; iac 3 with 1 orc file, utl 1, iac gate 1, Go 3) |
| vendor | claude 8 |
| kind | simple_coding 4, tests 4 |
| batches | batch 1: 7 rows at once; batch 2: row 05 |
| action files without a parsed `@example` | 73 -> 53 after rows 01-04, then held by row 05 |
| measured on | `5675aa1c3`, n=1 per command unless stated (Go: n=2) |

## 8. Changes

- v0.1: first draft (c-851): 8 rows, slug `r44`; no round 18 retro (not due).

## 9. Consensus

- Editor seat: c-851 (claude).
- Claude panel reviewer seat: pending, placed by the dispatch holder.
