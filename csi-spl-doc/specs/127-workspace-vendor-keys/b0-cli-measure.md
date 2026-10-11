# Spec 127 B0: CLI auth, measured

Lane B0 of [spec 127](spec.md) section 10: "measure per CLI: what
authenticates (env var, helper, login only), the telemetry switch (L16),
whether it writes the key to its state (L14), qwen `--auth-type` pin; record
each version".

Measured 2026-10-11 on the main box, as the agent user (`SPOOL_AGENT_USER`),
by c-985. Every run used an obviously fake key (built in 1.2) and a throwaway
`HOME` under the scratch dir, so no real login or key was read, used or
changed. No CLI was installed or updated.

## 1. Method

### 1.1 Versions

| CLI | kind | `<cli> --version` |
|---|---|---|
| `claude` | claude | `2.1.292 (Claude Code)` |
| `vibe` | mistral | `vibe 2.26.0` |
| `qwen` | qwen | `0.24.6` |
| `grok` | grok | `grok 1.0.50 (c58f321264ba) [stable]` |
| `agy` | agy | `1.3.3` |

All five are installed for the agent user; none is missing.

### 1.2 The fake keys

Each ends in the marker `b0tailMARKzz`, so a grep finds the full key, the
last 20 characters (what claude keeps) and the last 12 (what grok logs).

```bash
Z=$(printf '0%.0s' $(seq 60)); KA="sk-ant-api03-FAKE${Z}Qb0tailMARKzz"; KX="xai-FAKE${Z}Xb0tailMARKzz"; KG="AIzaFAKE${Z}Gb0tailMARKzz"; KM="FAKE${Z}Mb0tailMARKzz"; KO="sk-FAKE${Z}Ob0tailMARKzz"
```

### 1.3 One run

A run is: a fresh empty dir as `HOME`, a clean environment, the fake key in
the variable under test, one no-op prompt, then a grep of that whole `HOME`.

```bash
H=$SCRATCH/h1; rm -rf $H; mkdir $H; env -i PATH=$PATH HOME=$H TERM=dumb ANTHROPIC_API_KEY=$KA timeout 60 claude -p "say ok"
```

```bash
grep -rlF -- "$KA" $H; grep -rlF -- "${KA: -20}" $H; grep -rlF -- "${KA: -12}" $H
```

Interactive runs start the CLI the same way in a private tmux server
(`tmux -L b0m new-session -d ...`), step the first screens with `send-keys
Enter`, read them with `capture-pane`, then `kill-server` and grep.

"Network" here is only the vendor answering 401 to the fake key; for qwen the
base URLs pointed at closed local ports (`http://127.0.0.1:9/v1`,
`http://127.0.0.1:7`), so the fake never left the box. No packet capture was
taken: the telemetry column names the switch and where it is read, not a
measured absence of traffic.

## 2. Results

### 2.1 The table

n = number of runs behind the cell. "found" = the fake (or the part named)
appears in a file under the throwaway `HOME`.

| CLI | authenticates by (n) | key in its own state, L14 (n) | telemetry switch, L16 | qwen pin |
|---|---|---|---|---|
| claude | `ANTHROPIC_API_KEY` (n=4), or `apiKeyHelper` in a `--settings` file (n=4; helper called 6 times in 40 s, re-asked after each 401) | `-p` + env: 0 (n=2). `-p` + helper: 0 (n=3). **Interactive + env: last 20 chars found in `.claude.json` `customApiKeyResponses`, on Yes AND on No** (n=1 each). Interactive + helper: 0, no `customApiKeyResponses` (n=1) | `DISABLE_TELEMETRY=1`, `DISABLE_ERROR_REPORTING=1`, or both via `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC=1`; OTEL export is off unless `CLAUDE_CODE_ENABLE_TELEMETRY=1` | - |
| vibe | `MISTRAL_API_KEY` (n=2), or `~/.vibe/.env` (n=1); the variable beats the file (code, 2.3) | 0 (n=3) | `VIBE_ENABLE_TELEMETRY=false` (config `enable_telemetry`, default true) turns off telemetry AND Sentry crash reports | - |
| qwen | `OPENAI_API_KEY` + `OPENAI_BASE_URL` with `--auth-type openai` (n=4); also `ANTHROPIC_API_KEY` (n=1), and by auth type `GEMINI_API_KEY`, `DASHSCOPE_API_KEY` (names in the bundle, not run) | 0 (n=8, including `--openai-api-key` on argv) | `privacy.usageStatisticsEnabled: false` in `settings.json` (default **true**, no env var found); OTEL telemetry off unless `QWEN_TELEMETRY_ENABLED` / `telemetry.enabled` | pin wins over `settings.json` `selectedType` and is not written back (n=1); unpinned `-p` refuses with no auth type (n=3) or follows `selectedType` to another vendor (n=1) |
| grok | browser / device login first; `XAI_API_KEY` only as a fallback when no login is stored, probed at start (n=2); `GROK_AUTH_PROVIDER_COMMAND` helper (n=2) | env: full key 0, **last 12 chars found in `logs/unified.jsonl`** (`key_suffix`) (n=2). **Helper: full token found in `~/.grok/auth.json`** (n=1, interactive) | `GROK_TELEMETRY_ENABLED=false` or `DISABLE_TELEMETRY=1` (config `[features] telemetry = false`); trace upload follows it (`GROK_TELEMETRY_TRACE_UPLOAD`) | - |
| agy | **Google login only** (or Google ADC via `AGY_ADC_AUTH`, not measured): `GEMINI_API_KEY` and `GOOGLE_API_KEY` are ignored, the CLI asks for a browser login (n=3) | 0 (n=3) | no user-facing switch found: `disable_telemetry` exists only as a protobuf field in the binary | - |

### 2.2 claude

- `claude --help` -> "Anthropic auth is strictly ANTHROPIC_API_KEY or
  apiKeyHelper via --settings" (under `--bare`).
- Helper runs: `{"apiKeyHelper":"<SCRATCH>/helper.sh"}` in a settings file;
  the helper appends a line to a call log and prints the fake;
  `claude --settings <file> -p "say ok"` ran until its timeout (n=3), the call
  log held 6 lines after 40 s, `HOME` held no part of the key.
- **L14, the red control the spec predicted, confirmed**: interactive claude
  with `ANTHROPIC_API_KEY` shows "Detected a custom API key in your
  environment", prints `sk-ant-...` + the last 20 characters in the pane, and
  writes those 20 characters to `$HOME/.claude.json`:
  `{"approved": ["...b0tailMARKzz"], "rejected": []}` after Yes,
  `{"approved": [], "rejected": ["...b0tailMARKzz"]}` after the default No.
  The full key was never written (n=2). Read with:

```bash
python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1])).get("customApiKeyResponses"))' $H/.claude.json
```

- So the env var also shows the last 20 characters in the pane (L8). With the
  helper nothing was stored and no prompt was shown (n=1, run up to the
  trust screen).
- Telemetry names counted in the binary:

```bash
strings -n 8 $(readlink -f $(command -v claude)) | grep -oE '\b(DISABLE_TELEMETRY|DISABLE_ERROR_REPORTING|CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC|CLAUDE_CODE_ENABLE_TELEMETRY|CLAUDE_CODE_API_KEY_HELPER_TTL_MS)\b' | sort | uniq -c
```

  -> 15, 8, 30, 17, 7.

### 2.3 vibe

- `-p` with `MISTRAL_API_KEY` -> "Invalid API key (from env var
  MISTRAL_API_KEY)", rc 1 (n=2, the second with a different fake in
  `~/.vibe/.env` as well); with the env file alone the same message (n=1):
  vibe loads the file into its environment first.
- Precedence is the code's: `load_dotenv_values` skips a variable the
  environment already holds ("An explicit non-empty process/shell value wins
  over the .env file"). Read with:

```bash
grep -n -A14 'def load_dotenv_values' $(pipx environment --value PIPX_LOCAL_VENVS)/mistral-vibe/lib/python3*/site-packages/vibe/core/config/vibe_schema.py
```

- vibe writes a key only in its onboarding: `set_api_key_in_keyring`, else
  `~/.vibe/.env` (`vibe/setup/auth/api_key_persistence.py`,
  `_save_api_key_to_env_file`). With the key in the environment onboarding did
  not run and no `.env` was created (n=2).
- `vibe/cli/cli.py` calls `init_sentry(enabled=config.enable_telemetry, ...)`:
  the one switch covers the crash reporter too. `spawn-mistral.sh:63` already
  sets it.

### 2.4 qwen

- `-p` with no auth type and no `settings.json`: "No auth type is selected.
  Please configure an auth type (e.g. via settings or `--auth-type`) before
  running in non-interactive mode." `QWEN_DEFAULT_AUTH_TYPE=anthropic` did not
  change that (n=1).
- **Why the pin is needed** (n=1 each): with `settings.json`
  `{"security":{"auth":{"selectedType":"anthropic"}}}` and both
  `ANTHROPIC_API_KEY` and `OPENAI_API_KEY` set, unpinned qwen called
  `Anthropic.makeRequest`; the same with `--auth-type openai` called
  `OpenAI.makeRequest`. The pin did not rewrite `settings.json`. Read from the
  run's `--debug` file:

```bash
grep -ohE 'Anthropic[A-Za-z.]*\.makeRequest|OpenAI\.makeRequest' $H/.qwen/debug/*.txt | sort | uniq -c
```

- Usage statistics default ON (`usageStatisticsEnabled:{type:"boolean", ...,
  default:true` in the bundle); the agent user's `~/.qwen/settings.json` does
  not set it today.

### 2.5 grok

- `grok -p` with `XAI_API_KEY` and no login: "Not signed in ... set the
  XAI_API_KEY environment variable or run `grok login`" (n=1). Interactive
  (n=1): the log shows `"auth: first-party API key probe"` with
  `"verdict":"Unusable"` and `"key_suffix":"b0tailMARKzz"`, and the TUI falls
  back to a device login. Read with:

```bash
grep -oE '"msg":"auth: first-party API key probe","ctx":\{[^}]*' $H/.grok/logs/unified.jsonl
```

- `~/.grok/docs/user-guide/02-authentication.md`: "Grok uses the API key as a
  fallback when no session token is active. If you have already signed in
  interactively, the stored session token takes precedence." A seat on a
  customer key must therefore run with a `HOME` / `GROK_HOME` that holds no
  `auth.json`, or it spends the box login.
- The auth provider command (`GROK_AUTH_PROVIDER_COMMAND`, or `[auth]
  auth_provider_command`) printing the fake: interactive grok signed in and
  wrote the full fake to `~/.grok/auth.json` (n=1; the user guide says so:
  stdout "is captured by Grok and saved as the access token"). In `-p` it was
  not called (n=1).

### 2.6 agy

- `agy -p "say ok" --print-timeout 20s` with `GEMINI_API_KEY` (n=2, one with
  `AGY_ADC_AUTH=1`) or `GOOGLE_API_KEY` (n=1): an OAuth URL and "Waiting for
  authentication", or "authentication required. Run 'agy' to log in". The log
  says "Auth mode is unspecified" and "You are not logged into Antigravity";
  no API-key probe line. Read with:

```bash
grep -hE 'Auth mode|not logged' $H/.gemini/antigravity-cli/log/*.log | sort -u
```

- `AGY_ADC_AUTH` ("To log out, please run `unset AGY_ADC_AUTH`" in the binary)
  selects Google Application Default Credentials: a service account or user
  credential file, not an API key. Not measured: it needs a real credential.

## 3. What this changes in spec 127

| spec line | measured | consequence for the lanes |
|---|---|---|
| 3, claude: `apiKeyHelper` via `--settings` only, never `ANTHROPIC_API_KEY` (L14) | confirmed: the env var stores the last 20 chars on Yes and on No and shows them in the pane; the helper stores nothing | X2 as written. L14's red control works as predicted |
| 3, grok: `XAI_API_KEY`, "B0 confirms it beats a login" | **contradicted**: a stored login beats the key; the key's last 12 chars go to grok's log | X2: the grok seat runs with a `HOME` / `GROK_HOME` holding no `auth.json`, and grok's log dir counts as key-bearing for L5 and L14. The provider command writes the token to `auth.json`: X2 must not use it |
| 3, agy: "if B0 shows agy takes a Google login only, agy is not supported" | **login only** for API keys (n=3); ADC unmeasured | agy is "not supported" for workspace keys until it takes a key; D1's kind CHECK and W1 can keep the row and mark it so |
| 3, mistral: `MISTRAL_API_KEY` beats the env file | confirmed (code, and n=3 runs) | X2 as written; the seat home holds no `.vibe/.env` (onboarding writes there) |
| 3, qwen: `--auth-type openai` pinned | confirmed needed: unpinned follows `settings.json` to another vendor's key | X2 as written: pin plus the unset of other vendor variables (L10) |
| L16: telemetry off per CLI | switches named above; none found for agy; qwen usage statistics default ON and settings-only | X2 sets `DISABLE_TELEMETRY=1 DISABLE_ERROR_REPORTING=1` (claude), `VIBE_ENABLE_TELEMETRY=false`, `GROK_TELEMETRY_ENABLED=false`, and a seat `settings.json` with `privacy.usageStatisticsEnabled: false` (qwen). L16's own test still needs a packet capture: none was taken here |

Not done here, by the brief: no code, no launcher change, no other lane.
