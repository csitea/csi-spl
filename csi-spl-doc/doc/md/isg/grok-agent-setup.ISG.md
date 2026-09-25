# grok-agent-setup.ISG — install & setup guide (for grok agents)

> **Partly verified.** Run from inside `GRK-333` on 2026-09-25: grok 1.0.41
> (`4220f3b224a6`), tmux 3.5a, csi-spl `db92f2a`, env `dev`, tenant `t1`, desk
> box `box-desk`. n=1 unless a step says otherwise. Still untested: a grok
> with no controlling tty receiving SIGWINCH, and `do_spl_desk_session_upload`
> finding a grok transcript (section 6).

Measured on that seat:

- the window name carries `GRK-333`, and the seat directory was already there
  (the 5-minute reseat). `#{alternate_on}` was 1, so a human's message is
  typed into the prompt verbatim
- the notice pane was 48 columns and the agent pane 140x51
- `ps -o tty=` for that grok printed a pts, not `?`. An earlier look at
  `2463b73` found 2 of 3 grok processes with tty `?` (plain `su -`, no
  `--pty`); those are the ones section 2.2 is about

## 0. A person joining with a grok agent on their own machine

Use the installer exactly as in the Claude guide 0.1, with `--cli grok` (or
`--cli claude,grok`), then start the agent with `spool-agent grok`. Untested
for grok: record what happened in section 9.

MCP (the Claude guide 6.0): untested for grok. Whether `grok` can register the
`spool-dev` / `spool-prd` MCP servers is being checked (spec 028 T074); until
then use the desk actions of section 6.

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

The measured process was `su - <AGENT_USER> --pty` (a login shell, plus a
pty) and its argv included `--dangerously-skip-permissions`. Its tty was a
pts, `alternate_on` was 1, and no `kill -WINCH` was sent: the pane stayed
usable with the 48-column strip, n=1. A login shell does not keep the
spawner's environment, so `MCP_BOT_AGENT_ID` is unset unless the `-c`
command exports it. The terminal mirror then has no agent id unless it
reads one from the window name.

Whether a grok whose tty is `?` repaints on SIGWINCH is still untested.

### 2.3 Sudo to the box user

Identical to the Claude guide §2.3: the desk tree is `0700` and owned by the
box user.

```
BOX_USER=$(ps -eo user=,comm= | awk '$2 ~ /^tmux/ {print $1; exit}')
```

```
sudo -n -u "$BOX_USER" true && echo ok
```

Measured n=1: that printed `ok`. `ls` of the desk directory as the agent
user printed `Permission denied`. The directory mode was `700`, owned by
the tmux server's user.

### 2.4 Pinned desk

dev / t1 and prd / t1 on the reference box (prd since 2026-09-25T15:41:30Z).
A NEW box needs the tenant admin's pin: see the Claude guide 0.1.

## 3. Credentials

None held by the agent.

## 4. Install steps

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<GRK-ID> DRY_RUN=0 ./run -a do_spl_desk_up'
```

Measured: `GRK-333`'s seat directory was already present, so `do_spl_desk_up`
was not run again while section 5 was returning 429.

## 5. Verify

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<GRK-ID> ./run -a do_spl_desk_check'
```

Verdicts and the repair (`DESK_REPAIR=1 DRY_RUN=0`) as in the Claude guide §5.

A 429 is not one of those verdicts. Measured n=4, 18:06:06 through
18:11:45 EEST, each run exited 1 with
`{"step": "login", "status": 429, "error": "rate_limited"}` because every
seat ran this step at once. The local sidecar stayed up the whole time
(`hub session up` at 18:01:28 EEST). Do not run `DESK_REPAIR` for a 429.
Retry, or pass `DESK_ROSTER_JSON` as the action's own message says. An
earlier run the same day, 17:12:57 EEST, n=1, printed `verdict ok` for
`GRK-333` (hub listed the agent, prompt poke on, not muted) on a sidecar
process that has since been replaced.

## 6. Use

Read, open files and answer exactly as in the Claude guide §6, with your
`GRK-<n>` id. `do_spl_desk_reply` from this seat has delivered to the dev
hub (several notes the same day). `do_spl_desk_session_upload` locating a
grok transcript is still untested: a dry run sends nothing and does not
export, and a real run would publish the transcript to the tenant, so it
was not fired. If the export does not find yours, export the conversation
to a markdown file yourself and send that.

## 7. Conditions

As in the Claude guide §7. Plus: where grok runs in a mode that does not
use the alternate screen (test: `tmux display -p -t <pane> '#{alternate_on}'`
prints 0), a human's message arrives as a shell-inert `: 'SPOOL …'` line rather
than verbatim. That is the safety rule, not a fault.

## 8. Uninstall

As in the Claude guide §8.

## 9. Update this document

The measurements above are from `GRK-333`, grok 1.0.41, csi-spl `db92f2a`,
n as each step states. Two steps are still open: SIGWINCH on a grok with
tty `?`, and `do_spl_desk_session_upload` actually exporting a grok
transcript. Delete the "still untested" line at the top only after those
two have been run.

<!-- version: 0.2.0 · updated: 2026-09-25 · last-edit: 2026-09-25T15:15:00Z -->
