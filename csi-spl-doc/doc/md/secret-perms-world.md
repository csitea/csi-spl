# Secret files closed to other users, every home

> Generated from qto doc `827be63e-fd5b-4d5d-9897-f5b096f6cda2`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

SPL-1957. The sibling of [GCP key dir permissions](gcp-secret-perms.md)
(SPL-1924, one key dir, ACL-aware) for the three classes the SPL-1942 secret
inventory found readable by other local users on a box: GCP service-account
key files outside the csi key dir, ssh private keys and the qwen CLI's state
files. Owner answer A (poll d1585759): set them owner-only now, no rotation,
no delete, and prove each owner still works.

<a id="ws-doc-a610e20e-07b7-4dab-b1b7-aab5edbe390b"></a>
## 1. The action

```bash
cd csi-spl-orc && ./run -a do_spl_secret_perms_world
```

Dry run by default; `DRY_RUN=0` applies it. It reads other users' homes
through `sudo -n` unless it runs as root.

- `SECRET_PERMS_HOMES`: the homes, default `/root` and every `/home/*` dir.
- `SECRET_PERMS_DIRS`: the dirs searched in each home, default
  `.gcp .ssh .qwen`. A dir that does not exist is skipped.
- `SECRET_PERMS_UNDO`: on `DRY_RUN=0`, a file (mode 600) that gets one
  `<old mode> <path>` line per changed file, to put one file back. Keep it
  outside the repo.

A file's class: `gcp` is a `*.json` with a `private_key` and
`"type": "service_account"`; `ssh` is a file whose first bytes say
`PRIVATE KEY`; `qwen` is every file under a `.qwen` dir. Anything else is
not touched (a public key, a non-key json).

Per file of a class:

- other loses every bit;
- the group loses every bit only when it is not the owner's own group (a
  group named like the owner) and the file has no ACL. A `chmod g` on an
  ACL file moves the mask and can cancel a named entry's read (SPL-1924);
  such a file only loses other.

Files only: never a dir, a symlink, the content, the owner or the name;
nothing is deleted or rotated. It prints one row per file it changes, by
class, index and age in days, and a `summary <class> files= open= changed=`
row per class. Never a name, a path or content.

<a id="ws-doc-8cdc22e9-3fba-475d-8981-037e5e711fef"></a>
## 2. Tests

`csi-spl-orc/src/bash/tests/spl-secret-perms-world.tst.sh`: two fake homes
with placeholder keys; a CONTROL that the open check sees a 644 key as open
and a 600 key as closed; dry run changes nothing; the apply closes the
world-readable files, a foreign group loses its bits, the owner's own group
keeps them, owner-only and non-secret files, a symlink and the dirs stay;
a missing home is no error; the undo file; a second run is a no-op; a
CONTROL that the step with the other read put back fails the apply.

<a id="ws-doc-c696af5c-f4ac-4ac6-b746-fbc0bf81bb26"></a>
## 3. What it does not do

A file that is open by its bit but sits in a dir other users cannot enter
(a 700 `.ssh`) is closed too: the bit is the measurement, the dir is not
relied on. A CLI that writes new state files with its own umask opens them
again. qwen did (664 under the launcher's umask 0002); its launchers now
start it with `spool-harness.sh --umask 077` (`SPAWN_UMASK` /
`RESTORE_UMASK` in `spawn-qwen.sh` / `restore-qwen.sh`, SPL-1999), so the
files it creates are owner-only. Another CLI with the same gap: re-run the
action, or give its launcher a `--umask`.
Whether an exposed key must be rotated is the owner's decision.
