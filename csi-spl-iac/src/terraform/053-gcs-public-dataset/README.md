# 053-gcs-public-dataset

The public dataset's two buckets and three service accounts
([spec 091](../../../../csi-spl-doc/specs/091-public-dataset-export/spec.md)
section 6). Every name comes from cnf
`env.steps."053-gcs-public-dataset"` (`csi-spl-cnf/csi-spl/all.env.yaml`,
`<env>.env.yaml`), rendered into `csi-spl-cnf/csi-spl/<env>/tf/053-gcs-public-dataset.vars.tfvars`
by `do_tpl_gen`.

## 1. What the step makes

| file | resources |
|---|---|
| `03-public-bucket.tf` | the PUBLIC bucket: uniform access, `allUsers` object viewer (the one public grant), lifecycle on `daily/` and `stable/` |
| `04-staging-bucket.tf` | the PRIVATE staging bucket: public access prevention enforced, deleted at the first whole day past `candidate_ttl_hours` |
| `05-service-accounts.tf` | the export, publish and verifier SAs and their grants (below); no key: keys are minted out of band |

## 2. Who may do what

| SA | staging | public |
|---|---|---|
| export | `objectCreator` (and Cloud SQL client on the project) | nothing |
| publish | `objectViewer`; `storage.objects.delete` under `publish_delete_prefixes` only (SPL-5006 W3) | `objectCreator`; `objectUser` on `latest.json` only |
| verifier | `objectViewer`; `objectCreator` under `verdicts/` only | nothing |

### 2.1 The publish SA's delete on staging (SPL-5006 W3)

After a publish the name lists leave `candidates/<candidate>/names/`, and a
candidate past `candidate_ttl_hours` is dropped with its `verdicts/<sha256>/`.
No predefined role is delete alone, so the project custom role
`publish_delete_role_id` (cnf) holds `storage.objects.delete` and nothing
else. It is bound to the publish SA on the staging bucket with an IAM
condition, one `resource.name.startsWith(...)` per entry of
`publish_delete_prefixes` (cnf, today `candidates/` and `verdicts/`). The
variable refuses an empty list and an empty prefix, which would grant delete on
the whole bucket. The public bucket gets no delete grant: `latest.json` is
overwritten through its own `objectUser` binding.

Test: `csi-spl-orc/src/bash/tests/public-dataset-publish.tst.sh` part 7 reads
the role, the binding and both envs' tfvars, then runs the publish on a fake
bucket that allows a delete under those prefixes only; a delete elsewhere is
refused (red control).

The switch `env.public_dataset.enabled` stays `false`: this grant does not turn
publishing on.

## 3. Plan and apply

Only in the tf-runner container, from the main checkout, with the per-env SA
key; an apply needs the owner's go:

`cd csi-spl-orc && ENV=<env> STEP=053-gcs-public-dataset make do-tf-plan`
