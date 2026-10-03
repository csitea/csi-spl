## Claude Code instances start as `{{AGENT_USER}}` — verify every programmatic start

Standing order from the human, 2026-10-01. **Every Claude Code instance started
programmatically** (spawn, restore, resume, reopen, respawn-pane, a cron or
`@reboot` launcher, a hand-written launcher script) **runs as the OS user
`{{AGENT_USER}}`**, unless the human explicitly states that this one must run as `{{BOX_USER}}`.
`{{AGENT_USER}}` and `{{BOX_USER}}` are meant to be equivalent in access; the only difference is
that the human runs UI programs as `{{BOX_USER}}`, so the `{{BOX_USER}}` Claude login stays the
human's own and the agent fleet uses `{{AGENT_USER}}`'s.

- Launch with `SPOOL_AGENT_USER={{AGENT_USER}} CLAUDE_BIN={{AGENT_HOME}}/.local/bin/claude`
  (csi-spl harness), or `sudo su - {{AGENT_USER}} --pty -c '…claude…'` by hand. Never
  `CLAUDE_BIN={{BOX_HOME}}/.local/bin/claude` or `SPOOL_AGENT_USER={{BOX_USER}}` by default.
- Keep the agent inside its existing tmux window (`respawn-pane -k -t <pane-id>`
  for a restart) so the human can still navigate the fleet with tmux.
- **Check after every start**: this must print nothing.
  ```bash
  ps -u {{BOX_USER}} -o pid=,args= | awk '$2 ~ /(^|\/)claude$/'
  ```
  It matches the claude binary itself, not launcher shells whose command
  line merely mentions claude. Any line is a {{BOX_USER}}-owned agent: stop it, then restart it as `{{AGENT_USER}}` (below).
- Moving a {{BOX_USER}} session to `{{AGENT_USER}}`: the transcript lives under the user that
  ran it. Copy `~{{BOX_USER}}/.claude/projects/<slug>/<sid>.jsonl` (plus the `<sid>/`
  dir if present) to the same `<slug>` under `~{{AGENT_USER}}/.claude/projects/`,
  chown `{{AGENT_USER}}`, then `--resume <sid>` as `{{AGENT_USER}}` from the same cwd.
  Recipe used 2026-10-01 for 14 agents:
  `/var/tmp/claude/restore-20261001-aiusr/restart-one.sh <ID>`.
- Why: on 2026-10-01 the whole csi-spl fleet had been launched as `{{BOX_USER}}`, shared
  the human's gmail login, hit its weekly limit and stopped, while `{{AGENT_USER}}`'s
  login had quota.

