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

0 is expected on trunk (18a12d4). After the unpushed isolate wrap (awaiting
ORC), every gcloud-calling file is non-zero by 5 `diff` lines (the wrap).
Four API-enable/disable files are **9** (wrap + `--account` on `gcloud --version`).
`gcp-list-secrets` stays **0** (echo only, not wrapped).

### 1.1 Unpushed isolate wrap (hold: do not push until ORC)

CLE-3361: the copy-unchanged port still writes the shared `~/.config/gcloud`.
A first wrap (`trap … RETURN` that `rm -rf "$CLOUDSDK_CONFIG"`) is **not**
safe: a RETURN trap is not function-scoped; it fires again when the caller
returns and can delete the operator's own throwaway config (measured: planted
`credentials.db` gone). Do **not** push that shape (`b65e44b`).

Safer wrap, local, not on trunk — keep the function (not a subshell: several
actions `export` results the caller needs, e.g. `GOOGLE_APPLICATION_CREDENTIALS`,
secret env vars, `SRC_DIR` / `GCS_BUCKET`):

```bash
  local _spl_sdk_saved="${CLOUDSDK_CONFIG-}" _spl_sdk_dir
  _spl_sdk_dir="$(mktemp -d)"
  export CLOUDSDK_CONFIG="$_spl_sdk_dir"
  trap 'rm -rf "$_spl_sdk_dir"; if [[ -n "$_spl_sdk_saved" ]]; then export CLOUDSDK_CONFIG="$_spl_sdk_saved"; else unset CLOUDSDK_CONFIG; fi; trap - RETURN' RETURN
```

Repro of the fix: caller dir still exists after orch returns; `trap -p RETURN`
is empty. `gcp-list-secrets` only `echo`s gcloud and is not wrapped. Nobody
should run these actions until ORC decides.

`bash -n` on every ported file: ok. `cd csi-spl-iac && ./run -a do_print_help`
lists all 29 ported `do_gcp_*` actions (and still lists gcp-000..004).

Module tests: `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` →
`=== 19/19 test files passed` after the rebase that carried this table's
code.

## 2. The 52 files

| # | file | status | writes shared gcloud config | reason / rename-diff |
|---|---|---|---|---|
| 1 | gcp-000-bootstrap-gcp-env | in csi-spl already | n/a (other lane) | bootstrap; owned by the hub-cloud-deploy lane; not touched |
| 2 | gcp-001-create-project | in csi-spl already | n/a (other lane) | bootstrap; not touched |
| 3 | gcp-002-create-project-service-account | in csi-spl already | n/a (other lane) | bootstrap; not touched |
| 4 | gcp-002-delete-project-service-account | **ported** | **no** (isolated) | generic SA delete. diff → **5** (wrap). Destructive, never run without the owner's per-call go |
| 5 | gcp-003-configure-proj-sa-permissions | in csi-spl already | n/a (other lane) | bootstrap; not touched |
| 6 | gcp-004-project-apis-enable | in csi-spl already | n/a (other lane) | bootstrap APIs only; not touched. Distinct from #37 |
| 7 | gcp-add-iap-iam-policy-binding | not ported | n/a | csi-spl has no IAP |
| 8 | gcp-build-and-push-api-image | not ported | n/a | rel api image + step 030-gcp-cloud-run; csi-spl builds/deploys the hub with `csi-spl-orc do_build_push_hub_image` / `20_hub-build-deploy.yml` and step `030-cloud-run-hub` |
| 9 | gcp-check-iap-brand-org-internal | not ported | n/a | csi-spl has no IAP |
| 10 | gcp-compute-lb-cleanup | **ported** | **no** (isolated) | generic LB cleanup. diff → **5**. Destructive, never run without the owner's per-call go |
| 11 | gcp-compute-lb-list | **ported** | **no** (isolated) | generic LB list. diff → **5** |
| 12 | gcp-create-org-admin-user | not ported | n/a | org/project-level identity mutation superseded by gcp-000..004 |
| 13 | gcp-delete-cloud-run | not ported | n/a | same as #8: hub is `030-cloud-run-hub`, not the rel api Cloud Run action |
| 14 | gcp-delete-service-account | **ported** | **no** (isolated) | generic SA delete by email. diff → **5**. Destructive, never run without the owner's per-call go |
| 15 | gcp-deploy-api-full | not ported | n/a | same as #8 |
| 16 | gcp-deploy-cloud-function | not ported | n/a | no cloud functions in csi-spl |
| 17 | gcp-deploy-cloud-run | not ported | n/a | same as #8 |
| 18 | gcp-export-dns | **ported** | **no** (isolated) | generic DNS export. diff → **5** |
| 19 | gcp-export-dns-settings | **ported** | **no** (isolated) | generic DNS settings dump. diff → **5** |
| 20 | gcp-fetch-secrets | **ported** | **no** (isolated) | Secret Manager fetch. diff → **5** |
| 21 | gcp-import-to-cloudsql | **ported** | **no** (isolated) | Cloud SQL import. diff → **5** |
| 22 | gcp-list-buckets | **ported** | **no** (isolated) | generic bucket list. diff → **5** |
| 23 | gcp-list-cloudsql | **ported** | **no** (isolated) | generic Cloud SQL list. diff → **5** |
| 24 | gcp-list-firewall-rules | **ported** | **no** (isolated) | generic firewall list. diff → **5** |
| 25 | gcp-list-scheduler-jobs | **ported** | **no** (isolated) | generic scheduler list. diff → **5** |
| 26 | gcp-list-secrets | **ported** | **yes** (CLE-3400) | generic Secret Manager list, names and metadata only, as the per-env SA. diff → **0** (csi-rel adc94650). Was echo only before CLE-3400 |
| 27 | gcp-list-service-accounts | **ported** | **no** (isolated) | generic SA list. diff → **5** |
| 28 | gcp-list-static-dns-addresses | **ported** | **no** (isolated) | generic static address list. diff → **5** |
| 29 | gcp-list-vpcs | **ported** | **no** (isolated) | generic VPC list. diff → **5** |
| 30 | gcp-modify-project-apis-disable | **ported** | **no** (isolated) | generic API disable. diff → **9** (wrap + `--account` on `gcloud --version`). Destructive, never run without the owner's per-call go |
| 31 | gcp-modify-project-apis-enable | **ported** | **no** (isolated) | generic API enable. diff → **9** |
| 32 | gcp-modify-project-assign-owner | not ported | n/a | org/project-level identity mutation superseded by gcp-000..004 |
| 33 | gcp-modify-project | not ported | n/a | org/project-level mutation superseded by gcp-000..004 |
| 34 | gcp-modify-project-service-account-for-all-env | not ported | n/a | superseded by gcp-000..004 |
| 35 | gcp-modify-project-service-account | not ported | n/a | superseded by gcp-000..004 |
| 36 | gcp-project-apis-disable | **ported** | **no** (isolated) | generic API disable (all listed services). diff → **9**. Destructive, never run without the owner's per-call go |
| 37 | gcp-project-apis-enable | **ported** | **no** (isolated) | generic API enable (broader than bootstrap gcp-004). diff → **9** |
| 38 | gcp-project-delete | **ported** | **no** (isolated) | generic project delete. diff → **5**. Destructive, never run without the owner's per-call go (realm rule: never delete a project) |
| 39 | gcp-remove-files-from-gs-found-in-web-host | not ported | n/a | rel web host |
| 40 | gcp-remove-iap-iam-policy-binding | not ported | n/a | csi-spl has no IAP |
| 41 | gcp-run-cloud-build | not ported | n/a | hardcoded paths |
| 42 | gcp-s3-download-all | **ported** | **no** (isolated) | GCS download. diff → **5** |
| 43 | gcp-sm-secrets-to-env-file | **ported** | **no** (isolated) | Secret Manager → env file. diff → **5** |
| 44 | gcp-sync-local-to-s3 | **ported** | **no** (isolated) | local → GCS. diff → **5** |
| 45 | gcp-sync-s3-to-local | **ported** | **no** (isolated) | GCS → local. diff → **5** |
| 46 | gcp-sync-secrets | not ported | n/a | rel Google-Sheet secret source; csi-spl has none |
| 47 | gcp-sync-src-bucket-data-to-tgt-bucket | **ported** | **no** (isolated) | bucket → bucket. diff → **5** |
| 48 | gcp-sync-src-s3-to-tgt-s3 | **ported** | **no** (isolated) | GCS → GCS. diff → **5** |
| 49 | gcp-sync-src-s3-to-tgt-s3-silent | **ported** | **no** (isolated) | GCS → GCS silent. diff → **5** |
| 50 | gcp-tail-logs | **ported** | **no** (isolated) | Cloud Logging tail. diff → **5** |
| 51 | gcp-update-secrets | not ported | n/a | rel Google-Sheet secret source; csi-spl has none |
| 52 | gcp-user-stats | not ported | n/a | rel auth/payment log queries |

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

<!-- version: 1.0.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:24:52Z -->
