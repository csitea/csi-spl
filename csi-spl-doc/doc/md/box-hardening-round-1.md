# Box hardening, security round 1: sshd, exposed ports, swarm, dormant user

SPL-1960. Rows 2, 3 and 10 of the first security round. Each one is a named
action with a dry run. Nothing changes on a box until the owner approves a
`DRY_RUN=0` run in the session.

| row | action | what it changes |
|---|---|---|
| 2 | `do_spl_sshd_harden` | sshd: keys only, no root login |
| 3 | `do_spl_box_ports_loopback` | container ports published on every interface -> `127.0.0.1` |
| 3 | `do_spl_docker_swarm_leave` | leaves a docker swarm that nothing uses (:2377, :7946) |
| 10 | `do_spl_dormant_user_revoke` | a dormant user loses its sudoers grant and supplementary groups |

All four run from `csi-spl-orc` as `./run -a <action>`, dry run by default,
`DRY_RUN=0` to apply. They reach root through `sudo -n` unless they run as
root.

## 1. sshd: keys only (row 2)

```bash
cd csi-spl-orc && ./run -a do_spl_sshd_harden
```

It writes one drop-in, `/etc/ssh/sshd_config.d/05-spl-sshd-harden.conf`,
with the four lines the satellite box already has (its `sshd -T`):
`PasswordAuthentication no`, `KbdInteractiveAuthentication no`,
`PermitRootLogin no`, `PubkeyAuthentication yes`.

sshd keeps the first value it reads for a keyword, and Debian's
`sshd_config` includes the drop-ins before its own lines, so `05-` wins over
the main file and every later drop-in. A `Match` block can still turn
passwords on for some users, so the check is not the file but `sshd -T`:
globally and per user (`-C user=<u>,...`), for root and for every user with a
login shell. Every `Match` line that turns passwords or root login back on
is named.

The dry run prints:

- the effective settings now;
- who keeps key login: `key login kept: user=<u> keys=<n>` (a login shell and
  at least one authorized key; keys are counted, never printed), who loses
  ssh (`no key: user=<u>`), and root, which is refused after the fix;
- the drop-in it would write.

It refuses when no non-root user would keep key login. On `DRY_RUN=0` the
order is: write the file, `sshd -t`, the `sshd -T` checks, and only then
`systemctl reload ssh`. A failed step removes the file again, so sshd keeps
its old config. Open sessions stay. A second run is unchanged and does not
reload.

Options: `SSHD_CONF`, `SSHD_CONF_D`, `SSHD_BIN`, `SSHD_RELOAD_CMD`,
`SSHD_SUDO`; the test also uses `SSHD_ARGS` and `SSHD_PASSWD_FILE`.

Test: `csi-spl-orc/src/bash/tests/spl-sshd-harden.tst.sh`. It runs the real
`sshd -t` and `sshd -T` on a sandbox config with a throwaway host key.

## 2. Container ports on loopback (row 3)

```bash
cd csi-spl-orc && ./run -a do_spl_box_ports_loopback
```

For each port in `PORTS_LOOPBACK` (default `5432 3333`) and each running
container that publishes it off loopback, the dry run names:

- the container, its compose file, compose project and service;
- the exact change, `<file>:<line>: <old>  ->  <new>`: the ports item gets a
  `127.0.0.1:` prefix, and its quoting, `${VAR}` and comment stay;
- the recreate verdict. The compose config rendered from the edited file
  (the caller's env plus the project's `.env`) must give the same container
  name, image, bind-mount sources and environment as the live container.
  Values are compared but only names are printed.

Why the verdict matters: a compose file that builds a name or a data path
from `${ORG}` or `${APP}` renders to another name and an empty data dir when
those variables are not set. A recreate would then start the database on a
new empty directory. Any difference refuses the recreate. Export the
project's variables, the ones its own launcher sets, and run again.

On `DRY_RUN=0`, for each container that passed: the old compose file is
copied to the undo dir (`PORTS_LOOPBACK_UNDO`), the one line is replaced, and
`docker compose -p <project> -f <file> --project-directory <wd> up -d --no-deps --no-build <service>`
recreates that one service. `docker port` must then show the port on
`127.0.0.1` only. If `up` fails, the old file goes back. A container that
compose did not start, or whose ports item cannot be found exactly once, is
named and left alone.

The compose files belong to other projects. The edit is in their working
trees, and their owners commit it.

Test: `csi-spl-orc/src/bash/tests/spl-box-ports-loopback.tst.sh` (fixture
compose files, a docker stub that renders them).

## 3. Docker swarm (row 3)

```bash
cd csi-spl-orc && ./run -a do_spl_docker_swarm_leave
```

The swarm counts as unused when this is its only node and it has no service,
no secret, no config and no swarm network except the default `ingress`. The
action prints each measure and what listens on :2377 and :7946. Any use
refuses the leave and names it. `DRY_RUN=0` runs `docker swarm leave --force`
(a single-node manager needs `--force`). It then checks that the state is
`inactive` and that nothing listens on the two ports. Standalone containers
are not restarted.

Test: `csi-spl-orc/src/bash/tests/spl-docker-swarm-leave.tst.sh`.

## 4. Dormant user (row 10)

```bash
cd csi-spl-orc && DORMANT_USER=<user> ./run -a do_spl_dormant_user_revoke
```

The user keeps its account, home, files and primary group, so nothing it owns
is orphaned. It loses its own sudoers grant files and its supplementary
groups.

First the action proves that nothing launches as the user. Each of these
refuses, and is named:

- a running process of the user, or its crontab;
- a line naming the user in any crontab, `cron.d`, `anacrontab`, systemd
  unit, or a sudoers file other than its own grant;
- a launcher script under `DORMANT_SCAN_DIRS` (default
  `/etc /usr/local /opt /home /root`): `sudo -u`, `su`, `runuser -u`,
  `setpriv --reuid` or `User=` with that user. Docs, logs, `.txt` notes,
  agent transcripts, editor history and `.json` files without an execute bit
  (spool messages) are skipped, because they quote commands but run none. An
  executable `.json` is still scanned. The user's own home is skipped too.

A dir the owner has reviewed and ruled out, for example an archived copy of
old tooling that nothing calls, goes in `DORMANT_SCAN_EXCLUDE`. Every run
prints it as `not scanned (...)`, so the exclusion is never silent.

It refuses root, a uid below 1000, the user running it, and the spool's agent
and box users. A sudoers file that also grants someone else is named and left
alone.

On `DRY_RUN=0`, each grant file is copied to the undo dir (`DORMANT_UNDO`,
mode 600) and removed. `visudo -c` must still pass, or the files go back.
Then `gpasswd -d` runs per group, and a `gpasswd -a` undo line is kept for
each. The run ends with a check: no sudoers line and no supplementary group
left for the user.

Test: `csi-spl-orc/src/bash/tests/spl-dormant-user-revoke.tst.sh`.
