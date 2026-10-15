# Round 11 seat: mistral

Measured on `eb1d01ae1` (`origin/master`, 2026-10-15 03:19Z).

| row | practice | command | output | verdict |
|---|---|---|---|---|
| 01 | Last 3 CLOUDSDK files | `git grep -l 'local _spl_sdk_saved="${CLOUDSDK_CONFIG-}"' eb1d01ae1 -- csi-spl-iac | wc -l` | 3 | Agree |
| 02 | Isolated-config scan blind to helper form | `git grep -l '^\s*spl_gcp_temp_sdk_config || return 1' -- csi-spl-iac/src/bash/run csi-spl-iac/lib/bash/funcs | xargs -I{} bash -c 'file={}; count=$(grep -cE "gcloud auth (activate-service-account|login)" "$file"); echo "$count $file"' | awk '$1 == 0' | wc -l` | 12 | Agree |
| 03 | No `/opt/` path in `source` lines | `git grep -nE '^\s*(source|\.) +\"?/opt/' eb1d01ae1 -- 'csi-spl-iac/src/bash/run/' 'csi-spl-orc/src/bash/run/' 'csi-spl-iac/lib/' 'csi-spl-orc/lib/' | wc -l` | 0 | Agree |
| 04 | Push-master review line checkable | `grep -n 'PASS' csi-spl-orc/src/bash/run/spl-push-master.func.sh` | Line 137: `grep -qE '^review: \S+@\S+ \S+ PASS [0-9a-f]{7,40} '` | Agree |
| 05 | Pre-push hook review line | `git grep -n -i review eb1d01ae1 -- csi-spl-orc/src/bash/features/spawn-agents/hooks/pre-push | wc -l` | 0 | Agree |
| 06 | Review-line log check | `ls csi-spl-orc/src/bash/run | grep -c review-line` | 0 | Agree |
| 07 | WUI `live.ts` LONG | `sed -n '/^const LONG/,/^\]/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/stores/live.ts setup', 304]` | Agree |
| 08 | WUI `notification.ts` LONG | `sed -n '/^const LONG/,/^\]/p' csi-spl-wui/tests/unit/cleancode.test.mjs` | `['src/stores/notification.ts <anon>', 430]` | Agree |
| 09 | Bash `do_tf_init` LONG | `bash csi-spl-iac/src/bash/tests/bash-cleancode.tst.sh | grep -A1 'do_tf_init'` | 93 (current), 95 (ceiling) | Agree |
| 10 | Go coverage `repoEdit` | `cd csi-spl-api/src/go/spool-hub-api && go test -count=1 -coverprofile=cov.out ./cmd/spool/ && go tool cover -func=cov.out | awk '$1 ~ /hub_repo_edit.go/ && $3 == "0.0%"'` | `repoEdit` and `nonEmpty` at 0.0% | Agree |

## R1 Check
No path appears in two rows of the same batch.

## Summary
10 of 10 rows: **Agree**. No changes needed.