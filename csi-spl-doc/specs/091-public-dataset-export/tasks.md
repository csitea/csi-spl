# 091 Public dataset export: tasks

What gets built (`spec.md` v0.4.1 holds the behaviour, and §13 records the panel consensus at `51b40dca`). Each task is one lane: one agent, one task, the files it owns, the tests that prove it, and what it depends on. Status words: `../README.md` §2.3. Topic: `67b63c88-9de3-40d9-a54e-66aae05e4583`. The owner's rule is to start building once the panel agrees, without waiting for the owner's go.

Paths: `rdb/` = `csi-spl-rdb/src/sql/postgres/spool-hub/`, `roles/` = `csi-spl-rdb/src/sql/postgres/spool-hub-roles/`, `api/` = `csi-spl-api/src/go/spool-hub-api/`, `orc/` = `csi-spl-orc/`, `iac/` = `csi-spl-iac/`, `cnf/` = `csi-spl-cnf/csi-spl/`, `doc/` = `csi-spl-doc/`, `wf/` = `.github/workflows/`.

## Defaults until the owner answers (`spec.md` §11)

The build uses these and does not wait. A different answer later is a small change in the task named.

| Q | default the build uses | task that carries it |
|---|---|---|
| Q1b | members appear as their `HUM-n` id only; `display_name` = `human_id` | T006 |
| Q3 | a scan hit in a message body drops that message and counts it; the day fails above 1% dropped | T005 |
| Q7 | three verifier lanes every day on prd | T012, T013..T015 |
| Q9 | archived channels are out | T006 |
| Q2, Q4, Q5, Q6 | as the spec recommends (30/365 days; no workspace docs; no issues; loaded messages are history only) | T007, T006, T010 |

**Q1 (consent and opt-out) and Q8 (the step-053 apply and `enabled: true` on prd) block PUBLISH only.** Everything up to a verified candidate in private staging is built, tested and deployed without them. The kill switch `env.public_dataset.enabled` stays `false` on prd until both are answered. T017 (opt-out) is built **only if the owner says yes to Q1**.

## Rules for every task

- **Gate before every push, and again after the mandatory rebase**: run `cd csi-spl-iac && ./run -a do_check_pre_push`, plus the gate for each tree the task touches (repo `CLAUDE.md`):

  | tree | gate |
  |---|---|
  | `rdb/`, `roles/`, `api/internal/store/` | `PRE_PUSH_TIER=full ./run -a do_check_pre_push` (store tests on Postgres) |
  | `api/` | `bash csi-spl-api/src/bash/tests/run-all-tests.sh`; new Go functions pass the clean-code gate (≤ 80 lines, depth ≤ 4, ≤ 8 params) |
  | `orc/` | `bash csi-spl-orc/src/bash/tests/run-all-tests.sh` (the task's `*.tst.sh` alone while iterating); `./run -a do_check_pre_push_lint` |
  | `iac/`, `cnf/` | `ENV=<env> ./run -a do_tpl_gen` then `git diff --exit-code`; `./run -a do_check_pre_push_lint`; `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` |
  | `wf/` | `./run -a do_check_pre_push_lint` (actionlint, shellcheck on the run blocks) |
  | `doc/` | `./run -a do_check_dist_hygiene`, `lint-mdlinks` |

- **Deploy dev and prd, then prove it live.** A migration ships through `ENV=dev DRY_RUN=0 ./run -a do_spl_db_bootstrap`; for prd, send the exact command to the orchestrator and wait. Prove it with `do_spl_db_query` on the catalog on both envs. A hub change ships through wf 20 and is proven by `/version` on dev and prd. Terraform runs only through the tf-runner make path with the per-env service-account key; every apply needs the owner's go (Q8 for step 053) and is proven by a clean `make do-tf-plan` on dev and prd after it. Run `./run -a do_check_deploy_lag` and report `SHA=<sha> ENV=<env> ./run -a do_release_note_link` for both envs.
- **GCP**: only the per-environment service account (`~/.gcp/.csi/key-csi-spl-<env>.json`), `--account` on every call. Never the owner account. A key that lacks a permission is reported, never worked around.
- **Secrets**: the export and names logins' passwords live only in Secret Manager, seeded by a named seed action. Never in git, terraform state, a log, a spool message or a workflow artifact. **A missing secret blocks the task**: report it with `DESK_KIND=blocker`.
- **CI is public (§5.6)**: gate, export, publish and verifier output names the table, the primary key and the class of a hit, never the matched text. No `set -x` in those steps, no `upload-artifact` of a candidate or of a name list.
- **Nothing ad hoc**: every step is a `do_<verb>_<noun>` action in `orc/src/bash/run/<verb>-<noun>.func.sh` plus its test in the same commit.
- **Workspace id from cnf** (`env.public_dataset.workspace_id`), never a literal. Plain English, "workspace" in prose (the SQL column stays `tenant_id`). No host literals: read `BASE_DOMAIN` or the cnf. No personal names.
- **Numbers**: on `e5f40582e` the last migration is `0124_demo_user_role.sql`; 089 T002 takes `0125` and 090 T003 takes `0126`, so this spec uses `0127`. **Check again at build time** with `ls csi-spl-rdb/src/sql/postgres/spool-hub | tail -1` and take the next free number. Workflow numbers `46` and `47` are free on the same sha; check again too.

## Order and parallelism

```
T002 allow-list + cnf ─┬─► T004 export + names logins ─┬─► T006 export action ─┬─► T011 CI round trip + canaries
T003 rdb restrictive ──┘   (T003 too)                  │   (T005 too)          │   (T010 too)
                       ├─► T005 gate + names step ─────┘                       ├─► T008 publish + take-down ─► T012 daily workflow
                       └─► T007 tf step 053 (plans; apply = Q8) ───────────────┘                                │
T010 loader ──────────────────────────────────────────────────────────────────► T011                           ├─► T013 claude lane
T009 release-note links (after T006, T008) ───────────────────────────────────────────────────────────────────┤   T014 grok lane
T016 operator doc (after T012)                                                                                 └─► T015 agy lane
T017 opt-out (only if Q1 = yes; after T006, T011)
```

The serial spine is T002 -> T004 -> T006 -> T008 -> T012 -> T013..T015 (first live publish). T002, T003 and T010 own separate files and start at once. T005 and T007 start after T002. T009 and T011 run in parallel with T008. The three verifier lanes run in parallel with each other and are blind to each other.

---

### Phase 0: Specification
- [x] T001 **spec + tasks**: `spec.md` v0.4.1 (c-307, panel c-288, g-308, a-287) and this file (c-289).

### Phase 1: the fences and the allow-list

- [x] T002 **allow-list v1 + cnf** (orc, cnf). Done by c-294: 5 tables, 112 live columns classified (25 public, 87 withheld), measured on a fresh Postgres from all 127 migrations (0125 added `tenants.calendar_region`); workspace `t1` on dev and prd (live `tenants` read).
  - **Build**:
    - `orc/cnf/public-dataset/allow-list.v1.yaml`: `version: 1`; for each §4.1 table (`tenants`, `channels`, `messages`, `humans`, `tenant_memberships`) its row rule name, its `public` columns (§4.1), its `withheld` columns (every other live column, §4.4, measured from the migrations including multi-line `ADD COLUMN`), and the §4.4 constants for the NOT NULL withheld ones. A top-level `never` list carries the §4.2 tables.
    - cnf block `public_dataset` in `cnf/all.env.yaml` (env overrides in `dev.env.yaml` / `prd.env.yaml`): `enabled: false`, `workspace_id`, `allow_list_version: 1`, `topic_channel` (the dataset topic's channel, never exported), `body_drop_cap_pct: 1`, `size_tolerance_pct: 50`, `candidate_ttl_hours: 24`, `dev_synthetic: true` (dev publishes on the gate alone only while this is true, §11 Q7).
    - cnf block `steps."053-gcs-public-dataset"`: `public_bucket_name`, `staging_bucket_name`, `daily_retention_days: 30`, `stable_retention_days: 365`.
  - **Owns**: the allow-list file and those cnf keys (only those keys in the three env yaml files).
  - **Tests**: `orc/src/bash/tests/public-dataset-allow-list.tst.sh`: the file parses; its name and `version` agree; no column is both `public` and `withheld`; no §4.2 table or column (`email`, `msg`, `env`, `env_sig`, `files`, `typed_by`, `ref_task_id`, `mirror_of`, `root_pubkey`) is `public`; every `public` column is one §4.1 names. tpl-gen with no diff.
  - **Depends**: none. **Parallel** with T003 and T010.
  - **Needs from the owner**: nothing. The prd workspace id is read from the live `tenants` row through `do_spl_db_query` as the per-env SA.
  - **Deploy + prove**: tpl-gen clean on dev and prd; `./run -a do_check_dist_hygiene` green.

- [x] T003 **rdb migration** `rdb/0126_public_export_scope.sql` (fence 2, §5.2). Check the number at build time.
  - **Build**:
    - The role must exist before a policy names it: `CREATE ROLE spool_public_export NOLOGIN` if absent (the owner may create roles, as `roles/runtime-role.sql` shows). T004 gives it LOGIN and its password.
    - Table `public_export_workspace`: one row only (a `one_row boolean` primary key with `CHECK (one_row)`), `workspace_id text NOT NULL REFERENCES tenants (tenant_id)`. The export role gets `SELECT` only; no role but the owner may write it. The row is written by T004's action from cnf, never by the migration (no literal id).
    - A `RESTRICTIVE` policy `public_export_scope` `FOR SELECT TO spool_public_export USING (tenant_id = (SELECT workspace_id FROM public_export_workspace))` on each exported table that carries `tenant_id` (`tenants`, `channels`, `messages`, `tenant_memberships`; check each has RLS on at build time).
    - The column is named `workspace_id`, not `tenant_id`, so the generic per-workspace RLS loop and `TestCrossTenantEveryTable` do not treat the table as a workspace table. Confirm both on build; if either does, seed it in `seedTenantAll` in the same commit.
  - **Owns**: that `.sql` file (and the seed line if needed).
  - **Tests** (on Postgres, `api/internal/store/public_export_scope_test.go`): as `spool_public_export` with a second workspace present, a `SELECT` with no filter returns only the Spool Hub rows; **the same with `app.rls_scope = 'operator'` set** still returns only those rows (§5.2); the hub runtime role still sees what it saw before. `TestRLSPoliciesFailClosed` and the migration catalogue gate stay green.
  - **Depends**: none. **Parallel** with T002.
  - **Needs from the owner**: nothing (prd bootstrap goes through the orchestrator).
  - **Deploy + prove**: bootstrap dev, then prd via the orchestrator. On both, `pg_policies` lists `public_export_scope` as `RESTRICTIVE` on each table, and `pg_roles` shows `spool_public_export` with `rolbypassrls = false` and `rolsuper = false`.

- [x] T004 **export and names logins, column grants** (fence 1, §5.1; the names step's login, §5.5 item 3). Done by c-315: 25 column grants on 5 tables + `public_export_workspace`; cnf `public_dataset.{export,names}_login` and `{export,names}_password_secret` (the seed creates the two slots; `do_spl_secrets_check` lists them as optional). For T006: `tenant_id` of `channels` and `messages` is withheld, so the export cannot name it; fence 3 there is the join through the exported `channels` row, and fence 2 still pins the rows.
  - **Build**:
    - `roles/public-export-role.sql`: LOGIN, NOSUPERUSER, NOBYPASSRLS, NOINHERIT, not an owner, password as a SCRAM verifier computed client side (the `runtime-role.sql` pattern).
    - `roles/public-export-grants.sql`: **generated** from the allow-list by `do_spl_public_export_grants_gen` (`orc/src/bash/run/spl-public-export-grants-gen.func.sh`): `REVOKE ALL`, then `GRANT SELECT (<public cols>) ON <table>` for exactly §4.1, plus `SELECT` on `public_export_workspace`. Nothing else.
    - `roles/public-names-role.sql`: a login `spool_public_names` with only `SELECT (tenant_id, display_name) ON tenants`, read under the operator scope (that is its one purpose).
    - `do_spl_public_export_role` (`spl-public-export-role.func.sh`): as the schema owner, applies the three files, writes the `public_export_workspace` row from `env.public_dataset.workspace_id`, reads every flag back (the `do_spl_db_owner_split` verify pattern) and prints OK or FAIL.
    - `do_spl_public_export_secret_seed` (`spl-public-export-secret-seed.func.sh`): both passwords into Secret Manager, the `spl-mail-secret-seed` pattern.
  - **Owns**: those three role files, the three actions and their tests.
  - **Tests**: store test `api/internal/store/public_export_grants_test.go` (on Postgres): **the grants file equals what the generator makes from the allow-list** (§9.3 "grants equal allow-list"); as `spool_public_export`, a `SELECT` of a withheld column (`messages.msg`, `humans.email`) fails with a permission error; a `SELECT` on any §4.2 table fails; the names login reads `tenants (tenant_id, display_name)` and nothing else. Bash tests for the actions with psql and gcloud stubbed.
  - **Depends**: T002, T003. **Serial**.
  - **Needs from the owner**: nothing. The prd run of `do_spl_public_export_role` goes through the orchestrator.
  - **Deploy + prove**: `ENV=dev ./run -a do_spl_public_export_secret_seed` and `do_spl_public_export_role` print OK on dev; prd through the orchestrator; `do_spl_secrets_check` lists both secrets on both envs.

### Phase 2: the export, the gate and storage

- [ ] T005 **the gate and the names step** (§5.5, §5.6).
  - **Build**:
    - `do_spl_public_dataset_gate` (`spl-public-dataset-gate.func.sh`), run by T006 on the candidate before staging. Classes:
      - **C3 shape**: every table and column in the file is a `public` column of the allow-list; **every live column of a listed table** (read from `information_schema.columns`, not a grep) is `public` or `withheld`; else FATAL.
      - **C1/C2 workspace**: no `tenant_id` but Spool Hub's; `tenants` has exactly one row; every exported row is re-read on a second connection pinned by RLS alone (no filter) and must be found.
      - **C4 content scan**: e-mail, IPv4/IPv6, JWT, PEM, cloud/Slack/GitHub token shapes, `iam.gserviceaccount.com`, gitleaks with the repo's config, and every other workspace's id and display name as whole words. A hit in `messages.body` drops that message and counts it by class (Q3 default); the scan runs again and must be clean; more than `body_drop_cap_pct` dropped = FATAL. A hit anywhere else = FATAL.
      - **Size**: row counts within `size_tolerance_pct` of the previous published file, unless the allow-list version changed or there is no previous file.
    - `do_spl_public_dataset_names` (`spl-public-dataset-names.func.sh`): as `spool_public_names`, writes the other workspaces' ids and display names, and the lower-cased sha256 of each (for the grok lane, §8.2), to **private staging only** under the candidate's prefix.
    - Output names the class, the table and the primary key; never the matched text.
  - **Owns**: those two actions, `orc/src/bash/tests/public-dataset-gate.tst.sh`, `public-dataset-names.tst.sh` and their fixtures under `orc/src/bash/tests/fixtures/public-dataset/gate/`.
  - **Tests** (each plant fails closed, §9.3 "the gate catches plants"): a planted e-mail, a JWT, a PEM block, another workspace's name in a non-body column (FATAL), the same name in a body (dropped, counted, second scan clean), 2% of bodies hit (FATAL), an extra column in the file, **an unclassified new live column** (an `ALTER TABLE … ADD COLUMN` on the fixture database that the allow-list does not list fails the build: the claude opinion's C3 test), an extra workspace row, a row missing from the RLS re-read. A log-capture assertion: no planted string appears in the gate's output.
  - **Depends**: T002. **Parallel** with T004 and T007.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: the tests green in CI (wf 10 orc suite) on the landing sha.

- [ ] T006 **the export action** `do_spl_public_dataset_export` (fence 3 and the file: §4, §5.3, §5.4, §5.7).
  - **Build**:
    - `spl-public-dataset-export.func.sh`: opens the Cloud SQL proxy with the env key; connects as `spool_public_export`; every transaction starts `SET LOCAL app.tenant_id = <id from cnf>` and never sets `app.rls_scope`.
    - One named projection query per table in `orc/src/sql/public-dataset/v1/<nn>-<table>.sql`, each listing its output columns and carrying `WHERE tenant_id = $1` (or a join through a row that does). Row rules exactly §4.1: public, not deleted, not archived channels (Q9); no message of an archived task (the whole `task_id`, 0065; the lobby note in §4.4 keeps the safe direction); thread root in an exported channel; not expired; a `from_id`/`to_id` `HUM-n` that is not a Spool Hub member drops the message and counts it. `humans` only for authors and addressees of exported messages, `display_name = human_id`, `email` NULL (Q1b default). The §4.4 constants are emitted by the query, never read from `msg`, `env` or `env_sig`.
    - After the read, every emitted row's `tenant_id` is compared with the cnf id; one mismatch = FATAL, nothing written.
    - Calls T005's names step and gate, then writes `spool-hub-public-<YYYY-MM-DD>-v<X.Y.Z>.sql.gz` (data only, `COPY … FROM stdin`, FK order; `<X.Y.Z>` from prd hub `/version`) and its `.manifest.json` (sha256, version, commit sha, migration head, allow-list version and sha256, row counts, rows removed by class, and the version's `do_release_note_link`: §7 "manifest to note") to the **private staging bucket** only.
    - Exits 0 with a message when `env.public_dataset.enabled` is `false` and `PUBLIC_DATASET_FORCE` is unset (the dev and CI paths set it).
  - **Owns**: that action, the `orc/src/sql/public-dataset/v1/` projection files, and `orc/src/bash/tests/public-dataset-export.tst.sh`.
  - **Tests**: a grep test over the action and the projection files: no `SELECT *`, no `pg_dump`, no `set -x` (§3 principle 1, §5.6); a stubbed read returning a row with another `tenant_id` = FATAL and nothing written; the manifest schema; the file holds only `COPY` blocks. The fence and canary proof against a real database is T011.
  - **Depends**: T004, T005. **Serial**.
  - **Needs from the owner**: nothing to stage on dev. A staged candidate in the cloud needs T007 applied (Q8).
  - **Deploy + prove**: `ENV=dev PUBLIC_DATASET_FORCE=1 ./run -a do_spl_public_dataset_export` stages a candidate on dev; report its sha256, the row counts and the removed counts by class (no content).

- [ ] T007 **terraform step** `iac/src/terraform/053-gcs-public-dataset/` (§6).
  - **Build**: the public bucket (uniform access, `allUsers` `roles/storage.objectViewer`, nothing else in it); the private staging bucket; lifecycle rules from cnf (daily objects `daily_retention_days`, objects under `stable/` `stable_retention_days`); three service accounts:
    - **export** SA: Cloud SQL client (the proxy) and object create on staging; no access to the public bucket.
    - **publish** SA: read staging, object **create** on the public bucket, overwrite of `latest.json` only (IAM condition on the object name); no database access.
    - **verifier** SA: read staging, create under `verdicts/` only (IAM condition on the prefix).
  - Terraform creates no SA key (keys are minted out of band, the doc section 6.3 pattern). The templates `iac/src/tpl/%org%-%app%/%env%/tf/053-gcs-public-dataset.{vars,backend-config}.tfvars.tpl` and the rendered tfvars for dev and prd.
  - **Owns**: that step dir, its two templates, the rendered tfvars.
  - **Tests**: tpl-gen with no diff, iac suite, checkov (wf 65) clean or each finding justified inline, lint.
  - **Depends**: T002 (the cnf keys). **Parallel** with T004, T005, T006.
  - **Needs from the owner**: **Q8**: the go for `make do-provision` of step 053 on dev and prd. The task **stops at clean plans** on both envs and posts them (resource list, no values) to the orchestrator.
  - **Deploy + prove**: a clean `ENV=dev STEP=053-gcs-public-dataset make do-tf-plan` and the same for prd. After the owner's apply: a clean re-plan on both, and an anonymous `GET` of a test object in the public bucket answers 200 while one in staging answers 403.

### Phase 3: publish, links and the seed

- [ ] T008 **publish and take-down** `do_spl_public_dataset_publish`, `do_spl_public_dataset_takedown` (§8.4, §10).
  - **Build**:
    - `spl-public-dataset-publish.func.sh`, run as the publish SA. For the candidate's sha256 it requires: three files under `verdicts/<sha256>/`; their `lane_kind`s exactly {agy, grok, claude}; distinct `lane_id`s matching their kind's prefix (`a-`, `g-`, `c-`); each `PASS`; each `hub_msg_id` resolving to a hub message from that `lane_id` on the dataset topic carrying the same sha256 and verdict. Then a server-side copy of the file, the manifest with the three verdicts consolidated, and the verdicts to the public bucket; then `latest.json` (`Cache-Control: no-cache`). Then it deletes both name lists from staging and proves none was copied.
    - Anything less: nothing published, and a note on the dataset topic names what is missing (class only). A candidate older than `candidate_ttl_hours` is dropped with its name lists.
    - `spl-public-dataset-takedown.func.sh`: deletes one named published file and its manifest and points `latest.json` at the previous good one. A delete: it refuses without `TAKEDOWN_GO=<file name>`, set only after the orchestrator relays the owner's go.
    - Refuses on prd while `env.public_dataset.enabled` is `false`.
  - **Owns**: those two actions and `orc/src/bash/tests/public-dataset-publish.tst.sh`, `public-dataset-takedown.tst.sh`.
  - **Tests** (gcloud storage and the hub stubbed): 2 of 3 verdicts, two `claude` verdicts, a `FAIL`, a sha256 mismatch, a `lane_id` with the wrong prefix, a `hub_msg_id` from another sender: each publishes nothing; 3/3 publishes and writes `latest.json` last; a name list never reaches the public side; the 24 h drop; take-down without the go refuses.
  - **Depends**: T006 (the manifest), T007 (the bucket names). **Serial**.
  - **Needs from the owner**: nothing to build. A live prd publish needs **Q8** and an answer to **Q1**.
  - **Deploy + prove**: after the Q8 apply on dev, a dev candidate with three real lane verdicts publishes to dev's public bucket and `latest.json` names it.

- [ ] T009 **release-note links** (§7).
  - **Build**: `do_release_stable` (`orc/src/bash/run/release-stable.func.sh`) gains a "Data" section: the newest published file in prd's public bucket whose version is at or below the stable commit, linked next to that release's migrations, read from `latest.json` and an anonymous bucket listing (no key). That file is copied under `stable/` by `do_spl_public_dataset_stable_copy` (`spl-public-dataset-stable-copy.func.sh`, run as the publish SA). The README gets a short self-hosting paragraph linking `latest.json` (the URL built from cnf, no literal host) and the load command (§9.1).
  - **Owns**: one new function in `release-stable.func.sh` and its call, `spl-public-dataset-stable-copy.func.sh`, the README paragraph, and the new cases in `orc/src/bash/tests/release-stable.tst.sh`.
  - **Tests**: no published file = no Data section and no failure; a file newer than the stable commit is skipped; the link carries the version.
  - **Depends**: T006 (file naming), T008 (the publish SA path). **Parallel** with T011.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: the next weekly stable release (wf 55) shows the Data section, or "no file yet" while nothing is published.

- [x] T010 **the loader** `do_spl_public_dataset_load` (§9.1, §9.2).
  - **Build**: `SEED_FILE=<path or URL> SEED_ADMIN_EMAIL=<email> ./run -a do_spl_public_dataset_load` (`spl-public-dataset-load.func.sh`):
    1. Fetches the file and manifest, checks the sha256, refuses a manifest without three PASS verdicts (a `SEED_ALLOW_UNVERIFIED=1` switch exists for the CI round trip only, refused unless `CI=true`).
    2. Statement whitelist: only `COPY … FROM stdin` blocks and their data; each target a §4.1 table with exactly its public columns plus the §4.4 constants; anything else (DDL, `SET`, a function body, a `COPY` into a credential table) refuses the whole file.
    3. Refuses unless the database is at the manifest's migration head (the error names the release to check out) and holds no workspace row.
    4. One transaction under the operator scope: the empty check, the load, then one workspace and counts equal to the manifest.
    5. A new workspace root keypair (private key to the operator's path, mode `0600`, never into the database; the transaction refuses to commit while `root_pubkey` is still 32 zero bytes); the first admin: a new human with `humans_seq` past the highest loaded `HUM-n`, role `owner`, a native password credential for `SEED_ADMIN_EMAIL` with a generated password printed once. Reuse the key and password-hash helpers the new-workspace and invite actions already use; if a Go helper is missing, add it as a new `spool` subcommand file owned here.
    6. Prints how to sign in. `SEED_ADMIN_EMAIL` is required with no default.
  - **Owns**: that action, `orc/src/bash/tests/public-dataset-load.tst.sh`, its fixtures, and any new `api/cmd/spool/seed_admin.go` with its test.
  - **Tests**: each refusal in steps 1-3 (a `CREATE`, a `SET`, a `COPY` into `password_credentials`, a wrong migration head, a database with a workspace); a clean load creates exactly one workspace and one human who can sign in; no loaded human has a credential, identity or e-mail.
  - **Depends**: none to build (it reads the file format of §5.7). **Parallel** with T002..T008.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: T011's round trip is its proof.
  - **Built** (c-295): the manifest keys the loader reads, which T006 writes: `sha256`, `version`, `migration_head` (a migration file name), `row_counts.{tenants,humans,tenant_memberships,channels,messages}`, `verdicts[]` of `{lane_kind, lane_id, verdict, file_sha256}`. A COPY may name `tenant_id` on every table but `humans`; the loader forces every §4.4 constant itself, whatever the file holds. The first admin reuses `spool hub-provision-member --password-stdin`, so no new Go was needed.

- [ ] T011 **CI round trip and canaries** (§9.3, C5; the claude opinion's canary-row and unclassified-column tests).
  - **Build**:
    - A synthetic two-workspace fixture `orc/src/sql/public-dataset/fixture/canary.sql` (no real data) planting a unique marker in each §5.5 item 4 place: a second workspace with a channel of the **same `channel_id`** as a public one; a private channel; a DM; a reply in an archived task; an archived channel; a message revision; the `msg`, `env`, `env_sig` and `files` of a public message; the e-mail of a human who is a member of both workspaces; an invite; a box name; the dataset topic's channel.
    - A new workflow `wf/47_public-dataset-roundtrip.yml` (check the number), on every PR and push touching `orc/src/sql/public-dataset/**`, the export, gate or loader actions, `roles/public-*` or `rdb/**`: a Postgres service, `spool migrate`, `do_spl_public_export_role`, the fixture, `PUBLIC_DATASET_FORCE=1` export to a local file; **any marker in the file = FAIL**; load it into a second fresh Postgres; boot the hub; sign in as the seeded admin; the workspace count is 1 and no fixture member can sign in.
    - A step that adds an unclassified column to `messages` on the fixture database and expects the export to fail with class C3.
  - **Owns**: the fixture, the workflow file, and `orc/src/bash/tests/public-dataset-roundtrip.tst.sh` (the driver the workflow calls, runnable locally against `postgres:16-alpine`).
  - **Tests**: the workflow itself; a workflow test that greps it for `upload-artifact` and `set -x` (none allowed).
  - **Depends**: T004, T006, T010. **Parallel** with T008 and T009.
  - **Needs from the owner**: nothing.
  - **Deploy + prove**: the workflow green on the landing sha; a throwaway-branch run with one marker deliberately let through goes red (controls on a throwaway branch, never trunk).

### Phase 4: operation and the three verifier lanes

- [ ] T012 **daily workflow** `wf/46_public-dataset.yml` (§10; Q7 default daily). Check the number.
  - **Build**: a daily schedule after the 00:17 backup slot. Job 1 reads `env.public_dataset.enabled`; `false` = says so and exits 0. Job 2: the export to staging (prd, and dev with `PUBLIC_DATASET_FORCE=1`) as the export SA. Job 3: posts one request per verifier kind on the dataset topic to the orchestrator (`--to orchestrator`), carrying only the staged URI and sha256, so the orchestrator places the three lanes (T013..T015). Job 4 (`workflow_dispatch` and a later schedule): `do_spl_public_dataset_publish` as the publish SA. Job 5: after a publish, the round trip from `latest.json` (§9.3 "the published file boots"), reusing T011's driver.
  - Dev publishes on the gate alone only while `public_dataset.dev_synthetic` is true; a dev database with real workspaces uses the three lanes.
  - **Owns**: that workflow file and its workflow test (no `upload-artifact`, no `set -x`, the kill switch read first).
  - **Depends**: T006, T008, T011; live runs need T007 applied. **Serial**.
  - **Needs from the owner**: **Q8** (`enabled: true` on prd) and **Q1** before prd publishes. If Q7 is answered with change-triggered lanes, only job 3's trigger changes.
  - **Deploy + prove**: one dev run end to end: staged, lanes requested, published (dev synthetic), boot test green. Report the run link.

The three verifier lanes are **not code tasks**. The orchestrator places each one after a candidate is staged (first on dev, then the first prd candidate), as three separate lanes of three kinds, blind to each other. Each brief carries only: the staged file's URI, its sha256, a pointer to `spec.md` §4 and §8, the dataset topic id, and the per-env verifier SA key path. No access to the export code, the allow-list file or another lane's verdict. Each lane writes `verdicts/<sha256>/<lane-kind>.json` (§8.3), posts the same verdict on the dataset topic from its own id, and reports `n` for every check. A FAIL names the table, the primary key and the class, never the text. A lane may add checks, never drop the listed ones.

- [ ] T013 **claude verifier lane** (`c-NNN`), method **structure**.
  - **Brief content**: restore the file into a throwaway Postgres at the manifest's migration head; check every table and column against §4.1 as written; `tenants` has one row with the Spool Hub id; no row with another `tenant_id`; every §4.2 table empty; `humans.email` all NULL and `display_name = human_id`; no DM, no private channel, cross-checked against the live channel list read as `spool_public_export`.
  - **Depends**: a staged candidate (T006, T012). **Parallel** with T014, T015.
  - **Needs from the owner**: nothing for dev; a prd verdict leads to a publish only once Q1 and Q8 allow it.

- [ ] T014 **grok verifier lane** (`g-NNN`), method **content**.
  - **Brief content**: its own scanners, written by that lane and not copied from the gate: every string token of the file against its own patterns for contact data, credentials and keys; gitleaks default rules; the private sha256 list of other workspaces' lower-cased ids and display names from staging (never the names in clear).
  - **Depends**: a staged candidate and its names list (T005, T006). **Parallel** with T013, T015.
  - **Needs from the owner**: as T013.

- [ ] T015 **agy verifier lane** (`a-NNN`), method **reading**.
  - **Brief content**: a stratified random sample of at least 200 messages (every channel, every day present) plus every message new since the previous published file, read for what no pattern finds (another workspace or a customer named in prose, a quote from a private channel or DM, an internal host, path or credential described in words); and a shape diff against the previous file (new table, column or channel). It reports `n` and says the sample is evidence, not proof (principle 4).
  - **Depends**: a staged candidate (T006). **Parallel** with T013, T014.
  - **Needs from the owner**: as T013.

- [ ] T016 **operator doc** `doc/doc/md/public-dataset.md`.
  - **Content**: what is published and what never is (link `spec.md` §4), the kill switch, the daily flow, how to read a FAIL, the take-down action and that a downloaded copy cannot be recalled, and the load command for self-hosters.
  - **Owns**: that file.
  - **Depends**: T012. **Serial**.
  - **Needs from the owner**: nothing.
  - **Gate**: `do_check_dist_hygiene`, `lint-mdlinks`.

### Only if the owner says yes to Q1

- [ ] T017 **member notice and opt-out** (Q1, a-287's suggestion).
  - **Build**: a migration (the next free number at build time) adding `tenant_memberships.public_dataset_opt_out boolean NOT NULL DEFAULT false`, classified `withheld` in a new `allow-list.v2.yaml` (a §4.5 spec change first); the store and a `PATCH` route for a member's own flag; a toggle in the member's settings page with its i18n keys; the export drops every message authored by an opted-out member and counts them in the manifest; a notice post in the public channels, sent once by a named action.
  - **Owns**: that migration, the v2 allow-list, the store, route and WUI files it adds, and, once T006 is on master, the `messages` projection file (serial after T006, so never owned by two lanes at once).
  - **Tests**: an opted-out member's message is absent and counted; T011's canaries stay green; RLS and cross-workspace tests for the new column.
  - **Depends**: the owner's yes to Q1, T006, T011. **Serial**.
  - **Needs from the owner**: Q1 = yes, and the notice text.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T12:00:00Z -->
