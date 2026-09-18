# csi-spl-iac

`./run` actions and terraform for the spool. See
`../csi-spl-doc/doc/md/csi-spl.feature.md` sections 5–7.

| path | what |
|---|---|
| `src/bash/run/gcp-001-create-project.func.sh` | create `csi-spl-<env>` + link billing (dry run by default) |
| `src/bash/run/tpl-gen.func.sh` | render `csi-spl-cnf/csi-spl/<env>/tf/*.tfvars` |
| `src/bash/run/tf-plan.func.sh` | `terraform init/validate/plan` of one step, never apply |
| `src/terraform/000-gcp-remote-bucket` | the tf state bucket (local state) |
| `src/terraform/001-enable-gcp-services` | storage + iam APIs |
| `src/terraform/020-gcp-relay-bucket` | the git-rel relay bucket + sender SA |
| `src/terraform/030-cloud-run-hub` | the spool hub on Cloud Run (HTTPS + WS, min/max instances 1) + its runtime SA |
| `src/terraform/040-cloud-sql-postgres` | the hub's Cloud SQL Postgres + database + the empty DSN secret slot |
| `src/terraform/050-gcs-files` | the hub's `file_id` bucket (private, uniform, PAP enforced) |
| `src/bash/tests/` | `bash src/bash/tests/run-all-tests.sh` |
| `cnf/tpl-gen.ref` | the tpl-gen commit the renders are made with |

The hub steps are planned like the others (`TF_BACKEND=local TF_OFFLINE_PLAN=1`
until the state exists) and apply in the order 050, 040, 030 with the owner's
go. No step creates a password, a secret version or a key: the hub's DB user
and DSN are made out of band (see `040-cloud-sql-postgres/03-cloud-sql.tf`).
The hub's env-var names are published in `csi-spl-cnf/csi-spl/all.env.yaml`
under `env.hub.env`.
