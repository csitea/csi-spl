# mcp-bot — a headless Chrome for AI agents, one profile per agent

`scripts/mcp-start-chrome.sh` is the stdio entrypoint of a Playwright MCP
server (`@playwright/mcp`) that drives Google Chrome. Each agent gets its own
browser profile, so N agents can hold N browsers at once.

Ported from the box engine's mcp-bot feature, which is frozen for harness
work. This copy is canonical. The Firefox launcher and its profile reaper were
not ported.

## 1. Layout

| path | role |
|---|---|
| `scripts/mcp-start-chrome.sh` | the entrypoint: picks the profile, writes the per-agent config, runs the server behind the idle relay |
| `assets/mcp-config-chrome.json` | base `@playwright/mcp` config; `__MCP_BOT_HOME__` is replaced at install |
| `tests/run-all-tests.sh` | every test; each builds its own `MCP_BOT_HOME` under a tmp dir |

Runtime state lives under `MCP_BOT_HOME` (default `~/.local/mcp-bot`) of the
desktop user and is never committed: `cr-profile-<ID>/` per agent,
`run/mcp-config-chrome-<ID>.json`, `run/chrome-activity-<PID>` stamps.

## 2. Install

### 2.1 Link the entrypoint

The symlink makes the deployed script track this checkout.

```bash
mkdir -p "$HOME/.local/mcp-bot/run" && ln -sfn "$PWD/csi-spl-orc/src/bash/features/mcp-bot/scripts/mcp-start-chrome.sh" "$HOME/.local/mcp-bot/mcp-start-chrome.sh"
```

### 2.2 Seed the base config (first install only)

```bash
[ -f "$HOME/.local/mcp-bot/mcp-config-chrome.json" ] || sed "s|__MCP_BOT_HOME__|$HOME/.local/mcp-bot|g" csi-spl-orc/src/bash/features/mcp-bot/assets/mcp-config-chrome.json > "$HOME/.local/mcp-bot/mcp-config-chrome.json"
```

### 2.3 Harness entry

The agent user runs the entrypoint as the desktop user (`<BOX_USER>`) and
forwards its id, in the agent CLI's MCP config:

```json
"chrome": {"type": "stdio", "command": "sudo",
           "args": ["-u", "<BOX_USER>", "-H", "--preserve-env=MCP_BOT_AGENT_ID",
                    "<MCP_BOT_HOME>/mcp-start-chrome.sh"]}
```

A running agent picks up a changed entrypoint only when its CLI restarts.

## 3. Profile per agent

First match wins: `MCP_BOT_CHROME_PROFILE` (explicit dir), `MCP_BOT_AGENT_ID`
(`cr-profile-<ID>`), an ancestor `claude --name <ID>` or `spawn-*.sh <ID>`,
else an ephemeral `cr-profile-pid<PID>` removed when the server exits.
`MCP_BOT_AGENT_ID=base` selects the base profile `cr-profile` itself.

Profiles start empty (no base-profile clone unless `cr-profile/` exists).
Every start removes `cr-profile-*` dirs unused for `MCP_BOT_CHROME_TTL_DAYS`
(default 14) that no live browser holds. `MCP_BOT_CHROME_HEADLESS=0` opens a
visible window instead of running headless.

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

## 5. Tests

`tests/test-chrome-idle.sh` needs no browser: a fake `npx` records the bytes
the server is sent, and sleeping processes carrying `--user-data-dir` stand in
for Chrome. It checks byte-exact relaying, activity keeping the browser up,
the idle close and its scope (main process of this profile only), clean exit
on stdin EOF and on SIGTERM, and that `IDLE_SEC=0` starts no watchdog.

```bash
bash csi-spl-orc/src/bash/features/mcp-bot/tests/run-all-tests.sh
```
