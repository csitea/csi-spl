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
| `src/bash/tests/` | `bash src/bash/tests/run-all-tests.sh` |
| `cnf/tpl-gen.ref` | the tpl-gen commit the renders are made with |
