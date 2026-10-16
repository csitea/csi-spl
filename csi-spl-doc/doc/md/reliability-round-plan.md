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

**Status: v0.1 draft**. Submitted to expert panel seats for verification, review, and signing.

## 1. Measured baseline facts across fleet layers

Empirically measured across `PC`, `sat`, and the GCP cloud hub (read-only baseline probes, 2026-10-16 ~07:4xZ, n=1 each):

### 1.1 Layer 1: Operating System (Debian 13 Trixie)
- **Host `PC` (workhorse host):** Linux kernel 6.12.x, uptime 21h 30m. RAM: 62 GiB total, 28 GiB used, 40 GiB buff/cache, 34 GiB available. Swap: 49 GiB total (`/dev/nvme0n1p3`), 4.3 GiB used. Time sync: `systemd-timesyncd` active, NTP sync verified with `2.debian.pool.ntp.org`, local clock synchronized. Systemd: `systemctl --failed` returns 0 failed units currently. However, **zero background watchers monitor unit failure**: if a daemon dies, no alert is sent.
- **Kernel / package reboot flag:** `/var/run/reboot-required` and `/var/run/reboot-required.pkgs` are unmonitored. When critical packages (`libc6`, `systemd`, `linux-image`) update via unattended upgrades, the machine continues running outdated in-memory kernels/libraries indefinitely without scheduling a reboot in the 04:00 maintenance window.
- **Host `sat` (satellite server):** Root filesystem (`/dev/sda1`) 30 GB total, 74% used (previously reached 88% / 3.5 GB free before emergency sweep). Uncapped systemd journal (488 MB).

### 1.2 Layer 2: Networking & Certificates
- **DNS configuration:** Host `/etc/resolv.conf` lists nameservers `8.8.8.8`, `1.1.1.1`, and router DNS. `systemd-resolved` is not installed; DNS is managed directly by NetworkManager.
- **Outbound reachability:** Probes confirm HTTP/2 200 to `api.spool-hub.ai`, `dev.api.spool-hub.ai`, `api.github.com`.
- **Public TLS certificates & expiry:**
  - `api.spool-hub.ai`: Google Trust Services (WR3), expires Dec 18, 2026 14:45 GMT (**63 days remaining**).
  - `dev.api.spool-hub.ai`: Google Trust Services (WR3), expires Dec 18, 2026 14:15 GMT (**63 days remaining**).
  - `spool-hub.ai`: Google Trust Services (WR3), expires Dec 18, 2026 16:39 GMT (**63 days remaining**).
  - **Zero automated certificate expiry monitoring exists**: if Google Trust Services or Cloud Run domain mapping auto-renewal fails (due to DNS, CAA, or ACME rate issues), all public endpoints drop offline with browser TLS errors without prior warning.

### 1.3 Layer 3: Agent Fleet & Execution Harness
- **Tmux server:** Single tmux server daemon per box (`/tmp/tmux-<uid>/default` on `PC`) hosting 24 windows.
- **Tmux socket vulnerability:** Zero automated checks monitor tmux socket responsiveness (`timeout 3s tmux -S ... list-sessions`). If tmux deadlocks or socket permissions break, the entire fleet freezes.
- **Process load & zombies:** 20 user sessions logged in; system load average reached 21.40 on a 16-core machine. Subprocesses from crashed lanes or orphaned compiler runs linger under the agent user account with PPID 1.

### 1.4 Layer 4: Docker & CI Runners
- **Ephemeral container leaks:** Measured on `PC`: three ephemeral test postgres containers (`c581-pg`, `c579-pg`, `c554-pg`, image `postgres:16-alpine`) have been running for 14 to 17 hours! Container `con-bnc-cpt-gateway` has been crashlooping (restarting every 26 seconds) continuously for 3 months.
- **GitHub Actions runner:** Self-hosted runner managed via `gh-runner-cpu-budget-cron.sh`. Recent log: `CAP online=0 of 2 runner(s)`. Zero software checks verify whether local runner listeners have hung or become disconnected from GitHub Actions API.

### 1.5 Layer 5: Cloud Hub (Cloud Run & Cloud SQL)
- **Cloud Run API:** Serves Spool Hub API in `europe-north1`. Deploy-lag is checked only upon code push (`do_check_deploy_lag`); between pushes, no synthetic probe monitors API availability, `/version` endpoint consistency, or latency SLOs (p99 < 500 ms).
- **Cloud SQL backups:** Automated backups run in GCP, but no automated verification checks whether daily backups succeeded, whether WAL archiving is functional, or whether backup age has exceeded 26 hours.

### 1.6 Layer 6: Meta-Monitoring (Who Watches the Watchers)
- **Box crontab health:** 23 critical cron jobs run in the box user crontab on `PC`, writing to `/var/csi/csi-spl/<job>/<log>`. If the cron daemon hangs, a `flock` lockfile deadlocks, or an early shell error occurs, the cron silently dies without alerting.
- **Box beat fence telemetry:** Spec 102 §10.2 watchdog writes heartbeat beats to hub table `box_beats`; fences the box after 120 seconds of silence (which occurred at 2026-10-16 03:41Z..03:44Z during a Wi-Fi drop). No warning is emitted when beat latency degrades between 60s and 119s before the catastrophic fence triggers.

## 2. Existing inventory & disjointness

The reliability round builds on top of existing components without duplicating them:

| Existing detector / alert | Where it lives | Where it runs | Watched by |
|---|---|---|---|
| Disk headroom check (SPL-2053) | `csi-spl-orc/src/bash/run/check-disk-headroom.func.sh` | Host cron (15 min) | None (unwatched) |
| Agent watchdog (spec 102) | `csi-spl-orc/src/bash/run/spl-watchdog.func.sh` | Host cron / starter | Starter cron |
| Box beats & fence | `csi-spl-orc/src/bash/run/spl-dispatch-lease.func.sh` | Hub / box daemon | Watchdog |
| Agent login check | `csi-spl-orc/src/bash/run/spl-agent-login-check.func.sh` | Host cron (1 min) | None (unwatched) |
| Unanswered sweep | `csi-spl-orc/src/bash/run/spl-unanswered-sweep.func.sh` | Host cron (5 min) | None (unwatched) |
| Deploy lag check | `csi-spl-orc/src/bash/run/check-deploy-lag.func.sh` | Push hook / manual | CI gate |

**Disjoint from other rounds (do NOT duplicate):**
- Disk hygiene round (SPL-2111, `disk-hygiene-round-plan.md`): temp files, journal caps, docker prune, user forgotten files.
- Networking round (SPL-2109, `networking round plan`): multi-uplink auto-switching, Wi-Fi powersave, USB tethering on `PC`.
- Security round 1 (lanes c-184, c-187, c-547, c-550): GitHub permissions, prd account lockdown, sshd/ports, secrets scanning.

## 3. The 12 concrete action proposals

Every proposal is a permanent software or monitoring solution in `csi-spl-utl`, executable manually and via cron (`DRY_RUN=1` default), tested with red controls, and documented across guides.

| # | slug | title | what breaks today (evidence) | what the change does | target & proof (measured number) | csi-rel action & test | box | vendor | batch |
|---|---|---|---|---|---|---|---|---|---|
| 01 | `feat(rel-01-systemd-unit-health)` | Systemd service failure & crash detector | System daemons (docker, cron, sshd) can enter `failed` state silently; no watcher alerts `#alerts` or the dispatcher | Scans `systemctl --failed`; parses unit logs; sends structured alert on failed units | Detects failed unit in <= 15 s; extracts last 5 journal lines; 0 false alerts on healthy box | `do_os_systemd_unit_check`<br>`csi-spl-utl/src/bash/tests/systemd-unit-health.tst.sh` | PC, sat | agy | Batch 1 (Lane 1) |
| 02 | `feat(rel-02-reboot-required-check)` | Kernel reboot-required & security update advisory | Debian updates kernel/libc and sets `/var/run/reboot-required`; boxes run outdated kernel for weeks without scheduled reboot | Checks `/var/run/reboot-required`; advises dispatcher at 04:00 window to schedule clean reboot when 0 active lanes | Identifies pending reboot and exact packages in < 2 s; zero disruption to active lanes | `do_os_reboot_required_check`<br>`csi-spl-utl/src/bash/tests/reboot-required-check.tst.sh` | PC, sat | claude | Batch 1 (Lane 2) |
| 03 | `feat(rel-03-tls-cert-expiry-check)` | Public HTTPS certificate expiry monitor | `api.spool-hub.ai`, `dev.api.spool-hub.ai`, `spool-hub.ai` certs expire Dec 18, 2026 (63 days); zero code checks renewal | Probes TLS certs via `openssl s_client`; warns at <= 21 days, critical alert at <= 7 days | Outputs exact days remaining (63d today); triggers warning alert on test cert with <= 21d | `do_net_cert_expiry_check`<br>`csi-spl-utl/src/bash/tests/tls-cert-expiry.tst.sh` | PC, sat | mistral | Batch 1 (Lane 3) |
| 04 | `feat(rel-04-external-api-health-check)` | Outbound model & external API health probe | Network routing or Cloudflare blocks to Anthropic, Gemini, or GitHub APIs fail silently for individual vendors | Runs synthetic HEAD/OPTIONS probes (5s timeout); flags vendor degraded if 2 consecutive probes fail | Detects external API outage within 10 s; reports latency per endpoint in ms | `do_net_external_api_check`<br>`csi-spl-utl/src/bash/tests/external-api-health.tst.sh` | PC, sat | claude | Batch 1 (Lane 4) |
| 05 | `feat(rel-05-tmux-server-health-guard)` | Tmux server socket liveness guard | All 24 agent sessions run on single tmux server; if socket freezes or deadlocks, entire fleet stops without warning | Probes socket responsiveness (`timeout 3s tmux -S ... list-sessions`); checks socket permissions and process status | Unresponsive socket flagged in < 5 s; normal probe completes in < 50 ms | `do_fleet_tmux_health_guard`<br>`csi-spl-utl/src/bash/tests/tmux-health-guard.tst.sh` | PC, sat | mistral | Batch 2 (Lane 1) |
| 06 | `feat(rel-06-orphan-process-reaper)` | Orphaned process & zombie task reaper | Crashed agent lanes leave detached compiler, git, or node processes with PPID 1; load reached 21.40 | Strictly non-pattern multi-factor scan: reaps PPID 1 / zombie tasks older than 30 min unlinked to any tmux pane, worktree, or active registry lane | Reaps orphaned processes older than 30 min; never matches by pattern alone; 100% preserves active lane processes | `do_fleet_orphan_process_reap`<br>`csi-spl-utl/src/bash/tests/orphan-process-reap.tst.sh` | PC, sat | agy | Batch 2 (Lane 2) |
| 07 | `feat(rel-07-docker-test-container-prune)` | Stale ephemeral test container pruner | Ephemeral test containers (`c581-pg`, `c579-pg`) ran for 17 hours; gateway container crashlooping for 3 months | Strictly non-pattern multi-factor scan: stops and removes test containers older than 2h whose originating lane is inactive in registry; preserves infra | Cleans up orphaned test containers > 2h; never prunes by pattern alone; whitelists permanent infra containers | `do_docker_test_container_prune`<br>`csi-spl-utl/src/bash/tests/docker-test-container-prune.tst.sh` | PC, sat | claude | Batch 2 (Lane 3) |
| 08 | `feat(rel-08-gh-runner-health-check)` | GitHub Actions runner health & job hang detector | Self-hosted runner daemon can hang or disconnect (`CAP online=0 of 2 runners`); CI jobs queue up indefinitely | Checks GitHub API for runner `online` status; monitors runner process; flags wedged jobs exceeding 45 min | Reports runner status in < 3 s; alerts within 60 s if runner goes unexpectedly offline | `do_gh_runner_health_check`<br>`csi-spl-utl/src/bash/tests/gh-runner-health.tst.sh` | PC, sat | mistral | Batch 2 (Lane 4) |
| 09 | `feat(rel-09-hub-synthetic-slo-monitor)` | Cloud Run hub synthetic probe & latency SLO monitor | Cloud Run instances suffer cold-start stalls or 500 errors; no continuous probe verifies availability between deploys | Continuous 60s synthetic probe against `/version` and `/live`; checks status 200, latency < 2000ms | Records latency in ms (< 150 ms typical); alerts if 3 consecutive probes fail or latency > 2s | `do_hub_synthetic_slo_check`<br>`csi-spl-utl/src/bash/tests/hub-synthetic-slo.tst.sh` | PC, sat | claude | Batch 3 (Lane 1) |
| 10 | `feat(rel-10-cloud-sql-backup-verify)` | Cloud SQL daily backup verification | Cloud SQL automated backups run daily, but silent backup failures or quota locks are never checked from software | Queries GCP Cloud SQL API via environment service account; verifies newest successful backup < 26 hours old | Alerts if newest backup > 26h; verified against live dev and prd instances | `do_cloud_sql_backup_verify`<br>`csi-spl-utl/src/bash/tests/cloud-sql-backup-verify.tst.sh` | hub | agy | Batch 3 (Lane 2) |
| 11 | `feat(rel-11-cron-heartbeat-snitch)` | Cron dead-man's snitch & heartbeat age monitor | 23 critical crons write to `/var/csi/csi-spl/`; if cron daemon dies or lockfile hangs, all cron monitoring silently fails | Scans log mtime of all registered crons against expected schedule + grace period; alerts if any cron is silent | Detects frozen cron job within schedule + grace window (e.g. 5m for 1m job); runs in < 100 ms | `do_cron_heartbeat_snitch`<br>`csi-spl-utl/src/bash/tests/cron-heartbeat-snitch.tst.sh` | PC, sat | mistral | Batch 3 (Lane 3) |
| 12 | `feat(rel-12-box-beat-telemetry)` | Box beat & watchdog fence early-warning telemetry | Box fences itself at 120s of beat silence (fenced at 03:41Z for 2m48s); zero warning when latency spikes (60–119s) | Tracks hub beat ack latency; triggers early-warning alert and commits lane wip if ack age exceeds 60s | Alerts at 60s beat delay (50% before fence threshold); 0 false alarms on normal < 15s beats | `do_box_beat_telemetry_check`<br>`csi-spl-utl/src/bash/tests/box-beat-telemetry.tst.sh` | PC, sat | claude | Batch 3 (Lane 4) |

## 4. Detailed row specifications

### Row 01: `feat(rel-01-systemd-unit-health)` - Systemd service failure & crash detector
- **What:** Implement `do_os_systemd_unit_check` in `csi-spl-utl`:
  - Runs `systemctl --failed --plain --no-legend` across system and user units.
  - For any failed unit, inspects `journalctl -u <unit> -n 5 --no-pager` to extract the crash reason.
  - Filters out transient test services matching test patterns (`test-*`, `*-test`).
  - Emits a structured alert to `/var/spool-hub/dispatch/alerts/` and `#alerts` topic.
- **Why:** Core daemons (`docker`, `cron`, `rsyslog`, `systemd-timesyncd`) can crash or fail silently during operation or boot. Today, zero automated detectors watch `systemctl --failed`.
- **Command:** `cd csi-spl-utl && ./run -a do_os_systemd_unit_check`
- **Target:** Exits 0 with clean summary on healthy system; exits 1 and emits structured alert within 15 s when a unit fails.
- **Proof:** Planted failed unit (`systemd-run --unit=test-fail-probe /bin/false`) is immediately detected and reported.

### Row 02: `feat(rel-02-reboot-required-check)` - Kernel reboot-required & security update advisory
- **What:** Implement `do_os_reboot_required_check` in `csi-spl-utl`:
  - Checks existence of `/var/run/reboot-required` and parses package list in `/var/run/reboot-required.pkgs`.
  - Compares running kernel (`uname -r`) against the latest installed kernel in `/boot/vmlinuz-*`.
  - During the nightly maintenance window (04:00), if a reboot is pending and active lane count is 0, advises the dispatcher to coordinate a box reboot via `box-restart-cron.sh`.
- **Why:** Debian 13 unattended upgrades install kernel and core library security fixes, but boxes run for weeks without rebooting into the patched kernel, leaving memory vulnerable.
- **Command:** `cd csi-spl-utl && ./run -a do_os_reboot_required_check`
- **Target:** Outputs status `REBOOT_REQUIRED: no` or lists pending packages; schedules reboot only when lane count is 0.
- **Proof:** Simulated `/var/run/reboot-required` generates correct advisory payload; non-zero lane count prevents disruptive reboot.

### Row 03: `feat(rel-03-tls-cert-expiry-check)` - Public HTTPS certificate expiry monitor
- **What:** Implement `do_net_cert_expiry_check` in `csi-spl-utl`:
  - Checks TLS certificates for public endpoints: `api.spool-hub.ai`, `dev.api.spool-hub.ai`, `spool-hub.ai`.
  - Extracts `notAfter` date using `openssl s_client -connect <host>:443 -servername <host> < /dev/null 2>/dev/null | openssl x509 -noout -enddate`.
  - Calculates days remaining until expiration:
    - `>= 22 days`: OK (logged to telemetry).
    - `8..21 days`: WARNING alert (sent to `#alerts` and dispatch holder).
    - `<= 7 days`: CRITICAL alarm (escalated to owner topic).
- **Why:** Measured on 2026-10-16: all three domains have certs expiring on Dec 18, 2026 (63 days). Zero code monitors TLS cert validity; an auto-renewal failure drops the public API and WUI with no advance warning.
- **Command:** `cd csi-spl-utl && ./run -a do_net_cert_expiry_check`
- **Target:** Reports exact expiration dates and days remaining for all 3 endpoints in < 2 seconds.
- **Proof:** Planted test certificate with 14 days remaining triggers WARNING; test cert with 3 days triggers CRITICAL; production certs report OK (63d).

### Row 04: `feat(rel-04-external-api-health-check)` - Outbound model & external API health probe
- **What:** Implement `do_net_external_api_check` in `csi-spl-utl`:
  - Runs fast HTTP HEAD/OPTIONS probes (5s timeout) to external dependencies:
    - Anthropic: `https://api.anthropic.com`
    - Google Gemini: `https://generativelanguage.googleapis.com`
    - GitHub API: `https://api.github.com`
    - Spool Hub API: `https://api.spool-hub.ai`
  - Measures HTTP response code and round-trip time (RTT).
  - If 2 consecutive probes fail or return 403 (Cloudflare block), flags vendor status as DEGRADED in `/var/spool-hub/dispatch/vendor-health.tsv`.
- **Why:** Outbound connectivity to an individual LLM vendor or GitHub can fail due to ISP routing, DNS glitches, or IP rate limiting, causing newly spawned agent lanes to instantly fail.
- **Command:** `cd csi-spl-utl && ./run -a do_net_external_api_check`
- **Target:** Full scan completes in < 5 seconds; records latency per vendor; alerts on consecutive failures.
- **Proof:** Synthetic blackhole route (`192.0.2.1`) triggers failure detection within 10 s; healthy endpoints report HTTP 200/404 and RTT < 200 ms.

### Row 05: `feat(rel-05-tmux-server-health-guard)` - Tmux server socket liveness guard
- **What:** Implement `do_fleet_tmux_health_guard` in `csi-spl-utl`:
  - Tests socket responsiveness using `timeout 3s tmux -S /tmp/tmux-<uid>/default list-sessions`.
  - Verifies socket permissions (accessible only by the host user session).
  - Checks tmux server process state (`ps -o stat= -p <tmux_pid>` must not be `D` or `Z`).
  - If socket is unresponsive or frozen for > 5 seconds, logs a fatal alert and attempts graceful socket recovery.
- **Why:** The entire fleet relies on a single tmux server. If tmux deadlocks or the socket hangs, all agent panes, watchdogs, and dispatchers are severed simultaneously.
- **Command:** `cd csi-spl-utl && ./run -a do_fleet_tmux_health_guard`
- **Target:** Probe completes in < 50 ms on responsive server; flags hung socket within 5 seconds.
- **Proof:** Simulated frozen process (`kill -STOP <tmux_pid>`) triggers timeout alarm within 5 s; process resumes (`kill -CONT`) and probe recovers to OK.

### Row 06: `feat(rel-06-orphan-process-reaper)` - Orphaned process & zombie task reaper
- **What:** Implement `do_fleet_orphan_process_reap` in `csi-spl-utl`:
  - Inspects all processes running under the agent runner UID.
  - Identifies processes whose parent process ID (PPID) is 1 (orphaned init adopted child) or whose state is zombie (`Z`).
  - **Strict Non-Pattern Safety Constraints (c-002 order)**: Never matches or terminates processes by command name pattern alone. A process is targeted ONLY when ALL five conditions are satisfied:
    1. PPID is 1 (orphaned child) or process state is `Z` (zombie), AND
    2. Process PID and PGID do not belong to any active tmux session, window, or pane (`tmux list-panes -F '#{pane_pid}'`), AND
    3. Process working directory (`/proc/<pid>/cwd`) is NOT inside any active worktree directory, AND
    4. Process command line is unassociated with any active agent in `/var/spool-hub/registry.tsv`, AND
    5. Process has been idle/stale > 30 minutes without active I/O or state change.
  - Sends `SIGTERM`, followed by `SIGKILL` only if still running after 10 s.
- **Why:** When agent lanes crash or commands time out, background subshells, detached node processes, or compiler workers accumulate, consuming memory and pushing load average to 21.40.
- **Command:** `cd csi-spl-utl && DRY_RUN=1 ./run -a do_fleet_orphan_process_reap`
- **Target:** Frees CPU and RAM leaks; never matches by pattern alone; 0 active agent lane processes disturbed.
- **Proof:** Planted background orphan (`nohup sleep 3600 &`) detached from tmux is cleanly terminated after retention window; active agent processes remain untouched.

### Row 07: `feat(rel-07-docker-test-container-prune)` - Stale ephemeral test container pruner
- **What:** Implement `do_docker_test_container_prune` in `csi-spl-utl`:
  - Scans all Docker containers matching test prefixes (`c*-pg`, `pg*`, `test-*`).
  - **Strict Non-Pattern Safety Constraints (c-002 order)**: Never prunes containers by name pattern alone. A container is targeted ONLY when ALL four conditions are satisfied:
    1. The container originating lane ID (parsed from container name `c<NNN>-pg` -> `c-<NNN>`, or container labels) is cross-referenced against `/var/spool-hub/registry.tsv` and verified to be INACTIVE (status `done`, `diss`, or not registered), AND
    2. Container creation time / uptime exceeds 2 hours (`{{.CreatedAt}}` older than 120 minutes), AND
    3. Container is not referenced in any active worktree configuration (`.env`, `docker-compose.yml`), AND
    4. Container is NOT on the permanent infrastructure whitelist (`con-csi-csi-spl-tf-runner`, `con-csi-csi-spl-tpl-gen`, `con-csi-csi-spl-conf-validator`, `csi-spl-lde-main-pg-1`).
  - If all conditions are met, removes container: `docker rm -f <container_id>`.
  - Scans for crashlooping containers (restart count > 100 with active status `Restarting`) and alerts dispatch holder.
- **Why:** Ephemeral test containers (`c581-pg`, `c579-pg`) were found running for 14-17 hours; `con-bnc-cpt-gateway` has been crashlooping every 26 seconds for 3 months, leaking host ports and RAM.
- **Command:** `cd csi-spl-utl && DRY_RUN=1 ./run -a do_docker_test_container_prune`
- **Target:** Removes orphaned test containers older than 2h; never removes by pattern alone; frees bound localhost ports (32769..32959).
- **Proof:** Test container from an inactive lane is pruned; whitelisted permanent containers are strictly preserved.
### Row 08: `feat(rel-08-gh-runner-health-check)` - GitHub Actions runner health & job hang detector
- **What:** Implement `do_gh_runner_health_check` in `csi-spl-utl`:
  - Queries GitHub API (`gh api repos/csitea/csi-spl/actions/runners`) using the pinned GitHub token.
  - Verifies local runner status is `online`.
  - Checks local runner systemd service / process listener.
  - Inspects active GitHub Actions jobs for this repository: if any job assigned to a self-hosted runner has been running > 45 minutes, alerts the dispatch holder to prevent pipeline deadlocks.
- **Why:** Self-hosted runners can silently become un-registered or wedged when listener sockets break (`CAP online=0 of 2 runner(s)`), stalling the entire CI pipeline.
- **Command:** `cd csi-spl-utl && ./run -a do_gh_runner_health_check`
- **Target:** Reports runner connectivity and active job runtime in < 3 s; alerts on offline runner or job wedged > 45 min.
- **Proof:** Verified against real GitHub repository API; reports current runner count; alerts on simulated API error or offline status.

### Row 09: `feat(rel-09-hub-synthetic-slo-monitor)` - Cloud Run hub synthetic probe & latency SLO monitor
- **What:** Implement `do_hub_synthetic_slo_check` in `csi-spl-utl`:
  - Runs continuous synthetic HTTP probes against `https://api.spool-hub.ai/version` and `https://dev.api.spool-hub.ai/version`.
  - Verifies HTTP 200, valid JSON response, and expected commit/version schema.
  - Measures request round-trip latency; asserts p99 SLO < 2000 ms.
  - If 3 consecutive probes fail or return 5xx errors, dispatches immediate high-priority alert to `#alerts`.
- **Why:** Cloud Run instances can suffer cold-start deadlocks, memory throttling, or backend DB connection pool exhaustion. Deploy checks only run at deployment time; continuous synthetic monitoring detects mid-day degradation.
- **Command:** `cd csi-spl-utl && ./run -a do_hub_synthetic_slo_check`
- **Target:** Probes both dev and prd in < 500 ms; logs latency sample; triggers alert on 3 consecutive failures.
- **Proof:** Normal probe reports HTTP 200 and latency < 150 ms; synthetic 500 or timeout triggers structured failure notification.

### Row 10: `feat(rel-10-cloud-sql-backup-verify)` - Cloud SQL daily backup verification
- **What:** Implement `do_cloud_sql_backup_verify` in `csi-spl-utl`:
  - Uses the environment service account (`key-csi-spl-<env>.json`) with read-only permissions.
  - Runs `gcloud sql backups list --instance=csi-spl-<env>-db --format=json` for `dev` and `prd`.
  - Verifies that the most recent backup has `status: SUCCESSFUL` and `endTime` within the last 26 hours.
  - Alerts if no successful backup exists within 26 hours or if the latest backup failed.
- **Why:** Cloud SQL automated backups run daily, but backup failures (due to maintenance conflicts, disk lockouts, or quota limits) are silent unless explicitly queried.
- **Command:** `cd csi-spl-utl && ENV=prd ./run -a do_cloud_sql_backup_verify`
- **Target:** Exits 0 with backup ID and timestamp when backup is fresh (< 26h); exits 1 with alert if backup is stale.
- **Proof:** Read-only API verification passes on live GCP instances without mutating any production state.

### Row 11: `feat(rel-11-cron-heartbeat-snitch)` - Cron dead-man's snitch & heartbeat age monitor
- **What:** Implement `do_cron_heartbeat_snitch` in `csi-spl-utl`:
  - Reads `cnf/box-crons/box-crons.manifest` and active crontab.
  - For every registered cron job, checks the last-modified timestamp of its log file in `/var/csi/csi-spl/<job>/<log>`.
  - Calculates age against expected schedule + grace period (e.g. 1-min job has 5-min grace; 10-min job has 25-min grace).
  - Emits a high-priority alert if any core cron becomes silent.
- **Why:** 23 critical crons run on `PC`. If the cron daemon crashes, an agent script aborts on an unhandled error, or a `flock` locks up, the cron stops running silently. Dead-man's snitch watches the watchers.
- **Command:** `cd csi-spl-utl && ./run -a do_cron_heartbeat_snitch`
- **Target:** Verifies all 23 crons in < 100 ms; flags silent crons with exact log path and expected update time.
- **Proof:** Planted stale test log (> grace period) is flagged immediately; healthy active logs return 0 warnings.

### Row 12: `feat(rel-12-box-beat-telemetry)` - Box beat & watchdog fence early-warning telemetry
- **What:** Implement `do_box_beat_telemetry_check` in `csi-spl-utl`:
  - Queries hub table `box_beats` or local beat log to inspect heartbeat ack latency and jitter.
  - If the last acked beat is older than 60 seconds (warning threshold at 50% of the 120s fence threshold), emits an early warning to `#alerts`.
  - Triggers pre-emptive git commit of active lane worktrees so work is not lost if connectivity drops further.
- **Why:** On 2026-10-16 03:41Z..03:44Z, `PC` suffered a 2m48s Wi-Fi outage and fenced itself at 120s. Today, no telemetry warns when beat latency starts climbing (60..119s), resulting in abrupt termination of agent lanes.
- **Command:** `cd csi-spl-utl && ./run -a do_box_beat_telemetry_check`
- **Target:** Alerts at 60s beat delay (50% before fence); logs round-trip beat latency; 0 false alarms on healthy network.
- **Proof:** Simulated 75s beat delay triggers early warning and wip preservation; normal < 15s beat cycles report OK.

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
- **Row 09 (`rel-09`):** `csi-spl-utl/src/bash/run/hub-synthetic-slo.func.sh`, `csi-spl-utl/src/bash/tests/hub-synthetic-slo.tst.sh`
- **Row 10 (`rel-10`):** `csi-spl-utl/src/bash/run/cloud-sql-backup-verify.func.sh`, `csi-spl-utl/src/bash/tests/cloud-sql-backup-verify.tst.sh`
- **Row 11 (`rel-11`):** `csi-spl-utl/src/bash/run/cron-heartbeat-snitch.func.sh`, `csi-spl-utl/src/bash/tests/cron-heartbeat-snitch.tst.sh`
- **Row 12 (`rel-12`):** `csi-spl-utl/src/bash/run/box-beat-telemetry.func.sh`, `csi-spl-utl/src/bash/tests/box-beat-telemetry.tst.sh`

## 6. Owner approval poll form (msg f7b5e824)

Prepared for the dispatch lease holder to post to the owner as ONE checkbox poll form after v1.0 consensus and signatures (posted by the dispatcher after v1.0, not before):

```markdown
### Reliability Round: Permanent Software and Monitoring Solutions (12 Actions)

Owner HUM-10 order msg f7b5e824: "We need 12 concrete action proposals for what needs to be done. Let me list them all for me so that I could pick... separately approve it. After approval, start the work in lanes of 4 in parallel."

Please tick the items you approve for implementation:

- [ ] **01. Systemd Service Failure & Crash Detector** (`feat(rel-01-systemd-unit-health)`): Detects and alerts on failed system services (`docker`, `cron`, `sshd`) and extracts crash logs in < 15 s.
- [ ] **02. Kernel Reboot-Required & Security Update Advisory** (`feat(rel-02-reboot-required-check)`): Monitors `/var/run/reboot-required` and advises dispatcher at 04:00 window to schedule clean reboot when 0 active lanes.
- [ ] **03. Public HTTPS Certificate Expiry Monitor** (`feat(rel-03-tls-cert-expiry-check)`): Probes TLS certs for `api.spool-hub.ai`, `dev.api.spool-hub.ai`, `spool-hub.ai`; warns at <= 21 days, alarms at <= 7 days.
- [ ] **04. Outbound Model & External API Health Probe** (`feat(rel-04-external-api-health-check)`): Synthetic 5s probes to Anthropic, Gemini, GitHub APIs; flags degraded vendors before spawning failing lanes.
- [ ] **05. Tmux Server Socket Liveness Guard** (`feat(rel-05-tmux-server-health-guard)`): Continuous liveness probe on `/tmp/tmux-<uid>/default`; alerts within 5s if tmux server hangs or freezes.
- [ ] **06. Orphaned Process & Zombie Task Reaper** (`feat(rel-06-orphan-process-reaper)`): Strictly non-pattern multi-factor scan: reaps detached unlinked PPID 1 / zombie tasks older than 30 min unassociated with any active agent, worktree, or tmux pane.
- [ ] **07. Stale Ephemeral Test Container Pruner** (`feat(rel-07-docker-test-container-prune)`): Strictly non-pattern multi-factor scan: stops and removes test containers older than 2h whose originating lane is confirmed inactive in registry; preserves permanent infrastructure whitelist.
- [ ] **08. GitHub Actions Runner Health & Job Hang Detector** (`feat(rel-08-gh-runner-health-check)`): Monitors runner `online` status via GitHub API; alerts if runner disconnects or CI job hangs > 45 min.
- [ ] **09. Cloud Run Hub Synthetic Probe & Latency SLO Monitor** (`feat(rel-09-hub-synthetic-slo-monitor)`): 60s synthetic probe against `/version` and `/live`; alerts on 5xx errors or latency > 2000 ms.
- [ ] **10. Cloud SQL Daily Backup Verification** (`feat(rel-10-cloud-sql-backup-verify)`): Queries GCP Cloud SQL API via service account; alerts if newest successful backup is older than 26 hours.
- [ ] **11. Cron Dead-Man's Snitch & Heartbeat Age Monitor** (`feat(rel-11-cron-heartbeat-snitch)`): Scans log mtime of all 23 box crons; alerts if any cron fails to run within its schedule + grace window.
- [ ] **12. Box Beat & Watchdog Fence Early-Warning Telemetry** (`feat(rel-12-box-beat-telemetry)`): Tracks hub beat ack latency; alerts and commits lane work at 60s delay before the 120s fence kills lanes.
```

## 7. Panel consensus & signatures

| Seat | Vendor | Agent ID | Status | Signature SHA |
|---|---|---|---|---|
| Editor | agy | a-615@PC | Proposed v0.1 draft | Pending |
| Expert 1 | claude | Pending placement | Pending review | Pending |
| Expert 2 | mistral | Pending placement | Pending review | Pending |

Per owner order msg `f7b5e824`, once panel seats sign v1.0, the dispatcher posts the 12-item poll form above to the owner. Only rows ticked by the owner will be spawned, running in parallel batches of 4 lanes.
