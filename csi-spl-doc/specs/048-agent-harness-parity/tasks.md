# Tasks: 048 Agent Harness Parity

Status per item: `[x]` built, with the sha and the check; `[ ]` open. One task
per spool issue (epic SPL-1152, prd t1).

- [ ] T001 SPL-1153 this spec, `harness-parity.tsv` (every frozen reference
      file -> ported / replaced / excluded) and `tests/test-harness-parity.sh`
      + `./run -a do_check_harness_parity`
- [x] T002 SPL-1148 qwen kind: `spawn-qwen.sh`, QWN in the id rules,
      `spawn-window.sh`, `next-agent-id.sh`, `trust-workdir.sh`,
      `spool-agent.sh qwen` (seated; mirror hooks merged into
      `~/.qwen/settings.json`, claude-shaped payloads measured in qwen 0.24.6).
      Check: spawn-agents `run-all-tests.sh` all green (test-spool-agent 60,
      dry-run + next-agent-id qwen rows)
- [x] T003 SPL-1154 `install.sh --cli qwen` (npm into the user prefix, rg +x;
      no npm = exit 3 before anything runs) and `do_spl_agent_mcp_install`
      registers spool-dev/prd in qwen (user scope, trusted). Check:
      `spool-install/tests/test-install.sh` 40 PASS, `agent-mcp.tst.sh` 0 failures
- [ ] T004 SPL-1155 skills + slash commands as spool-native templates under
      `assets/`, rendered by `install.sh` (hand edits never overwritten silently)
- [ ] T005 SPL-1156 port the missing box scripts the manifest marks `ported`
      (tmux-close-window, the tmux status badge, ...)
- [ ] T006 SPL-1157 README section "Agent harness: what you get when you clone"
- [ ] T007 SPL-1158 proof: a throwaway HOME runs the installer `--dry-run` and
      for real; spawn commands work for every CLI installable without credentials
- [ ] T008 SPL-1159 switch this box over to the csi-spl harness (announce
      first, rollback line), then retire the reference's FROZEN.md (§1.4)
