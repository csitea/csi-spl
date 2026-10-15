# Round 11 Mistral Seat Verdict

> Generated from qto doc `9ee5cd92-8d07-438f-b326-7e7793e8effe`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Measured on `eb1d01ae1` (`origin/master`, 2026-10-15 03:19Z).

| Row | Practice | Verdict | Command | Output |
|-----|-----------|-----------|---------|---------|
| 01 | `refactor(r11-01-bash-temp-sdk-config-last-three)` | Agree | `git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' eb1d01ae1 -- csi-spl-iac | wc -l` | 3 |
| 02 | `test(r11-02-isolated-config-scan-helper-callers)` | Agree | `git grep -l '^\s*spl_gcp_temp_sdk_config \|\| return 1' -- 'csi-spl-iac/src/bash/run' 'csi-spl-iac/lib/bash/funcs' | xargs -I {} grep -lE 'gcloud auth (activate|login)' {} | wc -l` | 20 |
| 03 | `test(r11-03-no-box-path-source)` | Agree | `git grep -nE '^\s*(source\|\.) +"?/opt/' -- 'csi-spl-iac/src/bash/run/' 'csi-spl-orc/src/bash/run/' 'csi-spl-iac/lib/' 'csi-spl-orc/lib/' | wc -l`; `git grep -l '/opt/csi' -- 'csi-spl-iac/src/bash/tests/*' | grep -c no-box` | 0 (sites), 0 (tests) |
| 04 | `ci(r11-04-push-master-review-line-checkable)` | Agree | `grep -n 'PASS \[0-9a-f]\{7,40\}' csi-spl-orc/src/bash/run/spl-push-master.func.sh`; `grep -nF '| log:' csi-spl-orc/src/bash/run/spl-push-master.func.sh` | Line 137; no output |
| 05 | `ci(r11-05-pre-push-hook-review-line)` | Agree | `git grep -n -i review -- csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push | wc -l` | 0 |
| 06 | `ci(r11-06-review-line-log-check)` | Agree | `ls csi-spl-orc/src/bash/run | grep -c review-line` | 0 |
| 07 | `refactor(r11-07-wui-small-store-live)` | Agree | `sed -n '/^const LONG/,/^\])/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/stores/live.ts setup', 304]` |
| 08 | `refactor(r11-08-wui-small-store-notification)` | Agree | `sed -n '/^const LONG/,/^\])/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/stores/notification.ts <anon>', 430]` |
| 09 | `refactor(r11-09-bash-small-tf-init)` | Agree | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh | grep -E 'LONG|do_tf_init'` | `do_tf_init` is 93 lines |
| 10 | `test(r11-10-go-coverage-repo-edit)` | Agree | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out | awk '$3=="0.0%"'` | `repoEdit` and `nonEmpty` at 0.0% |

<a id="ws-doc-e1d17d13-84e0-4441-b442-05a58e7ac2c3"></a>
## Notes
- **Row 02:** The plan's counts (11 scanned, 23 total callers) are outdated. The current count is 20 scanned files.
- **Row 04:** The gate does not require `| log:` in the review line (no `| log:` in the file).
- **R1 Check:** No path appears in two rows of the same batch.

Signed: m-159 on 7dc9ed7e37c26624de9fc71f6b2d119dcf65166d