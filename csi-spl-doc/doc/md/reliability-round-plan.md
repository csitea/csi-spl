# Reliability round: permanent software and monitoring solutions for system continuity (12 actions)

Owner HUM-10, t1 topic `06ebfdd6-29ef-4a2e-aba1-420adf3e19ff`, verbatim orders:
- `c86872f6`: "We need a panel of experts on the issue of how to keep this whole system up and running effectively. I already started one discussion for the actual automated management of disk space, but there are for sure a lot of things, from the operating system to the networking stack, which must be taken care of. We need a panel of experts which evaluates our current stack and actually proposes concrete actions which are not one-off solutions, but permanent software solutions or monitoring solutions, to be able to ensure that the system is up and running effectively."
- `0626b425`: "it will be good to end up with a solution in which we have coded automatic detection, and the less intelligence in that, the better."
- `177ce9f3`: "Just some kind of a shell action which could also be run manually. Of course, it should be in the utils or the utils subfolder of the spool project."
- `4dde0ae9`: "Make sure to also document this future script in the maintenance and operations guide, in the DevOps guide, and the developer guide."
- `a24f4e86`: "And also mention it in the system guide that we do have a component which is periodically scanning and cleaning files, and just a small description on how it actually works."
- `f7b5e824` (owner addition & override): "We need 12 concrete action proposals for what needs to be done. Let me list them all for me so that I could pick. I would like, of course, probably to pick them all, but I would like to go through each one of them and separately approve it. After approval, start the work in lanes of 4 in parallel."

Rules: [rounds-rulebook.md](rounds-rulebook.md) (R1–R16) by pointer, with owner override:
- **Exactly 12 rows**, each concrete enough to approve alone: one-line title, what breaks today (evidence), what the change does, how we will know it works (measured number). Plain English.
- **This round DOES need the owner's go, per row** (overriding rulebook §1.4). After panel signs v1.0, the dispatcher posts all 12 rows as ONE checkbox poll form; only the ticked rows are built.
- **Batches of 4 lanes in parallel** (3 batches of 4 rows) with disjoint files (R1).
Issue: SPL-2114.
Editor: **a-615@PC** (agy).
Target boxes: **PC**, **sat**, and **hub** (Debian 13 fleet & GCP Cloud Run / Cloud SQL).

**Status: v1.0 consensus**. Signed by all panel seats: Claude (`c-285@sat`, commit `697f08e0a`), Mistral (`m-699@PC`, commit `78caf6cb6`), and Editor (`a-615@PC`, commit `3c7d50eeb`). Ready for owner checkbox poll approval.

## 1. Measured baseline facts across fleet layers

Empirically measured across `PC`, `sat`, and the GCP cloud hub (read-only baseline probes, 2026-10-16 ~07:4xZ by a-615, ~11:0xZ by c-285 on sat, ~11:1xZ by m-699 on PC):

### 1.1 Layer 1: Operating System (Debian 13 Trixie)
- **Host `PC` & `sat` system state:** Linux kernel 6.12.x across hosts. `systemctl is-system-running` is already queried by `csi-spl-api/src/go/spool-hub-api/internal/hubclient/host.go:270` and relayed to the hub in `HostSystem.State`, but **zero alerts fire when system state is `degraded`**.
- **Kernel / package reboot flag & library updates:** On Debian 13, `/var/run/reboot-required` and `.pkgs` are written exclusively by `/etc/kernel/postinst.d/unattended-upgrades` (kernel updates only). Outdated libraries (`libc6`, `systemd`) in running processes are detected via `needrestart -b -k -l`. Currently unmonitored; machines run outdated in-memory code indefinitely after unattended upgrades.
- **Time synchronization & clock drift (Claude & Mistral Proposal 1):** `timedatectl show -p NTPSynchronized` reports `yes` and `timedatectl timesync-status` shows offset -17 us to `169.254.169.254` (sat) or `2.debian.pool.ntp.org` (PC). However, **zero code monitors NTP sync loss or drift**. Silent loss of sync causes hub beat skew (triggering false fences), invalidates auth tokens, and breaks TLS validity.
- **Silent kernel OOM kills (Claude & Mistral Proposal 2):** `/proc/vmstat` tracks `oom_kill` counter, and kernel logs contain `oom-killer` events (`journalctl -k`). Currently, zero monitors detect when an agent subprocess or test container is terminated by the kernel OOM killer.
- **Resource baseline:** PC: 62 GiB RAM, 49 GiB swap (4.3 GiB used). Sat: 30 GB root disk at 74% used, 488 MB journal.

### 1.2 Layer 2: Networking & Certificates
- **Public TLS certificates & expiry:**
  - `api.spool-hub.ai`, `dev.api.spool-hub.ai`, `spool-hub.ai`: Google Trust Services (WR3), expires Dec 18, 2026 14:45 GMT (**63 days remaining**).
  - Existing reader: `csi-spl-orc/src/bash/run/spl-probe-hub-host.func.sh:37` already inspects certificate `-enddate` and SAN. It lacks threshold checks (`-checkend 1814400` for 21d, `-checkend 604800` for 7d) and cron automation.
- **Outbound reachability & model APIs:**
  - `spl-agent-login-check.func.sh` (cron 1 min) runs real model login probes (`LOGIN_PROBE_EVERY=300s`). `spl-uplink-probe` (cron 1 min) records gateway loss, DNS, and TCP 443 into a TSV.
  - Basic HTTP HEAD probes confirm TCP/TLS reachability to `api.anthropic.com` (404 in 0.18s), `generativelanguage.googleapis.com`, and `api.github.com`, but lack automated logging into the existing uplink-probe TSV format.

### 1.3 Layer 3: Agent Fleet & Execution Harness
- **Tmux server socket:** Single daemon per box (`/tmp/tmux-<uid>/default`, mode 700). Probes must run as the socket owner. Socket unresponsiveness locks all 24 sessions; recovery is non-automatic (requires human judgment or SIGUSR1 if socket unlinked).
- **Leaked test servers & detached workers:** 7 leaked test tmux servers (`/tmp/ppf.*`, up to 3 days old) found on sat; detached node and badge loops linger under runner UID with PPID 1.
- **Process reaper constraints:** Live daemons (`do_spl_watchdog`, tmux server) have PPID 1 and cwd outside worktrees; signals cannot remove zombies (`wait(2)`). Therefore, process detection must use **positive provenance** (targeting only processes with proven linkage to retired lanes or deleted worktrees) and run in **report-only advisory mode** (`DRY_RUN=1`).

### 1.4 Layer 4: Docker & CI Runners
- **Test container leaks & labels:** 9 `postgres:16-alpine` test containers were running unlabelled for up to 3 days (`cNNN-pg`, `pg-cNNN`). `registry.tsv` has no status column. Container creating call sites must pass `--label csi-spl.lane=$AGENT_ID` so orphaned test databases can be identified safely by lane retirement without pattern guessing.
- **GitHub Actions runner:** Self-hosted runner health is inspected by `do_check_gh_runner` (`check-gh-runner.func.sh`). Status `online=0` can be an intentional CPU budget cap; checks must read `CPU_BUDGET_STATE_DIR/parked` to avoid false alerts.

### 1.5 Layer 5: Cloud Estate (Cloud Run & Cloud SQL)
- **Cloud Run synthetic monitoring:** Step 070 (`csi-spl-iac/src/terraform/070-gcp-monitoring/`) **already provisions a 60s uptime check from 3 global regions to `/v1/health`** (`google_monitoring_uptime_check_config.hub_health`) with alert policies for uptime, 429 streak, 5xx rate, error-log rate, and SQL down. A single-box synthetic probe to `/version` or `/live` (which returns 404) is redundant.
- **Cloud SQL backups:** Daily backups run for `csi-spl-<env>-pg` (not `-db`). `csi-spl-orc/src/bash/run/spl-db-health.func.sh:115` already executes `gcloud sql backups list`. Scheduled workflow `45_db-backup.yml` exists where failure is the alert.

### 1.6 Layer 6: Meta-Monitoring (Who Watches the Watchers)
- **Box crontab:** The runner crontab contains **38 tagged active lines** (`# csi-spl:<tag>`), whereas `box-crons.manifest` has only 19. Many crons write logs only when output is generated (e.g. `gc`), making log mtime unreliable. Monitoring requires a shared heartbeat exit hook (`<state>/heartbeat/<tag>`).
- **Box beat fence telemetry:** Watchdog (`spl-watchdog.func.sh:1555`) already maintains `$WD_DIR/beat.ack` and pushes WIP before fence. Telemetry is needed to log beat latency and count near-fences (>= 60s) upon reconnect, with zero mutation of active worktrees.

## 2. Existing inventory & disjointness

| Existing detector / alert | Where it lives | Where it runs | Watched by |
|---|---|---|---|
| Disk headroom check (SPL-2053) | `csi-spl-orc/src/bash/run/check-disk-headroom.func.sh` | Host cron (15 min) | Unwatched |
| Agent watchdog (spec 102) | `csi-spl-orc/src/bash/run/spl-watchdog.func.sh` | Host cron / starter | Starter cron |
| Box beats & fence | `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` | Hub / box daemon | Watchdog |
| Agent login check | `csi-spl-orc/src/bash/run/spl-agent-login-check.func.sh` | Host cron (1 min) | Unwatched |
| Unanswered sweep | `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh` | Host cron (5 min) | Unwatched |
| Deploy lag check | `csi-spl-orc/src/bash/run/check-deploy-lag.func.sh` | Push hook / manual | CI gate |
| Cloud Run 60s Uptime (Step 070) | `csi-spl-iac/src/terraform/070-gcp-monitoring/` | GCP 3 regions | Cloud Monitoring Alerting |
| Runner health check | `csi-spl-orc/src/bash/run/check-gh-runner.func.sh` | Host manual | Manual |
| Hub TLS inspection | `csi-spl-orc/src/bash/run/spl-probe-hub-host.func.sh` | Host manual | Manual |

**Disjoint from other rounds (do NOT duplicate):**
- Disk hygiene round (SPL-2111, `disk-hygiene-round-plan.md`): temp files, journal caps, builder prune, user forgotten files. Note: Batch 1 depends on `csi-spl-utl` harness bootstrap from `hyg-01`.
- Networking round (SPL-2109, `networking-round-plan.md`): multi-uplink auto-switching, Wi-Fi powersave, USB tethering, beat gap shortening (`net-08`).
- Security round 1 (lanes c-184, c-187, c-547, c-550): GitHub permissions, prd account lockdown, sshd/ports, secrets scanning.

### 2.2 Delineation from the 8-gap refactoring run (owner order 7a98c2d1 msg 7377d13a)

Per owner order (msg `7377d13a`), the 8 outside review gaps form a separate 2-lane refactoring run. The reliability round maintains strict boundaries and avoids duplicate work:
- **Gap 1 (Chaos testing) vs Row 11 (`cron-heartbeat-snitch`):** Row 11 passively inspects cron heartbeat timestamps; zero fault injection or process termination.
- **Gap 2 (Load/soak testing) vs Step 070 / Row 09:** Step 070 handles uptime; Row 09 monitors clock synchronization. No CI load testing is added here.
- **Gap 3 (Spawn failure modes) vs Rows 05/06:** Row 05 provides passive host socket liveness checks; Row 06 provides report-only detached process advisories. Neither modifies `spawn-agents` failure suites.
- **Gap 4 (Rollback procedure) & Gap 5 (Disaster recovery guidance):** Zero overlap. Reliability round delivers runtime tools in `csi-spl-utl`.
- **Gap 6 (DB restore drill) vs Row 10 (`cloud-sql-backup-verify`):** Row 10 is strictly read-only GCP Cloud SQL backup age verification (< 26h); container restore drills (`spool_restore_drill`) belong entirely to Gap 6.
- **Gap 7 (Hub background loop supervision) & Gap 8 (Incident response runbooks):** Zero overlap. Reliability round does not modify hub Go code or fleet escalation matrices.

## 3. The 12 concrete action proposals

Every proposal is a permanent software or monitoring solution in `csi-spl-utl`, executable manually and via cron (`DRY_RUN=1` default), tested with red controls, and documented across guides.

| # | slug | title | what breaks today (evidence) | what the change does | target & proof (measured number) | csi-rel action & test | box | vendor | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `feat(rel-01-systemd-unit-health)` | Systemd service failure & crash detector | System daemons (docker, cron) can enter `failed` or `degraded` state silently; host report queries `is-system-running` but zero alerts fire | Reads `systemctl is-system-running` and `systemctl --failed`; checks unit logs; uses cnf unit ignore list; sends structured alert | Detects failed unit in <= 15 s; parses crash logs; tested against stub `systemctl`; 0 false alerts | `do_os_systemd_unit_check`<br>`csi-spl-utl/src/bash/tests/systemd-unit-health.tst.sh` | PC, sat | agy | Batch 1 (Lane 1) |
| 02 | `feat(rel-02-reboot-required-check)` | Kernel reboot & library restart advisory | Debian updates kernel (`/var/run/reboot-required`) and core libraries (`needrestart -b`); boxes run outdated code for weeks | Queries `needrestart -b -k -l` and `/run/reboot-required`; advises orchestrator at 04:00 window; strictly advisory, never auto-reboots | Identifies pending reboot and outdated services in < 2 s; zero disruptive reboots; alert only | `do_os_reboot_required_check`<br>`csi-spl-utl/src/bash/tests/reboot-required-check.tst.sh` | PC, sat | claude | Batch 1 (Lane 2) |
| 03 | `feat(rel-03-tls-cert-expiry-check)` | Public HTTPS certificate expiry monitor | Public endpoint TLS certificates expire Dec 18, 2026 (63 days); `spl-probe-hub-host` inspects date but lacks automated thresholds | Builds on `spl-probe-hub-host.func.sh`; uses `openssl x509 -checkend`; warns at <= 21d, alarms at <= 7d; hosts from cnf `BASE_DOMAIN` | Outputs days remaining (63d today); triggers warning at <= 21d and critical at <= 7d in < 2s | `do_net_cert_expiry_check`<br>`csi-spl-utl/src/bash/tests/tls-cert-expiry.tst.sh` | PC, sat | mistral | Batch 1 (Lane 3) |
| 04 | `feat(rel-04-external-api-health-check)` | Outbound model & external API reachability probe | DNS or TLS routing blocks to Anthropic, Gemini, or GitHub APIs fail silently between full login probes | Runs fast DNS/TCP/TLS probes (5s timeout) to endpoints in cnf; appends latency to `uplink-probe` TSV format; report-only | Detects endpoint reachability drops within 10 s; records latency in ms; report-only | `do_net_external_api_check`<br>`csi-spl-utl/src/bash/tests/external-api-health.tst.sh` | PC, sat | claude | Batch 1 (Lane 4) |
| 05 | `feat(rel-05-tmux-server-health-guard)` | Tmux server socket liveness guard | All 24 sessions depend on single tmux server; socket freeze halts entire fleet; `/tmp/tmux-<uid>/` is mode 700 | Probes socket as socket owner (`timeout 3s tmux -S ... list-sessions`); alerts within 5s on freeze; alert only (no auto-restart) | Probe completes in < 50 ms; flags hung socket in < 5s; tested against private test socket (`tmux -L`) | `do_fleet_tmux_health_guard`<br>`csi-spl-utl/src/bash/tests/tmux-health-guard.tst.sh` | PC, sat | mistral | Batch 2 (Lane 1) |
| 06 | `feat(rel-06-orphan-process-advisory)` | Orphaned process & detached worker advisory | Crashed lanes leave detached compiler, node, or test processes (64 PPID 1 processes on sat); load reached 21.40 | Report-only advisory (`DRY_RUN=1` permanent); scans using positive provenance (environ `AGENT_ID` in `registry.retired.tsv` or deleted cwd); never kills by pattern; explicit never-list | Detects orphaned processes from retired lanes; 100% preserves live agent processes and daemons | `do_fleet_orphan_process_reap`<br>`csi-spl-utl/src/bash/tests/orphan-process-reap.tst.sh` | PC, sat | agy | Batch 2 (Lane 2) |
| 07 | `feat(rel-07-docker-test-container-prune)` | Stale ephemeral test container pruner | Ephemeral test containers ran for 3 days; containers have no labels; name parsing is pattern-based | Adds `--label csi-spl.lane=$AGENT_ID` to test creating scripts; prunes only labelled containers whose lane is inactive and age > 2h; unlabelled reported only | Cleans up orphaned test containers > 2h; never prunes by name pattern alone; preserves infrastructure | `do_docker_test_container_prune`<br>`csi-spl-utl/src/bash/tests/docker-test-container-prune.tst.sh` | PC, sat | claude | Batch 2 (Lane 3) |
| 08 | `feat(rel-08-gh-runner-health-check)` | GitHub Actions runner health & job hang detector | Self-hosted runner daemon can hang or disconnect; CPU budget parks runners; jobs can hang indefinitely | Reuses `do_check_gh_runner`; reads `CPU_BUDGET_STATE_DIR/parked`; checks GitHub API for runner status and jobs > 45 min | Reports runner status in < 3 s; alerts on offline runner or job > 45 min; zero false alerts on parked runners | `do_gh_runner_health_check`<br>`csi-spl-utl/src/bash/tests/gh-runner-health.tst.sh` | PC, sat | mistral | Batch 2 (Lane 4) |
| 09 | `feat(rel-09-clock-sync-loss-check)` | Clock synchronization loss & NTP drift detector | Loss of time sync causes false watchdog fence (beat skew), auth token failures, and TLS errors; zero monitors check sync today | Checks `timedatectl show -p NTPSynchronized --value` and `timedatectl show-timesync`; alerts if sync lost > 30 min or \|offset\| > 1 s | Verifies NTP sync in < 100 ms; detects simulated sync loss within 30 min; alerts orchestrator | `do_os_clock_sync_check`<br>`csi-spl-utl/src/bash/tests/clock-sync-check.tst.sh` | PC, sat | claude | Batch 3 (Lane 1) |
| 10 | `feat(rel-10-cloud-sql-backup-verify)` | Cloud SQL daily backup verification | Cloud SQL backups run daily for `csi-spl-<env>-pg`; failures or quota locks are silent unless explicitly queried | Reuses `spl-db-health.func.sh` gcloud call under env SA; verifies newest successful backup < 26h; runs in workflow `45_db-backup.yml` | Alerts if newest backup > 26h; verified against live dev and prd instances; read-only | `do_cloud_sql_backup_verify`<br>`csi-spl-utl/src/bash/tests/cloud-sql-backup-verify.tst.sh` | hub | agy | Batch 3 (Lane 2) |
| 11 | `feat(rel-11-cron-heartbeat-snitch)` | Cron dead-man's snitch & heartbeat age monitor | 38 tagged crons run on host; crons logging only on output fail mtime checks; cron daemon crash fails silently | Reads tagged crontab directly; shared wrapper touches `<state>/heartbeat/<tag>` on exit; alerts if heartbeat age > schedule + grace | Detects silent cron stoppage within grace window (e.g. 5m for 1m cron); runs in < 100 ms | `do_cron_heartbeat_snitch`<br>`csi-spl-utl/src/bash/tests/cron-heartbeat-snitch.tst.sh` | PC, sat | mistral | Batch 3 (Lane 3) |
| 12 | `feat(rel-12-box-beat-telemetry)` | Box beat & watchdog fence early-warning telemetry | Box fences at 120s of beat silence (fenced at 03:41Z for 2m48s); watchdog makes WIP push; near-fences uncounted | Reads `$WD_DIR/beat.ack`; logs ack age and counts near-fences (>= 60s); sends summary note after reconnect; zero worktree commits | Records ack latency; alerts on reconnect after near-fence; disjoint from networking round net-08 | `do_box_beat_telemetry_check`<br>`csi-spl-utl/src/bash/tests/box-beat-telemetry.tst.sh` | PC, sat | claude | Batch 3 (Lane 4) |

## 4. Detailed row specifications

### Row 01: `feat(rel-01-systemd-unit-health)` - Systemd service failure & crash detector
- **What:** Implement `do_os_systemd_unit_check` in `csi-spl-utl`:
  - Inspects `systemctl is-system-running` and `systemctl --failed --plain --no-legend`.
  - For any failed unit, extracts crash logs via `journalctl -u <unit> -n 5 --no-pager`.
  - Replaces name-pattern filters with an explicit unit ignore list in cnf (`cnf/systemd-unit-ignore.tsv`), empty by default.
  - Emits a structured spool note to the orchestrator throttled by a state file (`<state>/systemd-unit-alert.stamp`).
- **Why:** Core daemons (`docker`, `cron`, `systemd-timesyncd`) can enter `failed` state. The host report already captures `is-system-running`, but zero background alerts fire when degraded.
- **Command:** `cd csi-spl-utl && ./run -a do_os_systemd_unit_check`
- **Target:** Exits 0 on running system; exits 1 and emits structured alert within 15 s when a unit fails.
- **Proof:** Tested against a stub `systemctl` on PATH; live box is left untouched.

### Row 02: `feat(rel-02-reboot-required-check)` - Kernel reboot & library restart advisory
- **What:** Implement `do_os_reboot_required_check` in `csi-spl-utl`:
  - Checks `/run/reboot-required` and parses `/run/reboot-required.pkgs` (set by kernel postinst).
  - Executes `needrestart -b -k -l` to detect running processes holding outdated libraries (`libc6`, `systemd`).
  - During nightly window (04:00), if reboot or service restart is pending, advises orchestrator via spool note. Strictly advisory; never initiates automated reboot.
- **Why:** Security updates install patched packages, but systems run outdated in-memory binaries for weeks without scheduling maintenance.
- **Command:** `cd csi-spl-utl && ./run -a do_os_reboot_required_check`
- **Target:** Identifies pending reboot and outdated services in < 2 s; zero disruptive reboots.
- **Proof:** Simulated `/run/reboot-required` and needrestart output triggers advisory note cleanly.

### Row 03: `feat(rel-03-tls-cert-expiry-check)` - Public HTTPS certificate expiry monitor
- **What:** Implement `do_net_cert_expiry_check` in `csi-spl-utl`:
  - Builds on `csi-spl-orc/src/bash/run/spl-probe-hub-host.func.sh:37`.
  - Reads public endpoints dynamically from cnf (`env.dns.BASE_DOMAIN` in `csi-spl-cnf/csi-spl/all.env.yaml`).
  - Uses `openssl x509 -checkend 1814400` (21 days) for WARNING and `openssl x509 -checkend 604800` (7 days) for CRITICAL alarms.
  - Emits a spool note to the orchestrator on threshold crossing, throttled by state stamp.
- **Why:** All public certificates expire Dec 18, 2026 (63 days remaining). Auto-renewal failure drops the public API and WUI without advance notice.
- **Command:** `cd csi-spl-utl && ./run -a do_net_cert_expiry_check`
- **Target:** Evaluates all domain endpoints in < 2 s; outputs days remaining; alerts on <= 21d.
- **Proof:** Tested with simulated certificate expiring in 14 days (WARNING) and 3 days (CRITICAL); production certs report OK (63d).

### Row 04: `feat(rel-04-external-api-health-check)` - Outbound model & external API reachability probe
- **What:** Implement `do_net_external_api_check` in `csi-spl-utl`:
  - Reads external API endpoints from cnf (Anthropic, Gemini, GitHub API).
  - Runs fast DNS/TCP/TLS reachability probes (5s timeout) without sending payload.
  - Appends round-trip latency to the existing `uplink-probe` TSV format on the same cron schedule, report-only.
- **Why:** DNS glitches, Cloudflare blocks, or ISP routing drops to specific model endpoints cause freshly spawned lanes to fail.
- **Command:** `cd csi-spl-utl && ./run -a do_net_external_api_check`
- **Target:** Scan completes in < 5 seconds; records latency per vendor; report-only.
- **Proof:** Synthetic blackhole route detects unreachable endpoint within 10 s; valid endpoints report TCP/TLS handshake in < 200 ms.

### Row 05: `feat(rel-05-tmux-server-health-guard)` - Tmux server socket liveness guard
- **What:** Implement `do_fleet_tmux_health_guard` in `csi-spl-utl`:
  - Runs as socket owner (`/tmp/tmux-<uid>/default`, mode 700).
  - Tests socket responsiveness using `timeout 3s tmux -S /tmp/tmux-<uid>/default list-sessions`.
  - Alerts within 5s if socket is unresponsive; alert only (no destructive automatic killing or restart of panes).
- **Why:** All 24 agent sessions run on a single tmux server. If tmux deadlocks, the entire fleet freezes silently.
- **Command:** `cd csi-spl-utl && ./run -a do_fleet_tmux_health_guard`
- **Target:** Probe completes in < 50 ms on responsive server; alerts on socket freeze > 5s.
- **Proof:** Tested against an isolated private test server (`tmux -L test-probe`); live fleet server is untouched.

### Row 06: `feat(rel-06-orphan-process-advisory)` - Orphaned process & detached worker advisory
- **What:** Implement `do_fleet_orphan_process_reap` in `csi-spl-utl`:
  - Operates strictly in **report-only advisory mode** (`DRY_RUN=1` permanent).
  - Identifies detached runner processes using **positive provenance**:
    1. Process environment contains `AGENT_ID` that is present in `registry.retired.tsv`, OR
    2. Process working directory (`/proc/<pid>/cwd`) points to a removed worktree (`(deleted)`), AND
    3. Process is NOT on the explicit never-list (`tmux`, `systemd`, `do_spl_watchdog`, runner listeners).
  - Reports findings to the orchestrator; leaves termination to lane lifecycle and harness exit traps.
- **Why:** 64 PPID 1 processes found on sat; leaked test tmux servers (`/tmp/ppf.*`) and detached badge loops push load average to 21.40. Signals do not reap zombies (`wait(2)`).
- **Command:** `cd csi-spl-utl && ./run -a do_fleet_orphan_process_reap`
- **Target:** Accurately identifies detached processes belonging to retired lanes; 0 false targets on live daemons.
- **Proof:** Planted orphan with retired AGENT_ID in environ is flagged; live tmux server and watchdog are ignored.

### Row 07: `feat(rel-07-docker-test-container-prune)` - Stale ephemeral test container pruner
- **What:** Implement `do_docker_test_container_prune` in `csi-spl-utl`:
  - Updates all container creating call sites (`hub-pg.tst.sh`, `box-purge.tst.sh`, `spl-doc-tree-timing.func.sh`, `spl-db-backup-verify.func.sh`) to pass `--label csi-spl.lane=$AGENT_ID`.
  - Prunes ONLY labelled containers where:
    1. The labelled `csi-spl.lane` has no active tmux pane and is absent from `registry.tsv` (or present in `registry.retired.tsv`), AND
    2. Container creation time exceeds 2 hours (`{{.CreatedAt}}` > 120 min), AND
    3. Container is not on the permanent infrastructure whitelist (`con-csi-csi-spl-tf-runner`, `con-csi-csi-spl-tpl-gen`, `con-csi-csi-spl-conf-validator`).
  - Unlabelled containers are reported to orchestrator, never removed.
- **Why:** Ephemeral test containers ran for up to 3 days unlabelled, leaking host ports and RAM.
- **Command:** `cd csi-spl-utl && DRY_RUN=1 ./run -a do_docker_test_container_prune`
- **Target:** Prunes labelled stale containers > 2h; never prunes by name pattern alone; preserves infrastructure.
- **Proof:** Labelled container from retired lane is pruned; unlabelled containers report warning only.

### Row 08: `feat(rel-08-gh-runner-health-check)` - GitHub Actions runner health & job hang detector
- **What:** Implement `do_gh_runner_health_check` in `csi-spl-utl`:
  - Extends `csi-spl-orc/src/bash/run/check-gh-runner.func.sh`.
  - Reads `CPU_BUDGET_STATE_DIR/parked` so parked runners are reported as PARKED, not offline.
  - Queries GitHub API (`gh api repos/csitea/csi-spl/actions/runners`) for runner status.
  - Inspects active GitHub Actions jobs for jobs running > 45 minutes on self-hosted runners.
- **Why:** Self-hosted runner listeners can hang or disconnect, stalling CI pipelines indefinitely.
- **Command:** `cd csi-spl-utl && ./run -a do_gh_runner_health_check`
- **Target:** Reports runner connectivity in < 3 s; alerts on offline runner or job > 45 min; zero false alerts on parked runners.
- **Proof:** Verified against real GitHub repository API; alerts on simulated API error or offline runner.

### Row 09: `feat(rel-09-clock-sync-loss-check)` - Clock synchronization loss & NTP drift detector
- **What:** Implement `do_os_clock_sync_check` in `csi-spl-utl` (Claude & Mistral Proposal 1):
  - Reads `timedatectl show -p NTPSynchronized --value` and `timedatectl timesync-status` (or `chronyc tracking`).
  - Detects when NTP synchronization has been lost (`NTPSynchronized=no`) for > 30 minutes, or when absolute clock offset exceeds 1 second (`|offset| > 1s`).
  - Emits a structured spool note to the orchestrator, throttled by a state stamp.
  - Replaces redundant Cloud Run synthetic probe (which duplicated Step 070 global uptime checks).
- **Why:** Loss of clock synchronization silently causes hub beat latency spikes (triggering catastrophic watchdog fences), invalidates auth tokens, and breaks TLS validity checks.
- **Command:** `cd csi-spl-utl && ./run -a do_os_clock_sync_check`
- **Target:** Probe completes in < 100 ms; reports current NTP offset and poll interval; alerts on sync loss > 30 min.
- **Proof:** Simulated `NTPSynchronized=no` triggers alert; synchronized system reports OK with measured offset.

### Row 10: `feat(rel-10-cloud-sql-backup-verify)` - Cloud SQL daily backup verification
- **What:** Implement `do_cloud_sql_backup_verify` in `csi-spl-utl`:
  - Reuses `gcloud sql backups list --instance=csi-spl-<env>-pg --account="$GCP_ACCOUNT" --limit=10` from `spl-db-health.func.sh:115`.
  - Resolves instance name `csi-spl-<env>-pg` from cnf (not `-db`).
  - Verifies latest backup has `status: SUCCESSFUL` and timestamp within last 26 hours.
  - Integrated into scheduled workflow `.github/workflows/45_db-backup.yml` where failure is the alert.
- **Why:** Automated backups run daily at 01:00, but backup failures due to disk locks or maintenance conflicts are silent unless verified.
- **Command:** `cd csi-spl-utl && ENV=prd ./run -a do_cloud_sql_backup_verify`
- **Target:** Exits 0 when backup < 26h; exits 1 with alert if backup is stale; read-only.
- **Proof:** Read-only verification passes on live GCP instances without mutating state.

### Row 11: `feat(rel-11-cron-heartbeat-snitch)` - Cron dead-man's snitch & heartbeat age monitor
- **What:** Implement `do_cron_heartbeat_snitch` in `csi-spl-utl`:
  - Inspects the runner crontab directly, discovering all 38 tagged active cron lines (`# csi-spl:<tag>`).
  - Provides a shared wrapper that touches `<state>/heartbeat/<tag>` when each cron completes.
  - Compares heartbeat timestamp against expected cron interval + grace window (e.g. 5 min grace for 1 min job).
  - Emits a spool alert to the orchestrator if any registered cron becomes silent.
- **Why:** 38 crons run on the box. Crons that log only on output (e.g. `gc`) fail log mtime checks; cron daemon death or lockfile deadlocks cause silent monitoring failure.
- **Command:** `cd csi-spl-utl && ./run -a do_cron_heartbeat_snitch`
- **Target:** Verifies all crons in < 100 ms; flags silent crons with schedule and last heartbeat.
- **Proof:** Simulated stale heartbeat log (> grace period) is flagged immediately; active jobs return 0 warnings.

### Row 12: `feat(rel-12-box-beat-telemetry)` - Box beat & watchdog fence early-warning telemetry
- **What:** Implement `do_box_beat_telemetry_check` in `csi-spl-utl`:
  - Reads last ack timestamp from watchdog state `$WD_DIR/beat.ack`.
  - Tracks round-trip heartbeat latency; logs warning and counts near-fences (ack age >= 60s, which is 50% of the 120s fence threshold).
  - Upon reconnection after near-fence, sends a summary note to orchestrator.
  - Telemetry only: zero modification of other lanes' worktrees; clear boundary with networking round `net-08` (which shortens the beat gap; row 12 counts it).
- **Why:** Box suffered a 2m48s outage and fenced at 120s on 2026-10-16 03:41Z. Zero telemetry tracks beat jitter or warns when ack latency approaches the fence threshold.
- **Command:** `cd csi-spl-utl && ./run -a do_box_beat_telemetry_check`
- **Target:** Telemetry probe completes in < 50 ms; logs ack latency; records near-fence events cleanly.
- **Proof:** Simulated 75s ack age logs near-fence count; normal < 15s beat cycles report OK.

## 5. Execution batches & disjoint files (R1)

The 12 rows are organized into **3 parallel batches of 4 lanes**. All files modified in each batch are completely disjoint:

### Batch 1 (4 parallel lanes): System Foundation & Network Reachability
- **Row 01 (`rel-01`):** `csi-spl-utl/src/bash/run/systemd-unit-health.func.sh`, `csi-spl-utl/src/bash/tests/systemd-unit-health.tst.sh`
- **Row 02 (`rel-02`):** `csi-spl-utl/src/bash/run/reboot-required-check.func.sh`, `csi-spl-utl/src/bash/tests/reboot-required-check.tst.sh`
- **Row 03 (`rel-03`):** `csi-spl-utl/src/bash/run/tls-cert-expiry.func.sh`, `csi-spl-utl/src/bash/tests/tls-cert-expiry.tst.sh`
- **Row 04 (`rel-04`):** `csi-spl-utl/src/bash/run/external-api-health.func.sh`, `csi-spl-utl/src/bash/tests/external-api-health.tst.sh`

### Batch 2 (4 parallel lanes): Fleet & Execution Engine Continuity
- **Row 05 (`rel-05`):** `csi-spl-utl/src/bash/run/tmux-health-guard.func.sh`, `csi-spl-utl/src/bash/tests/tmux-health-guard.tst.sh`
- **Row 06 (`rel-06`):** `csi-spl-utl/src/bash/run/orphan-process-reap.func.sh`, `csi-spl-utl/src/bash/tests/orphan-process-reap.tst.sh`
- **Row 07 (`rel-07`):** `csi-spl-utl/src/bash/run/docker-test-container-prune.func.sh`, `csi-spl-utl/src/bash/tests/docker-test-container-prune.tst.sh`
- **Row 08 (`rel-08`):** `csi-spl-utl/src/bash/run/gh-runner-health.func.sh`, `csi-spl-utl/src/bash/tests/gh-runner-health.tst.sh`

### Batch 3 (4 parallel lanes): Cloud Estate & Meta-Monitoring (Watch the Watchers)
- **Row 09 (`rel-09`):** `csi-spl-utl/src/bash/run/clock-sync-check.func.sh`, `csi-spl-utl/src/bash/tests/clock-sync-check.tst.sh`
- **Row 10 (`rel-10`):** `csi-spl-utl/src/bash/run/cloud-sql-backup-verify.func.sh`, `csi-spl-utl/src/bash/tests/cloud-sql-backup-verify.tst.sh`
- **Row 11 (`rel-11`):** `csi-spl-utl/src/bash/run/cron-heartbeat-snitch.func.sh`, `csi-spl-utl/src/bash/tests/cron-heartbeat-snitch.tst.sh`
- **Row 12 (`rel-12`):** `csi-spl-utl/src/bash/run/box-beat-telemetry.func.sh`, `csi-spl-utl/src/bash/tests/box-beat-telemetry.tst.sh`

## 6. Owner approval poll form (msg f7b5e824)

Prepared for the dispatch lease holder to post to the owner as ONE checkbox poll form after v1.0 consensus and signatures:

```markdown
### Reliability Round: Permanent Software and Monitoring Solutions (12 Actions)

Owner HUM-10 order msg f7b5e824: "We need 12 concrete action proposals for what needs to be done. Let me list them all for me so that I could pick... separately approve it. After approval, start the work in lanes of 4 in parallel."

Please tick the items you approve for implementation:

- [ ] **01. Systemd Service Failure & Crash Detector** (`feat(rel-01-systemd-unit-health)`): Detects and alerts on failed system services (`docker`, `cron`, `sshd`) and extracts crash logs in < 15 s; uses cnf ignore list.
- [ ] **02. Kernel Reboot & Library Restart Advisory** (`feat(rel-02-reboot-required-check)`): Queries `/var/run/reboot-required` and `needrestart -b`; advises orchestrator at 04:00 maintenance window; strictly advisory.
- [ ] **03. Public HTTPS Certificate Expiry Monitor** (`feat(rel-03-tls-cert-expiry-check)`): Probes TLS certs for domains in cnf; warns at <= 21 days, alarms at <= 7 days.
- [ ] **04. Outbound Model & External API Reachability Probe** (`feat(rel-04-external-api-health-check)`): DNS/TCP/TLS reachability probes to endpoints in cnf; records latency into uplink-probe format.
- [ ] **05. Tmux Server Socket Liveness Guard** (`feat(rel-05-tmux-server-health-guard)`): Continuous liveness probe on `/tmp/tmux-<uid>/default` as socket owner; alerts within 5s on freeze; no destructive auto-recovery.
- [ ] **06. Orphaned Process & Detached Worker Advisory** (`feat(rel-06-orphan-process-advisory)`): Report-only advisory (`DRY_RUN=1`); targets detached processes with positive provenance (retired AGENT_ID or deleted worktree); explicit never-list.
- [ ] **07. Stale Ephemeral Test Container Pruner** (`feat(rel-07-docker-test-container-prune)`): Test creating scripts pass `--label csi-spl.lane=$AGENT_ID`; prunes labelled containers older than 2h whose lane is inactive in registry.
- [ ] **08. GitHub Actions Runner Health & Job Hang Detector** (`feat(rel-08-gh-runner-health-check)`): Reuses `do_check_gh_runner`; reads CPU budget parked list; alerts if runner disconnects or CI job hangs > 45 min.
- [ ] **09. Clock Synchronization Loss & NTP Drift Detector** (`feat(rel-09-clock-sync-loss-check)`): Queries `timedatectl`; alerts if NTP sync is lost > 30 min or clock offset > 1s, preventing false watchdog fences.
- [ ] **10. Cloud SQL Daily Backup Verification** (`feat(rel-10-cloud-sql-backup-verify)`): Queries GCP Cloud SQL API for `csi-spl-<env>-pg`; alerts if newest successful backup is older than 26 hours.
- [ ] **11. Cron Dead-Man's Snitch & Heartbeat Age Monitor** (`feat(rel-11-cron-heartbeat-snitch)`): Scans 38 tagged active box crons; shared heartbeat exit wrapper; alerts if any cron fails to run within schedule + grace window.
- [ ] **12. Box Beat & Watchdog Fence Early-Warning Telemetry** (`feat(rel-12-box-beat-telemetry)`): Reads watchdog `beat.ack`; logs latency and counts near-fences (>= 60s) upon reconnect; zero worktree commits.
```

## 7. Panel consensus & signatures

| Seat | Vendor | Agent ID | Status | Signature SHA |
|---|---|---|---|---|
| Editor | agy | a-615@PC | Signed v1.0 consensus | `3c7d50eeb` |
| Expert 1 | claude | c-285@sat | Signed v1.0 | `697f08e0a` |
| Expert 2 | mistral | m-699@PC | Signed v1.0 | `78caf6cb6` |

Per owner order msg `f7b5e824`, once panel seats sign v1.0, the dispatcher posts the 12-item poll form above to the owner. Only rows ticked by the owner will be spawned, running in parallel batches of 4 lanes.
