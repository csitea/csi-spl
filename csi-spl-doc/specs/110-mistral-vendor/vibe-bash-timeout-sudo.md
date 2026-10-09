# vibe bash tool: a timed-out `sudo -u <box user>` command hangs the seat

Measured 2026-10-09 on the main box, mistral-vibe 2.26.0 (pipx venv, Python
3.13.5), against the defect m-617@sat reported (n=2, about 33 min each).

## 1. The defect

m-617's pane showed `Running command… 33m` twice. During the hang, vibe's pid
had only its own threads, with no shell and no other child. The hung call was
`cd <worktree> && sudo -u <box user> git push origin HEAD:master`: the push and its
pre-push gate (`do_check_pre_push`) run as the box user.

## 2. Cause: upstream in the Vibe CLI, triggered by our sudo push

`vibe/core/tools/builtins/bash.py` (`Bash.run`, the non-terminal path) runs the
command with `create_subprocess_shell(..., start_new_session=True)` and
`asyncio.wait_for(proc.communicate(), timeout=default_timeout)`, where the
default timeout is 300 s. On a timeout it calls
`vibe/core/utils/async_subprocess.py: kill_async_subprocess`, which does
`os.killpg(<group>, SIGKILL)`, swallows `PermissionError`, then
`await proc.wait()` **with no timeout**. By then `communicate()` is cancelled, so
nothing reads the stdout and stderr pipes any more.

- The agent user cannot signal processes running as the box user. The shell
  and `sudo` die, but the command sudo started (the git push and its pre-push)
  lives on, reparented to init, still holding vibe's pipes.
- Python 3.13's `Process.wait()` returns only once the pipes are closed too.
- The orphan keeps writing pre-push output into a pipe nobody reads. Once its
  64 KiB buffer is full, the orphan blocks in write, and vibe blocks in wait.
  That is a deadlock: it hangs until the seat is restarted (S4) or Esc
  cancels it. Nothing lands.

What the reported evidence missed: the orphan is a box-user process with
ppid 1, so it is not under vibe in `pstree`. It is no `SPOOL_AGENT_ID`
process either, because sudo resets the env. Reading `/proc/<pid>/fd` of a
box-user process as the agent user shows nothing.

## 3. Reproduction (vibe's own `spawn_shell_command` + `kill_async_subprocess`, 2 s timeout)

| command | result |
|---|---|
| `sleep 20` (control, no sudo) | kill returns at 2.3 s |
| `cd /tmp && sudo -n -u <box user> sleep 25` | kill returns at 25.0 s, the command's whole run |
| `cd /tmp && sudo -n -u <box user> bash -c 'sleep 3; print 200 KB'` | still hung at 40 s; vibe has no child; the orphan is the box user's `bash`, ppid 1, asleep |
| same chatty command, no sudo (control) | kill returns at 2.3 s |
| same chatty sudo command, timeout 30 s (the guard) | finishes normally at 3.0 s |

n=1 per row; each result is deterministic in shape.

## 4. Ruled out

- **Our hooks** (`~/.vibe/hooks.toml`: spool-mirror and three spool-agent-hook
  heartbeats): vibe's `HookExecutor` bounds each hook with `wait_for(timeout)`
  (5 s or 10 s). A hook runs before or after the tool, never while it runs,
  and it would leave a child while it ran.
- **The launch env** (`spawn-mistral.sh`, `restore-mistral.sh`): stdin is
  `/dev/null` in vibe's own spawn, so nothing waits on a TTY.
- **The Vibe CLI on its own**: a command running as the agent user is killed
  as a whole group and returns on time (controls in section 3).

## 5. Our guard

`spawn-mistral.sh` `SPAWN_EXEC_PREFIX` adds `VIBE_TOOLS__BASH__DEFAULT_TIMEOUT=840`.
vibe's env layer maps it to `tools.bash.default_timeout` (checked through
vibe's own config orchestrator: 300 without it, 840 with it). The timeout kill
is the only path into the deadlock, so a push plus pre-push of up to 14 min now
completes on the normal drain path. `restore-mistral.sh` reads the same line, so
restores and watchdog restarts carry the setting too. 840 stays below the
watchdog's S4 cap for `bash` (`wd_tool_cap`, 900 s). A call that runs longer
than that is still restarted by S4, as before.

Tests: `test-spawn-dry-run.sh` checks the launch line and the resume stub, plus
the 840 < S4 cap coupling. Its control is that the claude launch line does not
carry the setting. `test-restore.sh` checks the restore line. Against the old
`spawn-mistral.sh`, 3 and 1 of those asserts fail.

Still open: a model that passes its own `timeout` argument to the bash tool,
below the runtime of a sudo command, can still reach the deadlock. Only the
upstream fix closes that.

## 6. What an upstream report would say (not filed)

> **bash tool: timeout kill hangs forever when the command outlives SIGKILL
> (e.g. `sudo -u other`)** - vibe 2.26.0, Python 3.13, Linux.
> `kill_async_subprocess` sends SIGKILL to the process group, ignores
> `PermissionError`, then awaits `proc.wait()` with no bound, after
> `communicate()` was cancelled. A descendant that the user cannot signal
> (`sudo -u <other> cmd`) or that left the group keeps the stdout/stderr pipes
> open, and Python 3.12+ `Process.wait()` waits for pipe close. If that
> descendant writes more than the pipe buffer, both sides block forever; the
> UI shows "Running command…" with no child. Repro: run the bash tool with
> `timeout=2` on `sudo -n -u <other> bash -c 'sleep 3; yes | head -c 200000'`.
> Suggested fix: after the kill, close the parent's pipe transports
> (`proc._transport.close()`, or keep draining stdout and stderr), and bound
> `proc.wait()` with a timeout; report the call as timed out either way.
