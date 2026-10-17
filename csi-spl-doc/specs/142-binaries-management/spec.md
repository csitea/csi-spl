# 142: Binaries management for agents

Status: **v0.1, design only** (no code, no box touched). Issue: SPL-2271.
Source: t1 topic `06871e35`, owner HUM-10 on 2026-10-16, verbatim:

> "No no they should be able to install packages , we jut need better way for
> binaries management"

He declined SPL-2187, a guard that took root from the agents (reverted on
master: `git log origin/master --oneline --grep=SPL-2187` -> 81fd3ef47
`revert(...)` on top of its three commits). So: **agents keep the right to
install packages.** This spec makes every install named, recorded, checked
and undoable.

Paths: `iac/` = `csi-spl-iac/`, `orc/` = `csi-spl-orc/`,
`play/` = `iac/src/terraform/060-gcp-vm-satellite/roles/`. The boxes are
written by role: **PC** (the owner's laptop, the desk box) and **sat** (the
GCE satellite VM). "The agent user" and "the box user" are the two OS users
of a box (spec 058); this file names neither.

## 1. What happened (the case this spec must handle)

- 2026-10-16 10:19Z (13:19 local, PC is UTC+3): an agent ran, as root
  through `sudo`, `apt-get install -y manpages manpages-dev manpages-posix
  manpages-posix-dev network-manager`, then at 10:19:40Z `apt-get install -y
  systemd-resolved`. Source: PC `/var/log/apt/history.log`, read with the
  awk in 2.2.
- `apt-get -s install systemd-resolved` on PC today prints two `Inst` lines:
  `systemd-resolved` and `libnss-resolve`. The agent asked for one package
  and got two: resolved took over `/etc/resolv.conf`, `libnss-resolve` put
  `resolve [!UNAVAIL=return]` into the `hosts:` line of `/etc/nsswitch.conf`.
  DNS broke; PC was off the hub ~22 min; 15 lanes stopped.
- 12:43Z: c-001 purged both under the owner's go, by hand, after a backup:
  `/var/backups/c001-resolved-purge-20261016T1243Z/` holds `nsswitch.conf`
  (mtime 13:19 local, the file as libnss-resolve left it) and
  `resolv.conf.link`. History line: `apt-get purge -y systemd-resolved
  libnss-resolve` at 15:43:15 local. Today `/etc/resolv.conf ->
  /run/NetworkManager/resolv.conf` and `systemctl is-active systemd-resolved`
  -> `inactive`.
- No repo action did any of it: `git grep -n 'pkg_purge' origin/master` -> 0
  lines. c-001 queued a `do_box_pkg_purge` action; it has not landed (same
  grep, 2026-10-17), so section 5.4 designs it, once, under that name.

The same package is **not** a takeover on sat: there it is the GCE image's
DNS (`readlink -f /etc/resolv.conf` -> `/run/systemd/resolve/resolv.conf`,
`systemctl is-active systemd-resolved` -> `active`). A check that flags a
package name alone would cry wolf on sat. Section 5.3 flags a **change of
owner** of a service on the box it runs on.

## 2. Inventory: how packages and binaries reach the boxes today

Measured 2026-10-17, read-only, on PC and on sat (`ssh satellite`).

### 2.1 The channels

| channel | what it installs | where | record of who/why |
|---|---|---|---|
| apt, playbook | 27 Debian packages (28 list lines, rsync twice), Google Cloud CLI, Chrome `.deb`, Go and yq tarballs (sha256-pinned) | `play/02_os_binaries/tasks/main.yml` (sat only) | the playbook file; comments say why |
| playbook, agent tools | cloud-sql-proxy (pinned), pnpm via corepack (the WUI's pin), lint scanners + terraform, test images, tpl-gen | `play/09_agent_tools/tasks/main.yml` (sat only) | the file |
| `do_install_lint_tools` | the scanners at the CI workflows' pins, into `~/.local/bin` or, with `LINT_TOOLS_SYSTEM=1`, `/usr/local/bin` | `iac/src/bash/run/install-lint-tools.func.sh` | pins read from the workflows |
| spool-install | spool, spool-agent, spool-mcp, the agent CLIs (claude, qwen via npm, mistral via uv/pipx, agy, grok), skills, kill-guard shims | `orc/src/bash/features/spool-install/install.sh` | it never installs an OS package: a missing one is NAMED with its `sudo apt-get install` line (`grep -c 'this needs root, so it is yours to run' install.sh` -> 4) |
| other actions | sysstat (`setup-box-sysstat`), gcsfuse (`install-gcsfuse`), rootlesskit/uidmap/slirp4netns/fonts-noto-core (`gh-runner-add`, `spl-local-hub-install`) | `orc/src/bash/run/*.func.sh` | the action |
| `do_require_bin` hint | nothing: on a missing tool it prints `sudo apt-get install -y <name>` (fallback `*)` for any name) | `{iac,orc,utl}/lib/bash/funcs/require-bin.func.sh`, 3 copies | none: it teaches the raw command |
| ad hoc | anything an agent or a human types | `sudo apt-get`, `curl` into `/usr/local/bin`, `pip`, `npm -g`, `go install` | apt: `/var/log/apt/history.log` `Requested-By:` = the OS user only, no agent id, no reason; non-apt: none |

`iac/cnf/satellite-replica.tsv` is the closest thing to a manifest today: 37
tools (`grep -vc '^#'`) with a version command and the role that installs
them, read by `do_satellite_verify`. It lists tools, not packages, and says
nothing of who needs them.

### 2.2 What the apt history says

Command (PC; on sat the same through `ssh satellite`):

`zcat -f /var/log/apt/history.log* | awk '/^Start-Date/{d=$2" "$3;r=""} /^Commandline/{sub(/^Commandline: /,"");c=$0} /^Requested-By/{r=$2} /^End-Date/{if(r!="")print d" | "r" | "c}' | sort`

PC, the agent user's installs since the fleet's tooling settled (local time,
UTC+3), none named by any installer in the repo:

| when (local) | packages |
|---|---|
| 2026-08-24 21:47 | potrace |
| 2026-09-04 14:20 | python3-defusedxml |
| 2026-09-10 09:53..09:59 | google-chrome-stable (upgrade), strace, slack `.deb` |
| 2026-10-09 05:07, 10:46 | webp, ed |
| 2026-10-11 02:28 | shunit2 |
| 2026-10-12 10:30 | faketime |
| 2026-10-16 13:19 | manpages manpages-dev manpages-posix manpages-posix-dev network-manager |
| 2026-10-16 13:19:40 | systemd-resolved (+ libnss-resolve) |
| 2026-10-16 15:43 | purge systemd-resolved libnss-resolve |

Each is still installed except the purged two (`dpkg-query -W -f='${Status}'
<pkg>`). Which lane installed each, and why, is lost: the log has the OS user
only. That gap is the first thing the action closes.

### 2.3 Installed but named by no repo file

Heuristic: a package counts as REPO when
`git grep -qwE "(- |install.*|apt.*)<pkg>"` over `iac/src iac/cnf orc/src`
(no `*.md`) matches; else HIST when a `Commandline:` of the apt history
names it; else BASE (the OS image or installer). A word match, so it errs
towards REPO.

| box | `apt-mark showmanual` | REPO | HIST (installed by hand) | BASE |
|---|---:|---:|---:|---:|
| PC | 520 | 52 | 148 | 320 |
| sat | 164 | 43 | 5 | 116 |

sat's 5 HIST: fonts-noto-core, rootlesskit, uidmap, slirp4netns (box user,
10-03 and 10-07; `gh-runner-add.func.sh` installs each, so a repo action did
it, not the playbook) and **python3-pip** (agent user, 10-09 23:09; no repo
installer, only the `do_require_bin` hint). sat also carries
`systemd-resolved` and `libnss-resolve` from its GCE image (BASE).

PC's 148 HIST are mostly the owner's 2026-06-02 desktop setup; the fleet-era
ones are the table in 2.2. Non-apt: `/usr/local/bin` on PC holds 28 files;
the agent user's `~/.local/bin` holds the spool and agent CLIs, the lint
scanners and 5 `spool-mcp.bak-*` copies. Nothing lists the non-apt ones
except `satellite-replica.tsv` for the tools it names.

## 3. Goals and non-goals

- G1. An agent installs through **one named action**, which simulates, flags,
  records, installs and verifies. Agents keep `sudo`; nothing is refused.
- G2. **One manifest per box class in the repo**: every package and binary,
  who installs it and who needs it.
- G3. **An undo** for any recorded install, first case the 10-16 purge.
- G4. **A flag, never a block**, for a package that changes who runs DNS,
  the network or init on that box, sent to the orchestrator before the
  install runs.
- G5. Drift is **seen**: what is on a box and not in its manifest is
  reported.
- Non-goal: taking root from agents (SPL-2187, declined). Non-goal: managing
  the OS image's base set (BASE stays BASE). Non-goal: a package mirror.

## 4. Decisions

- D1. **apt first.** The action installs apt packages and local `.deb` files.
  Other kinds (tarball, pip, npm, go, corepack) are recorded with
  `BOX_PKG_KIND=<kind> BOX_PKG_CMD=record` after the agent installed them its
  own way; the manifest and drift cover them, the action does not run them.
- D2. **Manifest per box class, not per box name**: `pc` and `satellite`
  (the words the repo already uses), so no box name lands in a file. A box
  finds its class in `box.env` (`BOX_CLASS=`, read like `SPOOL_DESK_BOX`
  in `orc/lib/bash/funcs/spl-desk-box.func.sh`).
- D3. **The journal lives on the box, the manifest in git.** The action
  appends to the box's journal at once (root-owned, append-only); the agent
  adds the manifest row in its own lane commit, next to the code that needs
  the package. Drift (5.5) reports any journal entry still missing from the
  manifest.
- D4. **Flag = change of owner on THIS box** (section 1, sat vs PC).
- D5. **Auto-undo only for a flagged install that breaks the box's reach to
  the hub** (DNS + the hub's `/version`). It reverts the agent's own change;
  it refuses nothing beforehand. `BOX_PKG_AUTO_UNDO=0` turns it off per
  call. The 10-16 outage was 22 min; this would have cut it to about one
  health-probe timeout.
- D6. `satellite-replica.tsv` stays the tool/version list `do_satellite_verify`
  reads. The manifest is the one home of "which package, who needs it"; a
  test keeps the two consistent (every replica row's tool has a manifest
  row).

## 5. Design

### 5.1 The manifest

`iac/cnf/box-pkgs/<class>.tsv`, one per class (`pc.tsv`, `satellite.tsv`),
TAB separated, `#` comments, sorted by kind then name:

| column | example | rule |
|---|---|---|
| kind | `apt`, `deb`, `bin`, `pip`, `npm`, `go`, `corepack`, `image` | fixed set |
| name | `postgresql-client` | apt/deb: the package; bin: the path |
| pin | empty, or a version / sha256 | as the installer pins it |
| installed_by | `play 02_os_binaries`, `do_setup_box_sysstat`, `spool-install --cli grok` | an existing role or action, or `spool-install [--cli <name>]` for what orc `spool-install/install.sh` writes (the agent CLIs, the kill guard) with a name its `--cli` takes; the test resolves each |
| needed_by | `do_require_bin psql (43 actions)` | an action, a test, or `lane SPL-n`; never empty |
| service | empty, or `dns` / `network` / `init` / `firewall` / `ssh` | set when it owns a system service |
| added | `2026-10-17 SPL-2271` | date + issue key; `backfill` for the 2.2/2.3 rows |

The rows are the first build row (B1): the playbook roles, the actions of
2.1, and the 2.2/2.3 hand installs as `backfill` with
`needed_by=unknown (backfill)` until a lane claims them.

### 5.2 The install action: `do_box_pkg_install`

`iac/src/bash/run/box-pkg-install.func.sh`. Inputs: `BOX_PKG` (one or
more), `BOX_PKG_REASON` (required, free text), `AGENT_ID` (required),
`BOX_PKG_ISSUE` (optional SPL-n), `DRY_RUN` (default 1, as every infra
action here). Steps, in order:

1. **Simulate**: `apt-get -s install <pkgs>`; parse every `Inst` and `Remv`
   line. The closure is what gets checked and recorded, not the request
   (section 1: one asked, two installed).
2. **Flag** (5.3) on the closure. A flag sends a `note` to the orchestrator
   (`spool-send.sh --to orchestrator --kind note`, never a blocker, never
   the owner) and prints `FLAG <service> <pkg> <current owner> -> <new>`.
   It does not stop the install.
3. **Snapshot** before a flagged install: `dpkg --get-selections`,
   `readlink /etc/resolv.conf` + its content, `/etc/nsswitch.conf`,
   `/etc/NetworkManager/`, `/etc/systemd/network/`, `/etc/network/`, into
   `/var/backups/box-pkg/<UTC stamp>-<agent id>/` (generalises the 12:43Z
   hand backup).
4. **Journal**: append one line to `/var/lib/csi-spl/box-pkg/journal.tsv`:
   UTC time, box, agent id, issue, op=`install`, requested, closure, flag,
   snapshot dir, reason. The line is written **before** the install and a
   result line after, so a crash leaves the intent.
5. **Install**: `DEBIAN_FRONTEND=noninteractive apt-get install -y <pkgs>`
   (the request, not the closure; apt resolves the same).
6. **Verify**: each requested package `dpkg-query -W` = `install ok
   installed`; then the **health probe**: resolve the hub host
   (`BASE_DOMAIN` from cnf) and fetch its `/version` (the proof
   `do_check_hub_deploy` uses). Health red after a flagged install, with
   `BOX_PKG_AUTO_UNDO` unset or 1: run 5.4 on that journal entry, then send
   the orchestrator a `note` with both lines.
7. **Print the manifest row** for the agent to commit (D3).

`DRY_RUN=1` does 1 and 2 (the note says "dry run") and prints 3..7.

### 5.3 The service-takeover check: `do_box_pkg_flag`

`iac/src/bash/run/box-pkg-flag.func.sh`, pure: input the simulation text and
the box probes, output the flags. Read-only, any user.

Service map, cnf `env.box.pkg_services` (its one home), each with the
packages that can own it and a probe for who owns it now:

| service | candidate packages | current owner probe |
|---|---|---|
| dns | systemd-resolved, libnss-resolve, resolvconf, openresolv, dnsmasq, unbound, bind9 | `readlink -f /etc/resolv.conf`; the `hosts:` line of `/etc/nsswitch.conf` |
| network | network-manager, ifupdown, netplan.io, connman, dhcpcd, isc-dhcp-client (systemd-networkd by its unit) | the `active` one of their units |
| init | systemd-sysv, sysvinit-core, openrc, runit-init | `readlink -f /sbin/init` |
| firewall | ufw, firewalld, nftables, iptables-persistent | the `active` unit |
| ssh | openssh-server, dropbear | the `active` unit, the listener on 22 |

Flag when a closure `Inst` package is a candidate for a service whose
current owner is another package (a takeover), or a `Remv` line removes the
current owner. Not flagged: installing the package that already owns it
(sat + systemd-resolved). On PC on 2026-10-16 it would have printed
`FLAG dns systemd-resolved NetworkManager -> systemd-resolved` and
`FLAG dns libnss-resolve nsswitch:dns -> resolve`.

### 5.4 The undo: `do_box_pkg_purge`

`iac/src/bash/run/box-pkg-purge.func.sh`, the name c-001 queued, one action
only (if c-001's lands first, row B5 adds this behaviour to it instead of a
second action). Input `BOX_PKG_JOURNAL_ID` (a journal line) or `BOX_PKG` +
`BOX_PKG_SNAPSHOT` (a hand case such as 10-16). `DRY_RUN=1` default.

1. `apt-get -s purge <closure>`; refuse when it would remove anything outside
   the recorded closure (that is a different change).
2. Journal the intent line (op=`purge`).
3. `apt-get purge -y <closure>`.
4. Restore from the snapshot what the purge leaves wrong: the
   `/etc/resolv.conf` link, the `hosts:` line of `/etc/nsswitch.conf`, the
   network config dirs; restart the service owner the snapshot names.
5. Health probe (5.2 step 6); journal the result; note to the orchestrator.

Worked case, the replay test: snapshot = the 12:43Z backup dir's layout,
closure = `systemd-resolved libnss-resolve`, expected end state = the link
to `/run/NetworkManager/resolv.conf`, a `hosts:` line without `resolve`,
health green.

### 5.5 Drift: `do_box_pkg_drift`

`iac/src/bash/run/box-pkg-drift.func.sh`, read-only. Compares
`apt-mark showmanual` (minus a `base` list per class, captured once from the
image), the journal, `/usr/local/bin` and the agent user's `~/.local/bin`
with `<class>.tsv`. Prints `MISSING-FROM-BOX` and `NOT-IN-MANIFEST` (with
the journal's agent id and reason when known) and exits 0; `DRIFT_STRICT=1`
exits 2 on any `NOT-IN-MANIFEST`. A daily cron run per box posts a
non-empty report as one `note` to the orchestrator.

Present is not the same as manual (SPL-2339): a row is `MISSING-FROM-BOX`
only when `dpkg-query -W` does not say `ii` for it, so a package installed as
a dependency (marked auto) still counts, and a `bin` row that names a path
outside the bin dirs counts when that path is executable. `NOT-IN-MANIFEST`
stays `showmanual` minus the base list: an auto-marked package is a
dependency, not drift. Run it as the agent user: a bin that links into that
user's home (e.g. `grok`) is not executable for another user.

### 5.6 Pointing agents at it

- `do_require_bin`'s hint (3 copies) prints
  `./run -a do_box_pkg_install BOX_PKG=<pkg> BOX_PKG_REASON='...'` instead
  of `sudo apt-get install -y <pkg>`.
- spool-install's four "yours to run" hints stay (it runs before the repo is
  there).
- The seed (spawn-core) gets one line: "install a package with
  `do_box_pkg_install`; you keep sudo, the action records it". Its one home
  goes into `fleet-rules-index.md`.

## 6. Risks

- An agent still types a raw `sudo apt-get`. Nothing stops it (the owner's
  choice); drift (5.5) names it within a day and the apt history still has
  the time.
- The service map misses a service. The map is cnf; the 10-16 case is the
  test's control, and a new case adds a row.
- Auto-undo reverts a change a lane wanted. It fires only on a flagged
  install AND a red hub probe, i.e. the box is off the fleet; the note says
  what was undone and the journal keeps the request.
- Two lanes add manifest rows at once: sorted, one row per line, the usual
  rebase.

<!-- version: 0.1.0 · updated: 2026-10-17 -->
