# Reliability round: agy seat proposal (a-615@PC)

Seat: **a-615@PC** (agy), editor seat, task `dispatch-06ebfdd6`, issue SPL-2114.
Plan: the reliability round plan v0.1 draft.
Target boxes: **PC**, **sat**, and **hub** (Debian 13 fleet & GCP Cloud Run / Cloud SQL).

## 1. Measured facts & context (fleet baseline)

Empirically measured across `PC`, `sat`, and the GCP cloud hub (read-only baseline probes, 2026-10-16 ~07:4xZ, n=1 each):

### Layer 1: Operating System
- **Host `PC`:** Linux kernel 6.12.x, uptime 21h 30m. RAM: 62 GiB total, 28 GiB used, 40 GiB buff/cache, 34 GiB available. Swap: 49 GiB total (`/dev/nvme0n1p3`), 4.3 GiB used. Time sync: `systemd-timesyncd` active, NTP sync confirmed (`2.debian.pool.ntp.org`), system clock synchronized. Systemd: `systemctl --failed` returns 0 failed units; however, zero background watchers monitor unit failure (unalerted failure mode).
- **Reboot flag:** `/var/run/reboot-required` and `/var/run/reboot-required.pkgs` unmonitored; machines run outdated in-memory kernels/libc indefinitely after unattended security upgrades.
- **Host `sat`:** 30 GB root filesystem at 74% used; uncapped systemd journal (488 MB).

### Layer 2: Networking & Certificates
- **DNS:** `/etc/resolv.conf` lists `8.8.8.8`, `1.1.1.1`, and router nameserver. `systemd-resolved` not installed; NetworkManager generates file directly.
- **Reachability:** HTTP/2 200 to `api.spool-hub.ai`, `dev.api.spool-hub.ai`, `api.github.com`.
- **Public TLS Certificates:**
  - `api.spool-hub.ai`: Google Trust Services (WR3), expires Dec 18, 2026 14:45 GMT (**63 days remaining**).
  - `dev.api.spool-hub.ai`: Google Trust Services (WR3), expires Dec 18, 2026 14:15 GMT (**63 days remaining**).
  - `spool-hub.ai`: Google Trust Services (WR3), expires Dec 18, 2026 16:39 GMT (**63 days remaining**).
  - **Zero automated certificate expiry monitoring exists**: failure of Cloud Run or Firebase TLS auto-renewal causes unalerted outage.

### Layer 3: Agent Fleet
- **Tmux Server:** Single daemon at `/tmp/tmux-<uid>/default` hosting 24 windows. Socket unmonitored; deadlock freezes all agent sessions and watchdogs.
- **Process Load:** 20 active user sessions, load average 21.40 on 16 cores. Detached compiler/node/git processes from dead lanes linger under the runner UID with PPID 1.

### Layer 4: Docker & CI Runners
- **Ephemeral Container Leaks:** Three test postgres containers (`c581-pg`, `c579-pg`, `c554-pg`) running for 14-17 hours; gateway container crashlooping every 26 seconds for 3 months.
- **GitHub Runner:** Self-hosted runner listener can hang; log shows `CAP online=0 of 2 runner(s)`. No check verifies runner registration or wedged CI jobs (> 45 min).

### Layer 5: Cloud Hub
- **Cloud Run Hub:** Serves Spool Hub API in `europe-north1`. Deploy-lag is checked only at code push; no continuous synthetic probe monitors mid-day API health or latency SLOs (p99 < 2000 ms).
- **Cloud SQL:** Daily automated backups unverified by software; backup age or quota failures unmonitored.

### Layer 6: Meta-Monitoring (Who Watches the Watchers)
- **Crontab Health:** 23 critical crons run on `PC` writing to `/var/csi/csi-spl/`. Cron daemon crashes or lockfile deadlocks fail silently without alerting.
- **Fence Telemetry:** Box fences itself after 120s of unacked beats (triggered at 03:41Z for 2m48s); no warning exists between 60s and 119s.

## 2. Technical sources (Debian 13 / Linux / GCP system standards)

Proposals are grounded in verified Linux system standards and cloud specifications:
- `systemctl(1)`, `systemd(1)`: `systemctl --failed`, `journalctl -u <unit> -n 5`.
- `debian-goodies(1)`, `needrestart(1)`: `/var/run/reboot-required`, `/var/run/reboot-required.pkgs`.
- `openssl(1)`: `openssl s_client -connect ...`, `openssl x509 -enddate -checkend`.
- `curl(1)`: fast HTTP HEAD/OPTIONS latency probes and synthetic status checks.
- `tmux(1)`: `timeout 3s tmux -S ... list-sessions` socket health validation.
- `proc(5)`, `kill(1)`: PPID 1 detection, state `Z`, process tree tracing under `/proc`.
- `docker(1)`: container uptime filtering, label/name pattern matching, safe pruning.
- `gh(1)`: GitHub Actions Runner API (`gh api repos/:owner/:repo/actions/runners`).
- `gcloud(1)`: Cloud SQL backup verification (`gcloud sql backups list`).

## 3. The 12 actions proposal

| # | slug | title | sites | target | csi-rel action & test |
|---|---|---|---|---|---|
| 01 | `feat(rel-01-systemd-unit-health)` | Systemd service failure & crash detector | `csi-spl-utl` | Detects failed unit in <= 15 s; emits alert | `do_os_systemd_unit_check`<br>`csi-spl-utl/src/bash/tests/systemd-unit-health.tst.sh` |
| 02 | `feat(rel-02-reboot-required-check)` | Kernel reboot-required & security update advisory | `csi-spl-utl` | Identifies pending reboot; coordinates 04:00 reboot | `do_os_reboot_required_check`<br>`csi-spl-utl/src/bash/tests/reboot-required-check.tst.sh` |
| 03 | `feat(rel-03-tls-cert-expiry-check)` | Public HTTPS certificate expiry monitor | `csi-spl-utl` | Warns at <= 21d, alarms at <= 7d (63d today) | `do_net_cert_expiry_check`<br>`csi-spl-utl/src/bash/tests/tls-cert-expiry.tst.sh` |
| 04 | `feat(rel-04-external-api-health-check)` | Outbound model & external API health probe | `csi-spl-utl` | Synthetic 5s probes; flags degraded vendor in < 10 s | `do_net_external_api_check`<br>`csi-spl-utl/src/bash/tests/external-api-health.tst.sh` |
| 05 | `feat(rel-05-tmux-server-health-guard)` | Tmux server socket liveness guard | `csi-spl-utl` | Socket probe in < 50 ms; flags freeze in < 5 s | `do_fleet_tmux_health_guard`<br>`csi-spl-utl/src/bash/tests/tmux-health-guard.tst.sh` |
| 06 | `feat(rel-06-orphan-process-reaper)` | Orphaned process & zombie task reaper | `csi-spl-utl` | Reaps PPID 1 orphans > 30 min; strictly non-pattern; 0 active lanes hurt | `do_fleet_orphan_process_reap`<br>`csi-spl-utl/src/bash/tests/orphan-process-reap.tst.sh` |
| 07 | `feat(rel-07-docker-test-container-prune)` | Stale ephemeral test container pruner | `csi-spl-utl` | Prunes test containers > 2h; strictly non-pattern; whitelists infra | `do_docker_test_container_prune`<br>`csi-spl-utl/src/bash/tests/docker-test-container-prune.tst.sh` |
| 08 | `feat(rel-08-gh-runner-health-check)` | GitHub Actions runner health & job hang detector | `csi-spl-utl` | Alerts if runner offline or job > 45 min | `do_gh_runner_health_check`<br>`csi-spl-utl/src/bash/tests/gh-runner-health.tst.sh` |
| 09 | `feat(rel-09-hub-synthetic-slo-monitor)` | Cloud Run hub synthetic probe & latency SLO monitor | `csi-spl-utl` | 60s probe; alerts on 5xx or latency > 2000 ms | `do_hub_synthetic_slo_check`<br>`csi-spl-utl/src/bash/tests/hub-synthetic-slo.tst.sh` |
| 10 | `feat(rel-10-cloud-sql-backup-verify)` | Cloud SQL daily backup verification | `csi-spl-utl` | Verifies backup freshness (< 26h) via service account | `do_cloud_sql_backup_verify`<br>`csi-spl-utl/src/bash/tests/cloud-sql-backup-verify.tst.sh` |
| 11 | `feat(rel-11-cron-heartbeat-snitch)` | Cron dead-man's snitch & heartbeat age monitor | `csi-spl-utl` | Scans 23 crons; alerts on silence > grace window | `do_cron_heartbeat_snitch`<br>`csi-spl-utl/src/bash/tests/cron-heartbeat-snitch.tst.sh` |
| 12 | `feat(rel-12-box-beat-telemetry)` | Box beat & watchdog fence early-warning telemetry | `csi-spl-utl` | Alerts at 60s delay (50% before 120s fence) | `do_box_beat_telemetry_check`<br>`csi-spl-utl/src/bash/tests/box-beat-telemetry.tst.sh` |

## 4. Adherence to owner rules

1. **Permanent software and monitoring solutions (msg c86872f6):** Every action is a permanent, reusable software tool in `csi-spl-utl` rather than a one-off shell fix.
2. **Coded automatic detection, "the less intelligence in that, the better" (msg 0626b425):** Plain, deterministic code rules with fixed numeric thresholds (sizes, ages, latencies), zero LLM in the loop.
3. **Shell actions runnable by hand, in `csi-spl-utl` (msg 177ce9f3):** All actions live in `csi-spl-utl/src/bash/run/`, runnable as `./run -a do_<action>` (`DRY_RUN=1` default) and callable from cron.
4. **Documentation across guides (msgs 4dde0ae9, a24f4e86):** Documented in DevOps guide, Developer guide, Operations and maintenance guide, and System guide.
5. **Exactly 12 concrete actions for owner poll approval (msg f7b5e824):** Formatted as 12 standalone items ready for a single checkbox poll; build begins only upon explicit owner approval, structured in 3 parallel batches of 4 lanes.

## 5. Signature

`signed: a-615@PC on v0.1 draft`
