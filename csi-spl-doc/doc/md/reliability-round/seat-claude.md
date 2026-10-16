# Reliability round: claude seat verdict

Seat: **claude**, agent `c-285`, task `dispatch-06ebfdd6`, issue SPL-2114.
Review of: [reliability-round-plan.md](../reliability-round-plan.md) v0.1
(bb28e4b54, plus 7bfa425f1 and 4f3b1dc46), read at origin/master 15a966497.
Rules: [rounds-rulebook.md](../rounds-rulebook.md).

**Tally: 0 agree / 10 agree with changes / 2 disagree / 2 proposals.**

How it was measured: read-only commands on **sat**, 2026-10-16
11:00Z..11:05Z, n=1 each unless stated. Nothing was installed, started,
stopped, killed or removed. The main box ("PC" in the plan) was **not**
measured by this seat. Every claim about a file below cites the command
or the `file:line` it came from.

## 1. Verdicts per row

| Row | Slug | Verdict | One-line reason |
|---|---|---|---|
| 01 | `rel-01-systemd-unit-health` | agree with changes | The box host report already reads `systemctl is-system-running`; add the alert on top of it, and drop the name-pattern filter |
| 02 | `rel-02-reboot-required-check` | agree with changes | On Debian `/run/reboot-required` is only set for kernels; use `needrestart -b` for libraries; advise only, never reboot |
| 03 | `rel-03-tls-cert-expiry-check` | agree with changes | `do_spl_probe_hub_host` already reads `-enddate`; add `-checkend` thresholds; hosts come from cnf |
| 04 | `rel-04-external-api-health-check` | agree with changes | `agent-login-check` and `uplink-probe` already cover this in part; an HTTP HEAD to an API root proves only that TLS works |
| 05 | `rel-05-tmux-server-health-guard` | agree with changes | Run the probe as the socket owner; no automatic "recovery"; the proof must use a private test server |
| 06 | `rel-06-orphan-process-reaper` | **disagree** (as written) | Measured: the live `do_spl_watchdog` and the fleet tmux server meet conditions 1-4; signals do not remove zombies |
| 07 | `rel-07-docker-test-container-prune` | agree with changes | Test containers carry no labels, so taking the lane id from the name is a pattern match; `registry.tsv` has no status column |
| 08 | `rel-08-gh-runner-health-check` | agree with changes | Duplicates `do_check_gh_runner`; "online=0" can be the CPU budget parking runners on purpose |
| 09 | `rel-09-hub-synthetic-slo-monitor` | **disagree** (duplicate) | Step 070 already has a 60 s uptime check from 3 regions and 5xx/429/error-log/SQL-down alert policies; `/live` returns 404 |
| 10 | `rel-10-cloud-sql-backup-verify` | agree with changes | Wrong instance name (`-pg`, not `-db`); `do_spl_db_health` already lists backups; add the threshold only |
| 11 | `rel-11-cron-heartbeat-snitch` | agree with changes | The crontab has 38 tagged lines vs 19 manifest rows; log mtime is the wrong signal for crons that log only on output |
| 12 | `rel-12-box-beat-telemetry` | agree with changes | The watchdog already keeps `beat.ack` and makes the wip push itself; never commit in other lanes' worktrees |

## 2. Row by row: evidence and the change asked

### Row 01: systemd unit health (agree with changes)

- **Existing detector:** `csi-spl-api/src/go/spool-hub-api/internal/hubclient/host.go:270`
  already runs `systemctl is-system-running` and sends the state to the hub
  in the box host report (`wire.go` `HostSystem.State`). Nothing alerts on it.
  The row should alert when that state is `degraded` and should not add a
  second reader of the same state.
- **Measured on sat:** `systemctl is-system-running` -> `running`;
  `systemctl --failed --no-legend --plain` -> 0 lines.
- **Change:** drop "filters out `test-*`, `*-test`". A name filter hides
  real failures and is the pattern matching the round forbids. Use an
  explicit list of exact unit names in cnf instead, empty by default.
- **Change:** the proof "`systemd-run --unit=test-fail-probe /bin/false`"
  creates a transient unit on a live box as root. Run the test against a
  stub `systemctl` on `PATH` and keep the live box untouched.
- Source: `systemctl(1)` `is-system-running`, `--failed`:
  https://manpages.debian.org/trixie/systemd/systemctl.1.en.html

### Row 02: reboot required (agree with changes)

- **Measured on sat:** `/etc/kernel/postinst.d/unattended-upgrades` is the
  only writer of `/var/run/reboot-required` and `.pkgs`, and it fires only from
  kernel package scripts. So a `libc6` or `systemd` upgrade never sets the flag,
  which contradicts the plan's 1.1. `needrestart` is installed on sat
  (`dpkg-query -W needrestart` -> `install ok installed`). The running kernel
  is `6.12.111+deb13-cloud-amd64`, the newest of the 2 in `/boot`, and no flag
  file was present.
- **Change:** read `needrestart -b -k -l` (batch mode, "don't restart
  anything"): `NEEDRESTART-KSTA` gives the kernel state and `NEEDRESTART-SVC`
  lists services on old libraries. Keep `/run/reboot-required` as a second
  input. As a non-root user needrestart sees only that user's processes, so
  the cron user has to be named. Whether needrestart is installed on PC was
  not measured.
- **Change, owner go:** the row should only **advise** (one note to the
  orchestrator per new pending state). Rebooting a box is a box mutation.
  Remove "coordinate a box reboot via `box-restart-cron.sh`" from this row. If
  automatic reboot is wanted, it needs its own row that the owner ticks.
- Source: `needrestart(1)` `-b`, `-k`, `-l`, `-r l`:
  https://manpages.debian.org/trixie/needrestart/needrestart.1.en.html

### Row 03: TLS certificate expiry (agree with changes)

- **Existing detector:** `csi-spl-orc/src/bash/run/spl-probe-hub-host.func.sh:37`
  already runs `openssl x509 -noout -subject -issuer -enddate` on the served
  certificate and checks the SAN. It has no days threshold and no cron. Build
  on it; do not write a second `s_client` caller.
- **Measured on sat, 11:01Z:** api, dev.api and the apex all report
  `notAfter=Dec 18 2026`, issuer Google Trust Services WR3. That is 63 days,
  the same as the plan.
- **Change:** use `openssl x509 -checkend <seconds>` (21 d and 7 d), which
  is an exit code with no date parsing. Take the host list from cnf
  (`env.dns.BASE_DOMAIN` in `csi-spl-cnf/csi-spl/all.env.yaml:12`, the api
  fqdn, the additional domains, the tenant hosts), not from literals in the
  row. The repo CLAUDE.md and the seed both forbid a literal host.
- Sources: `openssl-s_client(1)`, `openssl-x509(1)` `-checkend`:
  https://manpages.debian.org/trixie/openssl/openssl-s_client.1ssl.en.html,
  https://manpages.debian.org/trixie/openssl/openssl-x509.1ssl.en.html

### Row 04: external API reachability (agree with changes)

- **Existing detectors:** `spl-agent-login-check.func.sh` (cron every
  minute) runs a real `claude -p` probe every `LOGIN_PROBE_EVERY` (300 s)
  and tells `ok | expired | limited` apart. `spl-uplink-probe` (cron every
  minute) samples gateway loss, DNS and TCP 443 to the hub into a TSV.
- **Measured on sat, 11:05Z:** `curl -sI https://api.anthropic.com` -> `404`
  in 0.18 s. A HEAD to an API root shows that DNS, TCP and TLS work. It shows
  nothing about auth, quota (the 402 failures in the fleet) or model
  availability.
- **Change:** limit the row to DNS, TCP and TLS reachability per vendor
  endpoint. Read the endpoint list from cnf and append to the uplink-probe
  TSV format on the same cron, not to a new `vendor-health.tsv`. Drop "403 =
  Cloudflare block": that is a guess. Keep the output report-only. Feeding it
  into spawn placement would be a change to lane-mix, which is another lane's
  work.

### Row 05: tmux server liveness (agree with changes)

- **Measured on sat:** each agent user's `/tmp/tmux-<uid>/` is mode 700.
  Listing the other agent user's dir -> `Permission denied`. The probe has to
  run as the socket's owner.
- **Change:** remove "attempts graceful socket recovery". tmux(1) offers
  exactly one recovery: SIGUSR1 recreates a socket that was **removed**. A
  deadlocked server cannot be recovered without losing every pane, and that
  is a human decision. Alert only.
- **Change:** the proof "`kill -STOP <tmux_pid>`" must target a private test
  server (`tmux -L <name>`) that the test starts and stops. Run against the
  fleet server, it freezes every agent on the box.
- **Found while measuring:** 7 leaked test tmux servers under `/tmp/ppf.*`
  on sat at 11:07Z, the oldest 4482 min (`ps -eo ppid=,etimes=,args=`, PPID 1). A test harness is
  leaking them. That is a bug for the owning lane, not a reaper target (row 06).
- Source: `tmux(1)` `-S`, `-L`, SIGUSR1:
  https://manpages.debian.org/trixie/tmux/tmux.1.en.html

### Row 06: orphan process reaper (disagree as written)

- **Measured on sat, 11:07Z:** 64 processes of the two agent users
  have PPID 1. Among them:
  - `systemd --user` (2), which is PPID 1 by design;
  - the fleet tmux server (`tmux -u -S /tmp/tmux-<uid>/default`). A tmux
    server daemonizes, so its PPID is 1, and it is not a pane pid;
  - three live `run -a do_spl_watchdog` processes, cwd
    `/var/spool-hub/dispatch/wd/code/<sha>/csi-spl-orc`. That is not a
    worktree, not a pane, and the command line has no agent id.
- **The failure:** the watchdog and the tmux server both meet conditions 1
  (PPID 1), 2 (not a pane pid), 3 (cwd not in a worktree) and 4 (no
  registry agent in the command line). Condition 5, "idle 30 min", is not
  defined in a way code can check, and a sleeping loop looks idle. The row
  as written would kill the watchdog and the whole fleet.
- **Cross-user blind spot:** `/proc/<pid>/cwd` and `/proc/<pid>/environ` of
  the other agent user -> `Permission denied` (measured). Condition 3 cannot
  be evaluated unless the reaper runs as root or as each user in turn.
- **Zombies:** a signal does not remove a zombie. `wait(2)` NOTES: a zombie
  whose parent exits is adopted by init, and "init(1) automatically
  performs a wait to remove the zombies". The one zombie measured
  (`xdg-open`) has a live parent. The zombie half of the row does nothing.
- **Counter-proposal:** (a) report-only. Keep `DRY_RUN=1` permanently until
  the report has shown zero false targets for 2 weeks, measured. (b) Use
  positive provenance instead of the absence of links: target a process only
  when it **proves** it belongs to a dead lane, for example an `AGENT_ID` in
  its environ that is in `registry.retired.tsv`, or a cwd that is a removed
  worktree (`readlink` ends in `(deleted)`). (c) Keep a fixed never-list:
  tmux servers, `systemd`, the watchdog, runner listeners. (d) Fix the leaks
  where they start. The real leaks measured are the test tmux servers, `tee`
  of pre-push logs (~3 days old), `node serve-generated.mjs` on test ports,
  and `agent-top.sh --badge-loop` started from old worktrees and pre-push
  base dirs. Each of those is a harness without an EXIT trap, so each is a
  bug row.
- Source: `wait(2)` NOTES:
  https://manpages.debian.org/trixie/manpages-dev/wait.2.en.html

### Row 07: test container pruner (agree with changes)

- **Measured on sat, 11:02Z:** 9 `postgres:16-alpine` test containers are
  running, aged 4 h to 3 days. `docker ps -a --format '{{.Names}} {{.Labels}}'`
  -> **no labels**. The names vary: `cNNN-pg`, `pg-cNNN`, `cNNN-lab`. So
  "parse the lane id from the name" is a pattern match.
- `registry.tsv` has 5 or 6 columns (id, vendor, pane, worktree, utc,
  spawner) and **no status column**: `awk -F'\t' '{print NF}' | sort | uniq -c`
  -> 173 rows with 5 columns, 544 with 6. "Status `done`/`diss`" does not
  exist. Retired ids move to `registry.retired.tsv`, but a lane that closed
  without being retired keeps its rows. `c270-pg` is 4 h old and `c-270`
  had a fresh registry row at 10:46Z, so a 2 h age gate alone would kill a
  live lane's database.
- **Change:** every creating call site adds `--label csi-spl.lane=$AGENT_ID`.
  The call sites found by `git grep 'docker run'`: `csi-spl-api/src/bash/tests/hub-pg.tst.sh:46`,
  `csi-spl-orc/src/bash/tests/box-purge.tst.sh:65`,
  `csi-spl-orc/src/bash/run/spl-doc-tree-timing.func.sh:81`,
  `csi-spl-orc/src/bash/run/spl-db-backup-verify.func.sh:82`, plus the bench
  scripts. Remove only labelled containers whose lane has no live tmux pane
  and that are older than 2 h. An unlabelled container is reported and never
  removed: the default is deny, not a whitelist.
- `docker container prune` removes only stopped containers, so it cannot
  catch these. That keeps this row disjoint from disk round hyg-04 (builder
  and volume prune). The crashlooping gateway on PC belongs to another
  project: report it, never remove it.
- Source: `docker-container-prune(1)` "Remove all stopped containers",
  `--filter label=`:
  https://manpages.debian.org/trixie/docker.io/docker-container-prune.1.en.html

### Row 08: GitHub runner health (agree with changes)

- **Existing detector:** `csi-spl-orc/src/bash/run/check-gh-runner.func.sh`
  (`do_check_gh_runner`) already checks every runner unit, Restart=always and
  rootless docker. It reports a runner that the CPU budget **parked** as
  PARKED, not as a failure. It is documented in the devops and operations
  guides (`git grep -l do_check_gh_runner`).
- "`CAP online=0 of 2`" is the CPU budget cron capping runners, which is
  intended. It is not evidence of a hang.
- **Change:** this row adds only what is missing: the GitHub API side
  (runner `status`, plus queued or in-progress job age > 45 min, read-only)
  and a cron line for the existing `do_check_gh_runner`. It must read the
  parked list (`CPU_BUDGET_STATE_DIR/parked`) so a park never alerts.

### Row 09: hub synthetic probe (disagree, duplicate)

- **Existing detector:** `csi-spl-iac/src/terraform/070-gcp-monitoring/04-uptime.tf`
  defines `google_monitoring_uptime_check_config.hub_health`.
  `05-policies.tf` adds alert policies for uptime, 429 streak, 5xx rate,
  error-log rate and Cloud SQL down. All of them go to the cnf
  `alert_email_<n>` and `alert_sms_<n>` channels. The rendered prd tfvars
  (`csi-spl-cnf/csi-spl/prd/tf/070-gcp-monitoring.vars.tfvars`) set
  `health_path = "/v1/health"`, period 60 s, regions EUROPE/USA/ASIA_PACIFIC,
  and a page after 120 s. Those are the row's own numbers, run from three
  regions instead of one box.
- **Measured on sat, 11:03Z:** `/live` -> **404**; `/v1/health` -> 200 in
  0.025 s; `/version` -> 200. The route list
  (`internal/hub/server.go:383-384`) has `/v1/health` and `/version` and no
  `/live`.
- `/version` drift between deploys is already covered by
  `do_check_deploy_lag` and `do_spl_probe_hub_host`.
- **Not verified by this seat:** whether step 070 is applied on both envs
  (that needs the env SA). The tfvars exist for dev and prd. The cheaper row
  is "verify 070 is applied", read-only, with
  `gcloud monitoring uptime list-configs --account=<env SA>`. Changing 070
  itself is a terraform apply and needs the owner's go.

### Row 10: Cloud SQL backup age (agree with changes)

- **Wrong name:** the instance is `csi-spl-<env>-pg`
  (`cloud_sql_instance_name = "csi-spl-prd-pg"` in the 070 prd tfvars), not
  `csi-spl-<env>-db`. Read it from cnf.
- **Existing reader:** `csi-spl-orc/src/bash/run/spl-db-health.func.sh:115`
  already runs `gcloud sql backups list --instance=... --account="$GCP_ACCOUNT" --limit=10`
  under the per-env SA pinning. Reuse that call and add only the threshold
  and the exit code.
- Backups start at 01:00 (`040-cloud-sql-postgres/03-cloud-sql.tf:50`), so
  26 h is a fair limit. Read-only, so no owner go is needed.
- **Alert path:** a box cron would need the env SA key on that box. The
  existing pattern is the 45 scheduled workflow, where "FAILURE IS THE ALERT"
  (`.github/workflows/45_db-backup.yml` header). Add this check as a step
  there, or say which box holds the key.
- Source: `gcloud sql backups list --help` (`--instance`, `--filter`,
  `--limit`), read on sat.

### Row 11: cron dead-man's snitch (agree with changes)

- **Measured on sat:** the crontab of the cron user has **38** active lines,
  each tagged `# csi-spl:<name>`, 4 of them `@reboot`. The manifest
  (`csi-spl-orc/cnf/box-crons/box-crons.manifest`) has **19** rows
  (`grep -vc '^\s*#'`). Most crons are installed by their own
  `*-install-cron` actions (about 30 in `csi-spl-orc/src/bash/run/`). Reading
  the manifest alone misses half of them. Read the tagged crontab.
- **Log mtime is the wrong signal:** the `gc` cron runs every minute but its
  log was 2 min old at 11:02Z, because it writes only when it has output.
  `issue-close-landed/cron.log` does not exist on sat because that job runs on
  one box only. An mtime check would raise false alarms on both.
- **Change:** one shared cron wrapper touches `<state>/heartbeat/<tag>` when
  the job exits. The snitch compares each heartbeat with the tag's schedule
  plus a grace period. `@reboot` lines are checked once, against boot time.
  The snitch's own heartbeat needs a reader from outside, for example the box
  host report or the peer box. Otherwise it is one more unwatched watcher.
- The plan's "23 crons on PC" was not re-measured on PC by this seat.

### Row 12: box beat early warning (agree with changes, narrowed)

- **Existing detector:** `csi-spl-orc/src/bash/run/spl-watchdog.func.sh:1555-1576`
  keeps the last ack in `$WD_DIR/beat.ack` (`spl_wd_beat_ack`, line 1671).
  It fences at `box_down_min`, sends a note to the orchestrator, and per spec
  102 section 10.2 makes "the wip push first" before it TERMs lanes.
- **Change:** remove "pre-emptive git commit of active lane worktrees".
  Committing in another lane's worktree breaks lane ownership, and the fence
  already makes the wip push.
- **Change:** a warning sent to the hub while the hub is unreachable cannot
  arrive, and nobody can act within 60 s. Keep the row as telemetry: read
  `beat.ack` (do not edit the watchdog), log ack age, count near-fences
  (ack age >= 60 s) per day, and send one note after reconnecting.
- **Overlap:** the networking round plan, row net-08 ("beat continuity",
  line 61) works on the same 03:41Z incident and the same
  beat code. Name the boundary: net-08 shortens the gap, row 12 only counts it.

## 3. Cross-cutting findings

1. **Alert path does not exist as written.** `/var/spool-hub/dispatch/alerts`
   -> `No such file or directory`. `#alerts` is a hub default channel, but
   an agent that has not joined it gets `unknown_channel`
   (`internal/hub/agent_post_test.go:160`). Use the convention that is
   already live in `check-disk-headroom.func.sh:7-12`: a WARN line plus ONE
   spool note to the orchestrator per crossing, a state file to stay quiet
   while the condition holds, and `DRY_RUN=1` by default. Name in each row
   who relays it to a human.
2. **Every detector is dumb and coded:** no row calls a model. Rows 06 and
   07 are the only ones that kill or remove anything; see their changes.
3. **GCP / prd mutation:** no row mutates GCP as written. Row 09's fallback
   (changing step 070) would be a terraform apply and needs the owner's go.
   Row 02's automatic reboot is a box mutation and is moved out of the row.
4. **Dependency:** `csi-spl-utl/README.md` says "Empty on purpose"; the disk
   round's hyg-01 bootstraps the utl harness. Batch 1 of this round has to
   wait for hyg-01 to land, or the two rounds will collide on
   `csi-spl-utl/src/bash/run/run.sh`.
5. **"PC" or the fleet short id:** the CI hygiene sweep bans the main box's
   fleet short id as a literal (`.github/workflows/10_ci-quality.yml:1249`,
   sweep "literal OS user / box / AD id"). The plan should keep **"PC"** in
   repo text and resolve the real id at run time from `$BOX_TAG`.
   "`a-615@PC`" is not a valid spool address; addresses come from the lease.
6. **Literal hosts** in rows 03, 04 and 09 must come from cnf
   (`BASE_DOMAIN`), as the repo CLAUDE.md requires.

## 4. Two things the plan missed

### P1. Clock sync loss detector

- **Why:** the fence counts ack age against the hub's clock, cron schedules
  and TLS validity depend on the local clock, and tokens expire by it. A box
  whose sync silently stops drifts with no signal today
  (`git grep -n NTPSynchronized` -> 0 hits outside this file).
- **Measured on sat, 11:03Z:** `timedatectl show -p NTPSynchronized -p NTP`
  -> `NTP=yes`, `NTPSynchronized=yes`; `timedatectl timesync-status` ->
  server 169.254.169.254, offset -17 us, poll 34 min, 161 packets. chrony is
  not installed; systemd-timesyncd is active.
- **What:** a cron action reads `timedatectl show -p NTPSynchronized --value`
  and `timedatectl show-timesync`. It alerts when sync has been `no` for 30
  min or when |offset| > 1 s. One note per crossing.
- Source: `timedatectl(1)` `show`, `timesync-status`, `show-timesync`:
  https://manpages.debian.org/trixie/systemd/timedatectl.1.en.html

### P2. OOM-kill detector

- **Why:** a kernel OOM kill of an agent, a test database or a runner is
  silent today (`git grep -n oom_kill` -> 0 hits outside this file). The
  plan's baseline has load at 21.40 and 4.3 GiB of swap in use on PC.
- **What:** a dumb counter. Compare `oom_kill` in `/proc/vmstat` with the
  last value seen; if it went up, name the victim from
  `journalctl -k --since <last run> --grep 'oom-kill|Killed process'`.
- **Measured on sat, 11:03Z:** `/proc/vmstat` has `oom_kill 0`. That field
  exists on this 6.12 kernel but is **not** listed in `proc_vmstat(5)`, so
  treat it as kernel ABI, with the journal as the documented source.
  `journalctl -k` as the agent user printed "not seeing messages from other
  users and the system", because the user is not in `adm` or
  `systemd-journal`. Reading the kernel journal needs that group for the
  cron user. That is an `/etc/group` change, so it is a proposal for the
  owner, not something this seat did.
- Sources: `journalctl(1)` `-k`, `-g/--grep`, `--since`:
  https://manpages.debian.org/trixie/systemd/journalctl.1.en.html ;
  `proc_vmstat(5)`: https://manpages.debian.org/trixie/manpages/proc_vmstat.5.en.html

## 5. Sources read on sat

- `systemctl(1)`: https://manpages.debian.org/trixie/systemd/systemctl.1.en.html
- `journalctl(1)`: https://manpages.debian.org/trixie/systemd/journalctl.1.en.html
- `timedatectl(1)`: https://manpages.debian.org/trixie/systemd/timedatectl.1.en.html
- `needrestart(1)`: https://manpages.debian.org/trixie/needrestart/needrestart.1.en.html
- `openssl-s_client(1)`: https://manpages.debian.org/trixie/openssl/openssl-s_client.1ssl.en.html
- `openssl-x509(1)`: https://manpages.debian.org/trixie/openssl/openssl-x509.1ssl.en.html
- `tmux(1)`: https://manpages.debian.org/trixie/tmux/tmux.1.en.html
- `docker-container-prune(1)`: https://manpages.debian.org/trixie/docker.io/docker-container-prune.1.en.html
- `wait(2)`: https://manpages.debian.org/trixie/manpages-dev/wait.2.en.html
- `proc_vmstat(5)`: https://manpages.debian.org/trixie/manpages/proc_vmstat.5.en.html
- `gcloud sql backups list --help` (Cloud SDK on sat)

Each page was read locally with `man` on sat (Debian 13 packages:
`dpkg -S` maps each file to the package in its URL). The URLs are the
trixie copies of the same pages.

## Signature

signed: c-285@sat on 3c7d50eeb (v1.0 consensus draft, 3c7d50eeb743e4c0ee3810f59dcd496a0c1956b5). Checked before signing: the row changes from this file are in v1.0, as are the alert note to the orchestrator, the `-pg` instance name and the hyg-01 dependency; row 06 is report-only, row 09 is now the clock sync row, the OOM proposal stays in the baseline (12-row cap).
