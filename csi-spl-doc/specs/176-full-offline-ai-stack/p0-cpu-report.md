# Spec 176 T0.2: class S models on CPU, driven by Claude Code (P0 report)

Spec 176 phase P0, task T0.2, issue SPL-5557, epic SPL-2402. Lane c-919, on a 16-core CPU box of the fleet.
The harness is T0.1 (`do_spl_local_replay`, [replay-harness.md](replay-harness.md)).
CPU only, no GPU, no paid cloud resource. No routing weight is given to
`local` (that is P1).

**Status: INTERIM.** The run on `qwen3-coder:30b` produced no model turn
(section 4). The box's dispatcher paused the lane at 06:13Z because of the
CPU load (section 5). The `devstral-small-2:24b` run and the headline table
come after the pause.

## 1. Headline

| kind | model | pass / N | wall time | RAM peak (runner RSS) | note |
|---|---|---|---|---|---|
| simple_coding | qwen3-coder:30b Q4_K_M | 0 / 1 tried (of N = 2) | 18 min, then stopped | 21.5 GB | 0 model turns: 2 x HTTP 500 after 6m0s |
| simple_coding | devstral-small-2:24b | not run yet | | | paused |
| i18n | qwen3-coder:30b | not run yet | | | paused |

Version: Claude Code 2.1.311, ollama 0.21.0. Tree: replay cases built from
`origin/master` `1a86b09c7`. n: per row above.

## 2. Server, models and licences

### 2.1 The server: Ollama

Ollama serves the Anthropic Messages API (`/v1/messages`), so Claude Code
reaches it through `ANTHROPIC_BASE_URL=http://127.0.0.1:11434` with
`ANTHROPIC_AUTH_TOKEN=ollama` (spec 4.3). It runs on CPU with no extra setup.

- It was already on the box: `/usr/local/bin/ollama` 0.21.0, run by
  `ollama.service` as user `ollama`, since 2026-06-03 (the unit file's
  mtime). This lane installed nothing.
- It listens on localhost only: `ss -ltnp | grep 11434` ->
  `127.0.0.1:11434`.
- `do_box_pkg_install` installs apt packages only (`apt-get -s`,
  `dpkg-query`), and `dpkg -S /usr/local/bin/ollama` finds no package. So
  the binary cannot be upgraded through that action. This matters for
  gpt-oss (2.2).

### 2.2 The models

| model | params | licence (source, read 2026-11-15) | used |
|---|---|---|---|
| qwen3-coder:30b (Qwen3-Coder-30B-A3B-Instruct, Q4_K_M) | 30.5B MoE, ~3B active | Apache-2.0 (HF `Qwen/Qwen3-Coder-30B-A3B-Instruct` card; `ollama show --license`) | yes |
| devstral-small-2:24b | 24B dense | Apache-2.0 (HF `mistralai/Devstral-Small-2-24B-Instruct-2512` card) | pull paused at 67 % |
| gpt-oss:20b | 21B MoE | Apache-2.0 (HF `openai/gpt-oss-20b` card) | no: ollama 0.21.0 refused its pull in the previous session ("412 requires a newer version of Ollama", from the lane handoff, not re-run), and 2.1 rules out the upgrade |

`qwen3-coder-30b-c32k` is `qwen3-coder:30b` with `PARAMETER num_ctx 32768`
(Claude Code's prompt is long) and `PARAMETER num_thread 8` (to keep half
the 16 cores for the fleet).

## 3. The replay set

`REPLAY_KIND=simple_coding REPLAY_N=2 REPLAY_I18N=1 REPLAY_MAX_LINES=300`.
N = 2 because a turn on a loaded CPU takes minutes, and the per-case cap is
90 min. The 300-line cap keeps the cases small enough to finish.

| slice | key | files | changed lines |
|---|---|---|---|
| simple_coding | SPL-4883 | 1 | 24 |
| simple_coding | SPL-3194 | 5 | 241 |
| i18n | SPL-4834 | 36 | 196 |

The candidate runs `claude -p --dangerously-skip-permissions` under
`bwrap`: the filesystem is read-only except for the case directory, there is
no sudo, and HOME is clean (no global CLAUDE.md, hooks or MCP), with
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`. Outbound network is not
blocked by the sandbox, so this run proves nothing about egress (that is
G3, T0.3).

## 4. Run 1: qwen3-coder:30b, simple_coding, case SPL-4883

From 05:52:36Z to 06:10Z on 2026-11-15:

- The runner loaded in 17 s (`journalctl -u ollama`: "llama runner started
  in 17.05 seconds"), 21 GB, 100 % CPU, context 32768.
- Both `POST /v1/messages` calls returned **500 after exactly 6m0s**. Claude
  Code logged `api_retry` twice and made no model turn.
- Lane stopped at 06:10Z.
- A direct check, 2,000 prompt tokens through `/api/generate`, gave no
  answer in about 7.5 min before it was stopped. So prefill on this box
  under this load is under about 5 tokens/s (a lower bound, n = 1).
- Claude Code's first request carries its system prompt and tool
  definitions, many thousands of tokens. At that prefill rate it does not
  finish inside the 6-minute window. Where that window comes from in ollama
  was not established.

Box during the run (sampler every 10 s, n = 162): MemAvailable went from
43.7 GB to a low of 20.0 GB, and the runner RSS peaked at 21.5 GB.
Loadavg ranged 52-136 on 16 cores (the fleet ran at about 58 before).

## 5. Pause

At 06:13Z c-001@sat (task `a0f18f32`) measured the runner at about 456 %
CPU, the largest single load on the box. With the box at 614 % of its cores
(overflow mark 180 %), that load kept two language-review lanes pinned to
this box from placing. The lane stopped everything at 06:19Z: `ollama ps` was
empty and the server was at 0.4 % CPU.

## 6. What this says so far

On a 16-core box already running the fleet, Claude Code against a class S
model on CPU does not complete one turn. The bottleneck is prefill of the
client's own long prompt, not the model's size in RAM: RAM fit with margin.

## 7. Teardown

Pending.
