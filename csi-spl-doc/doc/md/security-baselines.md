# Security baselines and pinned images

Owner security scan, revised list, action 10 (t1 topic 62eaacb9, msg
4a5b93de): "add a CI gate that fails if any security baseline file grows
without a linked ticket ID". Issue SPL-2153, epic SPL-2151.

## 1. The files

Each scanner gate passes the findings its baseline or allow-list names, and
fails on any other finding.

| file | scanner | gate |
|---|---|---|
| `.gosec-baseline.txt` | gosec (hub Go, HIGH) | `do_sec_gosec`, wf 62 |
| `.semgrep-baseline.txt` | semgrep | `do_sec_semgrep`, wf 61 |
| `.eslint-security-baseline.txt` | eslint-plugin-security (WUI) | `do_sec_eslint`, wf 63 |
| `.shellcheck-warning-baseline.txt` | shellcheck WARNING level | `do_sec_shellcheck`, wf 67 |
| `.trivyignore.yaml` | trivy config (terraform) | `do_sec_scan` iac, wf 15 |
| `.gitleaks.toml` | gitleaks (secrets) | `do_sec_scan` secrets, wf 15 |
| `osv-scanner.toml` | OSV-Scanner (lockfiles) | wf 70 |
| `.hadolint.yaml` | hadolint (Dockerfiles) | `do_sec_hadolint`, wf 66 |
| `.zap/rules.tsv` | OWASP ZAP baseline (DAST) | wf 68 |
| `csi-spl-iac/src/terraform/.checkov.baseline` | checkov (terraform) | `do_sec_checkov`, wf 65 |

The list lives in one place: `_BG_FILES` in
`csi-spl-iac/src/bash/run/check-baseline-growth.func.sh`.

## 2. A new entry names its ticket

`cd csi-spl-iac && ./run -a do_check_baseline_growth` (10 ci job
`baseline-growth`) compares each file at a fixed anchor commit (origin/master
when the gate landed, so the entries already there stay as they are) with
HEAD. A changed block that adds an entry passes only when one of its added
lines carries `SPL-<n>`:

- on the entry itself, as a trailing comment:
  `G402|internal/x/y.go|1  # SPL-1234 test-only TLS client`; the count gates
  read the row with its comment, and a regenerate (`*_WRITE_BASELINE=1`)
  keeps the comment while the row stays;
- or on a comment line right beside it: `# SPL-1234: why this is accepted`.

A count that goes down, a deleted row, a moved row and a comment-only change
pass. The checkov baseline is JSON and has no comments, so a new check id
there needs `SPL-<n>` in the message of a commit that touched the file.

Test, with its red controls (a planted row without a ticket fails, naming the
file and line): `csi-spl-iac/src/bash/tests/check-baseline-growth.tst.sh`.

## 3. The gitleaks allow-list

`.gitleaks.toml` adds no rule of its own (gitleaks default rules, `useDefault =
true`). Its allow-list holds exact values, each with a comment that says what
it is:

- five **test-only fixtures**: made-up plaintexts (`not-a-key`,
  `secret-key-bytes-not-a-real-key`, ...) in unit tests. They are not a
  pattern to copy: a real key, token or password never goes in a test, a doc
  or this list, it goes in Secret Manager;
- two **public identifiers** in cnf: Stripe publishable keys and the LinkedIn
  OAuth Client ID, public by their provider's design;
- one **doc phrase** (`LANE_MIX_KIND=secret`), anchored to that text.

A real credential still fails: the gate's control plants an AKIA key in a
throwaway repo and requires gitleaks to exit 1.

## 4. Released images are pinned by digest

Same action 10: "Pin production images to sha256 digests instead of the
floating stable-YYYY-MM-DD tag".

- Production here is Cloud Run, which deploys the hub by an immutable minted
  tag (`v<X.Y.Z>`, `do_deploy_hub`), never by a `stable-*` tag. The
  `stable-*` tags name the images self-hosters pull: the root
  `docker-compose.yml`.
- Its defaults name the newest stable release with each image's digest:
  `spool-hub:${SPOOL_IMAGE_TAG:-stable-<date>@sha256:<hub>}`, and
  `spool-web` with its own. A tag pushed again cannot change what runs.
  Setting `SPOOL_IMAGE_TAG` replaces tag and digest together, so a chosen tag
  never pulls a stale digest.
- A build cannot tag a name that holds a digest, so a build names a local
  tag: `SPOOL_IMAGE_TAG=local docker compose up --build -d` (wf 50 runs it
  so).
- The release writes the digests: wf 56 pushes the two images, then writes
  `spool-images.txt` (one `<repo>/spool-{hub,web}:<tag>@sha256:<digest>`
  line each) to its run summary and onto the stable release.
- Moving the pin to a new release is a named action, then an ordinary
  commit: `cd csi-spl-orc && PIN_TAG=stable-<date> DRY_RUN=0 ./run -a
  do_pin_compose_images`. Tests: `pin-compose-images.tst.sh` (orc),
  `compose-pulls-images.tst.sh` (iac).

## 5. Compose services run as a named non-root user

Owner security scan, revised list, action 2: "Add explicit non-root
user/group to every compose service." Issue SPL-2154, epic SPL-2151.

- Every service of every tracked compose file (the root `docker-compose.yml`
  and `csi-spl-orc/src/docker/docker-compose-*.yaml`) sets `user:`, and it
  is not root. Where the image already had a `USER`, the compose file now
  states it: the hub `10001:10001`, the backup job `postgres`, the tf infra
  stack `${UID}:${GID}` (the APPUSR its Dockerfiles create). Postgres runs as
  `postgres` and SeaweedFS as `seaweed` from their first process on, with no
  root start followed by a privilege drop. The lde GCS emulator runs as
  `65534:65534`.
- The standalone web image (`csi-spl-wui/src/docker/wui.Dockerfile`) runs as
  uid 10002, which owns `/srv` (where `config.json` is written at start) and
  Caddy's `/data` and `/config`. The caddy binary keeps
  `cap_net_bind_service`, so the image still binds 80 and 443.
- A volume that an older root container left root-owned gets a one-shot
  `*-volume-owner` service. It chowns only what is not yet owned by the
  service's uid, with `CHOWN` + `DAC_READ_SEARCH` only and no network:
  `gcs-volume-owner` (lde `gcs-data`) and `web-volume-owner` (standalone
  `web-data`).
- A service that must start as root is a row of `.compose-root-allow.tsv`
  (`<file> TAB <service> TAB <reason>`): the two volume owners, the vault
  `pg` (gocryptfs mounts FUSE, then the postgres entrypoint drops to
  postgres), the local hub's `wui-generate` (on the rootless dockerd,
  container root is the stack's own host user), and the standalone `web`
  until the pinned release image carries the new `USER`. Once
  `do_pin_compose_images` pins such a release, `web` gets
  `user: "10002:10002"` and its row goes.

Test, with its red controls (a planted `user: "0:0"`, a service with no user
and a `${X:-0}` each fail): `csi-spl-iac/src/bash/tests/compose-non-root.tst.sh`.
A row naming no service, or with no reason, also fails.

## 6. Compose services sit on one named bridge network

Owner security scan, revised list, action 3: "Define a custom bridge network
and attach all services." Issue SPL-2155, epic SPL-2151.

- The standalone `docker-compose.yml` declares the bridge network `spool`
  (compose names it `spool_spool`); `pg`, `s3`, `hub-init`, `hub` and `web`
  join it with `networks: [spool]`, and the service names keep resolving on
  it. `web-volume-owner` stays on `network_mode: none`. Only `web` publishes
  host ports (`${SPOOL_BIND:-127.0.0.1}`, 8080 and 8443); pg, s3 and the hub
  are reached by name only.
- The lde stack (`csi-spl-orc/src/docker/docker-compose-*.yaml`, loaded
  together by `lde_compose` and the local hub's extra files) declares `lde`
  with `driver: bridge` in `docker-compose-infra.yaml`; every service joins
  it, now also `wui-install`. `gcs-volume-owner` stays on `network_mode:
  none`.
- The tf infra stack keeps the external `all_lcl_docker`, which
  `make do-create-network` creates with `--driver bridge`.
- No stack has a service on compose's implicit `default` network.

Test, with its red controls (a service with no `networks:`, one on an
undeclared network, one on a non-bridge network, `network_mode: host` and a
declared `default` each fail):
`csi-spl-iac/src/bash/tests/compose-bridge-network.tst.sh`. Each tracked
compose file must belong to one of its stacks, and with docker present it
also checks the model `docker compose config` renders. It was red on
origin/master a255bb8c1 (20 FAIL).

## 7. Standalone services report their health

Owner security scan, revised list, action 4: "Add healthchecks to hub-init
and web." Issue SPL-2156, epic SPL-2151.

- `hub-init`, the one shot, writes the readiness file `init.ready` into its
  state dir as its last step and removes it at its start
  (`csi-spl-api/src/docker/hub-entrypoint.sh`), so a re-run that fails
  leaves none. Its healthcheck is `test -f /var/lib/spool/state/init.ready`.
  `hub` still starts only once `hub-init` has exited 0
  (`service_completed_successfully`). Once a container has exited, docker
  reports its health as `unhealthy` even after a passing check (measured:
  a plain alpine container with `--health-cmd true` read `healthy`, then
  `unhealthy` after its exit 0). So for the finished one shot read
  `docker compose ps -a`: `Exited (0)`. A hub image older than this check
  never writes the file, which nothing waits on.
- `web` (Caddy) is probed on its own port 80 with the busybox `wget` its
  `caddy:2-alpine` base already carries; nothing is installed for it. The
  plain-http default site answers `/config.json` (written by
  `wui-config.sh` at start) with 200; a site on your own domain answers
  plain http with its https redirect, 308. Either passes; any other status
  (a 404) or no listener fails. Unknown paths also get 200 (the SPA
  fallback), so the check proves Caddy serves the site, not that one file.
- Every long-running service of the root `docker-compose.yml` (pg, s3, hub,
  web) and `hub-init` has a healthcheck, and every `depends_on` waits for the
  right state: `service_completed_successfully` on a one shot,
  `service_healthy` on any other.

Test, with its red controls (a web with no healthcheck, a disabled hub-init
check and a `depends_on` on a one shot that only waits for it to start each
fail): `csi-spl-iac/src/bash/tests/compose-healthchecks.tst.sh`. The readiness
file: section 6 of `csi-spl-api/src/bash/tests/hub-entrypoint.tst.sh`.

## 8. Standalone secrets are Docker secret files

Owner security scan, revised list, action 1: "Migrate docker-compose secrets
from env vars to Docker secrets or GCP Secret Manager
(SPOOL_DB_SUPERUSER_PASSWORD, SPOOL_S3_SECRET_KEY, SPOOL_MAIL_SMTP_PASSWORD)."
Issue SPL-2158, epic SPL-2151. Built: the Docker secrets part, for the
standalone `docker-compose.yml`. Not built: the GCP Secret Manager part
(see the end of this section).

- The root `docker-compose.yml` declares three `secrets:`, each a file in
  `${SPOOL_SECRETS_DIR}`: `db_superuser_password`, `s3_secret_key` and
  `mail_smtp_password`. They are mounted under `/run/secrets` and read
  through `*_FILE` variables, so none of the three is in `.env`, in
  `docker compose config` or in `docker inspect`. Postgres reads
  `POSTGRES_PASSWORD_FILE` itself; hub-init reads
  `SPOOL_SUPERUSER_PASSWORD_FILE`, the hub `SPOOL_S3_SECRET_KEY_FILE` and
  `SPOOL_HUB_MAIL_SMTP_PASSWORD_FILE`.
- The hub reads a secret through `internal/secretfile.Lookup`
  (`csi-spl-api/src/go/spool-hub-api`): `<NAME>_FILE`, when set, wins over
  `<NAME>`; an unreadable file is an error naming the variable; with neither
  set the caller's existing check decides (the mail config's "must be set
  when SPOOL_HUB_MAIL_SMTP_USER is"). The plain env var stays for lde and
  Cloud Run. `hub-entrypoint.sh` does the same in shell (`file_env`).
- `csi-spl-api/src/docker/secret-env.sh` runs in front of the image's own
  entrypoint for `s3`, `hub-init` and `hub`. It exports `<NAME>` from
  `<NAME>_FILE`: SeaweedFS reads only `AWS_SECRET_ACCESS_KEY`, and a hub image
  older than SPL-2158 (the pinned `stable-2026-10-12`) reads only the plain
  variables. Both read the same file. Once `do_pin_compose_images` pins a
  release that carries SPL-2158, `hub-init` and `hub` can drop the shim.
- Unset, `SPOOL_SECRETS_DIR` is `csi-spl-api/src/docker/local-secrets`, the
  public local defaults (the former compose env defaults), so
  `docker compose up -d` still needs no setup on a laptop. Off localhost,
  hub-init refuses the default superuser password, as before.
  `do_spl_self_host_up` (csi-spl-orc) writes the three files to `./secrets`
  (git-ignored) and `SPOOL_SECRETS_DIR=./secrets` to `.env`. It moves a value
  an older run left in `.env` into its file unchanged. By hand: DEPLOY.md
  section 2.3.1.
- File modes: outside swarm, compose bind-mounts a secret file as it is and
  ignores `uid`, `gid` and `mode`. Measured on docker 26.1.5 / compose 2.26.1
  (n=1): a 0600 file owned by the host user was `Permission denied` for
  container uid 10001; a 0644 file in a 0700 dir was read. So the files are
  0644 in a 0700 directory. A missing file stops `up` with `bind source path
  does not exist`.
- The self-host secret checks follow the files: `do_spl_secrets_check` and
  `do_spl_secrets_seed_all` under `SPOOL_CLOUD_PROVIDER=none`, and
  `do_spl_m3_e2e` (its IMAP password). A key still in `.env` is `MOVED`, and
  a secrets dir other than 700 is `MODE`.

Tests, with their red controls: `csi-spl-iac/src/bash/tests/compose-secrets.tst.sh`
(no plain secret env var, every `*_FILE` mounted and declared, the default
files, `./secrets` ignored, the shim; 9 FAIL on the compose file before this
change), `internal/secretfile`, `TestS3SecretKeyFile`,
`TestMailSMTPPasswordFile`, `TestNoneS3SecretByFile`, section 7 of
`hub-entrypoint.tst.sh`, and the orc `secrets-none`, `self-host-up` and
`m3-e2e-none` tests.

GCP Secret Manager, not built (it needs the owner's go): the Cloud Run hub
already takes `SPOOL_HUB_MAIL_SMTP_PASSWORD` from Secret Manager
(terraform step 030 `secret_environment_variables`), and Cloud Run has no
compose S3 or Postgres superuser. Mounting those as files instead of env vars
would be a step 030 change (a `volumes` secret mount plus the `*_FILE` env
var), applied to dev, then prd, under the owner's go for each apply.
