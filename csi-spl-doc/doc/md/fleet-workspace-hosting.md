# Hosting a workspace on a fleet box

Spec [159](../../specs/159-byo-ai-keys/spec.md) section 5.2, row T3, with the
desk start checks of spec [127](../../specs/127-workspace-vendor-keys/spec.md)
section 5.3 (row X1). Owner HUM-10, Q-1 B (msg `2e9d03be`): a workspace's
seats may run on our fleet boxes, each workspace as its own OS user.

`<W>` is the workspace slug; `<base>` is cnf `env.box.fleet_workspace_base`.

## 1. What the action makes

`cd csi-spl-orc && ./run -a do_spl_fleet_ws_host` (dry run unless
`DRY_RUN=0`) makes, as root:

| path / thing | owner, mode | what it is |
|---|---|---|
| `<base>/<W>/` | root, 0755 | the workspace's base, the spec 108 shape |
| `<base>/<W>/claim` | root, 0644 | the slug: `spool join` declares the desk `dedicated` |
| `<base>/<W>/fleet-hosted` | root, 0644 | the marker: the desk guard runs the start checks |
| OS user `<workspace_user_prefix><W>` | system user | in its own group ONLY: no `-G`, no sudoers entry |
| `<base>/<W>/<W>/` with `spool/`, `state/` | the user, 0700 | its home, spool root and desk state |
| lingering (`loginctl enable-linger`) | | its tmpfs `/run/user/<uid>` exists with no login |

It then checks the user holds no root path (`id -nG` is its own group,
`sudo -l -U` lists nothing), empties the seat dir
`/run/user/<uid>/spool-seat` (spec 127 5.4) and starts the desk as that user:
`do_spl_desk_up` with `SPL_WS_BASE=<base>/<W>`. The first start enrols the
desk with a join token a workspace admin minted for this box
(`SPOOL_JOIN_TOKEN_FILE`, one use, spec 073); the token goes on stdin, never
on a command line, and is never printed. It then sits only in the
environment of W's own `do_spl_desk_up` process (`SPOOL_JOIN_TOKEN`, which
desk-up unsets before it starts the desk), readable by W and root alone
(hidepid).

A box enrolled into one workspace (spec 108 claim) is not a fleet box: the
action refuses it (exit 3). The fleet's agent user (`SPOOL_AGENT_USER`) is
never the workspace's user.

## 2. The desk start checks

`spl_box_ws_guard` runs them on every desk action of a fleet-hosted
workspace (the marker), and the desk refuses to start when one fails
(`csi-spl-orc/lib/bash/funcs/spl-desk-start-checks.func.sh`):

| check | passes when |
|---|---|
| groups | no workspace OS user (`<workspace_user_prefix>*`) and not the desk's user is in `sudo`, `wheel`, `admin`, `docker`, `lxd` or `disk` |
| sudoers | `sudo -n -l` as the desk's user: "may not run sudo" |
| hidepid | `/proc` mounted `hidepid=2` (or `invisible`), no `gid=` of a group of the desk's user |
| ptrace | `kernel.yama.ptrace_scope >= 2` |
| dumpable | `fs.suid_dumpable = 0`; `kernel.core_pattern` a file path or systemd-coredump |
| swap | none, zram or dm-crypt only |
| runtime | `/run/user/<uid>` is tmpfs, 0700, the desk's user |

The one exception (spec 159 5.2): the fleet's agent user and other non-workspace
users may be root-equivalent on a fleet box. A spec 108 workspace box (no
marker) runs no start check, as before.

What it means: any fleet lane that uses sudo can still read the workspace's
keys on that box (spec 159 5.4, the risk the owner accepted).

## 3. Running it on a real box

The first `DRY_RUN=0` on each box needs the owner's go for that box (spec 159
12.2): `OWNER_GO=<owner msg id>` is required, and the action refuses
without it. Lanes never run it; they send the line to the dispatch lease
holder.

```
cd csi-spl-orc && ENV=<env> TENANT_ID=<W> DESK_BOX=<box id> DESK_AGENT=<agent id> SPOOL_JOIN_TOKEN_FILE=<file> OWNER_GO=<msg id> DRY_RUN=0 ./run -a do_spl_fleet_ws_host
```

Not measured yet, for that first run: the workspace user reading the orc tree
the desk runs from, and the checks on a real fleet box (row T2 measures them).

## 4. Not built here

Spec 127 X1's desk socket (`SO_PEERCRED`), the lease client, the seal open, the
`apiKeyHelper` answers from the held lease and the outbound redaction need the
hub's lease route and the box X25519 key (127 H2), which do not exist yet.

## 5. Tests

`csi-spl-orc/src/bash/tests/fleet-ws-host.tst.sh`: the desk starts as `<W>` on a
fixture fleet box; `<W>`'s user in `sudo` or `docker`, `/proc` without
`hidepid`, and each other check -> refused, each with its control; the action's
plan, its refusals and that no token is printed.
