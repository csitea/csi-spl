# Hub secrets: pinned versions and rotation

SPL-2251, Cloud Run radar step 6. The hub's Cloud Run service reads each
Secret Manager secret at a **pinned version number**, never `latest`.

## 1. Where the pin lives

- cnf `env.hub.secret_versions` in `csi-spl-cnf/csi-spl/<env>.env.yaml`:
  secret id -> version number, one row per secret the hub injects.
- `ENV=<env> ./run -a do_tpl_gen` renders `secret_versions` into
  `csi-spl-cnf/csi-spl/<env>/tf/030-cloud-run-hub.vars.tfvars`, for the
  injected secrets only.
- Step 030 (`04-cloud-run-service.tf`) injects
  `lookup(var.secret_versions, <secret>)`. A precondition fails the plan when
  an injected secret has no pin; `02-variables.tf` refuses a pin that is not a
  number.
- The hub deploy (wf 20, `do_deploy_hub`) changes only the image, so a deploy
  keeps the pins. Only a 030 apply moves them.
- Test: `csi-spl-iac/src/bash/tests/hub-secret-versions-030.tst.sh`.

Why: with `latest`, every new instance resolves the newest version when it
starts. A version added out of band reaches instances one by one as they scale
or restart, so two instances can run with two values, and nobody chose the
moment. A pin makes the switch one reviewed apply, with one revision to roll
back to.

## 2. Rotating one secret

1. **Add the new version** with the secret's seed action (for example
   `do_spl_wui_key_seed`, `do_spl_mail_secret_seed`, `do_spl_gh_app_key_put`).
   The hub still reads the old pin: nothing changes yet.
2. **Raise the pin** in cnf `hub.secret_versions` to the new number, run
   `ENV=<env> ./run -a do_tpl_gen` and commit both.
3. **Apply 030**, dev first, then prd, with the owner's go:
   `cd csi-spl-orc && ENV=<env> STEP=030-cloud-run-hub make do-tf-plan`, then
   `make do-provision`. Cloud Run makes a new revision that reads the new
   version; the old revision still reads the old one.
4. **Prove it**: `do_check_hub_deploy` and `/version` answer, and the hub
   logs show no secret-access error.
5. **Disable the old version**:
   `cd csi-spl-iac && ENV=<env> SECRET=<id> ./run -a do_spl_secret_version_disable_old`
   (dry run first, then `DRY_RUN=0`). It refuses while the hub still pins the
   version it would disable.

Undo before step 5: lower the pin and apply 030 again, or route traffic back
to the previous revision. Undo after step 5:
`gcloud secrets versions enable <n> --secret=<id> --project=<project>` first.

## 3. What breaks if a pinned version is disabled first

Cloud Run resolves an env-var secret when an instance **starts**. A disabled
or destroyed pinned version:

- does not stop instances already running: the value is already in their
  environment;
- makes every new instance fail to start (scale-out, a crashed instance, the
  min-instance replacement), and a new revision (a deploy, a 030 apply) never
  becomes ready.

So the hub keeps serving on its warm instances and then fails at the next
start. That is why step 5 comes last, and why
`do_spl_secret_version_disable_old` reads the live service first. `latest`
does not avoid it: disabling the newest version breaks `latest` the same way.

## 4. Rotation schedule (proposal, the owner decides: SPL-1945)

`do_spl_secret_age_report` flags a version `OVER` once cnf
`env.secrets.max_age_days.secret_version` is set; it is `null` today.

| secret class | proposed cadence | note |
|---|---|---|
| DB DSN (`csi-spl-hub-db-dsn`) | 90 days | the password changes in SQL first, then the new DSN version |
| session key | 180 days, or on a leak | one key, no key ring: rotating it signs every session out |
| IdP client secrets, SMTP password, Stripe keys, GitHub App key, LinkedIn app | 180 days, or when the provider rotates | rotated at the provider, then seeded |
| box-wui key (`csi-spl-hub-wui-key`) | on a leak | the boxes trust its public key; a rotation is a box rollout too |
