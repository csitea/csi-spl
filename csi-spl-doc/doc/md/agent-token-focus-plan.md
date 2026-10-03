# Agent token + focus plan (2026-10-03)

Owner ask (t1 topic `64576223-7996-4b09-bc50-e01c2572bbdf`): best practices for
agents to keep token use down and stay on one topic.

This plan comes from MEASUREMENTS. Every number below gives its source and n. A
practice without a measured saving is not on the list, so this plan has **10
practices, not 30**.

## 1. Method and limits

- **Tree:** `3f9c9dff` (origin/master when measured). **Box:** the main box, 2026-10-03 ~02:45Z.
- **Conversion:** tokens ≈ chars / 4. This is a rough estimate for mixed English + code
  and is the same for every row, so the ranking does not depend on it.
- **Not measured: lane transcripts.** Reading `$HOME/.claude/projects/*/<sid>.jsonl` was
  refused as personal-data handling, so this lane did not open them. The per-turn rows
  below therefore come from proxies: the size of the output of the commands every lane
  is TOLD to run (the seed prompt names them), plus spool message sizes (lengths only,
  no bodies read). Brief 00 is the transcript measurement, for a lane whose brief
  explicitly clears the data rule. Run it if the per-turn shares must be confirmed.
- No message contents are quoted anywhere in this plan, only counts and file names.

## 2. Where a lane's context goes

### 2.1 Fixed preamble (loaded before the lane's first turn, then re-read on every turn)

| item | source | chars | ≈ tokens | share of the measured preamble |
|---|---|---:|---:|---:|
| seed prompt: INTEGRATION block | `spawn-core.inc.sh` `_spawn_seed_blocks`, `wc -c` of the assignment | 13,327 | 3,300 | 13% |
| seed prompt: DEPLOY_GATE | same | 2,714 | 680 | 3% |
| seed prompt: SPOOL_PROTO | same | 2,698 | 670 | 3% |
| seed prompt: SCOPE + head | same | 2,383 | 600 | 2% |
| global `$HOME/.claude/CLAUDE.md` | `wc -c` | 26,196 | 6,550 | 26% |
| … of which the doc-hub distribution rules (another project's rules) | per-`##` section byte sum, 12 sections | 11,517 | 2,880 | 11% |
| … of which "spawn up to 40" (tells a lane to spawn agents) | section bytes | 2,686 | 670 | 3% |
| repo `CLAUDE.md` | `wc -c` | 13,087 | 3,270 | 13% |
| … of which the lint-parts table | `awk` from "**Lint parts**" to "Pushing onto a red trunk" | 5,078 | 1,270 | 5% |
| memory index `MEMORY.md` (the part that loads) | `head -159 \| wc -c`; the file is 33,675 B / 211 lines | 25,252 | 6,300 | 25% |
| skills listing + plugin/connector tool text | NOT measured exactly (harness side); I believe, unchecked, it is ≥ 15,000 chars | ≥ 15,000 | ≥ 3,750 | ~15% |
| **measured preamble (without harness tool schemas)** | sum | **~100,700** | **~25,000** | 100% |

Two facts that matter beyond size:

- **52 memory lines are never seen.** `MEMORY.md` is 211 lines and 33,675 B. The loader cuts it
  at line 160, so the newest 8,423 B (52 entries) never reach any agent. Index line
  length: median 159 chars, longest 215 (`awk` over the file).
- **The preamble contradicts itself on focus.** The seed says "You do ONE small task".
  The global file says "Whenever spawning an agent is more rational than doing the work
  yourself, just spawn it", and that is 2,686 chars every lane reads.

### 2.2 Per-turn drivers (measured with proxies, n per row)

| driver | source | measured | n |
|---|---|---|---|
| `lane-map.sh` full map, which the seed tells every lane to read on a blocker | `wc -c` of its output | 28,505 B (~7,100 tokens) per call; 173 "live" rows, of which 148 (86%) are ≥ 2 h old or have no age | 1 run |
| `lane-map.sh --check <path> --agent <id>`, the "cheap" form | `wc -c` | 28,665 B. It prints the whole map as well as the verdict, so it is not cheaper | 1 run |
| `./run` log decoration (ANSI colours, timestamp, module, box, pid, DEBUG, START/STOP) | `do_check_dist_hygiene` output, decoration stripped with `sed` | 687 of 1,135 B (61%) is decoration | 1 action |
| spool bodies that reach the orchestrator seats (`CLE-001` + `c-001`) | `jq '.body\|length'` over `archive/*.json`, last 24 h | 749,846 B (~187,000 tokens) in 789 messages | 1,490 msgs total |
| … `result` bodies | same | avg 1,563 B, 244 msgs, 381,534 B | 244 |
| … `blocker` bodies | same | avg 974 B, 222 msgs | 222 |
| spool envelope overhead (what `spool recv` prints beyond the body) | avg file size − avg body length | 970 − 771 = ~200 B per message (~20%) | 1,490 |
| brief size | `find /var/tmp/claude/briefs -mmin -1440` | median 3,249 B, p90 3,957 B. Small. NOT a driver | 131 |

### 2.3 Focus breaks

| measure | source | value | n |
|---|---|---|---|
| worker lanes that received more than one task_id (`task`/`note`/`msg`) in 24 h | spool archive, `to` × `task_id` pairs, role seats `c-001..c-003` excluded | 13 of 39 (33%). Worst: 7, 6 and 4 topics | 39 lanes |
| role seats (dispatchers) | same | `c-002` 23 topics, `c-003` 12. Expected, because they route | 2 |

Caveat: a lane id that is reused after a retire counts both of its lanes. So 33% is
an UPPER bound. Brief 08 re-measures it with the lane-map topic column.

## 3. The practices, ranked by measured saving

The saving is per lane session unless the row says otherwise. "Owner" is the file
owner who must agree (or `ORC` = the orchestrator's spawn-agents lane). No live lane holds
any of these files (checked with `lane-map.sh --check`, 2026-10-03).

### 3.1 For lanes (preamble + per turn)

| # | practice | where | expected saving | measure before / after | owner |
|---|---|---|---|---|---|
| 1 | **Ask the lane map one question, get one line.** `--check` prints only the verdict (owner lane or "free"); the default map hides rows ≥ 2 h old or without an age unless `--all` | `csi-spl-orc/src/bash/run/spl-lane-map.func.sh`, `…/spawn-agents/scripts/lane-map.sh` | 28,665 → < 300 B per `--check`; 28,505 → ~4,000 B per map (−86% rows) | `lane-map.sh … \| wc -c`, n=3 runs | ORC |
| 2 | **A seed prompt states rules, not their history.** Move the measured anecdotes out of INTEGRATION / DEPLOY_GATE into one linked doc. Drop what repo CLAUDE.md already says | `spawn-agents/scripts/spawn-core.inc.sh`, new `csi-spl-doc/doc/md/lane-integration-rules.md` | 21,100 → ≤ 8,000 chars (−13,000, −3,300 tokens per lane per turn) | `SPAWN_DRY_RUN=1` spawn, `wc -c` of the PROMPT line, n=1 per kind (claude, qwen) | ORC |
| 3 | **Load only this project's rules.** The doc-hub distribution rules (11,517 B) move from the global file into the doc-hub repo's own CLAUDE.md | `$HOME/.claude/CLAUDE.md` (both harness users), the doc-hub repo's `CLAUDE.md` | −11,517 chars per lane in every non-doc-hub repo | `wc -c` of both files; section byte sum | **human owner** (global file) |
| 4 | **Keep the memory index under the load cut.** One line ≤ 110 chars; superseded entries go to per-area index files, not the top index | `$HOME/.claude/projects/<slug>/memory/MEMORY.md` + new `memory/index-*.md` | 25,252 → ≤ 12,000 B loaded (−13,000), and the 52 hidden lines become visible | `wc -c -l MEMORY.md`, `awk length` median/max | fleet memory (`<HARNESS_USER>`) |
| 5 | **Quiet logs for agents.** When stdout is not a TTY (or `RUN_LOG=compact`), `./run` prints `LEVEL msg` with no ANSI, timestamp, box or pid, and drops DEBUG and the START/STOP banner | `csi-spl-orc/src/bash/run/run.sh`, `csi-spl-iac/src/bash/run/run.sh` | −61% of every `./run` output (n=1; re-measure on 5 actions) | `./run -a <action> \| wc -c` on 5 actions, before vs after | ORC (orc), iac lane |
| 6 | **Reference tables live in docs, not in CLAUDE.md.** Move the lint-parts table and the FAST-tier paragraph into `csi-spl-doc/doc/md/pre-push-gate.md` and leave a 2-line pointer | repo `CLAUDE.md`, new doc | −5,078 B (table) and ~−1,500 B (paragraph) | `wc -c CLAUDE.md` | repo owner (doc lane) |

### 3.2 For the orchestrator and dispatchers

| # | practice | where | expected saving | measure before / after | owner |
|---|---|---|---|---|---|
| 7 | **Short results, detail in a file.** A `result` body ≤ 800 chars plus the doc path or sha. The exit-clean report template caps itself, and the skill says so | `spawn-agents/scripts/kill-your-self-report.sh`, `spawn-agents/assets/skills/exit-clean/SKILL.md` | results avg 1,563 → ≤ 800 B: ~−190,000 B/day at the orch seats (n=244) | the same `jq` length sum over 24 h | ORC |
| 8 | **One topic per lane, enforced at send time.** `spool-send.sh --kind task` to a live lane whose lane-map topic is a different task_id refuses with "spawn a new lane" (`SPOOL_SECOND_TOPIC_OK=1` overrides, logged); a body above 1,200 chars warns | `spawn-agents/scripts/spool-send.sh` (+ its test) | 13/39 lanes (33%, upper bound) → 0 unforced second topics | the `to` × `task_id` count above, 24 h after | ORC |
| 9 | **The orchestrator reads bodies, not envelopes.** `spool recv --compact` prints `from kind task_id` + body, without the v/msg_id/ts/files fields; `agent-inbox.sh` uses it | `csi-spl-api/src/go/spool-hub-api/cmd/spool/main.go`, `spawn-agents/scripts/agent-inbox.sh` | ~−20% of every recv (970 → ~780 B per message, n=1,490) | `spool recv --as <id>` vs `--compact`, `wc -c`, same inbox | api lane + ORC |
| 10 | **Lanes load only the skills and connectors they use.** Office-file, browser, desktop and doc-connector skills/plugins are disabled for the harness user's lanes | harness user `settings.json` (`enabledPlugins`) | NOT measured. Measure first: the listing's chars in a lane with vs without | count the skills/connector text in a lane transcript, n=2 | **human owner** (account) |

### 3.3 Practices considered and dropped (measured, no gain)

- **Shorter briefs.** Median 3,249 B, n=131, which is ~3% of the preamble. Not a driver.
- **Rebuilding the spool file mailbox.** Earlier fleet measurements show the mailbox is not the cost.

## 4. Briefs and run order

Briefs: `/var/tmp/claude/briefs/token-r1/NN-<slug>.md`, two changes each, and file-disjoint.
Brief 00 is the transcript measurement, which needs a lane cleared for it.

| order | brief | needs |
|---|---|---|
| 1 | 01-lane-map-one-line | ORC lane |
| 2 | 02-seed-rules-not-history | ORC lane, after 01 (the seed names `--check`) |
| 3 | 03-global-claude-md-scope | human owner go (global file) |
| 4 | 04-memory-index-under-cut | any lane; memory is not in git |
| 5 | 05-quiet-run-logs | ORC + iac files |
| 6 | 06-claude-md-reference-tables | doc lane |
| 7 | 07-short-results | ORC lane |
| 8 | 08-one-topic-per-lane | ORC lane |
| 9 | 09-recv-compact | api lane (Go) |
| 10 | 10-lane-skill-set | human owner go |
| 0 | 00-transcript-measure | lane cleared to read transcripts (counts only) |
