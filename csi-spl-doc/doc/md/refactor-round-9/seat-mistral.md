# Mistral seat review for refactor-round-9-plan.md

**Plan sha:** `afbd48aaa` (2026-10-14T08:09:42Z)

## Objections

1. **Row 03 (`refactor(r9-03-wui-small-stores-topic-viewer)`): Incorrect line counts in plan.**
   - **Plan claim:** `src/stores/topic.ts <anon>` is 117 lines, `src/stores/viewer.ts <anon>` is 173 lines.
   - **Measured (afbd48aaa):** `topic.ts` is 153 lines, `viewer.ts` is 183 lines.
   - **Measured (origin/master):** Same as afbd48aaa; **no LONG entries** for either file in `cleancode.test.mjs`.
   - **Command:** `find src/stores -name "*.ts" -exec wc -l {} \;` in `csi-spl-wui`.
   - **Objection:** The plan's line counts are incorrect. Neither file is listed as LONG in `cleancode.test.mjs`.
   - **Suggested replacement:**
     ```text
     | 03 `refactor(r9-03-wui-small-stores-topic-viewer)` | small functions | Two store anonymous setup bodies exceed MAX_LINES | `wui:src/stores/topic.ts:25`<br>`wui:src/stores/viewer.ts:28`<br>`wui:tests/unit/cleancode.test.mjs:40,41` | 2 entries (153 and 183 lines) | Decompose inner actions into named module-level step functions under 80 lines; preserve store interface and reactivity. Delete both lines from `cleancode.test.mjs` LONG map (10 -> 8 listed). **Red control:** dummy 81-line function in `topic.ts` fails `cleancode.test.mjs`. `topic-kind.test.mjs`, typecheck | PC | simple_coding | 1 |
     ```

2. **Row 05 (`test(r9-05-bash-stripe-measure-fix)`): Incorrect line counts in plan.**
   - **Plan claim:** `_spl_stripe_json_get` is 130 lines, `do_spl_provision_stripe_endpoints` is 119 lines.
   - **Measured (afbd48aaa):** `_spl_stripe_json_get` is 13 lines, `do_spl_provision_stripe_endpoints` is 118 lines.
   - **Measured (origin/master):** Same as afbd48aaa.
   - **Command:** Manual inspection of `spl-provision-stripe-endpoints.func.sh` (lines 59-71 and 71-190).
   - **Objection:** The plan's line counts are incorrect. The awk parser defect is confirmed (closing brace is inline with Python), but the function is 13 lines, not 130.
   - **Suggested replacement:**
     ```text
     | 05 `test(r9-05-bash-stripe-measure-fix)` | a gate measures what it claims | Awk parser misses closing brace in python one-liner, hides 118-line function | `orc:src/bash/run/spl-provision-stripe-endpoints.func.sh:69,71`<br>`iac:src/bash/tests/bash-cleancode.tst.sh:34` | 1 fake LONG (13) + 1 hidden function (118) | Put `}` on column 1 for `_spl_stripe_json_get` (11 lines); decompose `do_spl_provision_stripe_endpoints` into named steps under 80 lines; delete `_spl_stripe_json_get 130` from `LONG`. **Red control:** awk fixture verifying function after inline python brace is measured. `bash-cleancode.tst.sh`, `curl-time-bounded.tst.sh` | sat | complex_coding | 1 |
     ```

3. **Row 01 (`test(r9-01-go-coverage-spool-cli-fs)`): Tooling unavailable for verification.**
   - **Plan claim:** 4 subcommands at 0.0% coverage (`archive.go`, `move.go`, `react.go`, `edit.go`).
   - **Measured:** `go` not found in PATH. Cannot verify coverage claims.
   - **Command:** `go test -coverprofile=/tmp/cov.out ./cmd/spool/ && go tool cover -func=/tmp/cov.out | awk '$3=="0.0%"'`.
   - **Objection:** Tooling unavailable in this environment. Cannot confirm or refute the plan's claim.
   - **Suggested replacement:** None. This objection is informational.

## Signature

**No further objections.**

`signed: mistral seat on afbd48aaa`