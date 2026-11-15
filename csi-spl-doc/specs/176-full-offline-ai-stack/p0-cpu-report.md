# Spec 176 T0.2: class S models on CPU, driven by Claude Code (P0 report)

Spec 176 phase P0, task T0.2, issue SPL-5557, epic SPL-2402. Lane c-919, on a 16-core CPU box of the fleet.
The harness is T0.1 (`do_spl_local_replay`, [replay-harness.md](replay-harness.md)).
CPU only, no GPU, no paid cloud resource. No routing weight is given to
`local` (that is P1).

**Verdict: on a 16-core box that also runs the fleet, Claude Code against a
class S model on CPU does not complete one turn.** The model fits in RAM
with margin. The limit is prefill: the box's CPU is shared, so the
client's own first prompt (about 5k tokens) is not processed inside the
6 minutes the call stays open.

## 1. Headline

| kind | model | pass / N | wall time | RAM peak (runner RSS) | note |
|---|---|---|---|---|---|
| simple_coding | qwen3-coder:30b Q4_K_M | 0 / 2 attempts, both on case SPL-4883 (of N = 2 cases) | run 1: 18 min, run 2: 7.5 min, both stopped | 22.0 GB | 0 model turns: every `/v1/messages` call ended in HTTP 500 after 6m0s |
| simple_coding | devstral-small-2:24b | not run | | | 24B dense, slower than the model that already fails (section 6) |
| i18n | qwen3-coder:30b | not run | | | stopped once simple_coding showed no turn completes |

Version: Claude Code 2.1.311, ollama 0.21.0. Tree: replay cases built from
`origin/master` `1a86b09c7`. n: per row above.

No candidate produced a diff, so the cross-vendor review had nothing to
judge. Zero passes is a count of zero outputs, not a quality verdict.

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
| devstral-small-2:24b | 24B dense | Apache-2.0 (HF `mistralai/Devstral-Small-2-24B-Instruct-2512` card) | no: pull stopped at 67 % (section 6) |
| gpt-oss:20b | 21B MoE | Apache-2.0 (HF `openai/gpt-oss-20b` card) | no: ollama 0.21.0 refused its pull ("412 requires a newer version of Ollama"), and 2.1 rules out the upgrade |

`qwen3-coder-30b-c32k` is `qwen3-coder:30b` with `PARAMETER num_ctx 32768`
(Claude Code's prompt is long) and `PARAMETER num_thread` 8 in run 1, 6 in
run 2 (to leave most of the 16 cores to the fleet).

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
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1` and `API_TIMEOUT_MS=3000000`.
Outbound network is not blocked by the sandbox, so this run proves nothing
about egress (that is G3, T0.3).

## 4. The runs (qwen3-coder:30b, simple_coding, case SPL-4883)

### 4.1 Run 1: 05:52:36Z to 06:10Z

- The runner loaded in 17 s (`journalctl -u ollama`: "llama runner started
  in 17.05 seconds"), 21 GB, 100 % CPU, context 32768.
- Both `POST /v1/messages` calls returned **500 after exactly 6m0s**. Claude
  Code logged `api_retry` twice and made no model turn.
- Stopped by the lane at 06:10Z. At 06:13Z the box's dispatcher paused the
  lane for CPU load (section 5).

### 4.2 Run 2: 06:53:29Z to 07:00:55Z

Two changes against run 1: `num_thread` 6, and the client got a smaller
prompt (`--tools Bash,Read,Edit,Write,Glob,Grep`) and long stream timeouts
(`CLAUDE_STREAM_IDLE_TIMEOUT_MS`, `CLAUDE_STREAM_FIRST_BYTE_TIMEOUT_MS`,
`CLAUDE_BYTE_STREAM_IDLE_TIMEOUT_MS`, each 3000000).

- The first call again returned 500 after 6m0s (ollama log 06:59:33Z); the
  retry returned 500 after 1m15s when the lane stopped the run (07:00:49Z).
- Claude Code's retry record shows `error_status: null`: the call was ended
  without an HTTP answer, so the 500 in ollama's log is the closed
  connection. The setting behind the 6 minutes was not found; the four
  timeout variables above did not move it.

### 4.3 How big the first request is

A local dummy server captured Claude Code's first request in run 2's
configuration: 19,651 bytes of JSON, of which the system prompt is 5,988,
the 6 tool definitions 11,545 and the messages 1,662. That is about 5k
tokens (at ~4 characters a token, an estimate), plus about 3.6k characters
of case brief. To answer inside 6 minutes the server needs about 16
tokens/s of prefill.

### 4.4 Prefill measured directly (`/api/generate`, `num_predict` 8)

| when (Z) | prompt | result | rate it shows |
|---|---|---|---|
| 06:12-06:19 | ~2,000 tokens | no answer in 7.5 min, stopped | under ~4.4 tok/s |
| 07:02:38-07:25:21 | the captured first request, raw (~5k tokens) | no answer in 22m42s (ollama log), ended when its session closed | under ~3.7 tok/s |
| 07:25:42-07:35:22 | first 1,600 characters (~400 tokens) | no answer in 9m39s | not a clean sample: the runner was still at 426 % CPU with no request open, so it was most likely still on the abandoned prefill before it |

Each row is n = 1, and each is a bound, not a measured rate. The rate the
client needs is about 16 tok/s, at least 4 times more than the box gave.

### 4.5 The box while the model ran (sampler every 10 s)

GB = 10^9 bytes, from `/proc/meminfo` and the runner's `VmRSS`.

| run | samples | MemAvailable low | runner RSS peak | loadavg (1 min) on 16 cores |
|---|---|---|---|---|
| run 1 | 162 | 20.5 GB (from 44.7 GB) | 22.0 GB | 52-136 |
| run 2 + benches | 250 | 18.4 GB (from 45.0 GB) | 22.0 GB | 27-155 |

The runner's swap was 1.1 GB of its 20 GB at 07:36Z and swap-in was small
(`vmstat`: 200-680 KB/s), so swapping is not what slowed it. The run queue
was 33-65 on 16 cores: the runner got only part of its threads.

## 5. Pause

At 06:13Z c-001@sat (task `a0f18f32`) measured the runner at about 456 %
CPU, the largest single load on the box. With the box at 614 % of its cores
(overflow mark 180 %), that load kept two language-review lanes pinned to
this box from placing. The lane stopped everything at 06:19Z. Both lanes
placed by 06:54Z and the lane resumed (run 2) with one model load at a time.

## 6. Why devstral and the i18n slice were not run

- devstral-small-2 is 24B **dense**: every token runs all 24B parameters,
  against about 3B active in qwen3-coder's MoE. Prefill compute grows with
  the active parameters, so on the same box it would be several times
  slower than the model that already cannot answer one call in 6 minutes.
  Running it would only load the shared CPU for a known result.
- The i18n slice uses the same client prompt, so its first call has the
  same size and the same outcome.

## 7. What this says, and what would change it

- On a box that runs the fleet, the P0 question "does Claude Code work with
  a class S model on CPU" gets **no**, for a reason that is about the shared
  CPU, not about the models: RAM fit (22.0 GB peak with 18.4 GB still
  available).
- Not measured here: the same run on an idle or dedicated CPU box. The
  bounds in 4.4 were taken at loadavg 27-155 and do not say what an idle
  16-core box gives. That run is the next measurement if P0 is to be
  answered for CPU as such, not for this box.

## 8. Teardown

- Models removed: `ollama rm qwen3-coder-30b-c32k qwen3-coder:30b`, and the
  34 `-partial` blob files of the stopped pulls (all dated 2026-11-15, after
  this lane started; `ollama list` was empty before it). The models dir went
  from 28 GB to 20 KB (`du -sh`).
- The server keeps running: it was on the box before this lane and it was
  not started by it. It is idle, has no models and listens on 127.0.0.1
  only. Stopping it is for whoever owns it.
- Run logs, the Modelfile, the candidate script and the captured request
  are kept under the box's `/var/tmp/c-919-replay-logs/` (not in git).
