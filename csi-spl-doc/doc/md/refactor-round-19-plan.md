# Refactoring round 19 - plan (9 actions)

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
still open (`git log e19ee1cb8 -E --grep='r43-[0-9]{2}' --format='%h %s'` ->
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

**Status: v1.0 SIGNED** (editor c-851, claude, and panel reviewer c-971, claude, on
v0.2 `5e9af3b8f`; c-971 FAILED v0.1 `2341c31a7` on two row recipes, W1-W5,
and v0.2 folds them, section 8).

Editor: **c-851** (claude). Panel reviewer: a fresh-session claude seat, placed
by the dispatch lease holder. Dispatch lease holder: the current holder of
`lease.dispatch`.

**One sha:** every count is measured on **`e19ee1cb8`** (`origin/master`
e19ee1cb88bee65246db073a59a1a88ac038612d, 2026-10-31), n=1 per command
unless stated. Go: go1.26.10. v0.1 measured on `5675aa1c3`;
`git diff --stat 5675aa1c3 e19ee1cb8 -- csi-spl-api/src/go/spool-hub-api/internal/{action,billing,keyexec} csi-spl-api/src/bash/tests/go-coverage-floor.txt 'csi-spl-*/src/bash/run/' 'csi-spl-*/lib/bash/funcs/parse-metadata.func.sh'`
is empty, and the section 2 loop re-run on `e19ee1cb8` gives the same
73 / 61, so every v0.1 count holds on `e19ee1cb8` (the panel reviewer
reproduced them on both).

## 1. How to read this

- **Slug prefix `r44`.** Round 18's plan reserved it (its section 1).
  `git log e19ee1cb8 --oneline --grep='r44-' | wc -l` -> 0, and no brief
  names it:
  `grep -rl 'r44-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0 (this box, 2026-10-31 ~22:40Z; on 2026-11-01 ~00:25Z -> 1, the
  panel reviewer's own brief, which quotes this check). The older `r19-*` brief names in
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
  `t/` = `src/bash/tests/` of the sub-project named. Lines as of `e19ee1cb8`.
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
  (`git grep -l -F -e <basename> -e <do_name> e19ee1cb8 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row below.
- **The header the loader reads.** `do_parse_metadata`
  (`iac:lib/bash/funcs/parse-metadata.func.sh:14`, the same code in the orc
  and utl copies) starts the header only at a `#---` separator line (`:30`)
  and stops at the first non-comment line (`:33`). A closing `#---` does
  **not** end the header: it only sets `in_header=1` again, and every
  comment line down to the first command (blank lines included) is read
  into the last tag. Prose above the first separator is never read. Tags
  above the separator, or after the first command, are not read: `./run` neither
  shows them nor checks their `@param (required)` (`do_validate_params`,
  `iac:lib/bash/funcs/validate-params.func.sh:12`, skips a file with no
  parsed metadata). "Has the tag" in this plan means
  **`do_parse_metadata <file>` prints a `description=` / `example=` line**,
  not that `grep` finds the word, **and** no parsed `example=` line is
  longer than 200 characters (`do_parse_metadata <f> | grep '^example=' | awk 'length > 200' | wc -l`
  -> 0): a longer one is prose swallowed by the header, not an example.
- **Header rows change comments only.** No `@param` is added (a
  `(required)` one would make `./run` refuse a call that works today); no
  code line moves. A file whose first command (the
  `declare -F spl_gcp_temp_sdk_config ... || source ...` line, 37 action
  files) stands **above** its separator is not a header row: moving that
  line below the header puts its `# shellcheck source=` directive (which
  must sit right above it) inside the header, where the loader reads it
  into the last tag (simulated on a copy of
  `gcp-002-delete-project-service-account.func.sh`: `example=... shellcheck source=../../../lib/...`).
  Those files are left out (section 6). An `@example` of a terraform action names the tf-runner
  make target where one exists (`cd csi-spl-orc && ENV=dev STEP=<step> make do-tf-plan`;
  the targets: `grep -oE '^do-[a-z0-9-]+:' orc:src/make/tf-tasks.func.mk`,
  e.g. `do-provision`, `do-tf-apply-target`, `do-tf-state-list`; there is
  no `do-tf-apply`), never a host terraform run (repo `CLAUDE.md`).

## 2. Where the rows come from (measured on `e19ee1cb8`)

| source | input | command on `e19ee1cb8` | n | row / disposition |
|---|---|---|---|---|
| fresh | action files (a `do_*()` in `run/*.func.sh` of iac, orc, utl) with no `@description` or no `@example` anywhere in the file | `for f in <sub>/src/bash/run/*.func.sh; do grep -qE '^(function +)?do_[a-z0-9_]+ *\(\)' $f \|\| continue; grep -q '@description' $f; grep -q '@example' $f; done` | **20** files: iac 14 (all lack `@example`), utl 5 (lack `@description`), orc 1 (lacks `@description`) | **Rows 01-04** |
| fresh | the same files whose **parsed** header lacks a tag | the same loop with `do_parse_metadata $f \| grep -q '^description='` / `'^example='` | **73** files lack a parsed `example=` (iac 47, orc 21, utl 5), **61** a parsed `description=`; the 20 above are among them | 18 of the 20 in rows 01-04 (2 declare-first files left out, W1); the other 55 are the baseline of **Row 05**'s ratchet |
| fresh | action files whose first command stands above the separator | `awk '/^#-+$/{exit} /^declare -F .*\|\| source/{print FILENAME; exit}'` over the same files | **37** | **Left out** (section 6): no comments-only fix |
| fresh | action files with a parsed `example=` over 200 characters (prose swallowed) | the same loop with `do_parse_metadata $f \| grep '^example=' \| awk 'length > 200'` | **32** files (iac 9, orc 23); none is a row 01-04 file | **Row 05**'s shape check, as a second baseline section |
| fresh | of those, headers that declare a `(required)` `@param` | `grep -ciE '^# *@param .*\(required\)'` on the 73 | **9** files | **Left out** (section 6): making them visible turns on a refusal, a behaviour change |
| fresh | Go functions at 0% or under 50% in packages measured without Postgres | `cd go: && go test -count=1 -coverprofile=c.out ./...`, `go tool cover -func=c.out`; then `./internal/action/ ./internal/billing/ ./internal/keyexec/` again (n=2, same numbers) | `internal/action` 81.9% (floor 80.8): `Lane` 0.0, `Move` 0.0, `MoveMsg` 0.0, `Pin` 0.0, `checkRef` 42.9, `checkPeers` 28.6, `checkAnswers` 42.9; `internal/billing` 80.8% (floor 80.8): `ValidStatus` 0.0, `PeriodStart` 0.0; `internal/keyexec` 79.7% (floor 79.7): `Verdict.String` 0.0, `Lease.String` 0.0 | **Rows 06, 07, 08**; floors: **Row 09** |
| fresh | the `pg` packages (`internal/store` 47.5, `repodocs` 55.8, `auth` 80.4 without a DSN) | the same run | | **Left out:** their floors are measured with Postgres (`go-coverage-floor.txt`: `repodocs 90.7 pg`, `auth 82.9 pg`); the no-DSN number says nothing |
| retro 17 7.4 | `internal/keydesk` `logf` 50.0 | | | **Left out:** round 18 row 07 (`r43-07`) owns `internal/keydesk` |
| retro 17 7.5 | `cmd/spool` 77.8 vs 78.0 | the run above: 77.8 | 1 | **Left out:** the gap is in `hub.go`; live lane c-799 (`c002-api-err-r45-shutdown-drain`) works there |
| retro 17 7.6 | shims, unused exports, SFC size, tmp-path, eslint-security | `grep -v '^#' <baseline> \| grep -c .`: `.tmp-path-baseline.txt` 0, `.eslint-security-baseline.txt` 0 | 0 / 0 | **Left out:** nothing to lower |
| retro 17 7.7 | clean-code `LONG` / `wideFuncs` | briefs `c003-r41-0{1,2,3}-*.md` (2026-10-30) name `cleancode_test.go`, `cleancode.test.mjs`, `bash-cleancode.tst.sh` | 3 briefs | **Left out:** the three ratchet files stay with rows r41-01..03 (briefed, not on master, not queued) |
| retro 17 7.7 | `run.sh`, gosec G101 x4, semgrep x1, `internal/blob` 71.9%, shellcheck `-x` | `.gosec-baseline.txt` 4 rows, `.semgrep-baseline.txt` 1 row | | **Left out:** as retro 17 says (vendored, triaged false positives, needs a GCS fake, too slow) |
| fresh | WUI raw-text ratchet | `cd csi-spl-wui && node src/node/i18n/i18n-gates.mjs raw --list` | 14 in 12 files | **Left out:** each is a code or brand word (`USD`, `/search:`, `spool-hub`, `Csitea`, `YYYY-MM-DD HH:MM`), not translatable text |
| round 18 | shellcheck baseline, `go-coverage-floor.txt` | round 18 plan section 3 | | **Excluded:** every file a round 18 row names (brief rule) |

## 3. The 9 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r44-01-iac-header-example-gcp)` | an action's parsed header carries an `@example` | `./run` shows the example; these 3 have none (their `@description` is parsed: the separator is at `:3`, after the shebang and before any command) | `iac:run/divest.func.sh:4`<br>`iac:run/export-json-section-vars-as-tf-vars.func.sh:4`<br>`iac:run/provision.func.sh:4` | 3 files | Add one `# @example ...` line inside each header block (above the closing `#---`): a real call with the env vars the function reads. In `provision.func.sh` put it **above** `# @description`: the comment at `:7-8` is read into the last tag (W3; it already sits in `description=` today). Check: `source iac:lib/bash/funcs/parse-metadata.func.sh; do_parse_metadata <f> \| grep -c '^example='` -> 0 before, 1 after, per file, and `do_parse_metadata <f> \| grep '^example=' \| awk 'length > 200' \| wc -l` -> 0. (v0.1 also named `gcp-002-delete-project-service-account` and `gcp-export-dns-settings`: their first command stands above the separator, so no comments-only edit reaches the check; W1, section 6.) Tests: `orc:t/parse-metadata-nofork.tst.sh` (parses every `*.func.sh`), `orc:t/tf-runner-make-path.tst.sh`, `iac:t/export-json-section-vars-as-tf-vars.tst.sh`, `iac:t/gcp-key-path-no-eval.tst.sh`, `iac:t/tf-plugin-cache-shared.tst.sh`, `iac:t/return-not-exit-gcp.tst.sh`; for `provision`: `iac:t/bash-cleancode.tst.sh`, `comment-refs-exist.tst.sh`, `env-order-gate.tst.sh`, `gcp-alert-snooze.tst.sh`, `provision-052-entry-check.tst.sh`, `tf-apply-exit-status.tst.sh`, `wui-hosting-019-031.tst.sh`, `orc:t/check-env-order.tst.sh`, `lde-stack.tst.sh`, `lde-up.tst.sh`, `spool-permissions.tst.sh`, `stripe-endpoints-provision.tst.sh`, `tenant-host.tst.sh`. **Red control:** the first check reads 0 on the parent sha. | sat | claude | simple_coding | 1 |
| 02 `refactor(r44-02-iac-header-example-tf-apply)` | as row 01 | the same: 5 terraform actions without an `@example` | `iac:run/tf-apply.func.sh:4`<br>`iac:run/tf-apply-target.func.sh:4`<br>`iac:run/tf-destroy.func.sh:4`<br>`iac:run/tf-init.func.sh:4`<br>`iac:run/tf-new-step.func.sh:4` | 5 files | As row 01; each example is the tf-runner make target where `orc:src/make/tf-tasks.func.mk` has one (`do-provision` runs the apply, `do-tf-apply-target`, `do-tf-destroy-target`), else the `./run` call that make target runs **inside** the tf-runner. Tests: `orc:t/parse-metadata-nofork.tst.sh`; `iac:t/env-order-gate.tst.sh`, `provision-052-entry-check.tst.sh`, `satellite-ansible.tst.sh`, `tf-apply-destroy-quoted-paths.tst.sh`, `tf-apply-exit-status.tst.sh`, `tf-destroy-local-step-bucket.tst.sh`, `tf-destroy-target.tst.sh`, `gcp-tf-shared-bodies.tst.sh`, `tf-actions-tf-proj-after-init.tst.sh`, `tf-import-result-log.tst.sh`, `tf-init-project-key.tst.sh`, `tf-plugin-cache-shared.tst.sh`, `tf-state-actions.tst.sh`, `tf-state-remove-backup.tst.sh`, `tf-new-step.tst.sh`; `orc:t/check-env-order.tst.sh`, `tf-030-import-existing-cloud-run.tst.sh`. **Red control:** as row 01. | sat | claude | simple_coding | 1 |
| 03 `refactor(r44-03-iac-header-example-tf-state)` | as row 01, and a parsed `@description` for the one orc action without | 4 terraform actions without an `@example`; `do_spl_hub_run_metrics` has its tags in a comment the loader skips (no separator) | `iac:run/tf-plan.func.sh:4`<br>`iac:run/tf-state-list.func.sh:4`<br>`iac:run/tf-state-pull.func.sh:4`<br>`iac:run/tf-state-push.func.sh:4`<br>`orc:run/spl-hub-run-metrics.func.sh:2` | 5 files | As rows 01-02 for the 4 tf files. `spl-hub-run-metrics`: a `#---` line after the shebang, `# @description` on the existing first comment line, its `@param` and `@example` lines kept as they are, a closing `#---` above `:9`. Its one `@param` (`ENV, REQ_SINCE, REQ_MINUTES as do_spl_hub_request_minutes`) has no `(required)`, so `do_validate_params` refuses nothing new: the lane shows `do_parse_metadata <f> param` after the change and that no line holds `(required)`. Tests: `orc:t/parse-metadata-nofork.tst.sh`; `iac:t/env-order-gate.tst.sh`, `satellite-actions.tst.sh`, `tf-state-actions.tst.sh`; `orc:t/tf-plan-ref.tst.sh`, `tf-runner-make-path.tst.sh`, `tf-import-existing.tst.sh`, `canary-hub-deploy.tst.sh`, `spl-hub-load-test.tst.sh`, `spl-hub-request-minutes.tst.sh`. Simulated on a copy on `e19ee1cb8`: `description=` (385 chars, the prose), `param=`, `example=` (93 chars). **Red control:** as row 01 (and `^description=` 0 -> 1 for the orc file). | sat | claude | simple_coding | 1 |
| 04 `refactor(r44-04-utl-header-parsed)` | the utl actions' header is one the loader reads | all 5 utl actions open with prose, their `@example` lines sit at the end of it, and their only separator comes after those lines, so `./run` reads no `@description` and no `@example` for any of them | `utl:run/cron-heartbeat-snitch.func.sh:2`<br>`utl:run/docker-test-container-prune.func.sh:2`<br>`utl:run/docker-volume-prune.func.sh:2`<br>`utl:run/reboot-required-check.func.sh:2`<br>`utl:run/systemd-unit-health.func.sh:2` | 5 files | Per file: an opening `#---` line at the **end** of the prose, directly above the first existing `# @example` line (`cron-heartbeat-snitch :60`, `docker-test-container-prune :54`, `docker-volume-prune :39`, `reboot-required-check :43`, `systemd-unit-health :30`), then `# @description` + one sentence from the file's first prose line; the existing `@example` lines stay as they are (no new one), and the existing `#---` right after them (`:62`, `:56`, `:41`, `:45`, `:32`) is the closing one, directly above the first command. The prose above the opening `#---` is never read (`in_header=0`). A closing `#---` placed after the shebang (v0.1's recipe) would not end the header: `example=` would swallow the prose, 1,465-3,172 chars per file (W2). Simulated on copies on `e19ee1cb8`: `description=` + 2 `example=` lines per file, each 41-75 chars. No `@param` (none today: `grep -c '^# *@param'` -> 0 in each). Tests: `orc:t/parse-metadata-nofork.tst.sh`; `utl:t/cron-heartbeat-snitch.tst.sh`, `docker-test-container-prune.tst.sh`, `docker-volume-prune.tst.sh`, `reboot-required-check.tst.sh`, `systemd-unit-health.tst.sh`; `orc:t/reliability-checks-cron.tst.sh`, `box-name-from-cnf.tst.sh`; `iac:t/bash-cleancode.tst.sh` (names `reboot-required-check.func.sh`). **Red control:** `^description=` 0 -> 1 and `^example=` 0 -> 2 per file, and `do_parse_metadata <f> \| awk 'length > 200' \| wc -l` -> 0. | sat | claude | simple_coding | 1 |
| 05 `test(r44-05-iac-action-header-tags-gate)` | a gate: every action's parsed header carries both tags, in shape, a ratchet for the rest | developer guide 2.4.2 says "Enforced by: review only"; 73 action files lack a tag today, 32 more carry a swallowed-prose `example=` | `iac:t/action-header-tags.tst.sh` (new)<br>`iac:t/action-header-tags-baseline.txt` (new, two sections: `missing` 55 rows, `long-example` 32 rows) | 73 -> 55 files, + 32 | The test sources `iac:lib/bash/funcs/parse-metadata.func.sh`, walks `run/*.func.sh` of iac, orc and utl that define a `do_*()`, and fails on a file without `description=` or `example=` unless the `missing` section lists it, and on a file with an `example=` line over 200 characters unless the `long-example` section lists it; it also fails on a listed file that now passes that check (the list only shrinks, like `.shellcheck-warning-baseline.txt`). The 55 hold only if rows 01-04 land as written (18 files); the lane re-counts on its start sha and builds the list from the measurement, never from this number. `iac:t/run-all-tests.sh` runs it (it runs every `*.tst.sh`). R9: run under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** in a `mktemp -d` tree, an action file without `@example` -> FAIL; an action whose closing `#---` is followed by prose (an `example=` over 200 chars) -> FAIL; a listed file given both tags -> FAIL; then the real tree -> PASS. Docs: the developer guide is a Qto export (`do_spl_doctree_export_md`); the lane sends the new "Enforced by" line for 2.4.2 to the dispatch holder and lands `Docs: none (<why>)`. | sat | claude | tests | 2 (after 01-04) |
| 06 `test(r44-06-api-action-hub-verb-refusals)` | the hub-mode verbs' refusals under test | `Lane` (`lane.go:37`), `Move` (`move.go:29`), `MoveMsg` (`move.go:66`), `Pin` (`pin.go:38`) are 0.0%: every refusal (no hub URL, bad fleet slug, bad task / msg uuid, empty channel, bad `--as`, non-HUM `--acting-for`, `--pubkey` xor `--revoke`) is untested | `go:internal/action/lane.go:37`<br>`go:internal/action/move.go:29,66`<br>`go:internal/action/pin.go:38`<br>`go:internal/action/hub_verb_refusals_test.go` (new) | 4 functions at 0.0 (measure: section 2, the Go row) | Table tests per refusal, each asserting the error text; a success path only through an `httptest` hub that an existing test file of the package already builds (reuse it; define no helper whose name another test file of the package defines). `Pin` writes into a `t.TempDir()` pins dir. No floor change here: row 09 raises it (R1). Tests: `go test -count=1 -race -cover ./internal/action/`; `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (coverage part `ok`, floors unchanged). **Red control:** make `Move` accept an empty `--channel` -> a new case fails. | sat | claude | tests | 1 |
| 07 `test(r44-07-api-action-send-guards)` | the send guards under test | `checkRef` 42.9, `checkPeers` 28.6, `checkAnswers` 42.9: the hub-mode, uuid, `--to-box`, `--if-gen` and `--channel` refusals are not all exercised | `go:internal/action/action.go:209,228,243`<br>`go:internal/action/send_guards_test.go` (new) | 3 functions (measure: section 2, the Go row) | One table per guard, every `case` arm; `checkPeers` also asserts `ToBox` becomes `msg.PeersToBox` on success. A different test file from row 06 (R1); helper names prefixed `sg` so the two files compile together. Tests: as row 06. **Red control:** drop the `in.ToBox != msg.PeersToBox` arm -> a new case fails. | sat | claude | tests | 1 |
| 08 `test(r44-08-api-billing-keyexec-helpers)` | small pure helpers under test, the key-hiding `String` first | `keyexec.Lease.String` (`desk.go:56`) keeps a vendor key out of every `%v` and log line, at 0.0; `Verdict.String` (`classify.go:38`), `billing.ValidStatus` (`billing.go:77`) and `PeriodStart` (`:97`) are 0.0 too | `go:internal/keyexec/desk.go:56`<br>`go:internal/keyexec/classify.go:38`<br>`go:internal/billing/billing.go:77,97`<br>`go:internal/keyexec/keyexec_test.go`<br>`go:internal/billing/billing_test.go` | 4 functions at 0.0 (measure: section 2, the Go row) | `fmt.Sprintf("%v %+v %s", l, l, l)` on a `Lease` with a fake key holds `<VENDOR_KEY>` and never the key; both `Verdict` names; every `Status*` constant valid and `"x"` not; `PeriodStart` across a month end and from a non-UTC zone. Fake keys only, no key path. No floor change here: row 09 raises it. Tests: `go test -count=1 -race -cover ./internal/keyexec/ ./internal/billing/`; `run-all-tests.sh`. **Red control:** `Lease.String` returning `l.Key` -> the new case fails. | sat | claude | tests | 1 |
| 09 `test(r44-09-api-coverage-floors-raise)` | a lane that adds tests raises its package's floor (the floor file's own rule, `:4-5`) | rows 06-08 add tests to 3 packages but may not touch the floor file in batch 1: rows 06 and 07 would both edit the `internal/action` line (R1), and round 18 row 07 (`r43-07`, open) names the file | `api:src/bash/tests/go-coverage-floor.txt:27` (`internal/action 80.8`)<br>`:39` (`internal/billing 80.8`)<br>`:85` (`internal/keyexec 79.7`) | 3 lines | Raise each line to the n=3 reading of `cd go: && go test -count=1 -coverprofile=c.out ./internal/<pkg>/` on the sha the lane starts from, no fixed target (retro 17, 4.2); a package whose reading is not above its floor keeps its line, and the lane says so. Tests: `bash csi-spl-api/src/bash/tests/run-all-tests.sh` (coverage part `ok` at the new floors). **Red control:** revert row 06's test file in a scratch copy -> the coverage part fails `internal/action` against the new floor. Placed only after rows 06, 07, 08 **and** `r43-07` are on `origin/master`, and `lane-map.sh --check api:src/bash/tests/go-coverage-floor.txt` exits 0 (on `e19ee1cb8` it exits 3: c-862 (on this box)'s worktree holds stale staged edits to the file). | sat | claude | tests | 2 (after 06, 07, 08, `r43-07`) |

### 3.1 Lanes and batches

Disjoint files in batch 1 (R1): **7 rows at once** (01, 02, 03, 04, 06, 07,
08). Rows 06 and 07 share a package but no file; each adds its own test
file. Batch 2: row 05 follows once rows 01-04 have landed, so its baseline
holds exactly the files still failing (55 if all four land as planned; the
lane re-counts); row 09 follows rows 06-08 and `r43-07`. Rows 05 and 09
share no file, so batch 2 gives 2 at once. Under the owner's "keep 2 row lanes in parallel" (686bc1a3) the
dispatch holder places two at a time from batch 1, and more when the band
allows.

No batch 1 row touches a shared baseline file that exists today (row 09,
batch 2, edits `go-coverage-floor.txt` alone), `csi-spl-cnf/`, a
migration, a workflow or terraform code (rows 01-03 change comments in
terraform action files only).

### 3.2 Off every live lane and every round 18 row (R3)

- **Round 18:** `grep -cE '<the site basenames>' csi-spl-doc/doc/md/refactor-round-18-plan.md`
  -> 1: row 07's `keydesk.go`, which matches `desk.go` only as a substring
  (`internal/keydesk/keydesk.go`, not `internal/keyexec/desk.go`); round 18
  names no file of this round.
- **Live lanes:** `lane-map.sh --check <the 32 paths, comma separated> --agent c-851`
  (2026-10-31 ~22:45Z; v0.2 drops 2 of them) -> **exit 4**: no live lane lists any of the paths,
  but 25 live lanes record no files. Their briefs were read with
  `grep -oE '<the site basenames>|billing|keyexec|internal/action|go-coverage-floor'`:
  0 hits for every one (on this box `/var/spool-hub/<id>/lifetime/brief.md`
  and `dispatch/briefs/`; on sat `dispatch/briefs/` and the seats'
  `lifetime/brief.md`), except c-849 (`r43-07`), which names
  `go-coverage-floor`: no row here touches that file. The rotate and
  restarted seats (c-613, c-765, c-769, c-804, c-807, c-826, c-862, c-864,
  c-866, c-934, c-988, g-585, g-602) are seat or review briefs on other
  subjects. Row 09's `api:src/bash/tests/go-coverage-floor.txt`
  (2026-11-01 ~00:20Z) -> **exit 3**, two owners: c-862 (on this box),
  whose worktree holds staged edits to the floor file and to `cmd/spool`
  files under an unrelated seat brief (stale, not this round's to fix), and
  c-849, the `r43-07` lane (round 18 row 07; its worktree status was empty
  when the panel read it, but lane-map still counts it). Row 09 is batch 2
  and is placed only once `r43-07` has landed and that check exits 0, so
  both must clear.
- **Spawn queue:** `./run -a do_spl_spawn_queue` -> 22 queued, 0 placing;
  the same grep over each queued brief (on this box, and on sat for those
  queued there) -> 0 for 21 of 22; the brief of
  one queued bug brief (a read-only DNS bug of this box, ask 75077182) was found on neither box
  (read-only DNS bug, **unchecked**).

## 4. Per row: what the lane does

- **01:** One `@example` in the parsed header of 3 iac actions.
- **02:** The same for 5 terraform apply / destroy / init / new-step actions.
- **03:** The same for 4 terraform plan / state actions, and a parsed header for `do_spl_hub_run_metrics`.
- **04:** A parsed header (`#---` above the existing `@example` lines, `@description`) for the 5 utl actions.
- **05:** The gate test and its two-section ratchet (55 missing, 32 long-example).
- **06:** Refusal tests for `Lane`, `Move`, `MoveMsg`, `Pin`.
- **07:** Tests for every arm of `checkRef`, `checkPeers`, `checkAnswers`.
- **08:** Tests for `Lease.String` (key hidden), `Verdict.String`, `ValidStatus`, `PeriodStart`.
- **09:** Raise the `action`, `billing`, `keyexec` floors to the n=3 reading.

## 5. Panel and reviewers (R7)

- Editor: c-851 (claude). Panel reviewer: a fresh-session claude seat, named
  by the dispatch lease holder. Both sign the plan sha (rulebook 3.2).
- Row reviewers: a fresh-session claude seat per row (section 1); lines
  checked with `do_spl_review_line_check`. A row with no reviewer for 15
  minutes reports a blocker (2.7.3).
- **P1, ruled (c-971):** `r44` is free (section 1).
- **P2, ruled (c-971):** no floor change in batch 1, plus batch 2 row 09
  that raises the three floors after rows 06-08 and `r43-07` land.
- **P3, ruled (c-971):** the parsed-header ratchet is right; row 05 adds a
  shape check on `example=` (over 200 chars fails). The 9 `(required)`
  files stay in its baseline (section 6).
- **No round 18 retro, ruled (c-971):** allowed (rulebook 2.8 R8 and 1.4).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| the other 55 action files whose header the loader does not read (73 - 18) | 5 sites per row would take 11 more rows; they enter row 05's ratchet, and later rounds cut it down | section 2 loop on `e19ee1cb8` |
| 37 action files whose first command (`declare -F spl_gcp_temp_sdk_config ... \|\| source ...`) stands above the separator, among them v0.1 row 01's `gcp-002-delete-project-service-account` and `gcp-export-dns-settings` | no comments-only fix: the line's `# shellcheck source=` directive must sit right above it, and below the header the loader reads that directive into the last tag. A fix changes the loader (e.g. stop the header at a closing `#---`, which also fixes the swallowed prose of the 32 `long-example` files) or how the files source the helper: **input for round 20**, with every `./run` help and `do_validate_params` caller checked | `awk '/^#-+$/{exit} /^declare -F .*\|\| source/{print FILENAME; exit}'` over the run dirs -> 37 |
| 9 of those 55 declare a `(required)` `@param` the loader never checks: orc `spl-ask-ack`, `spl-ask-close`, `spl-ask-put`, `spl-lane-put`, `spl-spawn-enqueue`, `spl-spawn-group-put`, `spl-spawn-placed`; iac `gcp-project-delete`, `gcp-tail-logs` | making the header visible turns on `do_validate_params`, which would then refuse a call that runs today: a behaviour change with every caller checked, for a bug round, not a refactor row. **Input for the next bug round.** | `grep -ciE '^# *@param .*\(required\)'` on the 73 -> 9 files |
| `internal/keydesk` `logf` 50.0 | round 18 row 07 owns the package | retro 17 7.4 |
| `cmd/spool` 77.8 | the gap is in `hub.go`; live lane c-799 works there | `go tool cover -func` |
| `internal/store`, `repodocs`, `auth` low no-DSN numbers | their floors are measured with Postgres (`pg`) | `go-coverage-floor.txt` |
| clean-code `LONG` / `wideFuncs` / bash `LONG` | the three ratchet files are named by briefed rows r41-01..03 | briefs `c003-r41-0{1,2,3}-*.md` |
| WUI raw-text ratchet (14 in 12 files) | codes and brand words, not translatable text | `node src/node/i18n/i18n-gates.mjs raw --list` |
| gosec G101 x4, semgrep x1, `run.sh`, `internal/blob`, shellcheck `-x` | as retro 17 section 7.7 | the baselines on `e19ee1cb8`: 4 and 1 rows |
| shellcheck WARNING baseline | round 18 Lane 1 (rows 03-05) still edits it | round 18 plan 3.1 |

## 7. Counts

| metric | n |
|---|---|
| rows | 9 (refactor 4, test 5; iac 3 with 1 orc file, utl 1, iac gate 1, Go 3, Go floors 1) |
| vendor | claude 9 |
| kind | simple_coding 4, tests 5 |
| batches | batch 1: 7 rows at once; batch 2: rows 05 and 09, 2 at once |
| action files without a parsed `@example` | 73 -> 55 after rows 01-04 (if they land as written), then held by row 05 |
| action files with an `example=` over 200 chars | 32, held by row 05 |
| measured on | `e19ee1cb8`, n=1 per command unless stated (Go: n=2 on `5675aa1c3`, packages unchanged since) |

## 8. Changes

- v0.1 `2341c31a7`: first draft (c-851): 8 rows, slug `r44`; no round 18 retro (not due).
- v0.2: folds panel review c-971 FAIL (msg 243d8dad): **W1** row 01 drops
  the 2 declare-first gcp files (moving the line was simulated and puts its
  shellcheck directive in the header), 37 such files to section 6; **W2**
  row 04's recipe now opens the header above the existing `@example` lines
  (simulated, 41-75 char tags); **W3** `provision` gets its `@example`
  above `@description`; **W4** 73 -> 55, with its condition; **W5** batch 2
  row 09 raises the three floors; one sha moved to `e19ee1cb8` (counts
  unchanged, section 0); row 05 adds the `example=` shape check (32
  baseline rows); rows 06-08 point to their measure command.
- v1.0: c-971 PASS on v0.2 `5e9af3b8f` (msg fd241be8); folds its note N1
  (section 3.2 names c-849 as the floor file's second owner). No other
  change beyond the version label and the signatures.

## 9. Consensus

- Editor seat: c-851 (claude).
- Claude panel reviewer seat: c-971 (claude): FAIL on v0.1 `2341c31a7` (msg
  243d8dad); **PASS** on v0.2 `5e9af3b8f` (msg fd241be8), which signs v1.0.
- Editor seat: c-851 signs v1.0.
