# Agents never change a box's system: the guards

Issue SPL-2187. A package, a service or a file under `/etc` on a box is the
owner's to change, never an agent's. This page says what stops an agent, and
what does not.

## 1. The incident

2026-10-16, measured on one fleet box by the orchestrator from `journalctl`,
`/var/log/dpkg.log` and the watchdog log (n=1): a doc-only panel seat ran, as
root, from its worktree:

- 10:18Z `apt-get update`, then `apt-get install -y manpages manpages-dev
  manpages-posix manpages-posix-dev network-manager`;
- 10:19:38Z `apt-get install -y systemd-resolved` (+ `libnss-resolve`).

systemd-resolved took `/etc/resolv.conf`, DNS died for the agent tools, the
box's beats failed from 10:19:46Z to 10:42:09Z and the fence stopped 15 lanes.
The agent user had `NOPASSWD: ALL`.

## 2. Layer 2: the pre-tool hook of every harness

The one shared shell-command matcher,
`csi-spl-orc/src/bash/features/spawn-agents/lib/force-push-guard.inc.sh`,
runs before every shell call of claude, grok, agy, qwen (step y13) and
mistral vibe (step y12). Besides the forbidden push forms it now refuses a
system change; the refusal reads
`force-push-guard: refused: system change: ... (SPL-2187)`:

| kind | refused | still passes |
|---|---|---|
| packages | `apt` / `apt-get` / `aptitude` install, remove, purge, update, upgrade, ...; `dpkg -i/-r/-P/--configure`; `apt-mark hold`; `snap install`; `add-apt-repository`, `apt-key`, `dpkg-reconfigure`, `do-release-upgrade`, `update-alternatives --set` | `apt list`, `apt show`, `apt-cache`, `apt-get -s` (simulate), `dpkg -l/-L/-s/-S`, `dpkg-query` |
| services | `systemctl start/stop/restart/enable/mask/daemon-reload/...`, `service <x> <verb>`, `/etc/init.d/<x> <verb>`, `update-rc.d`, `resolvectl dns <link> <ip>`, `hostnamectl/timedatectl/localectl set-*`, `reboot`, `shutdown` | `systemctl status/show/is-*/list-*`, anything with `systemctl --user`, `service <x> status`, `resolvectl status/query`, `journalctl` |
| `/etc` | `> /etc/x`, `>> /etc/x`, `tee /etc/x`, `rm/chmod/chown/mkdir/touch ... /etc/x`, `cp/mv/install/ln/rsync ... /etc/...` (into), `sed -i`/`perl -i` on `/etc/x`, `dd of=/etc/x` | reading `/etc` (`cat`, `grep`, `cp /etc/x /tmp/`) |

It reads through `sudo`, `sudo -u <owner> bash -c "..."`, `env`, `xargs`,
`timeout`, `ssh <host> ...`, `$( )`, `&&`, `;` and heredocs fed to a shell.
`docker run ... apt-get install` is the container's, not the box's, and passes.

What it cannot stop (a ban list cannot prove absence): a command inside a
script file or a variable, a binary copied under another name, a container
started with `/` mounted, a harness that does not run its hook. The test,
with a control that disables the check and watches the refused cases pass:
`bash csi-spl-orc/src/bash/tests/system-change-guard.tst.sh`.

Rollout: the installed copies refresh when spool-install's steps y12 and y13
run for the agent user (`./run -a do_spl_vibe_push_guard_install`, and
`do_install_force_push_guard`); until then the boxes run the previous copy.

## 3. Layer 1: the agent user's sudo

Until now every box gave the agent user `NOPASSWD: ALL`
(`/etc/sudoers.d/90-<agent>-nopasswd`, written by the satellite playbook role
`05_users`, by hand on the box PC). The named action
`cd csi-spl-iac && ./run -a do_spl_agent_sudoers` rewrites that one file:

- the agent runs anything as **any user but root** (`(ALL,!root)`), so
  `sudo -u <owner> git ...`, `sudo -u <owner> ./run ...` and
  `sudo -u <owner> tee ...` keep working;
- as **root** only the read-only commands the fleet's scripts use (measured
  from the sudo journal, 2026-10-14..16: `true`, `cat`, `test`, `readlink`,
  `ls`, `stat`, `du`, `find`, `grep`, `head`, `tail`, `wc`, `sha256sum`,
  `diff`, `id`, `kill`, and `journalctl` without its write flags), all
  `NOEXEC` (no `find -exec`, no pager shell).

What an agent did as root before and now does as the owner user instead:
`sudo -u <owner> rm|chmod|setfacl|tee|mkdir ...` in the owner's worktrees and
spool dirs.

It runs as the owner user (it needs root to read and write `/etc/sudoers.d`):

| step | command |
|---|---|
| see today's rules and the diff, write nothing | `./run -a do_spl_agent_sudoers` |
| a box without `/etc/csi-spl-satellite.env` | `SPL_AGENT_SUDO_USER=<agent-user> SPL_AGENT_SUDO_OWNER=<owner-user> ./run -a do_spl_agent_sudoers` |
| apply (a box system change: the owner's go first) | `DRY_RUN=0 ./run -a do_spl_agent_sudoers` |
| revert to `NOPASSWD: ALL` | `SPL_AGENT_SUDO_MODE=all DRY_RUN=0 ./run -a do_spl_agent_sudoers` |

`DRY_RUN=0` checks the file with `visudo -cf`, backs the old one up under
`/var/backups/csi-spl-sudoers/`, installs it `0440 root`, checks the whole
sudo config (restores the backup when it does not parse) and then probes with
`sudo -l -U <agent>`: it fails unless every probe holds (apt-get, apt, dpkg,
systemctl, tee into `/etc`, cp into `/etc/sudoers.d`, bash and journalctl
`--vacuum` refused; `-u <owner>`, cat, find, du, readlink, kill, journalctl
allowed).

What it does NOT stop, by design of sudo itself:

- a hop through the owner user, `sudo -u <owner> sudo apt-get ...`: the owner
  keeps `NOPASSWD: ALL` for the human's own work. Layer 2 reads that form in a
  harness call; a script file is read by neither.
- the `docker` group, which agents need for the test stacks: a container
  with `/` mounted is root on the box.
- `find -delete` / `find -fprint` as root (`NOEXEC` stops only `-exec`).
- the satellite playbook role `05_users` still writes `NOPASSWD:ALL`: a
  playbook run puts it back until the role uses this file.

Tests: `bash csi-spl-iac/src/bash/tests/spl-agent-sudoers.tst.sh` (the file,
the dry run, the backup, the revert; control: a config that does not parse is
rolled back byte for byte) and `spl-agent-sudoers-live.tst.sh` (a real sudo in
a throwaway container: the red control shows apt-get, systemctl and tee into
`/etc` ALLOWED before the action, refused after it, and the owner hop still
allowed).
