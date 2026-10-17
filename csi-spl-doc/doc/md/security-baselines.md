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
