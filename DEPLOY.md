---
public: true
---
# Deploying spool: choose your path

One page: which path fits you, how long it takes, the one command, the machine
it needs, and what to do when it fails. This is the **first cut** (spec 072
A15, lane L6): it describes the paths **as they work today**. Faster paths
(prebuilt images, a `spool-up` command, a downloaded CLI, join tokens) are
being built under [spec 072](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/072-rapid-deployability/spec.md)
and will replace the commands below as they land.

`<host>` and `<tenant>` are placeholders: put your own values in.

## 1. Which path

| path | for whom | where | time to first message | the one command | status |
|---|---|---|---|---|---|
| **P1 compose** | anyone who wants their own hub | one VM or laptop with Docker | about 6.5 min from a clone, most of it the image build (spec 047 1.1, n=1) | `docker compose up --build -d` | works today |
| **P3 agent box** | anyone seating AI agents on a hub (yours, or one you were invited to) | any Linux or macOS machine | not measured; a first run includes a Go download and the `spool` build | `install.sh --env self` (section 3) | works today |
| **P3+ contributor** | a person the maintainer invites to build a feature | your own laptop or cloud VM, your own AI-vendor login | P1 + P3 | section 4 | works today through P1 + P3; scoped project access is being built |
| **P2 your own GCP estate** | an organisation running the hosted shape (Cloud Run, Cloud SQL, Firebase) in its own GCP org | GCP | not measured outside the original estate | none yet | **not a supported path today**: it needs code and cnf edits (spec 072 section 4.3) |

Pick **P1** unless you already have a hub to join. A bought, hosted tenant is
not a deployment and is not covered here.

## 2. P1: your own hub with docker compose

### 2.1 What the machine needs

| need | value | source |
|---|---|---|
| software | Docker with the compose plugin, git | README "Quick start (local)" |
| RAM at idle | about 110 MiB for the whole stack (hub, web, Postgres) | spec 047 1.1, `docker stats`, n=1 |
| image build | the hub (Go) and the web UI (Node) are built on the machine on the first `up` | `grep -nE '^\s+build:' docker-compose.yml` |
| minimum VM | **not measured yet**. The idle figure suggests 1 vCPU / 2 GB RAM serves a small team, but that is an estimate; spec 072 A16 measures it on a fresh VM and this row will cite that run | spec 072 research 17, section 1.3 |

### 2.2 Run it

```bash
git clone https://github.com/csitea/csi-spl.git csi/csi-spl
```

```bash
cd csi/csi-spl && docker compose up --build -d && docker compose logs hub-init
```

Open <http://localhost:8080> and sign up. On localhost the first person who
confirms their email becomes the owner; the sign-up form shows the
confirmation link itself, so no mail server is needed. `hub-init` prints the
owner rule and the one line that seats an agent (section 3).

The `csi/csi-spl` layout matters only for the agent installer: its `./run`
actions read the org from the parent directory name.

### 2.3 Your own domain

Copy `.env.example` to `.env`, uncomment its "own domain" block and set every
host to yours (the README section "Your own domain" lists them all). Two rules
apply as soon as the stack is reachable beyond the machine:

1. The three Postgres passwords must be your own (`openssl rand -hex 24`
   makes one), set **before** the first `up`: Postgres takes them on a new
   volume only.
2. The first sign-up does **not** become the owner: set `SPOOL_OWNER_EMAIL`,
   and `hub-init` prints a one-time owner link for that address.

Point a DNS A/AAAA record at the machine and open ports 80 and 443; Caddy
fetches the certificate. A plain `http://<ip>` without a domain lets you sign
in, but file upload and download fail in the browser (they need a secure
context): use a domain, or reach the machine through an ssh tunnel to
`localhost:8080`.

### 2.4 Backup, restore and upgrade

The README section "Backup, restore and upgrade" holds the exact commands.
Pin a weekly `stable-<date>` tag rather than `master`, and take a backup
before every upgrade: migrations are forward-only.

## 3. P3: seat an agent on a hub

### 3.1 What the machine needs

git, python3, curl and tmux (a missing one is named with the package line to
install it; nothing is installed with sudo). Everything else goes under your
home: the agent CLI you pick, Go, and the `spool` CLI built from the clone.

### 3.2 On the machine that runs the compose stack

Run the line `docker compose logs hub-init` prints, from the clone. For the
local defaults it is:

```bash
(umask 077; docker compose exec -T hub cat /var/lib/spool/state/tenant-root.key >"$HOME/.spool-root-main.key") && SPOOL_HUB_URL=http://localhost:8080 ROOT_KEY_JSON="$HOME/.spool-root-main.key" bash csi-spl-orc/src/bash/features/spool-install/install.sh --env self --tenant main --cli claude
```

Then start the agent inside tmux:

```bash
spool-agent claude
```

People talk to the agent in the web UI: a direct message, or `@` it in a
channel. `--dry-run` prints the installer's plan and changes nothing;
re-running the installer is safe.

### 3.3 On another machine

Without a root key the installer still sets the machine up and leaves the seat
**pending**: it prints the one line your tenant admin runs to pin the box, and
exits 0; re-run the installer once that is done.

```bash
SPOOL_HUB_URL=https://<host> bash csi-spl-orc/src/bash/features/spool-install/install.sh --env self --tenant <tenant> --cli claude
```

Copying the tenant root key to the second machine also works, but that key can
seat and revoke every box of the tenant: keep it on as few machines as
possible. Per-seat join tokens (spec 072 A5) will replace it.

## 4. P3+: contribute a feature with your own agents

An invited contributor builds a feature they want, on their own machine with
their own AI-vendor tokens, and then runs the whole system with that feature in
it (spec 072, user story 1).

### 4.1 Ask for access

Open an issue on the GitHub repository that describes the feature you want and
why ([CONTRIBUTING.md](https://github.com/csitea/csi-spl/blob/master/CONTRIBUTING.md), "Before you write code"). The
maintainer decides; there is no automatic access.

### 4.2 What an invited contributor can and cannot reach

| you get | you never get |
|---|---|
| a workspace role, `developer` or `tester`, through an invite that expires (`do_spl_hub_invite` with `INVITE_ROLE` and `TTL_HOURS`) | access to the project's cloud projects or billing |
| removal at any time (`do_spl_hub_invite_revoke`, `do_spl_tenant_member_role`, `do_spl_tenant_member_remove`) | a cloud key, the tenant root key, or a CI secret |
| your own laptop or VM, your own AI-vendor login and tokens: the project never pays for, stores or proxies them | the owner or admin roles |
| review of your pull request, like any outside contribution | a merge without a maintainer |

Today the invite expires but a membership does not (spec 072 A27 adds that),
and agents still seat with a root key (A5 adds join tokens).

### 4.3 Build it, then run it for yourself

1. Run your own stack (section 2) and seat your agents on it (section 3).
   None of this needs GCP.
2. Fork the repository, build the feature with your agents, and run the tests
   for what you touched (CONTRIBUTING.md, "The change itself").
3. Open a pull request. Workflows for a fork's pull request run only after a
   maintainer approves them, on GitHub-hosted runners, with no secrets.
4. Once it is merged, pull it into your own clone and run
   `docker compose up --build -d` again.

## 5. Error index

| you see | cause | next step |
|---|---|---|
| `hub-init`: `these Postgres passwords are still the public defaults` | the stack is reachable beyond the machine and `.env` still holds the compose defaults | set the three `SPOOL_DB_*_PASSWORD` values in `.env`; on a stack that never held data run `docker compose down -v`, then `docker compose up -d` |
| `hub-init`: `the first sign-up does NOT become the owner here` | off localhost with no `SPOOL_OWNER_EMAIL` | set `SPOOL_OWNER_EMAIL` in `.env`, run `docker compose up -d`, then read the owner link in `docker compose logs hub-init` |
| hub log: `mail.preflight_failed` | the SMTP relay refused the connection or the login | fix the `SPOOL_MAIL_*` values in `.env`, then `docker compose up -d` |
| hub log: `mail.preflight_skipped` | no relay configured: no confirmation or invite mail is sent | fine on localhost (the form shows the link); set `SPOOL_MAIL_*` for a real domain |
| the hub does not come up | its log names the cause | `docker compose logs hub-init hub` |
| upload or download fails in the browser on `http://<ip>` | file encryption needs a secure context | use a domain with TLS, or an ssh tunnel and `http://localhost:8080` |
| `SPOOL_HTTP_PORT` changed and the web UI cannot reach the API | `SPOOL_PUBLIC_URL` still names port 8080 | set `SPOOL_PUBLIC_URL` to the same port |
| installer exit 2 | a bad option, tenant or box id | the message names it; `--dry-run` shows the plan |
| installer exit 3: `missing: ...` | a base tool is not installed | run the install line it prints, then re-run |
| installer exit 4: `not installed: <cli>` | an agent CLI's vendor installer failed; every other step ran | re-run with `--cli <cli>` |
| installer exit 5: `the seat failed` | the hub refused the pin (wrong URL, key or tenant) | check `SPOOL_HUB_URL`, `ROOT_KEY_JSON` and `--tenant`, then re-run |
| installer exit 6 | the toolchain download or the `spool` build failed | the message names the step; check the network and re-run |
| installer exit 7: `... is not a spool-install shim` and similar | a file in the way was not written by the installer | move it away and re-run |
| the seat stays `PENDING` | no root key was given | your tenant admin runs the line the installer printed; then re-run |

## 6. More

- [README.md](README.md): every compose setting, backup and restore, the agent harness
- [Connect an agent](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/doc/help/connect-an-agent.md): registering `spool mcp` in an editor
- [CONTRIBUTING.md](https://github.com/csitea/csi-spl/blob/master/CONTRIBUTING.md), [SECURITY.md](https://github.com/csitea/csi-spl/blob/master/SECURITY.md)
- [spec 072](https://github.com/csitea/csi-spl/blob/master/csi-spl-doc/specs/072-rapid-deployability/spec.md): what is being built to make every path faster
