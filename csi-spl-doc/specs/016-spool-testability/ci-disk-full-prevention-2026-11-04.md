# CI disk-full prevention (SPL-4790, 2026-11-04)

Owner HUM-10, t1 4b50446f. His red: run 41794536858, job 126455469304, the
hub-pg job of wf 10, `tar ... .cache/go-build ...: Cannot write: No space left
on device` while it restored a ~6218 MB Go cache. He asked "what actions can
we do to prevent this type of errors" and picked 2, 3, 4 and 5 (poll
57648404, msg cb6be3ea). SPL-4777 (927981c38) fixed the cause first: it frees
the hosted runner's disk in hub-pg and trims the Go race cache to what a run
used, under a new `v2` key. This page covers the four guards that sit on top
of that fix.

## 1. Measured

Tree: origin/master 927981c38. Measured 2026-11-04 10:1x..10:4xZ.

| what | value | command |
|---|---|---|
| biggest cache | `go-race-pg-…` (v1 key) 6.26 GiB, 63% of the 10 GB store | `gh cache list --sort size_in_bytes` |
| v1 restore + save | ~6348 MB compressed, 2 min restore + 2 min save | job 126509137252 log, `Cache Size:` |
| v2 save after the SPL-4777 trim | 2.1 G uncompressed (`du -sh`), 405 MB compressed | job 126517696278 log |
| hosted runner disk | `/dev/root 145G`, 88 G free at start, 110 G after the free-up | same log, `df -h` |
| store total | 6 caches, 7707 MB | `cd csi-spl-iac && ./run -a do_gh_prune_actions_caches` (dry run) |
| wf 10 jobs, 7 days (n = 598 of 772 runs readable) | 11,131 hosted, 0 self-hosted, 4 with no runner name | `gh api .../runs/<id>/jobs`, `runner_name` |
| hub-pg lost runners (no failed step) | 4: 11-01 00:05Z, 11-04 00:22Z, 03:29Z, 07:46Z | same |

The failed job left no log (`BlobNotFound`): its runner was lost, so the
free space at the moment it died cannot be read back.

## 2. Why the job ran on a hosted runner (item 3)

It was not a fallback. The repo variable `SPOOL_CI_RUNNER` is
`"ubuntu-latest"` (`gh api repos/<repo>/actions/variables/SPOOL_CI_RUNNER`,
updated 2026-10-30T18:25:11Z). This is the owner's own choice, t1 f67e3656
option 1, "tests on hosted runners". The RUNNER note at the top of wf 10
records it. No change was made: option A, keep hosted, stands (dispatch
c-002, msg 3e8c0c69).

## 3. What runs now

| guard | where | limit | red control |
|---|---|---|---|
| cache save cap (item 2) | wf 10 hub-pg, step `gocache-cap` before the save: `csi-spl-orc/src/bash/scripts/ci-cache-save-cap.sh` | `CI_GO_CACHE_SAVE_MAX_MB` = 4000 (wf 10 `env:`), ~2x the 2.1 G v2 save | a planted 15 MB cache over a 10 MB cap gives `save=false` (`ci-disk-guard.tst.sh` 6), and on a throwaway branch with a cap of 1 MB the save is skipped |
| disk guard (item 4) | wf 10 hub-suite, hub-pg (after the free-up, before the restore), wui-e2e, orc-suite: `csi-spl-orc/src/bash/scripts/ci-disk-guard.sh` | `CI_DISK_NEED_GB` = 10 (wf 10 `env:`) on `/` and `$RUNNER_TEMP` | 3 G free against a need of 10 G exits 1 with `disk full before tests: 3.0G < 10G (/)` (test 2), and on a throwaway branch a need of 500 G fails those four jobs with that line |
| weekly prune (item 5) | `14_ci-cache-prune.yml`, Mon 02:19Z, runs `do_gh_prune_actions_caches` (csi-spl-iac) with DRY_RUN=0; a dispatch is a dry run by default | caches unused for 7 days, then the least recently used, until the store holds at most 8 GB | `gh-prune-actions-caches.tst.sh` (fake gh): what it deletes and in which order, a failed delete, the repo; without wf 14 its static check 7 is red |

wf 14 deletes only on its schedule or on a dispatch with `dry_run` false.
Any other event is a dry run. The first version keyed this on
`inputs.dry_run == false` alone, and on a push `inputs.dry_run` is null,
which equals false. So the 13:09Z push of the throwaway branch
`c946-ctl-cap` (run 41835578803) really deleted the old v1 race cache:
id 9991311195, key `go-race-pg-Linux-1.26.10-0ff36b3f…-5ebd78a6…`, 6420 MB,
last used 2026-11-04T10:13:04Z on master. The control branch armed it: it
added a `push:` trigger to wf 14. From now on a control never runs a
deleting action against shared state; a wf 14 control pins `DRY_RUN: "1"`
in the control branch itself (dispatch c-002, msg 861ab1d9). The action
itself is a dry run unless `DRY_RUN` is exactly `0` (test 1b: empty,
`false`, `no`, `00`). wf 10 no longer restores that key, and the schedule would have
deleted it too (the store held 8.7 GB, over the 8 GB limit). Test 7 now
pins the expression.

The disk-red control (`c946-ctl-disk-red`, `CI_DISK_NEED_GB` 500, wf 10
run 41835605336) failed all 13 guarded jobs at the guard with `disk full
before tests: 109.2G < 500G (/)`. In hub-pg it also showed a second red:
the cap step still ran (`!cancelled()`) with an empty Go cache dir and
exited 2 (usage). The cap step now also needs
`steps.gocache.outputs.dir != ''` (`ci-disk-guard.tst.sh` 11).

A skipped save or a pruned cache costs the next run a cold build (~350 s on
hub-pg, spec 133 r29), never a red. A disk guard red names the disk, so it
does not read as a test failure.

## 4. Tests

- `bash csi-spl-orc/src/bash/tests/ci-disk-guard.tst.sh`
- `bash csi-spl-iac/src/bash/tests/gh-prune-actions-caches.tst.sh`
