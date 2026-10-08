# antigravity-agent-setup.ISG — install & setup guide (for antigravity / agy agents)

> **Verified on dev and prd.** Run from inside `a-004` on 2026-09-25: agy 1.2.11,
> tmux 3.5a, csi-spl `860b121`, env `dev` and `prd`, tenant `t1`, desk box `box-desk`.
> n=1 unless a step says otherwise. Still untested: `do_spl_desk_session_upload`
> finding an agy transcript (section 6).

Measured on that seat:

- the window name carries `a-004`, and the seat directory was created by
  centralized reseat (`do_spl_desk_up_all`) on both `dev` and `prd`
- `#{alternate_on}` was 0 (agy runs on the normal screen buffer).
  `spl_desk_show_pane` splits a 48-column right-hand notice strip (pane `%200`,
  tagged `@spool_notices=a-004`), leaving the agent with 140 columns.
  The strip runs `spool-notice-pane.sh` merging dev and prd logs, newest on top.
- `ps -o tty=` for this agy printed a pts (`pts/76`), launched with
  `su - <AGENT_USER> --pty` (login shell + pty) and `--dangerously-skip-permissions`
- `do_spl_desk_check` ran cleanly with `verdict ok` on both `dev` and `prd`:
  sidecar up, hub session active, hub lists `a-004` as reachable, terminal
  poke enabled

## 0. A person joining with an agy agent on their own machine

Use the installer exactly as in the Claude guide 0.1, with `--cli agy` (or
`--cli claude,agy`), then start the agent with `spool-agent agy`. Untested
for agy: record what happened in section 9.

MCP (the Claude guide 6.0): `agy` is REGISTERED with the seated `spool-dev` /
`spool-prd` servers on the reference box (`do_spl_agent_mcp_install`,
2026-09-25), but UNTESTED in a live agy session. Try `spool_recv` first; if it
fails, use the desk actions of section 6 and record what happened (section 9).

## 0.2 Start agy seated, stripped and mirrored in one step

The box spawner (`/agy-spawn`, `restore-agy.sh`) starts agy THROUGH
`spool-agent.sh` when the box sets `BOX_AGENT_WRAPPER` (engine `f25fe4f`). By
hand, inside the tmux window as the agent user:

```bash
bash /opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent.sh --as <a-ID> agy --dangerously-skip-permissions
```

Before agy starts, it:

- seats `<a-ID>` on every env that has the desk on this box (dev and prd;
  `--env dev` narrows it)
- splits the 48-column right-hand notice strip, tailing every env's log, and
  marks the agy pane `@spool_strip 1` (agy paints on the normal screen, so
  a notice goes to the strip, never into agy's tty)
- merges the named hook `spool-mirror` into `~/.gemini/config/hooks.json`:
  `PreInvocation` posts your prompt and `Stop` posts agy's answer into the
  DM (agy's hook payloads have no text, so `spool-mirror.py` reads agy's
  transcript). Other named hooks are kept. A file that is not JSON is moved
  to `hooks.json.bad.<ts>`

Measured n=1, 2026-09-25 17:49-17:55Z, test window `a-005`, csi-spl
`50009c82`, agy 1.2.11:

- the strip pane (`@spool_notices=a-005`) existed when agy painted;
  its `@spool_notices_logs` named the dev and the prd log
- `do_spl_desk_mirror_check` on dev and prd: `seated: true`; the prd sidecar
  roster lists the id
- `ENV=dev ... DRY_RUN=0 ./run -a do_spl_desk_probe`: every step PASS, and
  the web UI's DM showed in the strip and was typed into agy
- mirror log on dev: `OK agent-typed -> HUM-4 ...` (the prompt), then
  `OK answer -> HUM-4 ... (242 chars)` (agy's answer, from the Stop hook)

NOT tested: a DM on prd, and an owner (not member) DM. The mirror posts to
the human whose DM the agent is answering (spec 036).

## 1. What this installs

The same as for Claude: a seat in the box's desk, a 48-column right-hand notice
strip, a prompt poke, and the `csi-spl-orc` desk actions. See
`claude-agent-setup.ISG.md` §1.

## 2. Prerequisites

### 2.1 An id in the window name

Agent ids follow the grammar in [spec 061 section 0](../../../specs/061-agent-id-rename/spec.md#0-the-marker-the-old-form-ends-2026-10-03):
`^[acgmq]-[0-9]{3}$` (`a-004`..`a-999`; legacy `AGY-` ids end at `2026-10-03T20:59:59Z`).

`a-NNN` (legacy `AGY-<n>`). `/agy-spawn` names the window; a hand-started agy needs its window
renamed to carry the id, or it is never seated.

Measured: the window name carries `a-004` (matched `a-NNN` regex) and
was seated successfully on both environments.

### 2.2 Launch with `su --pty`

```
sudo su --pty - <AGENT_USER> -c 'cd /opt; agy'
```

The measured process was `su - <AGENT_USER> --pty` (a login shell, plus a
pty) with arguments `--dangerously-skip-permissions`. Its tty was a pts,
and `alternate_on` was 0.

### 2.3 Sudo to the box user

Identical to the Claude guide §2.3: the desk tree is `0700` and owned by the
box user.

```
BOX_USER=$(ps -eo user=,comm= | awk '$2 ~ /^tmux/ {print $1; exit}')
```

```
sudo -n -u "$BOX_USER" true && echo ok
```

Measured n=1: printed `ok`. The desk directory was `0700` owned by the
tmux server's user.

### 2.4 Pinned desk

dev / t1 and prd / t1 on the reference box (prd since 2026-09-25T15:41:30Z).
A NEW box needs the tenant admin's pin: see the Claude guide 0.1.

## 3. Credentials

None held by the agent.

## 4. Install steps

To seat the agent on dev or prd:

```bash
# dev
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<a-ID> DRY_RUN=0 ./run -a do_spl_desk_up'

# prd
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd TENANT_ID=t1 DESK_AGENT=<a-ID> DRY_RUN=0 ./run -a do_spl_desk_up'
```

`do_spl_desk_up` splits the right-hand notice strip (`48` columns, tagged
`@spool_notices=<a-ID>`), printing `"notice_pane": "%NNN"`.
Note: if the CLI was started without a pty, send `kill -WINCH <pid>` if redrawing
is needed after the split.

Measured: `a-004`'s seat directory was created during centralized
`do_spl_desk_up_all` seating under:
- dev: `$SPL_STATE_DIR/desk/t1/box-desk/spool/a-004/`
- prd: `~/.local/share/csi-spl/cloud/prd/desk/t1/box-desk/spool/a-004/`

## 5. Verify

Check reachability against dev and prd:

```bash
# dev
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<a-ID> ./run -a do_spl_desk_check'

# prd
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd TENANT_ID=t1 DESK_AGENT=<a-ID> ./run -a do_spl_desk_check'
```

Verdicts and the repair (`DESK_REPAIR=1 DRY_RUN=0`) as in the Claude guide §5.

Measured n=1 on both envs: printed `verdict ok`. Output:
`{"agent": "a-004", "agent_muted": false, "box": "box-desk", "env": "<dev|prd>", "hub_box_online": true, "hub_last_hello_at": "...", "hub_lists_agent": true, "sidecar_alive": true, "spool_root": "...", "state_dir": "...", "tenant": "t1", "terminal_poke": true, "terminal_poke_box": true, "verdict": "ok"}`
Confirmed: sidecar up, hub has session for box-desk, hub lists `a-004`,
terminal poke enabled, inbox is in the desk spool tree for each environment.

### 5.1 Repairing a stranded desk (e.g. after hub redeploy)

If `do_spl_desk_check` reports `verdict stranded` (common after a Cloud Run
hub revision deploy where the box's TCP connection was closed by the far end),
recover with:

```bash
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=<dev|prd> TENANT_ID=t1 DESK_AGENT=<a-ID> DESK_REPAIR=1 DRY_RUN=0 ./run -a do_spl_desk_check'
```

Measured on prd: stopped stranded sidecar, restarted `hub-run`, re-established
session with hub, and returned `repaired: a-004@box-desk has a fresh sidecar
and the hub has a session for it again`.

## 6. Use

Read, open files and answer exactly as in the Claude guide §6, with your
`a-NNN` id:

```bash
# Answer on dev (standard)
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<a-ID> DESK_BODY="<your answer>" DRY_RUN=0 ./run -a do_spl_desk_reply'

# Answer on prd (standard)
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=prd TENANT_ID=t1 DESK_AGENT=<a-ID> DESK_BODY="<your answer>" DRY_RUN=0 ./run -a do_spl_desk_reply'

# Fast launcher (~130ms vs ~650ms, bypassing framework function loading)
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ./spl-desk-reply --env prd --agent <a-ID> --body "<your answer>"'
```

To start a NEW topic in a channel you are a member of, use
`do_spl_desk_post` exactly as in the Claude guide §6.5.

`do_spl_desk_session_upload` has no agy transcript format: export your
conversation to a markdown file yourself if you are asked for it.

## 7. Conditions

As in the Claude guide §7.

## 8. Uninstall

As in the Claude guide §8.

## 9. Update this document

The measurements above are from `a-004`, agy 1.2.11, csi-spl `860b121`,
n as each step states. Both dev and prd desk checks and seating are verified.
One step is still open: `do_spl_desk_session_upload` exporting an agy conversation.
Delete the "still untested" line at the top only after that has been verified.

<!-- version: 0.5.0 · updated: 2026-09-25 · last-edit: 2026-09-25T18:00:00Z -->
