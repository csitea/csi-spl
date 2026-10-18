# Local Spool-Hub Operator Guide

> Generated from qto doc `1504f548-1174-499b-83d8-c8bd170afcd5`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

This guide installs and runs a private, self-contained spool-hub on one Debian
box: the hub, Postgres, the generated Web UI and a GCS emulator, all in Docker,
with a local database and no cloud dependency. Nothing listens beyond
`127.0.0.1`, no DNS name or TLS certificate exists, and no data leaves the box.

Every command below runs from `csi-spl-orc` in any checkout of the repository,
as an operator who may `sudo` to the hub user. Each `./run` action re-runs
itself as the hub user in that user's own long-lived clone, so the operator
never needs a shell as the hub user.

<a id="ws-doc-7fd78285-01de-4bc3-96ab-3a0603b1eede"></a>
## 1. What runs

<a id="ws-doc-5c2f2ded-ee12-4a1c-88b1-2324e1042ce1"></a>
### 1.1 Services

All of them run in one Docker Compose project on the hub user's rootless
daemon. The ports are cnf `env.lde.local_hub` in
`csi-spl-cnf/csi-spl/lde.env.yaml`.

| Service | Role | Bound to |
|---|---|---|
| `hub` | the spool hub API | `127.0.0.1:58180` |
| `wui-static` | the generated Web UI, same-origin proxy to the hub | `127.0.0.1:3180` |
| `pg` | Postgres, data encrypted at rest | `127.0.0.1:55532` |
| `gcs` | GCS emulator for attachments | `127.0.0.1:54543` |
| `wui-generate` | one-shot build of the Web UI bundle | no port |

<a id="ws-doc-94bd4cbd-ef40-4d5e-b7c8-77472b8b2057"></a>
### 1.2 The hub user

One dedicated system user owns the instance (cnf `user`, default `spl-hub`;
home cnf `home`, default `/var/lib/spl-hub`):

- no login shell, in no `docker`, `sudo`, `wheel`, `adm` or `root` group, alone in its own group;
- home owned by it, mode `0700`; the long-lived clone is `<home>/csi-spl`;
- its own rootless Docker daemon at `/run/user/<uid>/docker.sock`, with every volume under its home, so members of the system `docker` group never reach the data.

<a id="ws-doc-95e5853b-5641-45fb-82d3-6924d7e00547"></a>
### 1.3 The encrypted database

The `pg` volume holds ciphertext only (gocryptfs inside the container).
Postgres starts locked; the owner types the passphrase on the terminal during
`do_spl_local_hub_up`. The passphrase is read from the terminal only, never
from an env var, an argument, a file or a pipe, and is never stored or logged.
Every restart of `pg` starts locked again.

<a id="ws-doc-0b1e4907-76c2-4dad-bb53-f95524bad32d"></a>
### 1.4 The private config, outside git

The repository is public, so the workspace name lives only in the hub user's
private config `<home>/.config/csi-spl/local-hub.env` (owned by the hub user,
mode `0600`). It accepts exactly two keys; any other key is refused:

- `LOCAL_HUB_TENANT`: the workspace slug, `^[a-z0-9][a-z0-9-]{0,31}$`;
- `LOCAL_HUB_OWNER_EMAIL`: the owner's sign-in email.

<a id="ws-doc-f6999de1-6720-41cb-abe7-c53b16b64d65"></a>
## 2. The trust caveat

The lock-down stops accidental reads: other users' processes, backup and
search sweeps, and anyone in the `docker` group. It does not stop root.

- Anyone with `sudo` on the box is root, can become the hub user, and can read the data while the database is unlocked. On a shared box that includes every agent user with `sudo`.
- While `pg` runs unlocked, the plaintext lives in RAM and in the container's FUSE view. `do_spl_local_hub_down` locks it again.
- For data that root on this box must not see, run the local hub on a box or VM where only the owner has an account and `sudo`.

<a id="ws-doc-588ff153-fc26-47ac-b5cb-ab6fd3721ac5"></a>
## 3. Installation

<a id="ws-doc-02e23c5b-a06e-4d9c-b201-24a26850cd66"></a>
### 3.1 Host packages

Docker is the only host tool; Postgres, gocryptfs and the Web UI build live in
the containers. `do_spl_local_hub_install` refuses to start when one of these
is missing and names the package:

```bash
sudo apt-get install -y docker-ce docker-compose-plugin docker-ce-rootless-extras uidmap slirp4netns iproute2 systemd
```

Docker CE comes from Docker's own apt repository. The kernel needs user
namespaces and `/dev/fuse`, both present on a stock Debian 12 or 13.

<a id="ws-doc-ccd22708-2456-4841-93d4-643ae3496648"></a>
### 3.2 Create the hub user and its rootless daemon

The one step that needs root. Run it first as a dry run, which prints every
root command and changes nothing:

```bash
./run -a do_spl_local_hub_install
```

Then apply it:

```bash
DRY_RUN=0 ./run -a do_spl_local_hub_install
```

It creates the system user and its `0700` home, a subuid and subgid range,
linger, and the user's rootless `dockerd`, then checks that the daemon is
rootless with its data under the home. It is idempotent. It reports, but never
changes, the firewall: the `127.0.0.1` binds are the gate.

<a id="ws-doc-0e0a555b-07d6-46a9-b8f9-dcfedbf110e0"></a>
### 3.3 Write the private config

Create the config directory:

```bash
sudo -u spl-hub mkdir -p -m 700 /var/lib/spl-hub/.config/csi-spl
```

Write the file. The command waits for input; type the two lines, then press
Ctrl-D. Typing them here keeps the workspace name out of the shell history:

```bash
sudo -u spl-hub sh -c 'umask 077; cat > /var/lib/spl-hub/.config/csi-spl/local-hub.env'
```

The two lines are:

```text
LOCAL_HUB_TENANT=<workspace>
LOCAL_HUB_OWNER_EMAIL=<owner email>
```

<a id="ws-doc-0534e645-ff57-47bd-8987-767b6b8a6e2c"></a>
### 3.4 First start

Clone the long-lived tree and bring the stack up, on the owner's terminal:

```bash
./run -a do_spl_local_hub_update
```

The first run clones the public repository over https into
`/var/lib/spl-hub/csi-spl` as the hub user, then runs
`do_spl_local_hub_up`. On a new database it asks for a new passphrase twice
(at least 16 characters). Keep it safe: without it the data cannot be read,
and nobody can reset it.

<a id="ws-doc-6d33f5db-0117-492f-87d8-064e30702be6"></a>
### 3.5 Seat the owner

Sign-up is closed: the hub has no mail transport and returns no debug tokens,
so every web registration answers 503. The owner's account is created from the
terminal. Check first (asks nothing):

```bash
./run -a do_spl_local_hub_owner_add
```

Then create it; it asks for a display name and the password twice, not shown:

```bash
DRY_RUN=0 ./run -a do_spl_local_hub_owner_add
```

It seats `LOCAL_HUB_OWNER_EMAIL` from the private config as the workspace's
owner, email pre-verified. A re-run keeps an existing password.

<a id="ws-doc-1fc09546-dfcb-41ce-a026-1112d74528bd"></a>
### 3.6 Sign in

Open `http://localhost:3180/` in a browser on the box and sign in with the
owner's email and password.

<a id="ws-doc-5112ec1c-a98f-4c01-96d8-f2b7ec90f4fa"></a>
## 4. Daily operation

<a id="ws-doc-c2007fab-76d5-4192-a6e4-5ba4b9fe2318"></a>
### 4.1 Start, also after a reboot

```bash
./run -a do_spl_local_hub_up
```

In order: render the env, run the hardening check (any FAIL stops it), build
the images, start Postgres and ask for the passphrase, start the GCS emulator,
migrate, run the hub smoke on the separate `smoke` workspace, create the
workspace once, generate the Web UI when the tree moved, serve it, and start
the daily backup job once its key exists (section 7.1).

<a id="ws-doc-9a415b0e-9373-4661-b092-e0941b0b41c0"></a>
### 4.2 Status and the ports gate

```bash
./run -a do_spl_local_hub_status
```

Lists the services and fails when one of them is not running, checks the hub
`/healthz` and the Web UI for 200, and fails when any listener of the hub user, or any listener on a local hub port,
is bound beyond loopback. The gate alone, as any user:

```bash
./run -a do_spl_local_hub_ports_gate
```

<a id="ws-doc-c9a1cb3e-0761-4258-a177-b0013097e396"></a>
### 4.3 The hardening check

`do_spl_local_hub_up` runs it every time. To run it alone:

```bash
sudo -u spl-hub -H bash -c 'cd /var/lib/spl-hub/csi-spl/csi-spl-orc && ./run -a do_spl_local_hub_harden_check'
```

One PASS or FAIL line per check: the hub user and its groups, the `0700` home,
subuid and subgid, linger, the rootless daemon and its data root, every
published port on loopback, a `hub.env` with no cloud credential and no
outside host, and no container process running as host root.

<a id="ws-doc-d7a4e169-d716-4bb0-8eba-6dc3b3248526"></a>
### 4.4 Stop

```bash
./run -a do_spl_local_hub_down
```

Stops every service; the database locks. The volumes are kept.

<a id="ws-doc-c9731673-6bd2-4bec-8045-c3cc69b7d05e"></a>
### 4.5 Remove everything

Deletes the workspace's data for good. Take a backup first (section 7):

```bash
LOCAL_HUB_PURGE=1 DRY_RUN=0 ./run -a do_spl_local_hub_down
```

<a id="ws-doc-d92a7504-4f57-4913-98bf-216926e46aec"></a>
## 5. The owner's account

<a id="ws-doc-a448f707-fe5f-4e4b-915a-240dd96a328b"></a>
### 5.1 Reset a forgotten owner password

The local hub sends no mail, so a reset link never arrives, and a re-run of
`owner_add` keeps the old password. Run these on the owner's terminal on the
box; a pipe, a file or a script is refused. Check what it will do (asks
nothing):

```bash
./run -a do_spl_local_hub_owner_reset
```

Reset it; it asks twice, then signs the owner out everywhere:

```bash
DRY_RUN=0 ./run -a do_spl_local_hub_owner_reset
```

Sign in again with the new password on `http://localhost:3180/`. If it says
no owner with a password is seated yet, seat the owner first (section 3.5).

<a id="ws-doc-27fd6f6b-2cdc-46d3-a9e8-fb80240dd4ab"></a>
### 5.2 The database passphrase

There is no reset for the database passphrase: it is the encryption key. A
lost passphrase means the data is restored from a backup into a new volume.

<a id="ws-doc-fa4761b0-fdd7-4169-a08e-68b82e05d09c"></a>
## 6. Agents on request

<a id="ws-doc-c0742394-124e-42ee-acf3-ce8f35a85d19"></a>
### 6.1 Admit an agent

No agent is seated on the local hub by default, and the fleet's own desk
actions never reach it. To admit one:

1. A workspace admin opens the local hub's **Settings -> Agents** and mints a join token for that agent.
2. On the box, save the token in a file only you can read (`chmod 600`).
3. Run the join; drop `DRY_RUN=0` to see the plan first.

```bash
LOCAL_HUB_TENANT=<workspace> DESK_AGENT=<agent id> LOCAL_HUB_JOIN_TOKEN_FILE=<file> DRY_RUN=0 ./run -a do_spl_local_hub_agent_join
```

Each agent gets its own box `lh-<agent>` and its own key, and serves one
workspace only. It talks to the hub on `127.0.0.1` only; a cloud hub URL is
refused.

<a id="ws-doc-d19bfccc-f2f8-4a7f-b1d4-c37fccea922b"></a>
### 6.2 Remove an agent

```bash
LOCAL_HUB_TENANT=<workspace> DESK_AGENT=<agent id> DRY_RUN=0 ./run -a do_spl_local_hub_agent_leave
```

Then revoke its seat in **Settings -> Agents**. Its inbox stays on disk under
`left/`; a new join needs a new token.

<a id="ws-doc-c796e9ca-41df-476b-bfb7-23d4870a08f3"></a>
## 7. Backup and restore

<a id="ws-doc-7a46b4ac-ecf1-4816-bf3b-fc4db8fc9e67"></a>
### 7.1 Make the backup key, once

Backups are encrypted with an age key pair. The job on the box holds only the
public half; the private half is wrapped with a passphrase and belongs off the
box. Until the key exists, `do_spl_local_hub_up` does not start the backup
job and says so on every start (`WARN no backup key yet`).

Make the key on the owner's terminal; it asks for a new passphrase twice:

```bash
./run -a do_spl_local_hub_backup_keygen
```

It writes `/var/lib/spl-hub/.config/csi-spl/backup-key/recipient` (the public
key) and `identity.age` (the wrapped private key) next to it. Copy the
private key off the box, for example to a USB stick:

```bash
sudo -u spl-hub cat /var/lib/spl-hub/.config/csi-spl/backup-key/identity.age > <off-box path>/identity.age
```

Then delete it from the box:

```bash
sudo -u spl-hub rm /var/lib/spl-hub/.config/csi-spl/backup-key/identity.age
```

Restart the stack so the daily job starts (section 4.1). Without the private
key and its passphrase no backup can be read: keep both, apart.

<a id="ws-doc-b6b20ff3-d4ae-4f1d-929a-3d5b85f4568d"></a>
### 7.2 The daily backup

Once a day at 03:15 UTC the job pipes `pg_dump` through age into the
`backups` volume; no clear dump touches the disk. It keeps the newest 14.
`LOCAL_HUB_BACKUP_AT` and `LOCAL_HUB_BACKUP_KEEP` change both. Check that the
key is in place:

```bash
./run -a do_spl_local_hub_backup_check
```

Take a backup now:

```bash
./run -a do_spl_local_hub_backup
```

List the backups:

```bash
./run -a do_spl_local_hub_backup_list
```

<a id="ws-doc-735882a8-7119-461f-93e6-3b802e01d8fb"></a>
### 7.3 Prove a backup restores

Restores the newest backup into a new scratch database, checks its table and
migration counts against the backup's record, then drops the scratch
database. The live data is not touched. It asks for the private key's
passphrase on the terminal:

```bash
LOCAL_HUB_BACKUP_IDENTITY_FILE=<off-box path>/identity.age ./run -a do_spl_local_hub_restore
```

`LOCAL_HUB_RESTORE_FILE=<backup name>` picks an older backup from the list.

<a id="ws-doc-8dd71f29-7d77-439d-b7ce-a37b043ac5ff"></a>
### 7.4 Restore over the live data

`LOCAL_HUB_RESTORE_LIVE=1` replaces the workspace's data with the backup. It
refuses while the hub runs and needs `LOCAL_HUB_RESTORE_CONFIRM` set to the
live database's name. Prove the backup first (section 7.3).

<a id="ws-doc-45d88234-d192-4770-991e-971edd7c2452"></a>
## 8. Updates

<a id="ws-doc-51e7ad55-bf60-4215-a312-d6e2a1d1f129"></a>
### 8.1 Update to the latest master

```bash
./run -a do_spl_local_hub_update
```

Fetches, fast-forwards the long-lived clone to `origin/master`, then runs
`do_spl_local_hub_up` from the updated code: new migrations apply and the Web
UI is regenerated. A clone with local edits cannot fast-forward and is
refused, never reset. To see what would change without changing anything:

```bash
DRY_RUN=1 ./run -a do_spl_local_hub_update
```

<a id="ws-doc-3a12db0a-1044-47fc-a974-683904291a58"></a>
## 9. Reaching it from another device

The local hub answers on the box only. The Web UI and the hub expect the
origin `http://localhost:3180`, so another device reaches it through a tunnel
that keeps that origin, for example an SSH port forward from the device:

```bash
ssh -N -L 3180:127.0.0.1:3180 <user>@<box>
```

Then open `http://localhost:3180/` on the device. A private network
(WireGuard, Tailscale) also works, but it changes the origin and needs a
matching cnf change; set it up only with the owner. Never publish a local hub
port on a public interface: the ports gate fails on it.

<a id="ws-doc-b0d7c038-1adf-478f-939a-7c3ec9942b7e"></a>
## 10. Troubleshooting

<a id="ws-doc-89fe3ebb-2dce-47bb-b23d-a8133b0626ed"></a>
### 10.1 Container logs

The containers belong to the hub user's rootless daemon, so the system
`docker` command does not list them. Follow the hub's log:

```bash
sudo -u spl-hub -H docker --host "unix:///run/user/$(id -u spl-hub)/docker.sock" logs -f spl-local-hub-hub-1
```

<a id="ws-doc-16235a13-2dea-4bba-bcb1-6accb787888c"></a>
### 10.2 The rootless daemon is down

Re-run the install; it is idempotent and restarts what is missing:

```bash
DRY_RUN=0 ./run -a do_spl_local_hub_install
```

<a id="ws-doc-eef11c9d-9a3f-4aa2-9ea5-aa7ee1de4073"></a>
### 10.3 A port is already in use

```bash
ss -ltnp 'sport = :58180 or sport = :3180 or sport = :55532 or sport = :54543'
```

The ports are cnf `env.lde.local_hub` (`hub_port`, `wui_port`, `pg_port`,
`gcs_port`); `LOCAL_HUB_*_PORT` env vars override them for one run.
