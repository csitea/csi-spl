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

`do_spl_secret_rotate` (csi-spl-iac, SPL-2657) walks these steps for one
secret and refuses a step out of order. `ROTATE_STEP=status` (the default)
prints the newest enabled version, the cnf pin and the live hub pin, and names
the next step:
`cd csi-spl-iac && ENV=<env> SECRET=<id> ./run -a do_spl_secret_rotate`.
Test: `csi-spl-iac/src/bash/tests/spl-secret-rotate.tst.sh`.

1. **Add the new version** with the secret's seed action; `status` names it
   per secret (for example `do_spl_mail_secret_seed`,
   `do_spl_payment_secret_seed`, `do_spl_gh_app_key_put`). The session key,
   the box-wui key and the DB DSN have no rotating seed action yet: their
   version is added by hand. The hub still reads the old pin: nothing changes
   yet.
2. **Raise the pin**: `ROTATE_STEP=pin DRY_RUN=0` sets cnf
   `hub.secret_versions` to the newest enabled version (it refuses when that
   is not above the pin) and runs `do_tpl_gen`; commit both.
3. **Apply 030**, dev first, then prd, with the owner's go:
   `cd csi-spl-orc && ENV=<env> STEP=030-cloud-run-hub make do-tf-plan`, then
   `make do-provision`. Cloud Run makes a new revision that reads the new
   version; the old revision still reads the old one.
4. **Prove it**: `ROTATE_STEP=verify` checks that the live hub reads the cnf
   pin and its newest revision is Ready; `do_check_hub_deploy` and `/version`
   answer, and the hub logs show no secret-access error.
5. **Disable the old version**: `ROTATE_STEP=disable`, which runs
   `do_spl_secret_version_disable_old` (dry run first, then `DRY_RUN=0`). It
   refuses while the hub still pins the version it would disable.

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

## 4. Rotation schedule (owner approved: poll c5bf2101, answer A, 2026-10-20)

cnf `env.secrets.max_age_days.per_secret` (all.env.yaml) holds a max age in
days for each secret the hub pins; it beats the class value
`secret_version` (still `null`). `do_spl_secret_age_report` shows each
secret's max age and flags it `OVER` past it (exit 1). A test keeps the list
equal to the secrets pinned in dev and prd.

| secret | max age, days | how a new version is made |
|---|---|---|
| `csi-spl-hub-db-dsn` | 90 | new password for the hub DB user in Cloud SQL, then the new DSN as a version |
| `csi-spl-hub-auth-session-key` | 180, or on a leak | 48 random bytes; signs every session out (one key, no key ring) |
| `csi-spl-hub-auth-{google,facebook,linkedin}-client-secret` | 180, or when the IdP rotates | at the IdP, then `do_spl_auth_idp_secret_seed` |
| `csi-spl-hub-marketing-linkedin-client-{id,secret}` | 180 | at LinkedIn, the pair together |
| `csi-spl-hub-mail-smtp-password` | 180 | a new app password, then `do_spl_mail_secret_seed` |
| `csi-spl-hub-stripe-secret-key` | 180 | roll at Stripe, then `do_spl_payment_secret_seed` |
| `csi-spl-hub-stripe-webhook-secret` | 365 | roll the endpoint's secret at Stripe |
| `spool-hub-github-app-key` | 180 | a new key in the GitHub App, then `do_spl_gh_app_key_put` |
| `csi-spl-hub-wui-key` | 365, or on a leak | spec 014 `contracts/wui-dispatch.md` section 2.3: the boxes trust its public key, so a box rollout too |

### 4.1 Why no secret rotates by itself

Secret Manager's own rotation schedule (`rotation` + `topics` on a secret)
only publishes a message to a Pub/Sub topic when a rotation is due; a
rotator subscribed to it would still have to add the version, and the pin
move is a 030 apply that waits for the owner's go. Nine of the twelve
secrets are made at a third party (IdPs, LinkedIn, Stripe, the mail
provider, GitHub), where no rotator can reach. So the schedule lives in cnf and the age report
reads it; no Pub/Sub topic, service agent or rotator is built, and the
project has no Pub/Sub API enabled (cnf `steps.001-enable-gcp-services`).
The three made here (DB DSN, session key, box-wui key) could get a rotator
later; each needs a seed action that adds a version first, and the box-wui
key a box rollout too.
