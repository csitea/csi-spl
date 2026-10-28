# Local dev mode: the whole spool on your own machine

For a developer who wants to run and change spool locally: the hub, the web
UI, Postgres, S3 storage and a mail catcher, started with one command, with
no cloud account and nothing sent off the machine. The design and its
decisions: [spec 148](../../specs/148-local-dev-mode/spec.md).

Self-hosting spool for real users is a different path:
[DEPLOY.md](../../../DEPLOY.md).

## 1. Start it

### 1.1 The one command

From a clone of the repository:

```bash
cd csi-spl-orc && ./run -a do_dev_mode_up
```

It runs in this order and stops at the first problem:

1. Refuses `SPOOL_HUB_ENV=dev` or `prd`: local dev mode runs public default
   secrets and a sign-in button with no password, so it runs only as `lde`.
2. Checks the prerequisites (`csi-spl-orc/src/bash/scripts/dev-preflight.sh`):
   Linux or macOS on x86_64 / arm64, git >= 2.30, a running Docker engine
   your user may use, Docker Compose >= 2.20, 5 GB free disk, 2 GB free RAM,
   and the four ports of section 1.3 free. A failed check prints one
   `ERROR:` line and the command that fixes it on your OS, and the action
   exits with the check's number (1..7).
3. Builds the hub and the web UI from your checkout and starts the `dev`
   profile of the root `docker-compose.yml`, then waits until every service
   is healthy (`docker compose --profile dev up -d --build --wait`). The
   first build takes several minutes; later ones reuse the cache.
4. Prints where the app and the mail inbox are.

Run it again after a code change: it rebuilds and restarts what changed.
`DEV_MODE_BUILD=0` pulls the published images instead of building; they
are older than the dev login, so the button of section 2.1 does not work
with them.

### 1.2 What runs

| service | what it is |
|---|---|
| `pg` | Postgres 16, the hub's database |
| `s3` | SeaweedFS, the S3 storage for uploaded files (bucket `spool-files`) |
| `hub-init` | one shot: migrations, the database logins, the session key and the workspace `main` |
| `hub` | the spool hub API, as `SPOOL_HUB_ENV=lde` |
| `web` | the web UI and the same-origin proxy to the hub |
| `mail` | Mailpit: catches every mail the hub sends |

### 1.3 Where things are

| what | address |
|---|---|
| the app | http://localhost:8080 |
| the mail inbox (Mailpit) | http://localhost:8025 |
| Mailpit's REST API | http://localhost:8025/api/v1/messages |
| SMTP into Mailpit | localhost:1025 |

Everything listens on 127.0.0.1 only. Port 8443 is also published (the web
container's https side) and is checked as free.

## 2. Sign in

### 2.1 The one-click dev login

On a fresh stack, open the app and press **Dev login** in the dev toolbar.
It signs you in as `dev-owner@spool.local`, the owner of workspace `main`
(`POST /api/v1/auth/dev-login`). It works only while the dev owner is the
first person to sign in: on a stack where someone else already claimed
`main`, it answers `dev_login_not_owner`; start from a fresh stack
(section 4.2).

The hub refuses the dev login anywhere but `SPOOL_HUB_ENV=lde`: it will not
start with the switch on in `dev` or `prd`, and the endpoint answers 404
there.

### 2.2 Email and password, with the mail in Mailpit

Every sign-in flow that needs no cloud identity provider works locally,
and each mail it sends lands in Mailpit:

- sign up, then confirm the email from the mail's link
- sign in with the password
- forgot password: the reset mail, then the new password signs you in
- change the password while signed in (the old session ends)
- invite a colleague to the workspace; they sign up and land in it
- a workspace admin resets a member's password (the member gets the mail)
- forgot password for an account that has no password (the dev owner):
  the mail says which sign-in to use instead
- switch workspace, sign out

Sign-in with Google, Microsoft, LinkedIn, Facebook or xAI needs a
registered cloud application and is out of scope here.

### 2.3 Prove every flow at once

```bash
bash csi-spl-orc/src/bash/tests/test-dev-mailpit-scenarios.tst.sh
```

It walks the flows of section 2.2 against the running stack through the
hub's API, reads each token from the mail in Mailpit's REST API (dev mode
turns the debug links off, so no API answer carries one), and prints one
PASS or FAIL line per step: 38 on a fresh stack. Start from a fresh stack
(section 4.2), so the dev login still owns `main`. Other ports:
`DEV_E2E_URL` and `DEV_E2E_MAIL_URL`. With no stack there it prints SKIP
and exits 0; `DEV_E2E_REQUIRE=1` turns that into a failure.

The hub's own rate floors still hold, per client IP and 15 minutes:

- 30 password sign-ins: about four runs; the fifth gets `429 rate_limited`
  until the window passes.
- one "sign in with ..." notice per address: a re-run inside the window
  sends none, and the test counts the earlier one.
- sign-up / confirm / forgot / reset: dev mode raises the hub's 10 to 100
  (`SPOOL_AUTH_FORM_PER_IP`).

## 3. Change a setting

Every value has a local default. To change one, copy `.env.example` to
`.env` at the repository root and set it there, or set it in the shell for
one run; the shell wins over `.env`, and `.env` over the default.

| variable | default | what it is |
|---|---|---|
| `SPOOL_HTTP_PORT` | 8080 | the app's port |
| `SPOOL_HTTPS_PORT` | 8443 | the web container's https port |
| `SPOOL_MAILPIT_UI_PORT` | 8025 | Mailpit's inbox and REST API |
| `SPOOL_MAILPIT_SMTP_PORT` | 1025 | Mailpit's SMTP port on the host |
| `SPOOL_MAIL_FROM` | spool@example.org | the sender of the hub's mail |
| `COMPOSE_PROJECT_NAME` | spool | run a second stack beside the first (with other ports) |

`do_dev_mode_up` sets the dev values itself (`SPOOL_HUB_ENV=lde`, the hub's
mail to Mailpit over SMTP without TLS, the dev login on, the dev toolbar on
with `SPOOL_ENV_NAME=lde`, the debug links off, the form limit at 100),
again only where neither the shell nor `.env` sets them. The block "local
dev mode" of `.env.example` lists them.

## 4. Stop it

### 4.1 Stop, keep the data

```bash
cd csi-spl-orc && ./run -a do_dev_mode_down
```

### 4.2 Stop and start fresh

```bash
cd csi-spl-orc && ./run -a do_dev_mode_down --purge
```

`--purge` also removes the volumes: the database, the uploaded files, the
session key. The next `do_dev_mode_up` starts from an empty workspace.

### 4.3 What is running

```bash
cd csi-spl-orc && DEV_MODE_CMD=status ./run -a do_dev_mode_ctl
```

## 5. When it does not work

| you see | do |
|---|---|
| `ERROR: Port 8080 is already bound` | stop what holds it (the fix line names the command), or set `SPOOL_HTTP_PORT` |
| `FATAL docker compose up failed` | `docker compose logs hub` (or `hub-init`, `web`) from the repository root names the cause |
| `dev_login_not_owner` | someone else signed in first: section 4.2 |
| no mail in Mailpit | `docker compose logs hub` shows the mail send; the hub starts only once its mail check reaches Mailpit |
| no Dev login button | the button shows only on a localhost address and on a stack started by `do_dev_mode_up` |

The code: `csi-spl-orc/src/bash/run/dev-mode-ctl.func.sh` (with
`dev-mode-up.func.sh` and `dev-mode-down.func.sh`), tested by
`csi-spl-orc/src/bash/tests/dev-mode-ctl.tst.sh`.
