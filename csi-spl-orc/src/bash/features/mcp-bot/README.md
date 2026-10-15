# mcp-bot — a browser for AI agents, one profile per agent

> Generated from qto doc `dbc7ebea-31d6-4baf-92fb-2197905f5ef4`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

`scripts/mcp-start-chrome.sh` (the agents' `chrome` MCP) and
`scripts/mcp-start.sh` (their `firefox` MCP) are the stdio entrypoints of a
Playwright MCP server (`@playwright/mcp`). Each agent gets its own browser
profile, so N agents can hold N browsers at once.

Ported from the box engine's mcp-bot feature, which is frozen for harness
work (the Firefox launcher and its profile reaper in spec 069 lane Y1). This
copy is canonical.

<a id="ws-doc-9f1ee716-1cdd-467b-b963-8f7f0eabdb73"></a>
## 1. Layout

| path | role |
|---|---|
| `scripts/mcp-start-chrome.sh` | the entrypoint: picks the profile, writes the per-agent config, runs the server behind the idle relay |
| `scripts/mcp-start.sh` | the Firefox entrypoint: clones the base profile `ff-profile` per agent, runs the server under the desktop session |
| `scripts/reap-profiles.sh` | removes retired `ff-profile-<ID>` clones; run by `mcp-start.sh` on every start (`MCP_BOT_REAP=0` turns it off) |
| `assets/mcp-config-chrome.json`, `assets/mcp-config.json` | base `@playwright/mcp` configs; `__MCP_BOT_HOME__` is replaced at install |
| `tests/run-all-tests.sh` | every test; each builds its own `MCP_BOT_HOME` under a tmp dir |

Runtime state lives under `MCP_BOT_HOME` (default `~/.local/mcp-bot`) of the
desktop user and is never committed: `cr-profile-<ID>/` per agent,
`run/mcp-config-chrome-<ID>.json`, `run/chrome-activity-<PID>` stamps.

<a id="ws-doc-653b7c57-7cf1-4758-b7b3-8f6da8dc8cb8"></a>
## 2. Install

<a id="ws-doc-87007a51-ed3d-4338-bf00-93b00fec3979"></a>
### 2.1 Link the entrypoints and seed the configs

`spool-install/install.sh` does it, run as the desktop user (step
`spool-install/steps/y1-mcp-bot.sh`): `mcp-start.sh`, `mcp-start-chrome.sh`
and `reap-profiles.sh` in `MCP_BOT_HOME` become symlinks into this checkout
(a link pointing elsewhere is repointed, a regular file is left alone and
reported), and a missing base config is seeded from `assets/`. A live config
is never rewritten. `SPOOL_INSTALL_MCP_BOT=0` skips the step. The plan alone:

```bash
bash csi-spl-orc/src/bash/features/spool-install/install.sh --dry-run --no-seat --cli none
```

<a id="ws-doc-354768ad-de9b-4e6b-abc1-17d0cda00ddc"></a>
### 2.2 Harness entry

The agent user runs the entrypoint as the desktop user (`<BOX_USER>`) and
forwards its id, in the agent CLI's MCP config:

```json
"chrome": {"type": "stdio", "command": "sudo",
           "args": ["-u", "<BOX_USER>", "-H", "--preserve-env=MCP_BOT_AGENT_ID",
                    "<MCP_BOT_HOME>/mcp-start-chrome.sh"]}
```

The `firefox` entry is the same with `<MCP_BOT_HOME>/mcp-start.sh`.

A running agent picks up a changed entrypoint only when its CLI restarts.

<a id="ws-doc-2aa53021-5848-4d73-b9e5-62ffc6f53b9d"></a>
## 3. Profile per agent

First match wins: `MCP_BOT_CHROME_PROFILE` (explicit dir), `MCP_BOT_AGENT_ID`
(`cr-profile-<ID>`), an ancestor `claude --name <ID>` or `spawn-*.sh <ID>`,
else an ephemeral `cr-profile-pid<PID>` removed when the server exits.
`MCP_BOT_AGENT_ID=base` selects the base profile `cr-profile` itself.

Profiles start empty (no base-profile clone unless `cr-profile/` exists).
Every start removes `cr-profile-*` dirs unused for `MCP_BOT_CHROME_TTL_DAYS`
(default 14) that no live browser holds. `MCP_BOT_CHROME_HEADLESS=0` opens a
visible window instead of running headless.

<a id="ws-doc-6372ff4a-f784-49b6-bac8-f05bfa9f15e4"></a>
## 4. Idle timeout

A browser nobody drives is closed. Measured 2026-10-01: an agent's headless
Chrome sat on a page with a WebGL animation for 3h43m after its last tool
call, rendering in software on ~5 cores (19.6 CPU-hours), and the box ran at
load 159 on 16 cores.

The agent's stdio is a socket, which keeps no last-write time, so a relay in
front of the server stamps `run/chrome-activity-<PID>` on every client
request. A watchdog closes this profile's main Chrome process once the stamp
is older than the limit. The MCP server stays up and starts a new browser on
the next tool call: the profile (cookies, logins) survives, open tabs and
page state do not.

| variable | default | meaning |
|---|---|---|
| `MCP_BOT_CHROME_IDLE_MIN` | 15 | idle minutes before the browser is closed; 0 disables the watchdog |
| `MCP_BOT_CHROME_IDLE_SEC` | from `_MIN` | the same in seconds, wins over `_MIN` |
| `MCP_BOT_CHROME_IDLE_POLL_SEC` | 60 | how often the watchdog checks |

Each close is logged to stderr (the CLI's MCP server log) as
`idle <N>s >= <limit>s: closing browser pid <PID>`.

<a id="ws-doc-549241b2-a879-474b-87a7-3f87cc38ce8f"></a>
## 5. Tests

`tests/test-install-links.sh` runs the install step in a sandbox `HOME`
seeded with links into a stand-in engine, and checks that all three
entrypoints end up resolving into this checkout. `tests/test-reap-profiles.sh`
is the reaper's suite (master guard, liveness, age).

`tests/test-chrome-idle.sh` needs no browser: a fake `npx` records the bytes
the server is sent, and sleeping processes carrying `--user-data-dir` stand in
for Chrome. It checks byte-exact relaying, activity keeping the browser up,
the idle close and its scope (main process of this profile only), clean exit
on stdin EOF and on SIGTERM, and that `IDLE_SEC=0` starts no watchdog.

```bash
bash csi-spl-orc/src/bash/features/mcp-bot/tests/run-all-tests.sh
```
