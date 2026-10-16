# Disk Hygiene Round: Mistral Expert Panel Seat

**Vendor**: Mistral
**Plan Version**: v1.1 (d429c1d01)
signed: m-283 on d429c1d01
**Verdict**: 10 agree, 0 agree with changes, 0 disagree, 2 proposals.

---

## Verdict Summary

| #  | Slug                                      | Verdict               | Notes                                                                                     |
|----|-------------------------------------------|-----------------------|-------------------------------------------------------------------------------------------|
| 01 | `feat(hyg-01-utl-harness)`                | **Agree**             | Owner order (msg 177ce9f3) requires all actions to live in `csi-spl-utl`.                |
| 02 | `feat(hyg-02-journald-caps)`              | **Agree**             | `journald.conf(5)` confirms caps; measured inventory shows uncapped growth.               |
| 03 | `feat(hyg-03-logrotate-maxsize)`          | **Agree**             | `logrotate(8)` confirms `maxsize`; measured `auth.log` growth justifies 100M cap.        |
| 04 | `feat(hyg-04-docker-prune-policy)`        | **Agree**             | `docker-builder-prune(1)` and `docker-volume-prune(1)` confirm commands.                  |
| 05 | `feat(hyg-05-shell-snapshot-retention)`   | **Agree**             | Measured inventory confirms accumulation; 7d retention and 500-file cap are reasonable. |
| 06 | `feat(hyg-06-cache-caps)`                 | **Agree**             | `apt-get(8)`, `apt.conf(5)`, and `go help cache` confirm commands.                        |
| 07 | `feat(hyg-07-stale-lane-leftovers)`       | **Agree**             | SPL-2053 sweeps only in emergencies; routine sweeping prevents crises.                   |
| 08 | `feat(hyg-08-human-forgotten-report)`     | **Agree**             | Owner order (msg ae18b94b) requires report-only; poll form ensures safety.               |
| 09 | `feat(hyg-09-disk-growth-tracker)`        | **Agree**             | SPL-2053 only checks static thresholds; 1.5 GB/day threshold is reasonable.              |
| 10 | `docs(hyg-10-guides-and-doctree)`         | **Agree**             | Owner orders (msgs 4dde0ae9, a24f4e86) require documentation.                            |

---

## Detailed Verdicts and Sources

### Row 01: `feat(hyg-01-utl-harness)` - Bootstrap `csi-spl-utl` run harness
- **Verdict**: **Agree**.
- **Why**: The owner explicitly ordered (msg 177ce9f3) that all disk hygiene actions must live in `csi-spl-utl` and be callable manually and from cron.
- **Sources**: Owner message 177ce9f3.

---

### Row 02: `feat(hyg-02-journald-caps)` - Systemd journald size & retention caps
- **Verdict**: **Agree**.
- **Why**: The `journald.conf(5)` man page confirms that `SystemMaxUse`, `SystemKeepFree`, `SystemMaxFileSize`, and `MaxRetentionSec` are valid settings. The measured inventory shows the journal is currently uncapped, using 633 MB on `PC` and 488 MB on `sat`. The default policy allows growth up to 10% of the root filesystem (~88 GB on `PC`). The proposed caps (`1G` on `PC`, `500M` on `sat`) are reasonable.
- **Sources**: `journald.conf(5)`, measured inventory.

---

### Row 03: `feat(hyg-03-logrotate-maxsize)` - Rsyslog & auth.log rotation maxsize caps
- **Verdict**: **Agree**.
- **Why**: The `logrotate(8)` man page confirms that `maxsize` is a valid directive to rotate logs when they exceed a specified size, regardless of the scheduled interval. The measured inventory shows `auth.log` on `sat` reached 1.3 GB in 5 days, with `auth.log.1` consuming another 700 MB uncompressed. Weekly rotation is too slow for fleet agent volume. The proposed `maxsize 100M` is reasonable.
- **Sources**: `logrotate(8)`, measured inventory.

---

### Row 04: `feat(hyg-04-docker-prune-policy)` - Automated Docker builder & volume hygiene
- **Verdict**: **Agree**.
- **Why**: The `docker-builder-prune(1)` and `docker-volume-prune(1)` man pages confirm that `docker builder prune -a --filter "until=48h"` and `docker volume prune -f` are valid commands. The measured inventory shows `PC` has 103.8 GB of build cache (94.55 GB reclaimable) and `sat` has 9.2 GB (100% reclaimable). The proposal correctly targets reclaimable space without disrupting active containers or volumes.
- **Sources**: `docker-builder-prune(1)`, `docker-volume-prune(1)`, measured inventory.

---

### Row 05: `feat(hyg-05-shell-snapshot-retention)` - Agent CLI shell snapshot retention & pruning
- **Verdict**: **Agree**.
- **Why**: The measured inventory confirms that hundreds of `snapshot-bash-*.sh` files accumulate indefinitely in `~/.claude/shell-snapshots/`. The proposed retention period (7 days) and cap (500 files) are reasonable.
- **Sources**: Measured inventory.

---

### Row 06: `feat(hyg-06-cache-caps)` - Package manager & build cache caps
- **Verdict**: **Agree**.
- **Why**: The `apt-get(8)` man page confirms that `apt-get clean` is a valid command to empty the package archive cache. The `apt.conf(5)` man page confirms that `APT::Clean-Installed "true";` ensures `/var/cache/apt/archives/` does not accumulate `.deb` packages indefinitely. The `go help cache` output confirms that `go clean -cache` removes build cache entries. The measured inventory shows `/var/tmp/gocache-*` consumed 1.9 GB on `PC`.
- **Sources**: `apt-get(8)`, `apt.conf(5)`, `go help cache`, measured inventory.

---

### Row 07: `feat(hyg-07-stale-lane-leftovers)` - Routine daily cleanup of retired lane temp dirs
- **Verdict**: **Agree**.
- **Why**: The existing `tmp-stale-sweep.sh` (SPL-2053) sweeps `/var/tmp` only when disk headroom is < 15% (emergency mode). The measured inventory shows `/var/tmp` swelled to 33 GB on `PC` and 5.1 GB on `sat` between emergencies. The proposal enforces the **Worktree Safety Invariant**: directories with unlanded commits (`git cherry origin/master`) or dirty files (`git status --porcelain`) are skipped and flagged for owner approval.
- **Sources**: `tmp-stale-sweep.sh` (SPL-2053), measured inventory.

---

### Row 08: `feat(hyg-08-human-forgotten-report)` - Human "files you made and forgot" report
- **Verdict**: **Agree**.
- **Why**: The owner explicitly ordered (msg ae18b94b) a report for large forgotten user files, with deletion only on explicit human approval. The proposal correctly limits the scope to **report-only** and requires a poll form for deletion.
- **Sources**: Owner message ae18b94b.

---

### Row 09: `feat(hyg-09-disk-growth-tracker)` - Daily disk growth tracker & rate alert
- **Verdict**: **Agree**.
- **Why**: The owner ordered (msg c4e5ec9f, ec060ebc) tracking of slow disk growth to provide early warnings. The existing `check-disk-headroom.sh` (SPL-2053) only triggers at static thresholds (85%/92%), providing no early warning for steady growth. The proposal correctly integrates with the 24h workdir retention table while enforcing the **Worktree Safety Invariant**. The threshold (1.5 GB/day) is reasonable.
- **Sources**: `check-disk-headroom.sh` (SPL-2053), owner messages.

---

### Row 10: `docs(hyg-10-guides-and-doctree)` - Documentation in guides and Qto doctree
- **Verdict**: **Agree**.
- **Why**: The owner explicitly ordered (msgs 4dde0ae9, a24f4e86) documentation in the DevOps, Developer, Operations, and System guides. The proposal correctly identifies the target documents and prepares Qto edits for the dispatcher.
- **Sources**: Owner messages 4dde0ae9, a24f4e86.

---

## Proposed Missing Items

### 1. Systemd-tmpfiles rules for `/var/tmp` and `/tmp`
- **Why**: The `systemd-tmpfiles(8)` and `tmpfiles.d(5)` man pages describe a declarative way to manage temporary directories, including cleanup based on age and size. This is more maintainable than custom sweeps and aligns with systemd's design.
- **Proposal**: Add a row to deploy `/etc/tmpfiles.d/10-disk-hygiene.conf` with rules like:
  ```
  # Clean up /var/tmp lane leftovers older than 72h (normal) or 24h (crit)
  e /var/tmp/[acgmq]-[0-9][0-9][0-9] 0755 root root 72h
  e /var/tmp/[acgmq]-gocache 0755 root root 72h
  ```
- **Sources**: `systemd-tmpfiles(8)`, `tmpfiles.d(5)`.

---

### 2. Containerd image garbage collection
- **Why**: The measured inventory shows that `containerd` snapshotter storage consumes 115 GB on the workhorse box. Docker's prune commands do not cover `containerd` images, which are managed separately. Unused `containerd` images can accumulate and consume significant disk space.
- **Proposal**: Add a row to run `ctr -n moby images prune` (or `nerdctl image prune`) to reclaim unused `containerd` images. This can be integrated into the existing Docker hygiene step or as a separate action.
- **Sources**: Measured inventory, `ctr(8)`/`nerdctl(1)` man pages.

---

## Notes on the Plan

- The plan should use the fleet's agreed short id for the workhorse box, not "PC".
- The **Worktree Safety Invariant** is correctly enforced in Row 07 and Row 09, ensuring unlanded work is never deleted without owner approval.
- The plan's batch structure ensures disjoint files, preventing collisions between actions.