# grok-agent-setup.ISG — install & setup guide (for grok agents)

> **NOT TESTED end to end.** Written 2026-09-25 from the Claude Code guide
> (`claude-agent-setup.ISG.md`, verified on the reference box) and from what the
> box shows for grok, n=1. Nobody has yet run every step below from inside a
> grok session. **Set yourself up on your own, and update this document** with
> what actually happened (section 9).

What is known on the reference box (2026-09-25, csi-spl `2463b73`, dev / t1):

- a grok window carrying an id (`GRK-333`) WAS seated by the 5-minute reseat
  cron (`do_spl_desk_up_all` output at 13:50:35Z lists it)
- its pane is on the alternate screen (`#{alternate_on}` = 1), so a human's
  message is typed into its prompt verbatim, as for Claude
- 2 of the 3 grok processes on the box had no controlling tty (`ps` tty `?`):
  they were launched with plain `su -` and will garble when the notice strip
  splits in (2.2 below)

## 1. What this installs

The same as for Claude: a seat in the box's desk, a notice strip, a prompt
poke, and the `csi-spl-orc` desk actions. See `claude-agent-setup.ISG.md` §1.

## 2. Prerequisites

### 2.1 An id in the window name

`GRK-<n>`. `/grok-spawn` names the window; a hand-started grok needs its window
renamed to carry the id, or it is never seated.

### 2.2 Launch with `su --pty`

```
sudo su --pty - <AGENT_USER> -c 'cd /opt; grok'
```

Untested for grok: whether grok repaints correctly on SIGWINCH once it does
receive it. Check yours after the strip arrives, and record it (section 9).

### 2.3 Sudo to the box user

Identical to the Claude guide §2.3: the desk tree is `0700` and owned by the
box user.

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
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<GRK-ID> DRY_RUN=0 ./run -a do_spl_desk_up'
```

## 5. Verify

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<GRK-ID> ./run -a do_spl_desk_check'
```

Verdicts and the repair (`DESK_REPAIR=1 DRY_RUN=0`) as in the Claude guide §5.

## 6. Use

Read, open files and answer exactly as in the Claude guide §6, with your
`GRK-<n>` id. Untested for grok: `do_spl_desk_session_upload` locates grok
transcripts through its export script. If it does not find yours, export your
conversation to a markdown file yourself and send that.

## 7. Conditions

As in the Claude guide §7. Plus: where grok runs in a mode that does not
use the alternate screen (test: `tmux display -p -t <pane> '#{alternate_on}'`
prints 0), a human's message arrives as a shell-inert `: 'SPOOL …'` line rather
than verbatim. That is the safety rule, not a fault.

## 8. Uninstall

As in the Claude guide §8.

## 9. Update this document

When you have set yourself up, edit this file in a worktree of
`github.com/csitea/csi-spl`: remove what was wrong, and next to each step write
what you measured (grok version, csi-spl sha, n). Then follow the repo's
CLAUDE.md: explicit pathspec, `cd csi-spl-iac && ./run -a do_check_dist_hygiene`
green, rebase, push to master. When every step has been verified, delete the
NOT TESTED banner.

<!-- version: 0.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T14:10:00Z -->
