# Merged remote branches: deleted, and kept that way

SPL-3609. The owner (HUM-10, csitea topic 4ffbcb64, msg 34b232f4): "for all
of the merged already github branches - just delete them".

## 1. The action

`cd csi-spl-orc && PRUNE_ALL_MERGED=1 ./run -a do_git_prune_round_branches`
lists every head on the remote, one line each:

- `REF <branch> <sha> <date>`: merged. `git cherry origin/master <tip>` shows
  no `+` line, so every commit of the tip is on master (a squash of a
  one-commit branch included).
- `KEEP <branch> <reason>`, where the reason is one of:
  - `trunk`: master or main
  - `ruleset`: a `ruleset*` head (the ruleset proof refs)
  - `protected`: a GitHub protected branch
  - `live-lane <id>@<box>`: a live lane's branch, or the `review/` or `wip/`
    name of that branch or of its slug, from
    `lane-map.sh --json --all` on every machine
  - `unlanded <n>`: `<n>` commits not cherry-equal to master; `?` when they
    cannot be checked. A squash of several commits is not cherry-equal, so it
    is kept.

The last line counts them: `DELETE n, KEEP n (<reason> n, ...)`.

`DRY_RUN=1` is the default. `DRY_RUN=0` deletes the `REF` heads in atomic
pushes of `PRUNE_BATCH` refs (default 100), one `DELETED` line each, then
lists the remote again. When the lane map or the protected list cannot be
read whole (the hub did not answer, or gh failed), `DRY_RUN=0` is refused.
`PRUNE_UNLANDED=1` is refused in this mode. The test is
`csi-spl-orc/src/bash/tests/git-prune-round-branches.tst.sh`, cases 11 and 12.

## 2. The hourly run

`csi-spl-orc/src/bash/scripts/git-prune-merged-cron.sh` runs the action with
`DRY_RUN=0` at minute 47 of every hour and logs to
`/var/csi/csi-spl/git-prune-merged/cron.out`. It is installed on the one box
whose git pushes to the remote, from the main checkout:

`cd csi-spl-orc && DRY_RUN=0 ./run -a do_git_prune_merged_install_cron`

It is not a box-crons manifest row, because a manifest row is installed on
every box. The test is `csi-spl-orc/src/bash/tests/git-prune-merged-cron.tst.sh`.
