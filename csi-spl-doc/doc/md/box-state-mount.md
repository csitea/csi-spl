# The box state bucket as a folder

Owner, t1 151d85fc: "is there a technical mean by which the S3 bucket will be
seen as internal in the internal file system, so that regular commands such as
`cp` or `rsync` will be able to write to it?" (msg ef3d31e1), and "both the
writer and the read-only drives are mapped ... They will have a certain name
from the point of view of the Spool codebase" (msg ec950b4b).

The bucket is step 056's `csi-spl-<env>-box-state` (the nightly box backups,
`do_spl_box_state_backup`). Cloud Storage FUSE (`gcsfuse`) maps it to two
folders. The actions live in `csi-spl-orc`.

## 1. The two names

The code never writes a path. It calls `spl_box_state_mounts`
(`csi-spl-orc/lib/bash/funcs/spl-box-state-mounts.func.sh`) and uses:

| name | what it is | identity |
|---|---|---|
| `SPL_BOX_STATE_RO` | the whole bucket, read-only | the env's project SA, from its key file |
| `SPL_BOX_STATE_RW` | only `<rw_prefix>/` of the bucket (`shared/`), read-write | the box writer SA, impersonated by the project SA (no key) |
| `SPL_BOX_STATE_RW_PREFIX` | that prefix, `shared` | |

The folders are set in cnf `env.box.box_state_mount` (`ro_dir`, `rw_dir`,
`rw_prefix`). `~/` means the running user's `$HOME` and `%env%` means the env,
so the default is `~/mnt/box-state/dev/ro` and `~/mnt/box-state/dev/rw`.

Scripts read from `SPL_BOX_STATE_RO` and write to `SPL_BOX_STATE_RW`.

## 2. The backups stay immutable

The nightly backups live under `<box>/<date>/`. They are never under the RW
folder. The writer SA keeps its bucket-wide `objectCreator` right, which can add
a new object but cannot overwrite or delete one. Its read, write and delete
rights are an IAM condition on `shared/` only, set in step 056. Until that grant
is applied, the RW mount fails and names the missing grant; the RO mount and the
file actions below work without it.

Objects under `shared/` follow the bucket's lifecycle rule: they are deleted
after 30 days, like the backups.

## 3. Mount and unmount

1. Install gcsfuse once per box: `cd csi-spl-orc && DRY_RUN=0 ./run -a do_install_gcsfuse`
   (with no `DRY_RUN=0` it prints the plan).
2. Mount both folders: `ENV=dev ./run -a do_spl_box_state_mount`. Use `MOUNT=ro`
   or `MOUNT=rw` for one of them. A folder that is already mounted is left
   as it is.
3. Unmount: `ENV=dev ./run -a do_spl_box_state_unmount`.

A mount is made only when the action runs: there is no fstab entry and no
boot-time mount, so a mount can never block or slow a boot. The owner asked for
this in t1 151d85fc (msg c1748651). A failed mount logs a `FAIL` line and
changes nothing else. The gcsfuse log (warnings only) is
`<state dir>/gcsfuse-<env>-<ro|rw>.log`.

## 4. Without the mount

These four call `gcloud storage` directly, which is faster than going through
the mount. They work whether or not the bucket is mounted. Every call carries
`--account`. `get`, `put` and `sync` print their plan unless you pass
`DRY_RUN=0`.

| action | what it does |
|---|---|
| `do_spl_box_state_ls` | lists names, sizes and times; `PREFIX=`, `RECURSIVE=1` |
| `do_spl_box_state_get` | downloads `SRC` (an object, or a prefix ending `/`) into `DEST`, a 0700 dir |
| `do_spl_box_state_put` | uploads `SRC` (a file or dir) to `shared/<PREFIX>/`; an existing object is skipped, never overwritten |
| `do_spl_box_state_sync` | rsyncs the dir `SRC` to `shared/<PREFIX>/`; never deletes a remote object |

A put or sync is refused (exit 3, nothing sent) when anything under `SRC` would
be left out of a backup. That covers `.gcp`, `.ssh`, key files, tokens, `.env`,
NetVisor or bank credentials, 0600 files under a home's dot-dirs, and key
material: owner rule csitea fc0119cd, msg 072a9990, "keys and secrets stay on
the box". The list is c-846's `box-state-pack.sh`, the same one the nightly
backup uses. The refusal prints counts only, never the names of the files.

## 5. What it is not

gcsfuse is not a POSIX file system:

- There are no locks, so two boxes writing one object means the last close wins.
- A rename is a copy plus a delete, so it is slow for a large file and not atomic.
- A write reaches the bucket when the file is closed, not before.
- File modes and owners are not stored.
- Listing a large prefix is slow, so use `do_spl_box_state_ls` for that.

The bucket holds agent transcripts. Never paste object content into a post or a
log; names and sizes are enough.
