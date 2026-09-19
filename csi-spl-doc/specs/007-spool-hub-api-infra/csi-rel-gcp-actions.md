# csi-rel `gcp-*` shell actions: what csi-spl ported

Lane IAC-GCP-ACTIONS (a sub-lane of IAC-FLOW-PORT). Owner rule: the
`gcp-*` actions in the rel iac tree are battle-tested, so they are copied
UNCHANGED, adapting only org/app naming (`csi-rel` → `csi-spl`, and `rel` →
`spl` where it is a name). Never change logic.

Source: `/opt/csi/csi-rel/csi-rel-iac/src/bash/run/gcp-*.func.sh` (52 files).
Target: `csi-spl-iac/src/bash/run/` (same file names). Classification was
given by the parent lane and is not re-decided here, except the ORC
amendment (08:39Z): destructive actions ARE ported but never run without
the owner's explicit per-call go. `gcp-project-delete` moved from not-ported
to ported under that rule.

None of the ported actions were executed against GCP. Another lane adds
`--account` pinning; this lane does not add it.

## 1. How the rename was measured

For each ported file:

```bash
diff <(sed 's/csi-rel/csi-spl/g' <src>) <dst> | wc -l
```

0 is expected. 25 of 29 ported files measured 0 (n=1, 2026-09-19). Four
API-enable/disable files are non-zero by 4 `diff` lines each: `$(gcloud --version)`
became `$(gcloud --version --account="${account}")` so the pin-scan that
landed on trunk (`gcloud-account-pinned.tst.sh`, 8ffb93c) stays green.
`account` is already resolved in those files. No other logic changed. The
gcloud-account-pin lane still owns pinning the rest of these actions.

`bash -n` on every ported file: ok. `cd csi-spl-iac && ./run -a do_print_help`
lists all 29 ported `do_gcp_*` actions (and still lists gcp-000..004).

Module tests: `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` →
`=== 19/19 test files passed` after the rebase that carried this table's
code.

## 2. The 52 files

| # | file | status | reason / rename-diff |
|---|---|---|---|
| 1 | gcp-000-bootstrap-gcp-env | in csi-spl already | bootstrap; owned by the hub-cloud-deploy lane; not touched |
| 2 | gcp-001-create-project | in csi-spl already | bootstrap; not touched |
| 3 | gcp-002-create-project-service-account | in csi-spl already | bootstrap; not touched |
| 4 | gcp-002-delete-project-service-account | **ported** | generic SA delete. `diff … \| wc -l` → **0**. Destructive, never run without the owner's per-call go |
| 5 | gcp-003-configure-proj-sa-permissions | in csi-spl already | bootstrap; not touched |
| 6 | gcp-004-project-apis-enable | in csi-spl already | bootstrap APIs only; not touched. Distinct from #37 |
| 7 | gcp-add-iap-iam-policy-binding | not ported | csi-spl has no IAP |
| 8 | gcp-build-and-push-api-image | not ported | rel api image + step 030-gcp-cloud-run; csi-spl builds/deploys the hub with `csi-spl-orc do_build_push_hub_image` / `20_hub-build-deploy.yml` and step `030-cloud-run-hub` |
| 9 | gcp-check-iap-brand-org-internal | not ported | csi-spl has no IAP |
| 10 | gcp-compute-lb-cleanup | **ported** | generic LB cleanup. diff → **0**. Destructive, never run without the owner's per-call go |
| 11 | gcp-compute-lb-list | **ported** | generic LB list. diff → **0** |
| 12 | gcp-create-org-admin-user | not ported | org/project-level identity mutation superseded by gcp-000..004 |
| 13 | gcp-delete-cloud-run | not ported | same as #8: hub is `030-cloud-run-hub`, not the rel api Cloud Run action |
| 14 | gcp-delete-service-account | **ported** | generic SA delete by email. diff → **0**. Destructive, never run without the owner's per-call go |
| 15 | gcp-deploy-api-full | not ported | same as #8 |
| 16 | gcp-deploy-cloud-function | not ported | no cloud functions in csi-spl |
| 17 | gcp-deploy-cloud-run | not ported | same as #8 |
| 18 | gcp-export-dns | **ported** | generic DNS export. diff → **0** |
| 19 | gcp-export-dns-settings | **ported** | generic DNS settings dump. diff → **0** |
| 20 | gcp-fetch-secrets | **ported** | Secret Manager fetch. diff → **0** |
| 21 | gcp-import-to-cloudsql | **ported** | Cloud SQL import. diff → **0** |
| 22 | gcp-list-buckets | **ported** | generic bucket list. diff → **0** |
| 23 | gcp-list-cloudsql | **ported** | generic Cloud SQL list. diff → **0** |
| 24 | gcp-list-firewall-rules | **ported** | generic firewall list. diff → **0** |
| 25 | gcp-list-scheduler-jobs | **ported** | generic scheduler list. diff → **0** |
| 26 | gcp-list-secrets | **ported** | generic Secret Manager list. diff → **0** |
| 27 | gcp-list-service-accounts | **ported** | generic SA list. diff → **0** |
| 28 | gcp-list-static-dns-addresses | **ported** | generic static address list. diff → **0** |
| 29 | gcp-list-vpcs | **ported** | generic VPC list. diff → **0** |
| 30 | gcp-modify-project-apis-disable | **ported** | generic API disable. diff → **4** (`gcloud --version` gained `--account="${account}"` for the pin-scan). Destructive, never run without the owner's per-call go |
| 31 | gcp-modify-project-apis-enable | **ported** | generic API enable. diff → **4** (`gcloud --version` gained `--account="${account}"` for the pin-scan) |
| 32 | gcp-modify-project-assign-owner | not ported | org/project-level identity mutation superseded by gcp-000..004 |
| 33 | gcp-modify-project | not ported | org/project-level mutation superseded by gcp-000..004 |
| 34 | gcp-modify-project-service-account-for-all-env | not ported | superseded by gcp-000..004 |
| 35 | gcp-modify-project-service-account | not ported | superseded by gcp-000..004 |
| 36 | gcp-project-apis-disable | **ported** | generic API disable (all listed services). diff → **4** (`gcloud --version` gained `--account="${account}"` for the pin-scan). Destructive, never run without the owner's per-call go |
| 37 | gcp-project-apis-enable | **ported** | generic API enable (broader than bootstrap gcp-004). diff → **4** (`gcloud --version` gained `--account="${account}"` for the pin-scan) |
| 38 | gcp-project-delete | **ported** | generic project delete. diff → **0**. Destructive, never run without the owner's per-call go (realm rule: never delete a project) |
| 39 | gcp-remove-files-from-gs-found-in-web-host | not ported | rel web host |
| 40 | gcp-remove-iap-iam-policy-binding | not ported | csi-spl has no IAP |
| 41 | gcp-run-cloud-build | not ported | hardcoded paths |
| 42 | gcp-s3-download-all | **ported** | GCS download. diff → **0** |
| 43 | gcp-sm-secrets-to-env-file | **ported** | Secret Manager → env file. diff → **0** |
| 44 | gcp-sync-local-to-s3 | **ported** | local → GCS. diff → **0** |
| 45 | gcp-sync-s3-to-local | **ported** | GCS → local. diff → **0** |
| 46 | gcp-sync-secrets | not ported | rel Google-Sheet secret source; csi-spl has none |
| 47 | gcp-sync-src-bucket-data-to-tgt-bucket | **ported** | bucket → bucket. diff → **0** |
| 48 | gcp-sync-src-s3-to-tgt-s3 | **ported** | GCS → GCS. diff → **0** |
| 49 | gcp-sync-src-s3-to-tgt-s3-silent | **ported** | GCS → GCS silent. diff → **0** |
| 50 | gcp-tail-logs | **ported** | Cloud Logging tail. diff → **0** |
| 51 | gcp-update-secrets | not ported | rel Google-Sheet secret source; csi-spl has none |
| 52 | gcp-user-stats | not ported | rel auth/payment log queries |

Counts: 5 already in, 29 ported, 18 not ported. 5+29+18 = 52.

## 3. Helpers the ported files call

Checked with `command grep -rn "^do_x()\|^do_x ()" csi-spl-iac` for each
`do_*` the ported files invoke.

| helper | where the rel tree defines it | what this lane did |
|---|---|---|
| `do_log` | run.sh / `lib/bash/funcs/log.func.sh` | already in csi-spl-iac run.sh; not overwritten |
| `do_require_var` | `lib/bash/funcs/require-var.func.sh` | already present; not overwritten |
| `do_resolve_oap` | `lib/bash/funcs/resolve-oap.func.sh` | already present (worktree-aware); not overwritten |
| `quit_on` | run.sh | already in csi-spl-iac run.sh |
| `do_require_run_vars` | rel `src/bash/run/run.sh` | **copied** as `csi-spl-iac/lib/bash/funcs/require-run-vars.func.sh`. The function body is unchanged. Not copied by replacing run.sh (this module already has one). Used by `gcp-export-dns-settings` and `gcp-sync-src-bucket-data-to-tgt-bucket` |
| `do_gcp_account` / `do_gcp_log_identity` | rel `lib/bash/funcs/gcp-account-pin.func.sh` | **not copied**. The gcloud-account-pin lane already has an untracked, rewritten `gcp-account-pin.func.sh` (conf-based fallback, not the rel file). This lane must not overwrite it. Ported files still *call* the two functions (logic unchanged); that lane lands the helper and later pins gcp-000..004 |
| `do_resolve_oa` | **undefined even in the rel tree** | called only by `gcp-list-vpcs` (`ORG=$(do_resolve_oa ORG)`). No helper file to copy. Left unchanged. Runtime of that one action needs ORG/APP set, or a later helper |

## 4. Hygiene

```bash
command grep -nE 'csi-rel|relish|orangecamps|flok|@[a-z]+\.(com|net|fi)|[0-9]{12}' <ported files>
```

One hit, justified:

| file | line | hit | why it stays |
|---|---|---|---|
| gcp-002-delete-project-service-account.func.sh | 24 | `your-email@domain.com` | generic placeholder in a `:?` error string, not a real mailbox. Copy-unchanged |

No `csi-rel` remains after the rename. No 12-digit org/account ids. ORG/APP/ENV
come from the environment.

## 5. Must-not-touch (honoured)

- gcp-000..004 (hub-cloud-deploy lane)
- `csi-spl-iac` tf-*/provision/divest + README (parent IAC-FLOW-PORT)
- anything in `csi-spl-orc`
- `csi-spl-cnf`
- `.github/workflows`
- `--account` pinning of gcp-000..004 / the pin helper (gcloud-account-pin lane)
