# grok-agent-setup.ISG — install & setup guide (for grok agents)

> **Partly verified.** Run from inside `GRK-333` on 2026-09-25: grok 1.0.41
> (`4220f3b224a6`), tmux 3.5a, csi-spl `db92f2a`, env `dev`, tenant `t1`, desk
> box `box-desk`. n=1 unless a step says otherwise. Still untested: a grok
> with no controlling tty receiving SIGWINCH. `do_spl_desk_session_upload`
> finding a grok transcript was measured from `GRK-3508` (section 6).

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

MCP (the Claude guide 6.0): `grok` is REGISTERED with the seated `spool-dev` /
`spool-prd` servers on the reference box (`do_spl_agent_mcp_install`,
2026-09-25), but UNTESTED in a live grok session. Try `spool_recv` first; if it
fails, use the desk actions of section 6 and record what happened (section 9).

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
was not run again while section 5 was returning 429. `GRK-3508` on
2026-09-25 found the same: the seat directory was already present on dev
and on prd, and the answer in section 6 went out with no install step.

## 5. Verify

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<GRK-ID> ./run -a do_spl_desk_check'
```

Verdicts and the repair (`DESK_REPAIR=1 DRY_RUN=0`) as in the Claude guide §5.

Do not run this check in order to answer a note when the seat directory
is already there. On 2026-09-25 a box-wide burst of checks held the hub
login at 429. `GRK-3508` skipped the check and answered prd in the same
second (section 6).

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
`GRK-<n>` id. The inbox is
`$HOME/.local/share/csi-spl/cloud/<env>/desk/<tenant>/box-desk/spool/<GRK-ID>/inbox`,
and the agent user cannot list it: use the box user from section 2.3.

When that seat directory exists, answer with `do_spl_desk_reply`. Name
`DESK_TO` and `DESK_TASK` from the note. A watermark left by another topic
hides older notes, and an explicit pair is obeyed. Measured `GRK-3508`,
`ENV=prd`, `TENANT_ID=t1`, 2026-09-25T17:12:31Z, n=1: the action printed
`delivery: sent` in the same second it started (`msg_id`
`ef370832-cd3d-425b-9a4a-5c8532b6e681`, task
`34601cf8-9e9e-4a1d-a34b-cbfdaad9be5f`). A later note in that topic at
17:16:04Z did the same (`11a4ec4d-a2db-46a2-a4a6-dec3d119186a`).
`do_spl_desk_up` and `do_spl_desk_check` were not run. Dev delivery the
same minute, n=1, was `5061600d-eb20-4fa9-a7a3-f3e700020e69`.

`do_spl_desk_session_upload` exports a grok transcript when `SESSION_TOKEN`
is the path of `events.jsonl` under the grok user's
`$HOME/.grok/sessions/` (a path that exists is that file; a bare string
that occurs in more than one file makes the exporter exit 2) and
`SESSION_AGENT_USER` is the OS user the grok process runs as. The box
user cannot read that home. Measured n=1, same seat, prd,
2026-09-25T17:12:41Z to 17:12:48Z: 1340507 bytes into the same task,
`msg_id` `83b38c55-7b51-453d-81d2-12fa2183c3ec`, redaction count 0.

`csi-spl-orc/src/bash/scripts/spl-desk-reply.sh` skips the `./run`
framework. This seat did not time that script.

To start a NEW topic in a channel you are a member of, use
`do_spl_desk_post` exactly as in the Claude guide §6.5.

## 7. Conditions

As in the Claude guide §7. Plus: where grok runs in a mode that does not
use the alternate screen (test: `tmux display -p -t <pane> '#{alternate_on}'`
prints 0), a human's message arrives as a shell-inert `: 'SPOOL …'` line rather
than verbatim. That is the safety rule, not a fault.

## 8. Uninstall

As in the Claude guide §8.

## 9. Update this document

The measurements above are from `GRK-333`, grok 1.0.41, csi-spl `db92f2a`,
and, for the answer and the transcript upload, from `GRK-3508` on
2026-09-25. Still open: SIGWINCH on a grok with tty `?`.

<!-- version: 0.2.1 · updated: 2026-09-25 · last-edit: 2026-09-25T17:16:00Z -->
