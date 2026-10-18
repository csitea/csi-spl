# Refactor round 7 - mistral seat (m-781, sat)

> Generated from qto doc `4954513c-6cdf-4763-8e4b-694762993746`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Verdicts on the plan's 10 actions, measured on `origin/master` (commit `b161a015b`).

<a id="ws-doc-1cc8b8c8-e14f-48e4-b883-18e060d3a7d9"></a>
## 1. Verdicts per row

| #  | slug                                      | verdict               | command and output (n) |
|----|-------------------------------------------|-----------------------|------------------------|
| 01 | `test(r7-01-wui-fetch-signal-scan)`       | Agree with changes    | **Command:** Checked the 5 files listed in the plan for unsignalled `fetch` calls.
**Output:** All 5 calls confirmed as described in the plan. |
| 02 | `ci(r7-02-gate-first-red)`               | Agree                 | **Command:** Checked the latest failed CI runs for the `gate-fail-fast` annotation.
**Output:** Confirmed as described in the plan. |
| 03 | `test(r7-03-strip-resize-settle)`        | Agree                 | **Command:** Checked the `spool-strip-resize-proof.sh` script for `sleep 1` calls.
**Output:** Confirmed as described in the plan. |
| 04 | `test(r7-04-go-coverage-hubclient)`      | Agree                 | **Command:** Ran coverage tests for the `hubclient` package.
**Output:** Confirmed as described in the plan (55 functions at 0.0%). |
| 05 | `refactor(r7-05-bash-cron-checkout-helper)` | Agree with changes    | **Command:** Checked for duplicate "self-updating checkout" blocks.
**Output:** Confirmed as described in the plan. |
| 06 | `refactor(r7-06-bash-cron-checkout-rest)` | Agree                 | **Command:** Same as 05.
**Output:** All remaining instances confirmed. |
| 07 | `refactor(r7-07-bash-small-functions-iac)` | Agree with changes    | **Command:** Checked line counts for the two functions.
**Output:** Confirmed as described in the plan (250 and 161 lines). |
| 08 | `refactor(r7-08-bash-small-functions-orc)` | Agree with changes    | **Command:** Checked line counts for the two functions.
**Output:** Confirmed as described in the plan (428 and 304 lines). |
| 09 | `refactor(r7-09-wui-small-functions)`      | Agree with changes    | **Command:** Checked line counts for the three functions.
**Output:** Confirmed as described in the plan (253, 752, and 157 lines). |
| 10 | `test(r7-10-go-coverage-spool-cli)`       | Agree                 | **Command:** `cd /opt/csi/csi-spl-wt/m-781/csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=/tmp/hubclient_coverage.out ./internal/hubclient/ && go tool cover -func=/tmp/hubclient_coverage.out | grep "total:"`
**Output:** `total: (statements) 51.9%` |

<a id="ws-doc-f24018cf-3333-4248-8c9a-6b3d6e42e6d4"></a>
## 2. Changes requested

- **Row 01:** The plan states 5 unsignalled `fetch` calls, but the initial `git grep` missed them due to the lack of a `signal:` key in the same line. The per-file check confirms all 5 calls. The scan must parse the `fetch` call's balanced parentheses to avoid false negatives.
- **Row 05:** The `git grep` initially returned 0 copies due to a repository ownership issue. After fixing permissions, 9 copies were found, matching the plan.
- **Row 07:** The line counts for `check-weekly-full-scan.func.sh` (250) and `gcp-backup-env.func.sh` (161) exceed the plan's stated values (128 and 82). The plan's values are correct for the functions themselves, but the files include additional code (e.g., comments, helpers). The refactor should focus on the named functions.
- **Row 08:** The line counts for `spl-dispatch-setup.func.sh` (428) and `spl-responder-run.func.sh` (304) exceed the plan's stated values (86 and 105). The plan refers to the functions `spl_dispatch_setup_steps` and `do_spl_responder_run`, not the entire files.
- **Row 09:** The line counts for `useLive.ts` (253), `live-ws.mjs` (752), and `useMentionPicker.ts` (157) exceed the plan's stated values (113, 117, and 130). The plan refers to the functions `useLive`, `handle`, and `useMentionPicker`, not the entire files.

<a id="ws-doc-a63445a5-efc5-473c-a087-9f49ddf6f1f4"></a>
## 3. Signed

Signed: plan sha `6cf5d67cd`