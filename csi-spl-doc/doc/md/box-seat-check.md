# Box seat check: a fleet box against the workspace seat start checks

SPL-3706, [spec 159](../../specs/159-byo-ai-keys/spec.md) row T2. Before a
workspace's seats run on a fleet box as the workspace's own OS user (spec
159 5.2, owner Q-1 B), the box must pass the desk start checks of
[spec 127](../../specs/127-workspace-vendor-keys/spec.md) 5.3 that spec 159
5.2 keeps. This action measures a box against them and reports which fail.

It is **read only**: it reads `/proc`, `/sys` and the mount table as the
calling user, with no sudo, and changes nothing on any box. A fix it calls
for is a separate owner go per box (spec 159 12.2). Its first run on a real
box also waits for the owner's go, relayed by the dispatch lease holder.

## 1. Run it

### 1.1 This machine

```bash
cd csi-spl-orc && ./run -a do_spl_box_seat_check
```

### 1.2 Several boxes over ssh

`local` is this machine; any other box id is reached over ssh at
`BOX_SSH_<BOX>` (upper case, `-` as `_`), else at the box id itself.

```bash
cd csi-spl-orc && BOX_SEAT_CHECK_BOXES="local,<BOX>" BOX_SSH_<BOX>=<ssh-alias> ./run -a do_spl_box_seat_check
```

## 2. The checks

| check | passes when | spec 127 |
|---|---|---|
| `hidepid` | `/proc` is mounted `hidepid=2` (shown as `invisible` on newer kernels) | 5.3, L21 of 159 |
| `ptrace` | `kernel.yama.ptrace_scope` >= 2 | 5.3 |
| `suid_dumpable` | `fs.suid_dumpable` = 0 | 5.3, L7 |
| `core_pattern` | a file path, or a pipe to systemd-coredump | 5.3, L7 |
| `swap` | no swap, or only dm-crypt (`CRYPT-` uuid) or zram | 5.3, L13 |
| `tmpfs` | the runtime dir `/run/user/<uid>` of the box user sits on tmpfs | 5.4 |

Not measured here: "no OS user is root-equivalent", which spec 159 5.2
exempts on a fleet box, and the workspace OS user's own checks, which exist
only once T3 creates that user.

## 3. The output

One row per box and check, `box=<b> check=<c> verdict=pass|fail
detail=<d>`, then one line per box: clean, or the list of failing checks.
An unreachable box is a `check=reach verdict=fail` row, and the next box is
still measured. The run exits 0 only when every box is clean.

## 4. The test

`csi-spl-orc/src/bash/tests/spl-box-seat-check.tst.sh` runs on fake box
roots (`SEAT_CHECK_ROOT`), never the real `/proc`. Its red control: a fake
box with plain swap on is reported failing on `swap` (127 L13); the same box
without swap is reported clean. Each other check is planted bad once, and a
stub ssh drives two boxes and an unreachable one.
