# Tasks: 048 Agent Harness Parity

Status per item: `[x]` built, with the sha and the check; `[ ]` open. One task
per spool issue (epic SPL-1152, prd t1).

- [x] T001 SPL-1153 this spec (`ddddb25f`), `harness-parity.tsv` (all 110
      files of the frozen reference at `844b088`: 23 ported, 36 replaced, 15
      excluded, 36 deferred to SPL-1160) and `tests/test-harness-parity.sh`
      + `./run -a do_check_harness_parity`, gated in the orc CI job by
      `tests/harness-parity.tst.sh` (parts 1-3; part 4 needs the private
      reference). Check: 44 PASS with `HARNESS_REF_DIR`, 42 without. CONTROLS
      (n=1 each): a dropped row -> 1 red ("every reference file has a row");
      the pre-048 tree `ddddb25f` -> 7 red, all qwen
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
- [x] T004 SPL-1155 skills + slash commands as spool-native templates under
      `assets/` (/claude-spawn /agy-spawn /grok-spawn /qwen-spawn
      /spawn-an-agent /riname /tmux-close-window; skills agent-msg, exit-clean,
      kill-your-self), rendered by `install.sh` step 5b into ~/.claude and,
      with qwen, ~/.qwen/skills; sha256 marker: untouched = rewritten, hand
      edit = kept and named (`--force-skills` + backup), foreign = never
      touched; `--no-skills`. Check: `test-install.sh` 50 PASS
- [x] T005 SPL-1156 port the missing box scripts the manifest marks `ported`:
      `tmux-close-window.sh` onto the spool resolver and
      `assets/tmux-agent-status.conf` (`94db833f`; test-tmux-close-window 15
      PASS; used live on 2026-09-29 to close the throwaway CLE-9048)
- [x] T006 SPL-1157 README section "Agent harness: what you get when you clone"
      (root README) and the spawn-agents README layout + "Not ported (yet)"
- [x] T007 SPL-1158 proof: a clean `node:22-bookworm` container, a new user
      with an empty HOME, a fresh clone of the PUBLIC repo from GitHub,
      2026-09-28/29, n=2:
      - run 1 at `2283df22`: `--dry-run --cli claude,grok,agy,qwen --no-seat`
        rc 0, HOME unchanged. The real run installed claude 2.1.284 and grok
        1.0.41, then the agy vendor URL returned a non-script body once
        ("cannot execute binary file") and the run died there (rc 4) before
        qwen and the skills. Fixed in `d31691ea`: a failed CLI is named, the
        rest still runs, exit 4 at the end; a non-script installer is refused
        (test-install 53 PASS). The same URL served the script 3/3 afterwards
      - run 2 at `d31691ea`: dry run rc 0; real run rc 0: claude 2.1.284, grok
        1.0.41, agy 1.2.13, qwen 0.24.6 (npm, 4 vendored rg made executable),
        Go + yq downloaded, spool 1.1.3 built, 20 skill/command files rendered
        (10 in ~/.claude, 10 in ~/.qwen/skills), the tmux line printed; a
        re-run wrote 0 of 20. `spawn-window.sh <kind> auto` for all four in a
        private tmux server: CLE-01, GRK-01, AGY-01, QWN-01 each rc 0 and each
        CLI up at its own sign-in screen (credentials are the user's step);
        `test-harness-parity.sh` from the clone 42 PASS
- [x] T008 SPL-1159 switch this box over to the csi-spl harness (announce
      first, rollback line), then retire the reference's FROZEN.md (§1.4)
      PLANNED in `switch-over.md` (measured refs, steps, rollback line).
      Owner answered A (2026-09-29): orchestrator first. Built:
      `agent-send.sh` + `agent-inbox.sh` (`49e0401a`, test-agent-send 29 PASS);
      proved on this box (`59b6356d`: throwaway CLE-9048 round trip with
      CLE-001 via /var/spool-hub, an old-engine agent reached via legacy).
      OPEN: the flip itself (4.5-4.8), proposed 2026-09-29 19:00Z, waiting for
      CLE-001's confirm; CONFIRMED by CLE-001 at 11:23Z for 19:00Z. FLIPPED
      2026-09-29 12:19Z on the owner's order (switch-over.md "FLIP RUN"):
      20 files rendered, post-flip round trip CLE-35098 <-> CLE-001 green;
      tmux snippet kept until agent-top is ported (SPL-1160)
- [ ] T009 SPL-1160 port the rows marked `deferred` in `harness-parity.tsv`:
      the fleet views (agent-top, pane-scan, badges), restore-*, the spawn
      chains/tasks, the kill-your-self report. None is needed to spawn or talk
