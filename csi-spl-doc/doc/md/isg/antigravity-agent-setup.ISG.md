# antigravity-agent-setup.ISG — install & setup guide (for antigravity / agy agents)

> **Partly verified.** Run from inside `AGY-3493` on 2026-09-25: agy 1.2.11,
> tmux 3.5a, csi-spl `b4ef063`, env `dev`, tenant `t1`, desk box `box-desk`.
> n=1 unless a step says otherwise. Still untested: `do_spl_desk_session_upload`
> finding an agy transcript (section 6).

Measured on that seat:

- the window name carries `AGY-3493`, and the seat
  directory was created by the centralized reseat (`do_spl_desk_up_all`)
- `#{alternate_on}` was 0 (agy runs on the normal screen buffer, 189x51).
  Because `alternate_on` is 0, `spl_desk_show_pane` in `spl-desk-up.func.sh`
  skips opening a split notice pane (which is only opened for `alternate_on = 1`
  TUIs to avoid display corruption). Messages and prompt pokes write to the tty
  directly, keeping the full terminal width intact with no split noise
- `ps -o tty=` for this agy printed a pts (`pts/76`), launched with
  `su - <AGENT_USER> --pty` (login shell + pty) and `--dangerously-skip-permissions`
- `do_spl_desk_check` ran cleanly with `verdict ok`: sidecar up, hub session
  active, hub lists `AGY-3493` as reachable, terminal poke enabled

## 0. A person joining with a agy agent on their own machine

Use the installer exactly as in the Claude guide 0.1, with `--cli agy` (or
`--cli claude,agy`), then start the agent with `spool-agent agy`. Untested
for agy: record what happened in section 9.

MCP (the Claude guide 6.0): untested for agy. Whether `agy` can register the
`spool-dev` / `spool-prd` MCP servers is being checked (spec 028 T074); until
then use the desk actions of section 6.

## 1. What this installs

The same as for Claude: a seat in the box's desk, a notice strip (skipped on
normal screen `alternate_on = 0`), a prompt poke, and the `csi-spl-orc` desk
actions. See `claude-agent-setup.ISG.md` §1.

## 2. Prerequisites

### 2.1 An id in the window name

`AGY-<n>`. `/agy-spawn` names the window; a hand-started agy needs its window
renamed to carry the id, or it is never seated.

Measured: the window name carries `AGY-3493` (matched `AGY-<n>` regex) and
was seated successfully.

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

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGY-ID> DRY_RUN=0 ./run -a do_spl_desk_up'
```

Measured: `AGY-3493`'s seat directory was created during centralized
`do_spl_desk_up_all` seating under `$SPL_STATE_DIR/desk/t1/box-desk/spool/AGY-3493/`.

## 5. Verify

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGY-ID> ./run -a do_spl_desk_check'
```

Verdicts and the repair (`DESK_REPAIR=1 DRY_RUN=0`) as in the Claude guide §5.

Measured n=1: printed `verdict ok`. Output:
`{"agent": "AGY-3493", "agent_muted": false, "box": "box-desk", "env": "dev", "hub_box_online": true, "hub_last_hello_at": "...", "hub_lists_agent": true, "sidecar_alive": true, "spool_root": "...", "state_dir": "...", "tenant": "t1", "terminal_poke": true, "terminal_poke_box": true, "verdict": "ok"}`
Confirmed: sidecar up, hub has session for box-desk, hub lists `AGY-3493`,
terminal poke enabled, inbox is in the desk spool tree.

## 6. Use

Read, open files and answer exactly as in the Claude guide §6, with your
`AGY-<n>` id. `do_spl_desk_session_upload` has no agy transcript format: export
your conversation to a markdown file yourself if you are asked for it.

## 7. Conditions

As in the Claude guide §7.

## 8. Uninstall

As in the Claude guide §8.

## 9. Update this document

The measurements above are from `AGY-3493`, agy 1.2.11, csi-spl `b4ef063`,
n as each step states. One step is still open: `do_spl_desk_session_upload`
exporting an agy conversation. Delete the "still untested" line at the top
only after that has been verified.

<!-- version: 0.2.0 · updated: 2026-09-25 · last-edit: 2026-09-25T16:45:00Z -->
