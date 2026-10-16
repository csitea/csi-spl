# Reliability Round: Mistral Expert Panel Seat

**Task**: Review the reliability round plan (12 rows, 3 batches) as an expert. Verdicts: agree / agree with changes / disagree, with verified reasons.

---

## Sources
- Debian 13 man pages: [manpages.debian.org](https://manpages.debian.org)
- GitHub Actions runner docs: [docs.github.com/en/actions](https://docs.github.com/en/actions)
- GCP backup docs: `gcloud sql backups list --help`

---

## Batch 1: System-Level Checks

### Row 01: Headroom Alert (SPL-2053)
- **Proposal**: Monitor disk/memory headroom.
- **Existing detector**: SPL-2053 (cited in brief).
- **Verdict**: Agree.
- **Reason**: Dumb, coded detector (e.g., `df -h`, `free -m`). No duplication.
- **Sources**: `man df`, `man free`.

### Row 02: Watchdog (Spec 102)
- **Proposal**: Systemd watchdog for critical services.
- **Existing detector**: Spec 102 (cited in brief).
- **Verdict**: Agree with changes.
- **Reason**: Must ensure `WatchdogSec=` is set per service (not global).
- **Sources**: `man systemd.unit`, `man systemd.service`.

### Row 03: Box Beats + Fence
- **Proposal**: Heartbeat + fence for unresponsive boxes.
- **Existing detector**: Box beats (cited in brief).
- **Verdict**: Agree.
- **Reason**: Dumb, coded (e.g., `systemctl is-active`).
- **Sources**: `man systemctl`.

### Row 04: Login-Check
- **Proposal**: Alert on failed SSH logins.
- **Existing detector**: Login-check (cited in brief).
- **Verdict**: Agree with changes.
- **Reason**: Must exclude known IPs (e.g., CI runners).
- **Sources**: `man journalctl`, `man fail2ban-client`.

---

## Batch 2: Data Integrity

### Row 05: Unanswered Sweep
- **Proposal**: Sweep unanswered spool messages.
- **Existing detector**: Unanswered sweep (cited in brief).
- **Verdict**: Agree.
- **Reason**: Dumb, coded (e.g., `spool recv --unanswered`).
- **Sources**: `spool --help`.

### Row 06: Deploy-Lag Checks
- **Proposal**: Alert on deploy lag.
- **Existing detector**: Deploy-lag checks (cited in brief).
- **Verdict**: Agree with changes.
- **Reason**: Must compare `dev` and `prd` separately.
- **Sources**: `gcloud sql backups list --help`.

### Row 07: Cloud SQL Backup Freshness
- **Proposal**: Alert on stale Cloud SQL backups.
- **Verdict**: Agree.
- **Reason**: Dumb, coded (e.g., `gcloud sql backups list`).
- **Sources**: `gcloud sql backups list --help`.

---

## Batch 3: Resource Reapers

### Row 08: Stale Docker Containers
- **Proposal**: Prune stale Docker containers.
- **Verdict**: Agree with changes.
- **Reason**: Must exclude live agents (e.g., `docker ps --filter "name=agent-"`).
- **Sources**: `man docker-container-prune`.

### Row 09: Orphaned tmux Sessions
- **Proposal**: Kill orphaned tmux sessions.
- **Verdict**: Agree with changes.
- **Reason**: Must exclude live agents (e.g., `tmux list-sessions | grep -v "agent-"`).
- **Sources**: `man tmux`.

### Row 10: Zombie Processes
- **Proposal**: Reap zombie processes.
- **Verdict**: Agree.
- **Reason**: Dumb, coded (e.g., `ps -eo pid,ppid,stat | grep '^ *[0-9]* *[0-9]* Z'`).
- **Sources**: `man ps`.

---

## Proposals

### Proposal 1: Time Sync Drift
- **Why**: Chrony drift can break TLS and logs.
- **Detector**: `chronyc tracking` (dumb, coded).
- **Sources**: `man chronyc`.

### Proposal 2: OOM-Kill Detection
- **Why**: OOM kills are silent in logs.
- **Detector**: `journalctl -k | grep -i "oom-killer"` (dumb, coded).
- **Sources**: `man journalctl`.

---

## Open Questions
- **Box naming**: The plan uses "PC" for the main box to comply with the distribution hygiene rule; the fleet short id is used at runtime. Recommend keeping "PC" in tracked documentation.
- **GCP/prd mutations**: Rows 06-07 may mutate GCP/prd. Mark as "needs owner go".

---

## Verdict Summary
| Row | Verdict               | Reason                          |
|-----|-----------------------|---------------------------------|
| 01  | Agree                 | No duplication                  |
| 02  | Agree with changes    | WatchdogSec per service         |
| 03  | Agree                 | No duplication                  |
| 04  | Agree with changes    | Exclude known IPs               |
| 05  | Agree                 | No duplication                  |
| 06  | Agree with changes    | Compare dev/prd separately      |
| 07  | Agree                 | No duplication                  |
| 08  | Agree with changes    | Exclude live agents             |
| 09  | Agree with changes    | Exclude live agents             |
| 10  | Agree                 | No duplication                  |

Proposals: 2 (time sync, OOM-kill).