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

## 4. The desk key socket (spec 127 X1)

`spool hub-run` started with `SPOOL_KEY_DESK=1` also runs the desk's key
socket (`csi-spl-api/src/go/spool-hub-api/internal/keydesk`, wired in
`cmd/spool/key_desk.go`). Without that variable nothing changes, so the
fleet's own desks are as before. The seat side is `spool key-exec` and
`spool key-helper` (spec 159 9.1).

| part | what it does |
|---|---|
| socket | `<spool root>/.hub/key.sock`, mode 0600. A seat's launcher passes this path as `$SPOOL_KEY_SOCK`. One JSON line each way: `lease`, `helper`, `exhausted`, `redact` (the package comment has the wire) |
| caller check | `SO_PEERCRED`: only the desk's own uid, and no process in `sudo`, `wheel`, `admin`, `docker`, `lxd` or `disk`. Any other caller gets nothing back, not even an error |
| lease | a seat start (`lease`) gets the lease the desk holds, else a new one from the hub (`POST /v1/vendor-keys/<kind>/lease`). The hub's token passes through as it is (`box_not_approved`, `no_key`, `key_exhausted`) |
| seal | the hub's answer is age-sealed to the desk's X25519 key, `<spool root>/.hub/desk-x25519.key` (0600, made on the first start). Its plaintext names the kind and the box, and the desk refuses one that names another (`bad_seal`). The key stays in memory only |
| helper | claude's `apiKeyHelper` (`helper`) is answered from the held lease only, never with a new hub lease; with none held it is refused `no_lease` |
| TTL | a held lease lives `SPOOL_KEY_LEASE_TTL` (default `15m`), or the hub's shorter TTL |
| exhausted | `exhausted <kind>` drops the held lease, refuses that kind for one TTL and reports it to the hub |
| seat dirs | `SPOOL_SEAT_ROOT` (default `/run/user/<uid>/spool-seat`) is emptied at desk start. Every 30 s the desk removes a seat dir whose leasing wrapper is gone (pid and start time), and an unleased dir after 10 min |
| redaction | every `spool send` on that box root asks the socket to replace each key the desk handed out with `[vendor key removed]` before any copy is written. The terminal mirror posts through `spool send`, so it is covered. A key socket that is there but does not answer refuses the send |

Not live yet: the hub's lease and exhausted routes and the X25519 field
in the join payload are spec 127 H2's. Until H2 lands, a lease is refused
`no_lease_route` (404), and the desk logs its public recipient at start
for H2 to register. Ending a revoked kind's running seats within one TTL
also needs H2's answer, and is not built.

### 4.1 core_pattern, measured

Spec 127 5.3 left open whether a piped `core_pattern` collector honours
the wrapper's hard core limit of 0.

| measure | command -> result |
|---|---|
| this box's pattern | `cat /proc/sys/kernel/core_pattern /proc/sys/fs/suid_dumpable` -> `core`, `0` |
| the satellite's pattern | the same over ssh -> `core`, `0`; no `coredumpctl` on either box |
| a file pattern | `ulimit -Hc 0` then a self-abort -> exit 134, 0 core files; with `unlimited` (the control) -> 1 core file |

2026-10-27, n = 1 each. Neither fleet box uses a piped pattern, so the
piped case does not arise on them today. Its behaviour is still
unmeasured: measuring it needs a box change. The desk start checks
(section 2) keep refusing any pattern that is neither a file path nor
systemd-coredump.

## 5. Tests

`csi-spl-orc/src/bash/tests/fleet-ws-host.tst.sh`: the desk starts as `<W>` on a
fixture fleet box; `<W>`'s user in `sudo` or `docker`, `/proc` without
`hidepid`, and each other check -> refused, each with its control; the action's
plan, its refusals and that no token is printed.

The key socket, with its red controls: `internal/keydesk/keydesk_test.go`
(a peer of another uid gets nothing, the helper with no lease is refused,
a handed-out key is redacted, a dead seat's dir is swept);
`internal/hubclient/vendor_key_lease_test.go` (a `spool send` body with the
key reaches no file of the spool root; a dead key socket refuses the send);
`cmd/spool/key_desk_test.go` (off by default).
