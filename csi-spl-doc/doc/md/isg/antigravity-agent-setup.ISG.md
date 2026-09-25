# antigravity-agent-setup.ISG — install & setup guide (for antigravity / agy agents)

> **NOT TESTED at all.** Written 2026-09-25 from the Claude Code guide
> (`claude-agent-setup.ISG.md`, verified on the reference box). On that box no
> `AGY-<n>` window was seated at the time of writing, so not one step below has
> been seen working for agy. **Set yourself up on your own, and update this
> document** with what actually happened (section 9).

What is known on the reference box (2026-09-25, csi-spl `2463b73`, dev / t1):

- `spool-env.inc.sh` knows the `agy` CLI and maps it to the `AGY` id prefix
- 2 `agy` processes were running; one had no controlling tty (`ps` tty `?`)
- none was in the reseat cron's seated list at 13:50:35Z: no window named
  `AGY-<n>` was live

## 1. What this installs

The same as for Claude: a seat in the box's desk, a notice strip, a prompt
poke, and the `csi-spl-orc` desk actions. See `claude-agent-setup.ISG.md` §1.

## 2. Prerequisites

### 2.1 An id in the window name

`AGY-<n>`. `/agy-spawn` names the window; a hand-started agy needs its window
renamed to carry the id, or it is never seated.

### 2.2 Launch with `su --pty`

```
sudo su --pty - <AGENT_USER> -c 'cd /opt; agy'
```

Unknown for agy: whether it runs on the alternate screen, and whether it
repaints on SIGWINCH. Both decide whether a human's message reaches your
prompt verbatim and whether the notice strip garbles your pane.

### 2.3 Sudo to the box user

Identical to the Claude guide §2.3.

```
BOX_USER=$(ps -eo user=,comm= | awk '$2 ~ /^tmux/ {print $1; exit}')
```

```
sudo -n -u "$BOX_USER" true && echo ok
```

### 2.4 Pinned desk

dev / t1 only on the reference box. No prd desk yet (owner step).

## 3. Credentials

None held by the agent.

## 4. Install steps

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGY-ID> DRY_RUN=0 ./run -a do_spl_desk_up'
```

## 5. Verify

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGY-ID> ./run -a do_spl_desk_check'
```

Verdicts and the repair (`DESK_REPAIR=1 DRY_RUN=0`) as in the Claude guide §5.

## 6. Use

Read, open files and answer exactly as in the Claude guide §6, with your
`AGY-<n>` id. `do_spl_desk_session_upload` has no agy transcript format: export
your conversation to a markdown file yourself if you are asked for it.

## 7. Conditions

As in the Claude guide §7.

## 8. Uninstall

As in the Claude guide §8.

## 9. Update this document

When you have set yourself up, edit this file in a worktree of
`github.com/csitea/csi-spl`: remove what was wrong, and next to each step write
what you measured (agy version, csi-spl sha, n). Then follow the repo's
CLAUDE.md: explicit pathspec, `cd csi-spl-iac && ./run -a do_check_dist_hygiene`
green, rebase, push to master. When every step has been verified, delete the
NOT TESTED banner.

<!-- version: 0.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T14:10:00Z -->
