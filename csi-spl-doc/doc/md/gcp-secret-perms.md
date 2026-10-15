# GCP key dir permissions: no secret open to other users

SPL-1924. On a box where the agent user's `~/.gcp` is a symlink to the box
owner's, the agent user reads the keys through a named ACL entry
(`user:<agent>:r-x`, from the dir's default ACL). Two shapes were found
there on 2026-10-15:

- a project key at mode 674 (`other::r--`): readable by every local user;
- files at 600 whose `chmod 600` set `mask::---`: the agent user's entry was
  cancelled, so it could no longer read them (the overlay, several keys).

The rule: a secret is owner `rw-`, `other` has nothing, and a named entry
keeps at most `r--`, effective.

## 1. The action

```bash
cd csi-spl-orc && ./run -a do_spl_gcp_secret_perms
```

Dry run by default; `DRY_RUN=0` applies it. Run it as the box owner (or it
goes through `sudo -n`). The dir is `GCP_KEY_DIR`, default `$HOME/.gcp/.csi`,
the key dir of `do_gcp_account`. For every regular file directly in it:

- the owner: `rw-`; other: `---`;
- the group: `---` (SPL-1932, owner answer A, topic 8e2b0ce4: the group read
  is removed, the group membership is kept);
- each named ACL entry: `r--` if it read before, else `---` (never wider);
- the mask: `r--` when a named entry reads, else `---`. The mode then shows
  `640` on an ACL file, `600` on a plain one.

The dir loses its group and `other` access, in its default ACL too, so a new
file is not born group- or world-readable; a named entry keeps its `r-x`
through the mask (nothing on the box reads the dir through the group). Subdirs and symlinks are skipped and counted.

It prints one row per file: index, role (`key`, `overlay`, `file`), the mode
and the `getfacl -c` entries before and after. Never a file name, never
content. A box without ACLs (separate homes, every file 600) shows no change.

## 2. The overlay pull uses the same step

`do_spl_private_overlay_pull` placed the overlay with a bare `chmod 600`,
which cancels a named entry on a shared-ACL box. It now runs the same step
(`spl_gsp_fix`) after the `chmod 600`, and its verify accepts 600, or 640 with
a named entry, and checks the file is closed to other (`spl_gsp_check`).

## 3. Tests

- `csi-spl-orc/src/bash/tests/spl-gcp-secret-perms.tst.sh`: the shapes on a
  temp dir; a CONTROL that the check fails on 674 and on `mask::---` over a
  named read; dry run changes nothing; the apply; a second run is a no-op.
  It skips, with the reason, where the temp fs has no ACLs.
- `csi-spl-orc/src/bash/tests/spl-private-overlay-pull.tst.sh` section 4c:
  a key dir shared by ACL keeps the named read on the pulled file; a CONTROL
  that the old bare `chmod 600` cancels it.

## 4. What it does not do

It changes permissions only: it never reads a key, rotates one or touches
GCP IAM. Whether a key that was readable by other users must be rotated is
the owner's decision.
