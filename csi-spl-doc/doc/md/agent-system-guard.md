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
