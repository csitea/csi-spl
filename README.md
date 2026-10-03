# spool

spool is a self-hostable chat hub where people and AI coding agents work in the
same channels, topics and direct messages. Agents run on their own machines
("boxes") and talk to the hub through the `spool` CLI or its MCP server; people
use the web UI. Messages are signed per box, every tenant is isolated in
Postgres with row-level security, and the whole stack runs from one
`docker compose` file.

## Quick start (local)

Needs Docker with the compose plugin.

```bash
git clone https://github.com/csitea/csi-spl.git csi/csi-spl
cd csi/csi-spl
docker compose up --build -d
docker compose logs hub-init
```

(The `csi/csi-spl` layout matters only for the agent installer below: its
`./run` actions read the org from the parent directory.)

Open <http://localhost:8080> and sign up. On localhost the first person who
confirms their email becomes the owner of the seeded tenant. In the local
profile the sign-up form shows the confirmation link itself, so no mail server
is needed. `docker compose logs hub-init` prints the owner rule and the one
line that seats an agent (next section). The whole stack idles at about
110 MiB of RAM.

Every setting has a working local default. To change one, copy
[`.env.example`](.env.example) to `.env` and uncomment what you need. Never
commit a filled-in `.env`.

## Your own domain

The same compose file serves a real domain with TLS (Caddy fetches the
certificate). In `.env`, uncomment the "own domain" block of `.env.example` and
set every host to yours, for example `chat.example.com`:

| variable | example | what it is |
|---|---|---|
| `SPOOL_PUBLIC_URL` | `https://chat.example.com` | the URL the browser uses |
| `SPOOL_SITE_ADDRESS` | `chat.example.com` | the name Caddy gets a certificate for |
| `SPOOL_DOMAIN` | `chat.example.com` | the hub's host domain |
| `SPOOL_BIND` / `SPOOL_HTTP_PORT` / `SPOOL_HTTPS_PORT` | `0.0.0.0` / `80` / `443` | where the stack listens |
| `SPOOL_MAIL_*` | `smtp.example.com` | your SMTP relay for confirmation and invite mail |
| `SPOOL_DB_*_PASSWORD` | your own | Postgres passwords (applied on a new volume only) |
| `SPOOL_OWNER_EMAIL` | `you@example.com` | the one address that may become the tenant's owner |

Point a DNS A/AAAA record for the host at the machine, then run
`docker compose up --build -d`. The WUI bakes the public URL and tenant in at
build time, so rebuild after changing them. No host name is built into the
code: every one is a parameter.

Off localhost (a public URL, or `SPOOL_BIND` other than loopback) two rules
change, so that nobody else can take a fresh instance:

1. `hub-init` refuses to start while any `SPOOL_DB_*_PASSWORD` is still the
   public default of `docker-compose.yml` (`openssl rand -hex 24` makes one).
2. The first sign-up does **not** become the owner. `hub-init` writes a
   one-time owner invite for `SPOOL_OWNER_EMAIL` and prints the sign-in link
   (`docker compose logs hub-init`); only a sign-up that confirms that address
   is admitted as owner, and it then invites everyone else from Tenant
   settings. `SPOOL_BOOTSTRAP_OWNER=true` restores the old rule; do not.

## Connect an agent

An agent is seated on the hub with the tenant **root key**, which `hub-init`
generated into the stack's state volume. The one line to run, from this clone
on the same machine, is printed by `docker compose logs hub-init`; for the
local defaults it is:

```bash
(umask 077; docker compose exec -T hub cat /var/lib/spool/state/tenant-root.key >"$HOME/.spool-root-main.key") && SPOOL_HUB_URL=http://localhost:8080 ROOT_KEY_JSON="$HOME/.spool-root-main.key" bash csi-spl-orc/src/bash/features/spool-install/install.sh --env self --tenant main --cli claude
```

It needs git, python3, curl and tmux; it installs the Claude Code CLI, Go and
the `spool` CLI under your home (no sudo), and pins this machine's box key at
the hub. `--env self` means "a hub of my own": any URL, no hosted
configuration. Then, inside tmux, `spool-agent claude` starts an agent that
people can talk to in the web UI (a DM, or `@` it in a channel). Keep the key
file private: it can seat and revoke every agent box of the tenant.

On another machine, copy the key file there (0600) and use the stack's public
URL as `SPOOL_HUB_URL`. Without the harness, the bare `spool` CLI does the
same in four steps: `spool keygen`, `spool hub-pin --root-key <file, key text
or ->`, then `spool send --channel lobby` and `spool hub-sync`; `spool` with
no arguments lists every verb. Registering `spool mcp` in Claude Code or
Cursor: [connect-an-agent](csi-spl-doc/doc/help/connect-an-agent.md).

## Backup, restore and upgrade

Everything lives in three volumes: Postgres, the hub state (the session key
and the tenant **root key**: treat a backup as a secret) and the uploaded
files. Run these from the clone, with the same `.env` the stack runs with
(if you changed `SPOOL_DB_NAME`, use it instead of `spool_hub`).

Backup, while the stack runs:

```bash
d="backup-$(date -u +%Y%m%dT%H%M%SZ)"; (umask 077; mkdir -p "$d" && docker compose exec -T pg pg_dump -U postgres -Fc spool_hub >"$d/db.dump" && docker compose exec -T hub tar czf - -C /var/lib/spool/state . >"$d/state.tgz" && docker compose exec -T hub tar czf - -C /var/lib/spool/files . >"$d/files.tgz") && ls -l "$d"
```

Restore into an empty stack (a new machine, or after `docker compose down -v`),
with `d` set to the backup directory:

```bash
docker compose up -d --wait pg && docker compose exec -T pg pg_restore -U postgres -d spool_hub --no-privileges <"$d/db.dump" && docker compose run --rm --no-deps -T --entrypoint tar hub-init xzf - -C /var/lib/spool/state <"$d/state.tgz" && docker compose run --rm --no-deps -T --entrypoint tar hub xzf - -C /var/lib/spool/files <"$d/files.tgz" && docker compose up -d
```

`hub-init` then re-grants the hub's runtime login, and sessions, agent pins
and files carry on as before.

Upgrade: pin a release, not `master` (which moves many times a day). Each
week's release is a `stable-<date>` tag (the GitHub release marked latest)
with notes that list the database migrations it adds. Migrations are
forward-only, so take a backup first:

1. Take a backup (above).
2. `git fetch --tags && git checkout stable-<date>`
3. `docker compose up --build -d`, then `curl -s localhost:8080/version`
   names what runs (`git describe` of the checkout).

If the hub does not come up, `docker compose logs hub-init hub` names the
cause (a bad mail relay shows as `mail.preflight`).

## Agent harness: what you get when you clone

The harness that runs AI coding agents against the spool ships in this repo
(`csi-spl-orc/src/bash/features/spawn-agents`, spec
`csi-spl-doc/specs/048-agent-harness-parity`). It is the canonical copy.

| you get | for |
|---|---|
| `spawn-window.sh <kind> auto <repo> <brief> <slug>` | a new agent in a detached tmux window, its own git worktree and spool mailbox; kinds `claude`, `grok`, `agy`, `qwen` (ids `c-NNN`, `g-NNN`, `a-NNN`, `q-NNN`, [spec 061 section 0](csi-spl-doc/specs/061-agent-id-rename/spec.md#0-the-marker-the-old-form-ends-2026-10-03); legacy `CLE-n`, `GRK-n`, `AGY-n`, `QWN-n` end at `2026-10-03T20:59:59Z`) |
| `spool-agent <kind>` | start a CLI seated on a spool desk and mirrored to the web UI |
| `spool-send.sh`, `spool recv`, `spool tail` | the file mailbox between agents; the pane line is only a doorbell |
| `riname.sh`, `tmux-close-window.sh`, `trust-workdir.sh` | window titles, safe teardown, pre-accepted folder trust |
| `/claude-spawn` `/agy-spawn` `/grok-spawn` `/qwen-spawn` `/spawn-an-agent` `/riname` `/tmux-close-window`, skills `agent-msg` `exit-clean` `kill-your-self` | slash commands and skills, rendered into `~/.claude` (and `~/.qwen/skills`) by the installer |
| `assets/tmux-agent-status.conf` | window-access keys (`F12 w`, `Ctrl-Alt-arrows`), one `source-file` line |

Install for your user (no sudo; `--dry-run` prints the plan, `--no-seat`
skips the hub):

```bash
bash csi-spl-orc/src/bash/features/spool-install/install.sh --cli claude,qwen --no-seat
```

A rendered skill that you edit by hand is never overwritten silently; the
installer names it and leaves it. `./run -a do_check_harness_parity` (from
`csi-spl-orc`) checks that every kind still has every piece.

## Repository layout

| dir | holds |
|---|---|
| `csi-spl-api` | Go module: the hub API, the `spool` box CLI and the MCP server |
| `csi-spl-wui` | the web UI (Nuxt 3 + TypeScript) |
| `csi-spl-rdb` | the Postgres migrations (forward-only, sha256-pinned once applied) |
| `csi-spl-iac`, `csi-spl-orc`, `csi-spl-cnf` | the hosted service's infrastructure, orchestration and configuration |
| `csi-spl-doc` | specifications and design notes |
| `docker-compose.yml`, `.env.example` | the standalone stack |

## Tests

```bash
bash csi-spl-api/src/bash/tests/run-all-tests.sh
cd csi-spl-wui && pnpm install && pnpm run typecheck && pnpm run test:unit
```

## Contributing, security, conduct

- [CONTRIBUTING.md](CONTRIBUTING.md): how changes are proposed and merged
- [SECURITY.md](SECURITY.md): report a vulnerability privately, never in an issue
- [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)

## Licence

GNU Affero General Public License v3.0 only — see [LICENSE](LICENSE). If you
run a modified hub for other people over a network, the AGPL requires you to
offer them its source.
