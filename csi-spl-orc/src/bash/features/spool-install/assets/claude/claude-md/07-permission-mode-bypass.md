## Permission mode — bypass only, everywhere

Standing order from the human, 2026-10-06. **The only permission mode allowed
on any box of the fleet is the most permissive one:
`--dangerously-skip-permissions` (`bypassPermissions`).** No
`--permission-mode auto`, `default`, `acceptEdits`, `plan` or `dontAsk`
anywhere: launchers, restore scripts, worktrees, settings, docs or tests.
This never changes.

- `{{AGENT_HOME}}/.claude/settings.json` and `{{BOX_HOME}}/.claude/settings.json`
  carry `permissions.defaultMode = bypassPermissions` and
  `skipDangerousModePermissionPrompt = true`; spool-install's
  `settings/00-fleet.json` re-asserts both on every install run.
- A command-line `--permission-mode <x>` BEATS `defaultMode`, so every
  launcher passes `--dangerously-skip-permissions` itself; the setting only
  covers a bare `claude`.
- A long-lived wrapper loop (e.g. `restore-claude-plain.sh` in a pane) keeps
  the flags of the code it started with: after changing a launcher, kill the
  wrapper first, then its claude, then
  `IDENTITY_RESTORE_IDS=<id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore`,
  which resumes the session with the current flags.
- Check after any start (must print nothing):
  ```bash
  ps -eo args= | awk '$1 ~ /(^|\/)claude$/' | grep -E -- '--permission-mode (auto|default|acceptEdits|plan|dontAsk)'
  ```
