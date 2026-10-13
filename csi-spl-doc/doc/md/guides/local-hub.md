# Local Spool-Hub Operator Guide

This guide covers the installation, operation, lifecycle management, backup, restore, upgrade, and security model of a fully self-contained local spool-hub on Debian. The local hub runs entirely in Docker containers (hub API, PostgreSQL, static Web UI, GCS emulator, and backup service) with a dedicated local database, loopback-only network bindings (`127.0.0.1`), rootless Docker execution under a dedicated unprivileged user, and zero cloud dependencies.

This document is maintained as plain Markdown (`csi-spl-doc/doc/md/guides/local-hub.md`) until a dedicated workspace doctree seat and folder are assigned for Qto import via `do_spl_doctree_import_md`.

## 1. Overview and architecture

### 1.1 Core components

The local spool-hub architecture provides a private, isolated spool instance with no reliance on external Google Cloud Platform services (no Cloud SQL, Cloud Run, Firebase Hosting, or GCS buckets). All workloads run as Docker containers orchestrated via Docker Compose:

| Component | Container Service | Role | Network Binding |
|---|---|---|---|
| Spool Hub API | `hub` | Core Go API server handling messages, topics, leases, and authentication | `127.0.0.1:58180` |
| Web UI | `wui-static` | Static asset server (Caddy) serving the pre-generated Nuxt 3 bundle with same-origin API proxy | `127.0.0.1:3180` |
| UI Builder | `wui-generate` | One-shot builder producing static distribution into named volume `wui-dist` | Internal volume |
| Database | `pg` | PostgreSQL database with encrypted-at-rest storage volume via gocryptfs FUSE mount | `127.0.0.1:55532` |
| Object Storage | `gcs` | Local fake-gcs-server emulator for attachments and objects | `127.0.0.1:54543` |
| Backup Service | `backup` | Periodic automated `pg_dump` worker encrypting archives with `age` | Internal network |

### 1.2 Dedicated unprivileged user

To isolate container volumes, sockets, and configuration from general host users and AI agent processes, the local hub runs under a dedicated locked-down system user:

- **Username:** `LOCAL_HUB_USER` (default: `spl-hub`).
- **Home directory:** `LOCAL_HUB_HOME` (default: `/var/lib/spl-hub`).
- **Permissions:** The home directory and all child directories are strictly mode `0700`, accessible exclusively by the dedicated user.
- **Group isolation:** General host users and AI agents are not members of the `spl-hub` group.

### 1.3 Rootless Docker execution

On standard Debian installations, membership in the system `docker` group grants root-equivalent control over the host. To prevent host users in the `docker` group from inspecting, mounting, or executing commands inside the local hub containers:

- The dedicated user runs its own isolated rootless Docker daemon (`dockerd-rootless`).
- Container state, rootless sockets, and volumes reside inside the user's private runtime directory (`/run/user/<uid>/docker.sock`) and home directory (`$LOCAL_HUB_HOME/.local/share/docker`).
- Container root (`uid 0` inside the container) maps to the unprivileged host user (`spl-hub`), preventing container breakout or unauthorized host access.

### 1.4 Network isolation and loopback bindings

All service ports are strictly bound to IPv4 loopback (`127.0.0.1`):

- `hub`: `127.0.0.1:58180`
- `wui`: `127.0.0.1:3180`
- `pg`: `127.0.0.1:55532`
- `gcs`: `127.0.0.1:54543`

The local hub never binds to `0.0.0.0` or external network interfaces. No public DNS records, TLS certificates, or Certificate Transparency entries are ever created. Access from external devices requires a secure private network tunnel (such as WireGuard or an SSH tunnel) configured by the operator.

### 1.5 Database volume encryption at rest

The PostgreSQL database storage volume is encrypted at rest using `gocryptfs` inside the database container:

- The physical Docker volume (`pg-data`) contains only encrypted ciphertext blocks.
- At startup, the database container waits for the operator to supply the encryption passphrase via `do_spl_local_hub_unlock`.
- The decrypted filesystem is mounted via FUSE inside the container's rootless user namespace at `PGDATA` (`/var/lib/postgresql/data`).
- The encryption passphrase is read interactively from the operator's terminal over standard input and is never written to disk, passed in command-line arguments, recorded in environment variables, or logged.

### 1.6 Private configuration outside git

Because the repository is public, all instance-specific identity and workspace details live outside version control:

- **Config file:** `$LOCAL_HUB_HOME/.config/csi-spl/local-hub.env` (mode `0600`).
- **Workspace key:** `LOCAL_HUB_TENANT=<workspace-id>` (no default value exists in the codebase).
- **Identity:** Operator credentials and owner email addresses are stored only in this private file or within the local database.

## 2. The trust caveat

### 2.1 The isolation boundary

The local hub hardening measures create a robust barrier against ambient access, unintended inspection, and unprivileged processes:

1. Rootless Docker ensures that members of the host's `docker` group cannot execute `docker exec` against the database or mount local hub volumes.
2. Mode `0700` permissions on `$LOCAL_HUB_HOME` prevent non-root users from listing or reading local configuration, keys, or logs.
3. Database volume encryption protects data at rest if the host drive is unmounted, copied, or inspected while the stack is stopped.

### 2.2 Sudo access on the host

Operators must understand the fundamental trust boundary when hosting on a shared machine:

> [!WARNING]
> Users on the host with passwordless `sudo` privileges (including host developer accounts with passwordless sudo access) possess root privileges. Because root can assume any user identity (`sudo -u spl-hub`) and inspect process memory or kernel mounts, any user or AI agent with sudo access can technically access local hub data while the instance is unlocked.

The local hardening prevents accidental reads, background search indexing, and ambient tool sweeps, but cannot prevent intentional inspection by a process with host root privileges.

### 2.3 At-rest versus in-memory security

While the PostgreSQL container is running and unlocked:

- The plaintext database pages reside in host RAM and inside the active FUSE mount.
- Stopping the stack (`do_spl_local_hub_down`) immediately unmounts the FUSE filesystem, reverting the stored database volume to unreadable ciphertext.

### 2.4 Deployment recommendation

For sensitive private workspaces requiring total isolation:

- **Recommended:** Deploy the local hub on a dedicated Debian machine or virtual machine where only the human operator has user accounts and `sudo` access.
- **Shared box:** If deployed on a multi-user or AI-assisted development machine, maintain awareness that host root access encompasses container access.

## 3. Host prerequisites and installation

### 3.1 Operating system requirements

- Debian 12 (Bookworm) or Debian 13 (Trixie).
- Linux kernel supporting user namespaces (`CONFIG_USER_NS=y`, default in Debian).
- FUSE support (`/dev/fuse` accessible to user sessions).

### 3.2 Required software packages

Install the base container tools and rootless prerequisites:

```bash
sudo apt-get update && sudo apt-get install -y \
  docker-ce docker-ce-cli containerd.io \
  docker-buildx-plugin docker-compose-plugin \
  docker-ce-rootless-extras uidmap dbus-user-session \
  fuse3 age git curl jq
```

### 3.3 Automated host installation

The host setup action `do_spl_local_hub_install` automates user creation, subuid allocations, and rootless daemon initialization:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && sudo ./run -a do_spl_local_hub_install
```

This action performs the following tasks:

1. Creates the system user `spl-hub` with home directory `/var/lib/spl-hub` (mode `0700`).
2. Configures subordinate UID and GID ranges in `/etc/subuid` and `/etc/subgid` (e.g. `spl-hub:100000:65536`).
3. Enables systemd user lingering via `loginctl enable-linger spl-hub` so the user's services run without an active login session.
4. Initializes the rootless Docker daemon for `spl-hub`.
5. Prepares the long-lived repository clone at `/var/lib/spl-hub/csi-spl`.

### 3.4 Manual host configuration

If configuring the host manually without `do_spl_local_hub_install`:

```bash
# 1. Create system user
sudo useradd -r -m -d /var/lib/spl-hub -s /bin/bash spl-hub
sudo chmod 0700 /var/lib/spl-hub

# 2. Assign subordinate IDs if not automatically allocated
grep -q "^spl-hub:" /etc/subuid || echo "spl-hub:100000:65536" | sudo tee -a /etc/subuid
grep -q "^spl-hub:" /etc/subgid || echo "spl-hub:100000:65536" | sudo tee -a /etc/subgid

# 3. Enable lingering
sudo loginctl enable-linger spl-hub

# 4. Initialize rootless dockerd as spl-hub
sudo -u spl-hub -H dockerd-rootless-setuptool.sh install

# 5. Clone repository
sudo -u spl-hub git clone https://github.com/csitea/csi-spl.git /var/lib/spl-hub/csi-spl
```

### 3.5 Private environment configuration

Create the private configuration file for the instance:

```bash
sudo -u spl-hub mkdir -p /var/lib/spl-hub/.config/csi-spl
sudo -u spl-hub tee /var/lib/spl-hub/.config/csi-spl/local-hub.env > /dev/null << 'EOF'
LOCAL_HUB_TENANT=my-private-workspace
LOCAL_HUB_HUB_PORT=58180
LOCAL_HUB_WUI_PORT=3180
LOCAL_HUB_PG_PORT=55532
LOCAL_HUB_GCS_PORT=54543
EOF
sudo chmod 0600 /var/lib/spl-hub/.config/csi-spl/local-hub.env
```

## 4. Lifecycle management

### 4.1 Starting the local hub

To bring up the entire stack:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub ./run -a do_spl_local_hub_up
```

The startup sequence executes in strict dependency order:

1. **Hardening check:** Runs `do_spl_local_hub_harden_check` to verify rootless daemon isolation and loopback configuration. If any check fails, startup aborts.
2. **PostgreSQL startup:** Starts the `pg` container and prepares the encrypted volume mount.
3. **Vault unlock:** Invokes `do_spl_local_hub_unlock`, prompting the operator to type the encryption passphrase.
4. **Database migrations:** Executes database migrations against the unlocked PostgreSQL instance.
5. **Web UI compilation:** Compiles the static distribution via `wui-generate` into volume `wui-dist`.
6. **Service startup:** Starts `hub`, `wui-static`, `gcs`, and `backup` services.
7. **Health verification:** Polls `http://127.0.0.1:58180/healthz` until the hub reports healthy.

### 4.2 Database unlocking

When prompted by the startup process (or when unlocking a running container after a daemon restart), provide the database passphrase:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub ./run -a do_spl_local_hub_unlock
```

The passphrase prompt uses silent terminal input (`read -rs`), ensuring no characters or echoes appear in terminal scrollback or shell histories.

### 4.3 Verifying status and the ports gate

Verify container status and network boundaries using `do_spl_local_hub_status`:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub ./run -a do_spl_local_hub_status
```

This command runs:

- `docker compose -p spl-local-hub ps` to display active containers.
- The loopback ports gate (`do_spl_local_hub_ports_gate` / `ss -ltnp`), asserting that all listening ports match `127.0.0.1` and no ports are exposed externally.
- API health check verification.

### 4.4 Stopping the local hub

To shut down the instance cleanly:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub ./run -a do_spl_local_hub_down
```

This stops all running compose services. The database FUSE mount unmounts immediately, locking all on-disk data. Named Docker volumes (`pg-data`, `wui-dist`) are preserved across stops.

## 5. Owner provisioning and access

### 5.1 Closed registration security model

Unlike public or shared hub environments, the local hub strictly disables public self-registration:

- `SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS=false`: No authentication tokens are ever returned in API response bodies.
- `SPOOL_HUB_MAIL_TRANSPORT=none`: No verification emails are dispatched.
- `SPOOL_HUB_AUTH_BOOTSTRAP_OWNER=false`: No unauthenticated first-come ownership race is permitted.
- `SPOOL_HUB_AUTH_PROVIDERS=""`: Third-party OAuth and social login providers are disabled.

Any public HTTP attempt to call the `/api/v1/auth/register` endpoint returns HTTP 503 `mail_unavailable`. Sign-up is closed by construction.

### 5.2 Initial owner account creation

The workspace owner is provisioned directly through the local operator CLI, bypassing network registration:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub ./run -a do_spl_local_hub_owner_add
```

1. Enter the desired owner email address and display name.
2. Enter the account password twice when prompted on the terminal.
3. The action executes `spool hub-provision-member` within the container, creating a pre-verified user with the `biz_owner` role.

### 5.3 Accessing the Web UI

Once provisioned, access the Web UI from a browser running on the host:

1. Navigate to: `http://localhost:3180` (or `http://127.0.0.1:3180`).
2. Log in using the provisioned email address and password.
3. All UI requests communicate directly with the local hub via the same-origin proxy, ensuring no external network requests are made.

## 6. Agent participation on request

### 6.1 Least privilege for agents

To protect private workspace data from broad agent access:

- No agent desks or seats are created by default.
- Background reconcile loops and fleet desk monitors ignore the local hub.
- Agents can only connect if explicitly issued a one-time join token by the workspace owner.

### 6.2 Generating join credentials

The workspace owner generates a desk join token from the Web UI or via the operator CLI:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub \
  docker compose -p spl-local-hub exec -T hub spool hub-desk-token --tenant <workspace-id> > /tmp/join-token.txt
chmod 0600 /tmp/join-token.txt
```

### 6.3 Joining an agent desk

When an AI agent is requested to perform work in the private workspace, it connects using `do_spl_local_hub_agent_join`:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && sudo -u <agent-user> \
  env LOCAL_HUB_JOIN_TOKEN_FILE=/tmp/join-token.txt \
      LOCAL_HUB_TENANT=<workspace-id> \
      ./run -a do_spl_local_hub_agent_join
```

- The join action enforces loopback-only hub URLs (`http://127.0.0.1:58180`).
- Desk state and cryptographic keys are isolated in `$HOME/.local/share/csi-spl/local-hub`.
- Once consumed, the temporary token file should be shredded (`shred -u /tmp/join-token.txt`).

### 6.4 Leaving the local hub

When the agent's task is completed, remove the agent seat:

```bash
cd /opt/csi/csi-spl/csi-spl-orc && sudo -u <agent-user> \
  env LOCAL_HUB_TENANT=<workspace-id> \
  ./run -a do_spl_local_hub_agent_leave
```

This unseats the agent, terminates the local desk sidecar, and deletes local session credentials. Future access requires a newly minted join token.

## 7. Backup and disaster recovery

### 7.1 Automated daily backups

The local hub includes a containerized backup service running on an automated daily schedule:

- Executes `pg_dump` against the local PostgreSQL container.
- Streams the SQL dump through `age` encryption using the owner's recipient public key.
- Stores the encrypted archive (`backup-YYYY-MM-DDTHHMMSSZ.sql.age`) in `/var/lib/spl-hub/backups` (mode `0700`).
- Rotates old backups according to retention policies.

### 7.2 On-demand manual backups

To trigger an immediate backup:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub ./run -a do_spl_local_hub_backup
```

The resulting encrypted archive is placed in `$LOCAL_HUB_HOME/backups/`. The private key required to decrypt the archive must be kept securely off-box or protected with a passphrase.

### 7.3 Restoring from backup

To restore a database backup archive:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub \
  env BACKUP_FILE=/var/lib/spl-hub/backups/backup-<timestamp>.sql.age \
  ./run -a do_spl_local_hub_restore
```

The restore procedure enforces safety checks:

1. Prompts the operator for the `age` decryption key or passphrase.
2. Restores the decrypted archive into an isolated scratch database first.
3. Validates database schema integrity and message row counts in the scratch database.
4. With operator confirmation, switches the active database to the restored copy.

## 8. Updates and maintenance

### 8.1 Software updates

To update the local spool-hub software to a newer version of the repository:

```bash
cd /var/lib/spl-hub/csi-spl/csi-spl-orc && sudo -u spl-hub ./run -a do_spl_local_hub_update
```

The update action safely performs the following sequence:

1. Performs `git fetch origin master` and `git merge --ff-only origin/master` in the long-lived clone.
2. Checks for updated Docker image references and pulls new images.
3. Automatically triggers `do_spl_local_hub_up`, which applies any pending database migrations and rebuilds static UI assets.
4. Runs `do_spl_local_hub_status` to ensure all services and loopback ports remain healthy.

### 8.2 Log inspection and monitoring

Inspect service logs via Docker Compose without exposing outputs to external monitoring:

```bash
# Follow logs for all services
sudo -u spl-hub docker compose -p spl-local-hub -f /var/lib/spl-hub/csi-spl/csi-spl-orc/src/docker/docker-compose-local-hub.yaml logs -f

# Inspect hub API logs specifically
sudo -u spl-hub docker compose -p spl-local-hub logs -f hub

# Inspect rootless daemon systemd logs
sudo -u spl-hub journalctl --user -u docker.service -f
```

### 8.3 Troubleshooting common issues

#### 8.3.1 Rootless Docker daemon fails to start

Verify that subordinate UID and GID ranges are properly mapped and that lingering is enabled:

```bash
loginctl show-user spl-hub | grep Linger
cat /etc/subuid | grep spl-hub
```

#### 8.3.2 Database fails to mount or unlock

Ensure that the FUSE device `/dev/fuse` is accessible and that the `fuse3` package is installed on the host. If an incorrect passphrase was entered during `do_spl_local_hub_unlock`, re-run the unlock action.

#### 8.3.3 Port conflicts on loopback interface

If startup fails with `bind: address already in use`, verify whether another service is occupying the configured loopback ports:

```bash
sudo ss -ltnp | grep -E ':(58180|3180|55532|54543)\b'
```
Modify port assignments in `/var/lib/spl-hub/.config/csi-spl/local-hub.env` if required.
