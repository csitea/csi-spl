# Refactoring round 20 - plan (9 actions)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/011-spool-project-refactor  
Class: refactor  
Kind: specs_and_docs  
Issue: SPL-4561  

Owner HUM-10 directives and fleet rules, by pointer:
- msg 7f664194 / 8cb6cc7d: 20-30% of the fleet on refactoring
  ([fleet-rules-index.md](fleet-rules-index.md)).
- msg b8e22a15: reach consensus in the panel and start, no owner input;
  msg 3d22fcea: rounds run continuously, no owner go
  ([rounds-rulebook.md](rounds-rulebook.md) 1.4).
- t1 dc15ad65 msg 686bc1a3: **"keep 2 row lanes in parallel"**: this round
  has two tracks that share no file (section 3.1), so two rows can run at
  once while both tracks have rows left.
- owner 10-17 (t1 b61851fb): no mistral coding rows: **vendor claude for
  every row**. Code reviews grok or claude only (msg cf7a7ee5).
- Rules: [rounds-rulebook.md](rounds-rulebook.md) (at most 10 items, pushes
  aim 1 up to 3 never more than 5, R1-R16).

**Why now.** The fleet's refactor share is under its band: c-001@sat
blocker d5028446 (task spawn-share, 2026-11-01T07:1xZ): refactor 12%, 1 of
8 classed live lanes, and no refactor row queued. Round 19
([plan](refactor-round-19-plan.md), v1.0) had rows 01-06 and 08 on master at
`ffd36e3e5` (`git log ffd36e3e5 -E --grep='r44-[0-9]{2}' --oneline` -> 7 row
commits: 01 `fe75c7304`, 02 `2975facfa`, 03 `f3097c224`, 04 `3ccda94f6`, 05
`99fa6c6d4`, 06 `44ca5f516`, 08 `80f8844ad`). Since then row 07 landed as
`27b31ed58` (`git log origin/master -E --grep='r44-0[679]' --oneline` -> 06
and 07, 2026-11-01T18:4xZ); row 09 is not on master. **No round 19 retro
yet**: it is not due while 09 is open (rulebook 2.8). This plan takes round 19's section 6 inputs, above all
its 37 declare-first files, and re-measures each (section 2).

Round 20 focus: **a closing `#---` ends an action's header**, so prose
after it is no longer read as part of the last tag (31 -> 4 long examples);
then the declare-first files, which that change makes fixable by moving one
line; and **four Go packages' untested helpers under test**, two of them the
code that keeps a secret out of logs.

**Status: v0.2 DRAFT**, for the panel.

Editor: **c-889** (claude; agy is out of quota until 2026-11-03T12:42Z and
claude is the specs_and_docs backup). Panel reviewer: **g-895** (grok, a
fresh-session cross-vendor seat; c-002 msg 8d17d549: the claude-only
waiver this brief was written under has lapsed), placed by the dispatch
lease holder. Dispatch lease holder: the
current holder of `lease.dispatch`.

**One sha:** every count is measured on **`ffd36e3e5`** (`origin/master`
ffd36e3e51b1f4b1007a73a539cbbfcd8a34a0d7, 2026-11-01T15:19Z), n=1 per
command unless stated. Go: go1.26.10. Box: sat.

## 1. How to read this

- **Slug prefix `r46`.** `r45` is taken by another series
  (`ls /var/spool-hub/dispatch/briefs | grep -c r45` -> 1,
  `c002-api-err-r45-shutdown-drain.md`, as round 19 section 1 said).
  `git log ffd36e3e5 --oneline --grep='r46-' | wc -l` -> 0, and
  `grep -rl 'r46-' /var/spool-hub/dispatch/briefs /var/spool-hub/spawn-remote | wc -l`
  -> 0 at 2026-11-01T17:32Z and 1 at 18:4xZ: the one hit is this round's
  panel reviewer brief, which quotes the search (g-895). No r46 lane. The
  next planner proves its prefix free the same way, and discounts briefs
  that only quote the search.
- One row = one practice = one lane, at the sites named and nowhere else,
  with a test that shows behaviour kept or, for a gate change, a **red
  control**: the check fails on the bad input before the change and passes
  after.
- **Paths:** `iac:` = `csi-spl-iac/`, `orc:` = `csi-spl-orc/`,
  `utl:` = `csi-spl-utl/`, `api:` = `csi-spl-api/`,
  `go:` = `csi-spl-api/src/go/spool-hub-api/`; `run/` = `src/bash/run/`,
  `t/` = `src/bash/tests/` and `lib/` = `lib/bash/funcs/` of the
  sub-project named. Lines as of `ffd36e3e5`.
- **Box:** the preferred box; the spawner's pick may move a row (no pin).
- **Vendor:** claude for every row. **R7 reviewer:** a cross-vendor seat
  per row, named by the dispatch holder at placement. I believe, unchecked,
  that c-001 ruled on 2026-11-01 (msgs 6ebd1281 / 89313b26) that the R7 on
  a claude author is a grok seat again, since grok is back (owner d07ab9da);
  if grok is out, the holder re-rules. Each review line names the author's
  vendor too.
- **Subject** (R6 reads it): `<type>(r46-NN-<slug>, SPL-<row issue>): ...`.
- **R7 line:** `review: <id>@<box> <vendor> PASS <40-char sha> ran: <commands> | read: <output> | log: <id>@<box>:<path>`.
- **Re-measure first:** every row lane re-runs its measure command on the
  `origin/master` it starts from and says in its result if the number moved.
- **Tests per row (R2):** every test file that names a site's basename or
  the action it defines
  (`git grep -l -F -e <basename> -e <do_name> ffd36e3e5 -- '*tst.sh' '*/tests/*' '*test*.sh'`),
  listed per row below; for Go, the package's tests.
- **The header the loader reads, today.** `do_parse_metadata`
  (`iac:lib/parse-metadata.func.sh:14`; the orc and utl copies are the same
  code: `diff` against the iac copy -> only lines 7-8, its two `@example`
  lines) starts the header at a `#---` line (`:30`) and stops at the first
  non-comment, non-blank line (`:32-33`). A closing `#---` only sets
  `in_header=1` again, so every comment line below it, down to the first
  command, is read into the last tag. That is why round 19 found 32 (now
  31) files whose `example=` swallows prose, and why it could not move a
  file's first command (`declare -F ... || source ...`) below the header:
  the `# shellcheck source=` directive that must sit right above that line
  would then be read into the last tag (round 19 section 1, W1).
- **The shared baseline.** `iac:t/action-header-tags.tst.sh` (round 19 row
  05) fails on a file listed in `iac:t/action-header-tags-baseline.txt`
  that now passes. So **every header row deletes its files' lines from that
  baseline in the same commit**, and no two header rows can share a batch
  (R1). Rows 01-05 are therefore one serial track; rows 06-09 are a second
  track on Go files.

## 2. Where the rows come from (measured on `ffd36e3e5`)

| source | input | command on `ffd36e3e5` | n | row / disposition |
|---|---|---|---|---|
| round 19 6 | action files whose parsed header lacks a tag | `bash iac:t/action-header-tags.tst.sh` | 765 files: **55** missing, **31** long-example (round 19 counted 32 before `6d35b9b18`) | reproduces |
| fresh | the loader with "a `#---` after header lines ends the header" (`:30` becomes: on a separator, `break` when `in_header` is 1 and the header is not empty) | per action file, `do_parse_metadata` today vs a changed copy: output equal? sorted tag names equal? `(required)` `param=` count equal? `arg=` lines equal? | of 765 files: **82** parse differently, **0** change their tag names, **0** their `(required)` params, **0** their `arg=` lines (8 files carry `@arg`) | **Row 01**: only tag values change, all by dropping swallowed prose |
| fresh | the same change on a copy of `ffd36e3e5` (`git archive` of the iac, orc, utl trees, all three lib copies patched) | `bash orc:t/parse-metadata-nofork.tst.sh`; `bash iac:t/action-header-tags.tst.sh` | nofork: `0 failure(s)`; tags: `measured 765 files: 55 missing, 4 long-example`, 28 FAIL = 27 listed long-example files that now pass + its red control "closing `#---` followed by prose" (that prose is no longer read) | **Row 01** deletes the 27 lines and rewrites that red control |
| round 19 6 | action files whose first command stands above the separator | `awk '/^#-+$/{exit} /^declare -F .*\|\| source/{f=1; exit} END{exit !f}'` over the run dirs | **37** (iac 35, orc 2): reproduces; all 37 are in `[missing]` | rows 02-05 take 17; the other 20 are in section 6 |
| fresh | the 35 iac ones, with the changed loader, after moving the lines above the first `#---` (the directive, the `declare` line, a blank) to just below the closing `#---` | simulated per file on a copy: `description=` / `example=` counts, the longest parsed line, `grep -ciE '^# *@param .*\(required\)'` | **31** get both tags, every parsed line at most 182 characters, no `(required)`; 2 lack an `@example` (`gcp-002-delete-project-service-account`, `gcp-export-dns-settings`); 2 declare a `(required)` `@param` (`gcp-project-delete`, `gcp-tail-logs`) | rows 03-05 take 15 of the 31 |
| fresh | the 2 orc ones (`spl-asks-open`, `spl-asks-tick`): no `#---` at all, so the loader reads nothing | simulated: a `#---` after the shebang and one above the first comment that is not a tag (`:29`, `:68`) | `spl-asks-open`: 19 `description=`, 6 `param=`, 2 `example=`, longest 190, 0 `(required)`; `spl-asks-tick`: 48 / 16 / 2, longest 179, 0 `(required)`; the same with today's loader | **Row 02** |
| round 19 6 | the `(required)` files in `[missing]` | `grep -ciE '^# *@param .*\(required\)'` on the 55 | **9**: reproduces (iac `gcp-project-delete`, `gcp-tail-logs`; orc `spl-ask-ack`, `spl-ask-close`, `spl-ask-put`, `spl-lane-put`, `spl-spawn-enqueue`, `spl-spawn-group-put`, `spl-spawn-placed`) | **Left out**: still a bug-round input (section 6) |
| fresh | Go functions at 0% or under 50% in packages measured without Postgres | `cd go: && go test -count=1 -coverprofile=c.out ./...`, `go tool cover -func=c.out` | `internal/marketing` 83.9%: `Plaintext.GoString` 0.0, `Plaintext.MarshalText` 0.0; `internal/wire` 84.5%: `FleetWorkspacesPayload` 0.0, `FleetEnrolPayload` 0.0, `ValidLeaseReason` 0.0, `InnerMsgID` 0.0, `JoinKeyPayload` 0.0; `internal/hubclient` 83.5%: `MoveMessage` 0.0, `TopicList` 0.0 (x2), `FlowRead` 0.0 (x2), `DialStatusError.Unwrap` 0.0; `internal/payments` 80.9%: `Load` 0.0, `NewWired` 0.0, `CardKeyMode` 0.0 | **Rows 06-09** |
| round 19 6 | `internal/keydesk` `logf` | the same run | 50.0: reproduces; its reason (round 18 row 07 owned the package) is gone: `bf9e6c9ac` landed `r43-07` | **Left out**: one branch of a log helper, the lowest value here; input for round 21 |
| round 19 6 | `cmd/spool` | the same run | 77.8%: reproduces; `hub.go` `cmdServe`, `claimOperatorWorkspace`, `checkSchemaHead` 0.0 | **Left out**: the server entry points need the hub's Postgres and boot path, not a small row |
| round 19 6 | `internal/store`, `repodocs`, `auth` low no-DSN numbers | the same run | 47.5 / 55.8 / 80.4: reproduces | **Left out**: their floors are measured with Postgres |
| round 19 6 | clean-code `LONG` / `wideFuncs` / bash `LONG` | `git log ffd36e3e5 -E --grep='r41-0[1-3]' --oneline \| wc -l` -> 0; `ls /var/spool-hub/dispatch/briefs \| grep -c 'r41-0[123]'` -> 3 | 3 briefs, none landed | **Left out**: still named by briefed rows r41-01..03 |
| round 19 6 | WUI raw-text ratchet | `cd csi-spl-wui && node src/node/i18n/i18n-gates.mjs raw` | 14 in 12 files: reproduces | **Left out**: codes and brand words |
| round 19 6 | gosec G101, semgrep | `grep -v '^#' <baseline> \| grep -c .` | `.gosec-baseline.txt` 4, `.semgrep-baseline.txt` 1: reproduces | **Left out**: as retro 17 section 7.7 |
| round 19 6 | shellcheck WARNING baseline | `git log ffd36e3e5 -E --grep='r43-0[45]' --oneline \| wc -l` -> 0 | round 18 rows 04, 05 not landed | **Left out**: still theirs |
| round 19 | `internal/action`, `go-coverage-floor.txt` | round 19 row 09 (07 landed `27b31ed58`) | | **Excluded**: open round 19 rows (brief rule) |

## 3. The 9 rows

| # | practice | why | sites file:line (max 5) | n | test or red control (R2) | box | vendor | kind | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 `refactor(r46-01-lib-header-ends-at-closing-separator)` | a closing `#---` ends an action's header | today every comment below the closing separator is read into the last tag: 31 files show prose as their `@example` in `./run`, and no file can put a command with its `# shellcheck source=` directive below its header | `iac:lib/parse-metadata.func.sh:30`<br>`orc:lib/parse-metadata.func.sh:30`<br>`utl:lib/parse-metadata.func.sh:30`<br>`orc:t/parse-metadata-nofork.tst.sh` (the new case below)<br>`iac:t/action-header-tags.tst.sh:9-11,71` (its header comment, its FAIL hint, and the red control "closing `#---` followed by prose")<br>`iac:t/action-header-tags-baseline.txt` (`[long-example]` and its "Measured on" comment) | 3 copies, 31 -> 4 long-example | The same edit in the three copies: on a `^#-+$` line, `break` when `in_header` is 1 and `header` is not empty, else set `in_header=1`, **as one line**: `[[ "$line" =~ ^#-+$ ]] && { [[ $in_header -eq 1 && -n "$header" ]] && break; in_header=1; continue; }`. The cap of `iac:t/bash-cleancode.tst.sh` is `MAX_LINES=75` (`:20`, SPL-3725 80 -> 75) and `do_parse_metadata` is not in its ceiling list (`grep -c parse_metadata` -> 0), so the function must stay at or under 75 lines: 72 today and 72 with the one-line edit, but 76 with a 5-line `if` and 78 with a 7-line one, both red (g-895, the test's own awk on the iac copy). A multi-line `if` fails the gate. In the tags test, the red control becomes **one `@example` line over 200 characters -> FAIL**, and its comments and hint say what is read now; delete the 27 `[long-example]` lines that now pass and re-measure the comment. Before the commit, the lane runs section 2's old-vs-new comparison on its start sha and quotes it: tag names, `(required)` params and `arg=` lines unchanged in every action file. Tests: `orc:t/parse-metadata-nofork.tst.sh` (add a case: `#---`, `@example x`, `#---`, `# prose`, a command -> `example=x`), `iac:t/action-header-tags.tst.sh`, `iac:t/comment-refs-exist.tst.sh`, `iac:t/run-log-nofork.tst.sh`, `iac:t/bash-cleancode.tst.sh`, then `bash iac:t/run-all-tests.sh` and the orc and utl suites. R9 (a gate's input): run under `PRE_PUSH_TIER=full` and once with every `PRE_PUSH_*` unset. **Red control:** the new nofork case FAILS on the parent sha (`example=x prose`) and passes after. Docs: `Docs: none (./run help text only; developer guide 2.4.2 names the gate, not the parser)`. | sat | claude | complex_coding | 1 |
| 02 `refactor(r46-02-orc-asks-header-parsed)` | the two ask actions' header is one the loader reads | `spl-asks-open` and `spl-asks-tick` have their tags but no `#---`, so `./run` shows no description and no example for them, and checks none of their `@param` lines | `orc:run/spl-asks-open.func.sh:2,29`<br>`orc:run/spl-asks-tick.func.sh:2,68`<br>`iac:t/action-header-tags-baseline.txt` (`[missing]`, 2 lines) | 2 files | Per file: a `#---` line after the shebang, and a closing `#---` above the first comment that is not a tag (`:29` and `:68`, the `# spl_role_seat:` line), right above the `declare -F spl_role_seat` command. Comments only, no tag text changes. Both declare `@param` lines, none `(required)` (`grep -ciE '^# *@param .*\(required\)'` -> 0 each), so `do_validate_params` refuses nothing new; the lane shows `do_parse_metadata <f> param` after. Delete the two `[missing]` lines. Simulated on copies of `ffd36e3e5`: 19 / 48 `description=`, 2 `example=` each, longest line 190 / 179. Under today's loader the `# spl_role_seat:` comment is appended to the last `example=` (so the text differs from row 01's loader, the counts and the longest line do not); 190 and 179 stay under 200, so the tags gate does not need row 01. The row waits only for the shared baseline. Tests: `iac:t/action-header-tags.tst.sh`, `orc:t/parse-metadata-nofork.tst.sh`, `orc:t/asks.tst.sh`, `agent-restart.tst.sh`, `dispatch-rotate.tst.sh`, `orch-rotate.tst.sh`, `peer-restart.tst.sh`, `wd-takeover.tst.sh`, `tests-hermetic.tst.sh`, `desk-dir-follows-desk-user.tst.sh`, `spl-epic-stall-check.tst.sh`, `spl-security-round-queue.tst.sh`, `spl-spawn-fill.tst.sh`, `spl-spawn-group.tst.sh`, `spl-spawn-queue.tst.sh`, `spl-zombie-topics.tst.sh`, `orc:src/bash/features/spawn-agents/tests/test-role-seat-vendor-param.sh`. **Red control:** `do_parse_metadata <f> \| grep -c '^example='` -> 0 on the parent sha, 2 after, per file. | sat | claude | simple_coding | 2 (after 01) |
| 03 `refactor(r46-03-iac-header-declare-below-gcp-sync)` | an action's first command sits below its header | these 5 gcp actions open with `# shellcheck source=` + `declare -F spl_gcp_temp_sdk_config ... \|\| source ...` above the separator, so the loader stops before their header | `iac:run/gcp-s3-download-all.func.sh:2`<br>`iac:run/gcp-sync-local-to-s3.func.sh:2`<br>`iac:run/gcp-sync-s3-to-local.func.sh:2`<br>`iac:run/gcp-sync-src-bucket-data-to-tgt-bucket.func.sh:2`<br>`iac:run/gcp-sync-src-s3-to-tgt-s3.func.sh:2` (+ their 5 `[missing]` lines; the baseline is shared by rows 01-05, which is why each is its own batch) | 5 files | Per file: move the lines between the shebang and the first `#---` (the directive, the `declare` line and a blank after it) unchanged to just below the closing `#---`, above any other line. Nothing else moves: the `declare` still runs before every function definition. Delete the 5 `[missing]` lines. Simulated on copies with row 01's loader: each gets `description=` and 1-2 `example=`, longest line 58-152, no `(required)`. Needs row 01: with today's loader the moved directive is read into the last tag. Tests: `iac:t/action-header-tags.tst.sh`, `orc:t/parse-metadata-nofork.tst.sh`, `iac:t/gcp-actions-isolated-config.tst.sh`, `gcp-exit-status-checks.tst.sh`, `gcp-key-path-no-eval.tst.sh`, `gcp-misc-actions.tst.sh`, `gcp-project-delete.tst.sh`, `gcp-s3-download-all-mkdir.tst.sh`, `gcp-temp-sdk-config.tst.sh`; `do_check_pre_push_lint` (shellcheck still follows the directive). **Red control:** `do_parse_metadata <f> \| grep -c '^description='` and `'^example='` -> 0 on the parent sha, at least 1 after, per file. | sat | claude | simple_coding | 3 (after 02) |
| 04 `refactor(r46-04-iac-header-declare-below-gcp-data)` | as row 03 | the same, 5 gcp secret, dns and data actions | `iac:run/gcp-copy-secret.func.sh:2`<br>`iac:run/gcp-fetch-secrets.func.sh:2`<br>`iac:run/gcp-export-dns.func.sh:2`<br>`iac:run/gcp-import-to-cloudsql.func.sh:2`<br>`iac:run/gcp-backup-env.func.sh:2` (+ their 5 `[missing]` lines) | 5 files | As row 03. Simulated: both tags each, longest line 80-182, no `(required)`. `gcp-import-to-cloudsql` carries 2 `# @arg` lines (`:93`, `:182`) inside functions, below the first command, so never read (`do_parse_metadata <f> arg` -> empty before and after; the lane shows it). Tests: `iac:t/action-header-tags.tst.sh`, `orc:t/parse-metadata-nofork.tst.sh`, `iac:t/adhoc-harvest-gcp-actions.tst.sh`, `gcp-exit-status-checks.tst.sh`, `gcp-misc-actions.tst.sh`, `return-not-exit-gcp.tst.sh`, `gcp-actions-isolated-config.tst.sh`, `gcp-temp-sdk-config.tst.sh`; `do_check_pre_push_lint`. **Red control:** as row 03. | sat | claude | simple_coding | 4 (after 03) |
| 05 `refactor(r46-05-iac-header-declare-below-spl-secret)` | as row 03 | the same, 5 spl secret and kms actions | `iac:run/spl-secret-age-report.func.sh:2`<br>`iac:run/spl-secret-rotate.func.sh:2`<br>`iac:run/spl-secret-scan-alert-triage.func.sh:2`<br>`iac:run/spl-secret-version-disable-old.func.sh:2`<br>`iac:run/spl-kms-check.func.sh:2` (+ their 5 `[missing]` lines) | 5 files | As row 03. Simulated: both tags each, longest line 76-105, no `(required)`. `spl-secret-unused-list` (7 lines above its separator, 3 `declare` commands) sources `spl-secret-age-report` and is **not** a site. Tests: `iac:t/action-header-tags.tst.sh`, `orc:t/parse-metadata-nofork.tst.sh`, `iac:t/spl-secret-age-report.tst.sh`, `spl-secret-rotate.tst.sh`, `spl-secret-scan-alert-triage.tst.sh`, `spl-secret-version-disable-old.tst.sh`, `spl-secret-unused-list.tst.sh`, `spl-kms-check.tst.sh`, `gcp-temp-sdk-config.tst.sh`; `do_check_pre_push_lint`. **Red control:** as row 03. | sat | claude | simple_coding | 5 (after 04) |
| 06 `test(r46-06-api-marketing-plaintext-redaction)` | the secret wrapper's redaction under test, every encoder | `marketing.Plaintext` keeps a token out of logs and payloads; its `GoString` (`%#v`) and `MarshalText` (map keys, text encoders) are 0.0 | `go:internal/marketing/seal.go:61`<br>`go:internal/marketing/seal.go:70`<br>`go:internal/marketing/plaintext_redact_test.go` (new) | 2 functions at 0.0 | With a fake token: `fmt.Sprintf("%#v", p)`, `%#v` of a struct holding it, `p.MarshalText()` and `json.Marshal(map[marketing.Plaintext]int{p: 1})` each hold the redaction text and never the token; `Reveal()` still returns it. A new test file; define no helper whose name another test file of the package defines. Fake tokens only. No floor change (round 19 row 09 holds `go-coverage-floor.txt`). Tests: `go test -count=1 -race -cover ./internal/marketing/`; `bash api:src/bash/tests/run-all-tests.sh` (coverage part `ok`, floors unchanged). **Red control:** `GoString` returning `p.s` -> the new case fails. | sat | claude | tests | 1 |
| 07 `test(r46-07-api-wire-signed-payloads)` | the bytes a box signs, under golden tests | `FleetWorkspacesPayload`, `FleetEnrolPayload` and `JoinKeyPayload`'s x25519 branch build what a box key signs (one changed byte breaks every box's enrol or join), and two small parsers are untested | `go:internal/wire/fleet_enrol.go:22`<br>`go:internal/wire/fleet_enrol.go:29`<br>`go:internal/wire/wire.go:1078`<br>`go:internal/wire/wire.go:153,1019`<br>`go:internal/wire/signed_payloads_test.go` (new) | 5 functions at 0.0 | Each payload builder against the literal bytes its doc comment states (the `jq -cS` shape: sorted keys, its `op`), and `JoinKeyPayload` with `x25519 == ""` equal to `JoinModePayload`; `ValidLeaseReason` for `""`, each of `LeaseReasons` and `"x"`; `InnerMsgID` of a good envelope and of a bad one (`""`). A new test file; helper names prefixed `sp`. Tests: `go test -count=1 -race -cover ./internal/wire/`; `run-all-tests.sh`. **Red control:** drop `"tenant"` from `FleetEnrolPayload`'s map -> its golden case fails. | sat | claude | tests | 1 |
| 08 `test(r46-08-api-hubclient-cli-verbs)` | the one-shot cli verbs under test | `MoveMessage`, both `TopicList` and both `FlowRead` (the `Client` dial and the `Session` frame) are 0.0, and so is `DialStatusError.Unwrap`, which lets `errors.Is` / `errors.As` see the error a refused dial wraps | `go:internal/hubclient/move.go:38`<br>`go:internal/hubclient/topics.go:15,25`<br>`go:internal/hubclient/flow.go:14,24`<br>`go:internal/hubclient/backoff.go:103`<br>`go:internal/hubclient/cli_verbs_test.go` (new) | 6 functions at 0.0 | Through the fake hub an existing test file of the package already builds (reuse it; the lane names which); per verb: the frame type sent, the `msg_id` match and the raw object returned, and a hub error frame -> a `*HubError`. `Unwrap`: a `DialStatusError` wrapping a sentinel -> `errors.Is` true. A new test file; helper names prefixed `cv`. Tests: `go test -count=1 -race -cover ./internal/hubclient/`; `run-all-tests.sh`. **Red control:** `MoveMessage` sending `wire.TTopicList` -> its case fails. | sat | claude | tests | 1 |
| 09 `test(r46-09-api-payments-config-entry-points)` | the payment config's entry points under test, the key-mode log first | `CardKeyMode` is what the boot log prints in place of the card key (`"test"` / `"live"` / `""`, never the key), at 0.0; `Load` (the process-env path) and `NewWired` too | `go:internal/payments/handler.go:99`<br>`go:internal/payments/handler.go:92`<br>`go:internal/payments/config.go:96`<br>`go:internal/payments/config_entry_test.go` (new) | 3 functions at 0.0 | `CardKeyMode` with fake test-shaped, live-shaped, malformed and empty keys -> `"test"`, `"live"`, `""`, `""`, and the result never holds the key; `Load` under `t.Setenv` (no `t.Parallel`) equal to `LoadFrom` with the same map; `NewWired` with a nil store -> the error `New` gives. Fake keys only, no key path. Tests: `go test -count=1 -race -cover ./internal/payments/`; `run-all-tests.sh`. **Red control:** `CardKeyMode` returning `c.StripeSecretKey` -> the new case fails. | sat | claude | tests | 1 |

### 3.1 Lanes and batches

Two tracks, no file in both:

- **Header track (rows 01-05), one row at a time.** Every row edits
  `iac:t/action-header-tags-baseline.txt`, so each is its own batch (R1):
  01, then 02, 03, 04, 05. Rows 03-05 also need row 01's loader; row 02
  does not, but it shares the baseline, so it waits too. Each next row is
  placed within 30 minutes of the previous one landing (R16).
- **Go track (rows 06-09), all in batch 1.** Four packages, one new test
  file each; they change no source file and no floor.

So batch 1 holds rows 01, 06, 07, 08 and 09. Under "keep 2 row lanes in
parallel" (686bc1a3) the dispatch holder places row 01 with one Go row,
then the next Go row as each lands. Once rows 06-09 are on master the
header track runs alone, one lane at a time.

No row touches `csi-spl-cnf/`, a migration, a workflow, terraform code,
`go-coverage-floor.txt` or `internal/action/` (round 19 row 09).

### 3.2 Off every live lane and every queued row (R3)

- **Live lanes:** `lane-map.sh --check <the 3 lib copies, the tags test,
  its baseline, orc:t/parse-metadata-nofork.tst.sh and the 37 declare-first
  files, comma separated> --agent c-889` -> **exit 0, `free`**. The same
  check for each Go source file of rows 06-09 (`seal.go`,
  `meta_publish.go`, `wire.go`, `fleet_enrol.go`, `move.go`, `topics.go`,
  `flow.go`, `backoff.go`, `handler.go`) -> exit 0 each (sat,
  2026-11-01 ~17:35Z, the exit code read from the command itself, never
  through a pipe). **Re-measured at v0.2 (2026-11-01T18:4xZ): exit 4**,
  `unknown:` for 7 live lanes that record no files (g-895 saw g-585, a
  read-only grok language review of SPL-4043 WUI strings; c-889 saw
  c-894, c-934 and c-988 among them, all on the other box). No path is printed as owned,
  but exit 4 is not free: the dispatch holder re-runs the check before each
  row's spawn and asks any `unknown:` lane first. SPL-4555 (c-851, the 11 `spl_desk_dir` callers) owns
  `spl-issue-create` and `spl-topic-copy-cross`: both stay among the 4
  long-example files after row 01, and no row edits them. SPL-4536 (c-823,
  desk paths) and the queued box-crons row (ask 5c4a5a8f) name no file
  here.
- **Spawn queue:** `./run -a do_spl_spawn_queue` -> 30 queued, 0 placing.
  For each queued brief on this box, `grep -oE` for the site basenames,
  `internal/(marketing|wire|hubclient|payments)`, `parse-metadata`,
  `action-header-tags`, `gcp-temp-sdk-config`, `go-coverage-floor` -> 0
  hits in 29 briefs. 1 brief is not on this box
  (ask 75077182, a read-only DNS bug of the other box,
  **unchecked**). The two queued marketing rows
  (`c002-s090-t034-meta-publish-followups`, `c002-bug-marketing-runid-utf8`)
  name neither `seal.go` nor `meta_publish.go`; the keyexec row
  (`c002-bug-keyexec-lease-gostring`) is another package.

## 4. Per row: what the lane does

- **01:** A closing `#---` ends the header, in the 3 loader copies; the
  tags test's red control and baseline follow (31 -> 4).
- **02:** Two separators make the two ask actions' headers readable.
- **03:** Move the declare line below the header in 5 gcp sync actions.
- **04:** The same for 5 gcp secret, dns and data actions.
- **05:** The same for 5 spl secret and kms actions.
- **06:** Tests for `Plaintext`'s `%#v` and text redaction.
- **07:** Golden tests for the fleet and join payloads a box signs, and
  two small parsers.
- **08:** Tests for the cli verbs `MoveMessage`, `TopicList`, `FlowRead`
  and `DialStatusError.Unwrap`.
- **09:** Tests for `CardKeyMode` (key never shown), `Load`, `NewWired`.

## 5. Panel and reviewers (R7)

- Editor: c-889 (claude). Panel reviewer: g-895 (grok, fresh session),
  named by the dispatch lease holder (c-002 msg 8d17d549). Both sign the plan sha (rulebook 3.2).
- Row reviewers: a cross-vendor seat per row (section 1); lines checked
  with `do_spl_review_line_check`. A row with no reviewer for 15 minutes
  reports a blocker (2.7.3).
- **P1, for the panel:** row 01 changes what `./run` shows for 82 action
  files, and nothing it checks (section 2). Is that a refactor row? The
  editor says yes: no tag, `(required)` param or `arg=` mapping moves;
  only swallowed prose leaves the values.
- **P2, for the panel:** the header track is serial (five batches) because
  of one shared baseline. The editor kept it so, rather than let a row
  leave a stale baseline line for a later row: that would turn the tags
  test red on master in between.
- **P3, for the panel:** no round 19 retro yet (row 09 open); allowed
  as in round 19 (rulebook 2.8 R8 and 1.4).

## 6. Left out, measured

| what | why | measured by |
|---|---|---|
| 16 more declare-first iac files that row 01 makes movable as rows 03-05 do: `gcp-alert-snooze`, `gcp-audit-iam`, `gcp-audit-wsdoc-buckets`, `gcp-compute-lb-cleanup`, `gcp-compute-lb-list`, `gcp-delete-service-account`, `gcp-hub-instance-health`, `gcp-hub-restart`, `gcp-purge-wsdoc-prefix`, `gcp-report-sa-usage`, `gcp-sync-src-s3-to-tgt-s3-silent`, `spl-compute-sa-editor-drop`, `spl-gh-app-key-put`, `spl-secret-unused-list`, `spl-vendor-key-grant-check`, `spl-vendor-key-pepper-put` | at most 10 rows a round and 5 sites a row, and the header track is serial; **input for round 21** (4 rows), simulated the same way: both tags, longest line at most 130, no `(required)` | section 2, the simulation on `ffd36e3e5` |
| `gcp-002-delete-project-service-account`, `gcp-export-dns-settings` | the move gives a `description=` but no `example=`: each also needs a real `@example`; **input for round 21** | the same simulation |
| `gcp-project-delete`, `gcp-tail-logs` (declare-first, `(required)` `@param`) and the 7 orc `(required)` files | a readable header turns on `do_validate_params`, which then refuses a call that runs today: a behaviour change with every caller checked, **for the next bug round** | `grep -ciE '^# *@param .*\(required\)'` on the 55 -> 9 |
| the 4 long-example files left after row 01: `provision-firebase-dns` (two examples joined by a `\` continuation), `spl-tenant-member-add` (one long real example), `spl-issue-create`, `spl-topic-copy-cross` | the last two belong to SPL-4555 (c-851); the first two are one-line edits, input for round 21 | section 2, the patched copy |
| floor raises for `internal/marketing`, `wire`, `hubclient`, `payments` (`go-coverage-floor.txt`) after rows 06-09 | rows 06-09 share batch 1, so none may edit the floor file (rulebook 2.1); round 19 row 09 holds it. `payments` sits at its floor (80.9), so a new test there that lowers coverage fails the floor gate | **input for round 21**: one row raises the four lines after r44-09 lands | g-895, `go test -coverprofile` on the four packages, go1.26.10 |
| `internal/keydesk` `logf` 50.0, `cmd/spool` `hub.go`, `store` / `repodocs` / `auth` | section 2 | `go tool cover -func` on `ffd36e3e5` |
| `internal/gcal` `ListCalendars`, `internal/mail` `encodeWord`, `Send`, `Messages`, `EmbedRelink` | api-err series briefs name both areas (`c002-api-err-r7-smtp-ipv4`, `c002-api-err-r8-gcal-invalid-grant`); taken once that series is closed | `ls /var/spool-hub/dispatch/briefs \| grep api-err` |
| clean-code ratchets, WUI raw text, gosec / semgrep, shellcheck WARNING baseline | section 2 | section 2 |

## 7. Counts

| metric | n |
|---|---|
| rows | 9 (refactor 5, test 4; lib 1, orc header 1, iac header 3, Go 4) |
| vendor | claude 9 |
| kind | complex_coding 1, simple_coding 4, tests 4 |
| batches | batch 1: rows 01, 06, 07, 08, 09 (5 at once); batches 2-5: rows 02, 03, 04, 05, one each |
| action files with an `example=` over 200 chars | 31 -> 4 after row 01 |
| action files without a parsed tag | 55 -> 38 after rows 02-05 (if they land as written; each lane re-counts) |
| declare-first files | 37 -> 20 after rows 02-05 |
| measured on | `ffd36e3e5`, n=1 per command unless stated |

## 8. Changes

- v0.1: first draft (c-889): 9 rows, slug `r46`; no round 19 retro (not due).
- v0.2 (c-889, on g-895 FAIL f86472e2 and c-002 1b58fd45): W1 row 01 cap is
  75, not 80, and the separator edit is one line; N2 panel reviewer is
  g-895 (grok); N4 lane-map now exit 4 (`unknown:` lanes); N5 floor raises
  to round 21 (section 6); N6 row 01 names the nofork test as a site; N7
  rows 03-05 say why they are serial; N9 row 02 under today's loader; P1
  the r46 brief grep is 1 (the reviewer brief); P4 r44-07 landed
  `27b31ed58`, only 09 open.

## 9. Consensus

- Editor seat: c-889 (claude): drafts v0.1.
- Grok panel reviewer seat: g-895@sat, placed 2026-11-01T17:56:39Z on
  `24a11b3c6`.
