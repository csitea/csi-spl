# Fleet rules: where each rule lives (index)

Owner, t1 5c3bb16a (2026-10-08): "is that manageable", "does it need somekind
of optimization / rationalization", then "go". This page lists every source of
fleet rules, what it governs, and the ONE home of each rule that used to be
written in two or more places. A rule is changed in its home; every other
mention is a one-line pointer.

## 1. The sources

| # | source | read by | governs |
|---|---|---|---|
| 1.1 | `csi-spl-orc/src/bash/features/spool-install/assets/claude/claude-md/*.md` | every Claude seat on every box: spool-install (step y4) renders these parts into the installed global `~/.claude/CLAUDE.md`; every mistral (vibe) seat: step y8 renders the same parts into `~/.vibe/AGENTS.md` (vibe loads AGENTS.md, never CLAUDE.md) | `05` seats run as the agent user; `07` permission mode bypass only; `10` push trunk, deploy dev and prd; `20` spawn an agent: launcher choice, the agent ceiling + count command, the data rule, the language rule; `25` stay in your own lane; `30` a cross-lane finding states version, tree and n |
| 1.2 | repo `CLAUDE.md` (the repo `AGENTS.md` only points to it, for vibe) | every agent working in this repo | repo rules: environments, service accounts only, nothing ad hoc, terraform via tf-runner, cheap gates before a push, version minting, the commit identity; pointers to 1.1 and to this page |
| 1.3 | `csi-spl-doc/doc/md/SPEC-spool-fleet-roles.md` | orchestrator and dispatcher seats | roles `001`..`003`, where messages come from, the routing rule, the leases, failover, hourly rotation |
| 1.4 | `csi-spl-doc/doc/md/lane-integration-rules.md` | a lane, when a rule of its seed seems odd | the why of the spawn seed's INTEGRATION (1)-(8), SCOPE (a)-(d) and DEPLOY-GATE (a)-(e); the rules themselves are in `spawn-agents/scripts/spawn-core.inc.sh` (`_spawn_seed_blocks`) |
| 1.5 | `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/spawn-an-agent.md` + cnf `env.box.agent_split` (`csi-spl-cnf/csi-spl/all.env.yaml`) + `do_spl_lane_mix` | a seat that spawns | which vendor takes a task: the split (approximate, +/- tolerance over the last spawns), the kinds `spec`, `i18n`, `secret`, `hard` |
| 1.6 | `csi-spl-orc/src/bash/features/spawn-agents/assets/commands/{claude,grok,agy,qwen,mistral}-spawn.md` | a seat that runs that launcher | how to spawn or message one vendor's lane: count, brief, window, seed |
| 1.7 | `csi-spl-doc/doc/help/how-to-post.md` | everyone who posts in the spool | the one rule for a post: markdown, no fence |

## 2. One home per rule

| rule | its home | pointers elsewhere |
|---|---|---|
| agent ceiling (40) and the window-count command | 1.1 `20-spawn-an-agent.md` | repo `CLAUDE.md` (one line); each launcher 1.6 keeps the count command in its section 1.1, because a launcher is read on its own: the drift check (section 3) pins those copies to the home |
| agent-id grammar `^[acgmq]-[0-9]{3}$` | spec 061 section 0; in code `SPOOL_AGENT_ID_NEW_RX` (`spawn-agents/lib/spool-env.inc.sh`) | repo `CLAUDE.md` (link), 1.3 section 1 |
| data rule: personal data and secrets to claude or mistral only | 1.1 `20-spawn-an-agent.md` | repo `CLAUDE.md` (one line); the routing row in 1.5 |
| language rule: agy has the final word on multilingual text | 1.1 `20-spawn-an-agent.md` | repo `CLAUDE.md` (one line); the `i18n` row in 1.5 |
| commit identity, no AI trailers | repo `CLAUDE.md`, the "Commits:" line (the canonical address the seed's LEAK-GATE defers to) | 1.4 section 5 (the why) |
| spool posts are markdown | 1.7 | repo `CLAUDE.md` (one line) |
| stay in your own lane („Всяка жаба да си знае гьола“): your brief only, a finding outside it to the orchestrator | 1.1 `25-stay-in-your-lane.md` | rendered, not copied, into every vendor's file: claude `~/.claude/CLAUDE.md` (y4; grok reads it through its default `compat.claude` scan), mistral `~/.vibe/AGENTS.md` (y8), agy `~/.gemini/config/rules/25-stay-in-your-lane.md` and qwen `~/.qwen/QWEN.md`, which is also qwen's memory file (y9); the mistral seed (`spawn-mistral.sh`, `spawn_rename_how`, one line), because vibe 2.26.0 keeps no memory file across sessions |
| lane integration (commit, rebase, push, teardown) | the seed, `spawn-core.inc.sh` | 1.4 (the why) |
| never force-push master (`--force`, `--force-with-lease`, `+ref`, nor `SPL_PREPUSH_OVERRIDE`) without the owner's explicit approval of that one push, which the owner may do by hand; a refused push is fetch, rebase, re-test, push again (owner, HUM-10 2026-10-10 msgs 853a4084, 1cdfa5ba, 097f9de3, 1ca01c83, 3e095a04: every agent type) | the seed, `NO_FORCE` in `spawn-core.inc.sh` (`_spawn_seed_blocks`), rendered into every kind's seed: c-, g-, a-, q-, m- (guard: `spawn-agents/tests/test-seed-no-force-push.sh`, with a control per kind) | 1.4 section 3.2 (the why); the seed's INTEGRATION (4) points to it |
| refactoring rounds need no owner go: round N served -> the dispatcher requests round N+1's planner; panel and row lanes follow (owner, HUM-10 msg 3d22fcea) | 1.3 section 1.2 | the round plans `refactor-round-<N>-plan.md` (one line in their header) |

## 3. The drift check

`cd csi-spl-orc && ./run -a do_check_fleet_rules_drift` reads the sources in
section 1 and fails when two of them disagree on a pinned fact:

| # | fact | compared |
|---|---|---|
| 3.1 | id-letters | every `[..]-[0-9]{3}` letter class in the sources vs `SPOOL_AGENT_ID_NEW_RX` |
| 3.2 | ceiling-count | the window-count regex in 1.1 `20` vs every launcher and any other source |
| 3.3 | ceiling-number | the default of `install.sh` and `y4-claude-config.sh` vs "Agent ceiling: N" in the repo `CLAUDE.md` |
| 3.4 | data-rule | every `fleet-pin data-rule-vendors` pin (1.1 `20`, 1.5) agrees, its prose names each pinned vendor, and `do_spl_lane_mix`'s secret pick is in the set |
| 3.5 | language-rule | the same for the `fleet-pin language-rule-final` pins and `do_spl_lane_mix`'s `i18n` pick |
| 3.6 | commit-address | the repo `CLAUDE.md` "Commits:" address vs every recent commit by that author name |

It runs in the pre-push hygiene part (`do_check_pre_push`) and in the orc
suite (`csi-spl-orc/src/bash/tests/check-fleet-rules-drift.tst.sh`, with a
control per fact that plants a disagreement). `FLEET_RULES_HOME=<home>` adds a
box's INSTALLED copies (`<home>/.claude/CLAUDE.md`,
`<home>/.claude/commands/*-spawn.md`), which refresh only on a spool-install
run.

A changed rule: edit its home, then any pinned copy, then run the check.
