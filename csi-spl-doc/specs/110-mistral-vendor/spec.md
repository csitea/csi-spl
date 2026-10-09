# Spec 110: Mistral as the 5th agent vendor (Mistral Vibe CLI)

Version **v1.0** (2026-10-08). Drafted by seat 1 (claude c-569) as v0.1.
All three review seats agreed, and every change they asked for is folded in
(section 9). The build lanes start on this consensus. Build tasks:
[tasks.md](tasks.md).

## 0. Owner asks and decisions (verbatim, HUM-10, t1 topic 5c3bb16a)

| msg | text |
|---|---|
| 12759536 | "add new AI vendor Mistral - discussion" |
| ff513efe | "ideally should be added via it's own cli tool - if it has one" |
| 6d3ab799 | "ideally with some kind of monthly subscription etc." |
| 99423692 | "so ideas how-to install it , how-to integrate it , implementations - needs to be added to the settings etc." |
| f4fd88fc | "I am considering the Mistral to take the place of grok even for now , because there seems to be some kind of problem with the payment of the overlimit for grok , it should have taken minutes , but it took several hoours" |
| **3393f016** | **DECIDED**: "so add it and so that it takes the current allocations from grok" |
| **803c3b38** | **DECIDED**: "q1 yes , q2 b , q3 b" (to the section 8 questions) |
| 1b27e902 | the owner bought a yearly Team subscription |
| **c7970593** | **DECIDED**: "good good so we start utilizing mistral more for documentation and lower level coding tasks in the beginning ... and also in every consensus and debate" |

**Decision D1 (msg 3393f016): Mistral takes grok's place.**

- **Share.** Mistral gets grok's share. In cnf `env.box.agent_split` that means
  `grok: 55` becomes `mistral: 55, grok: 0`. In each workspace's
  tenant_settings split the grok points move to mistral.
- **Fallback chain.** Today's chain is grok -> agy -> claude (owner 10-08,
  topic 65f75266, msg e5b8bf49). It becomes **mistral -> agy -> claude**.
- **grok stays installed and spawnable.** It can be picked by hand
  (`/grok-spawn`), and if its share is raised again it keeps its old chain,
  grok -> agy -> claude. Grok has been off in Fleet load since 10-07
  (t1 41fa1f2d), and this spec does not change that.

Grok is not removed: D1 is a share move, which is reversible from the
settings screen.

**Decisions D2-D4 (msg 803c3b38).** Owner order is final. Each overrides
the (a) that all three review seats had picked:

- **D2 (Q1 = b).** Mistral lanes may take personal-data and secret work
  (section 6).
- **D3 (Q2 = b).** Team plan, bought yearly (msg 1b27e902), with one seat
  per box (sections 2.3 and 5).
- **D4 (Q3 = b).** The share moves NOW. T013 follows T001 + T003 + T013a,
  not T014.
  - Until a box has the Mistral login, mistral is skipped there and its
    pick falls to agy, then claude (section 3.5).

**Decision D5 (msg c7970593, folded into T013a by c-001, msg e221f7b3).**
Mistral is routed by KIND as well as by share:

- **Documentation and specs** (`do_spl_lane_mix` kind `spec`): mistral
  first, then agy, then claude.
- **Low-level / mechanical coding** (kind `default`, difficulty unset):
  mistral first; a skipped mistral falls down its chain, agy then claude.
- **secret** and **hard** are unchanged: claude.
- **How share and kind combine.** The kind picks the FIRST vendor, and a
  vendor whose share is 0 is never first (so a share of 0 takes mistral out
  of every kind-first pick and restores agy for specs and grok for the
  default). The share drives only the easy-work nudge (difficulty < 60) and
  where a skipped vendor's points go.
- **Panels.** Every consensus or debate panel gets **one mistral seat**, in
  addition to the seats it has today. Seating panels is the orchestrator's
  job; no lane-mix or skill change.
- **Timing.** Nothing reaches mistral before T014: with no auth marker (or
  a dead key, 2.5) mistral is skipped and its work falls to agy, then claude.

## 1. Goals

| # | goal | measured by |
|---|---|---|
| G1 | The Mistral Vibe CLI is installed for the **agent user** on the main box and on the satellite by ONE named action, pinned to a version from cnf | `do_install_mistral_vibe` exit 0 + `vibe --version` equals the cnf pin on both boxes |
| G2 | `m-NNN` is a fifth agent kind: spawn, restore, spool, mirror, hook-ping, lane-mix and watchdog all treat it like qwen | `/mistral-spawn` seats `m-004`, which answers a spool task end to end (n >= 1 per box) |
| G3 | Workspace settings show Mistral and its share is editable; the hub stores five numbers summing to 100 | WUI e2e: set mistral 55, grok 0, reload, values kept |
| G4 | Mistral takes grok's allocation (D1) | `do_spl_agent_split_show` prints `mistral=55 grok=0`; the `do_spl_lane_mix` default pick is mistral; the chain is mistral -> agy -> claude |
| G5 | No key in git, a log, a command line or terraform state | hygiene sweep + the key-leak check in the install test (2.4) |

Out of scope: a Mistral API key for the HUB (no hub feature calls Mistral),
Le Chat web use, and the Mistral IDE plugin.

## 2. Install

### 2.1 Vendor facts: verified vs not

The facts below were read from the vendor's own sources on **2026-10-08**:
the README at `github.com/mistralai/mistral-vibe`, the PyPI JSON, the Vibe
source, `docs.mistral.ai` and `mistral.ai/pricing`. "Source" means the Vibe
python source at 2.26.0.

| claim (from c-002, unverified) | verdict | evidence |
|---|---|---|
| pypi package `mistral-vibe` | **CONFIRMED** | 2.26.0, uploaded 2026-10-06, `requires_python >=3.12` |
| binary `vibe` | **CONFIRMED** | README "Run Vibe: `vibe`" |
| non-interactive `--prompt` | **CONFIRMED** | `-p`/`--prompt` = programmatic mode, runs and exits; `--output text\|json\|streaming`; budgets `--max-turns`, `--max-price`, `--max-tokens` |
| key in `~/.vibe/.env` | **CONFIRMED** | `MISTRAL_API_KEY=...` in `~/.vibe/.env`; an env var of the same name wins over the file |
| (new) config | **CONFIRMED** | `./.vibe/config.toml` first, then `~/.vibe/config.toml`; `VIBE_HOME` overrides `~/.vibe` |
| (new) login | **CONFIRMED** | `vibe --setup` offers a browser sign-in OR a pasted key; README: "The credential is still a Mistral API key" (the browser flow mints a console key; my reading of the source, whose default sign-in host is the Mistral console) |
| (new) auto-approve | **CONFIRMED** | `--auto-approve` / `--yolo` approves every tool call, interactive too; the default agent `accept-edits` approves edits only |
| (new) resume | **CONFIRMED** | `-c`/`--continue`, `--resume SESSION_ID` (partial match) |
| (new) hooks | **CONFIRMED** | `~/.vibe/hooks.toml` (+ project `.vibe/hooks.toml`, trusted only); `pre_tool`/`post_tool`; JSON on stdin with `session_id`, `transcript_path`, `cwd` |
| (new) MCP | **CONFIRMED** | `[[mcp_servers]]` in config.toml; stdio, http, streamable-http |
| (new) instructions | **CONFIRMED** | `~/.vibe/AGENTS.md` + project files, trusted folders only; trust kept in `~/.vibe/trusted_folders.toml` |
| (new) transcripts | **CONFIRMED** (source) | `$VIBE_HOME/logs/session`, on by default |
| default model "Devstral" | **CONTRADICTED** | source default `mistral-vibe-cli-latest` = **Mistral Medium 3.5**; Devstral is only the local llama.cpp entry. The pricing page still says "powered by Devstral". A server-side experiment layer can route an unset `active_model` elsewhere, so 2.3 pins it |
| install method | **CONFIRMED** | README recommends `curl … /vibe/install.sh \| bash`; `uv tool install mistral-vibe` and `pip install` are alternatives. pipx is not mentioned (it installs the same PyPI package) |

**Measured by T005** on the main box, 2026-10-08, vibe 2.26.0 (pipx), as
the agent user, n = 1 each:

| question | answer | evidence |
|---|---|---|
| seed an interactive session | **YES, positional.** `vibe --auto-approve … '<prompt>'` starts the TUI with the prompt already sent, answers it and stays up at the `>` box. The adapter passes the seed positionally (no flag); no pane typing | `vibe --help`: "PROMPT  Initial prompt to start the interactive session with."; a scratch tmux pane answered `PONG` and kept the TUI up (`auto approve` mode shown) |
| self-update | **an interactive start shows an update PROMPT** (a dialog that would block an unwatched pane) when a newer version is cached; the install itself runs only from that dialog (`uv tool upgrade` / `brew upgrade`). Off: `enable_update_checks = false` (no check, no prompt); `enable_auto_update = false` too | source `cli/cli.py` `_maybe_run_startup_update_prompt`, `setup/update_prompt/update_prompt_dialog.py` -> `do_update` |
| telemetry | **ON by default** (`enable_telemetry = true`): events go to `api.mistral.ai/v1/datalake/events`; with telemetry on, crashes go to **Sentry `ingest.de.sentry.io` (not a Mistral host)**; the experiments client fetches from `experiments.mistral.services`. Off: `enable_telemetry = false` (also gates Sentry) and `[experiments] enable = false` | source `core/telemetry/send.py`, `observability/sentry.py`, `core/config/models.py`; egress in 2.5 |
| switch without a file edit | **`VIBE_<FIELD>` env vars override any config field** (`__` nests: `VIBE_EXPERIMENTS__ENABLE`). The launch line carries the four switches, so the agent user's `config.toml` (hand-set on the main box) is never rewritten | source `core/config/layers/environment.py` (`env_prefix="VIBE_"`, `env_nested_delimiter="__"`); `vibe --help` epilog |
| `--max-price` | **enforced in `-p` mode only.** The interactive TUI accepts the flag and ignores it, so in an m- seat the Mistral console spend limit is the cap that holds (2.5) | `vibe --help`: "Maximum cost in dollars (only applies in programmatic mode with -p)" |
| trust store | `$VIBE_HOME/trusted_folders.toml` = `trusted = [...]`, `untrusted = [...]`; a trusted ancestor counts; a cwd with no trustable files never prompts | source `core/trusted_folders.py`; vibe's own `TrustedFoldersManager` reads a `trust-workdir.sh` entry as trusted |
| project instructions | **vibe loads a trusted dir's `AGENTS.md`, never its `CLAUDE.md`.** This repo has no `AGENTS.md`, so the m- seed's first action reads the workdir's `CLAUDE.md` and `how-to-post.md` (`spawn-mistral.sh`). A fleet-wide `~/.vibe/AGENTS.md` (the twin of the global claude file) is not written by anyone yet | two `vibe -p` runs in a trusted git dir holding a codeword: `AGENTS.md` -> the codeword, `CLAUDE.md` -> `NONE` (n = 1 each) |
| model | the seat banner reads `mistral-large[off]` (the hand-set `active_model`); a set `active_model` already turns off the server-side routing, so the launch does not force cnf `model` | `~/.vibe/config.toml`; the banner also read `[Subscription] Pro` for the key on this box |

**NOT verified** (open for the review seats):

- **Hook output.** Whether a `post_tool` hook can inject context into the
  model, as claude's `additionalContext` does.
- **Automated use.** Whether the ToS limits automated or non-interactive
  agent use. Not read; the pricing page only says "Subject to fair usage
  limits and Mistral's Terms of Service". Read 2026-10-08 (T014): no clause
  bars it, quoted in 5.1.
- **EU data residency.** Only third-party sources claim it.

### 2.2 The action

`do_install_mistral_vibe` is a new orc action:
`csi-spl-orc/src/bash/run/install-mistral-vibe.func.sh`, named to the csi-rel
`<verb>-<noun>` rule.

- It runs as the **agent user** (`SPOOL_AGENT_USER`), never as the human
  user, the same on both boxes. On the satellite it runs as the box user
  over ssh, the way the satellite lanes do today.
- It is a thin wrapper over the box installer:
  `spool-install/install.sh --cli mistral`. One install code path, so a fresh
  box gets Mistral the way it gets qwen today, and `do_spl_box_update`
  keeps it current.
- **Method:** `uv tool install "mistral-vibe==<pin>"` when `uv` is on the
  agent user's PATH, else `pipx install "mistral-vibe==<pin>"`.
  - On the main box today the agent user has pipx and python 3.13 but no uv.
  - Python older than 3.12 fails fast and names the fix.
  - **Never `curl | bash`.** It is unpinned remote code, and the installer
    script is not the PyPI artefact.
- **Pin:** cnf `env.box.mistral_vibe.version: 2.26.0`. This is unlike qwen,
  which installs `@latest`, and the owner asked for pinning. A bump is one
  cnf edit plus a re-run. The action's report prints the installed version
  and the pin, and differing values are an error.
- **`DRY_RUN=1` prints the plan.** The default is the real install: it only
  touches the agent user's home, no root, no GCP.
- **The flag contract is checked after every install** (seat 4).
  - The action greps `vibe --help` for `--auto-approve`, `--resume`,
    `--continue` and `-p`. If one is missing, it refuses the pin.
  - `do_spl_box_update` never moves past the cnf pin.
  - T005 checks whether Vibe updates itself, and turns that off.
  - Transitive dependencies float under `==2.26.0`, so the report prints
    the `uv`/`pipx` dependency list.
- **Telemetry off** (seat 2): the switch found by T005's egress measurement
  (2.5) is written into `config.toml` or the launch env.

### 2.3 Where the login lives

- **The key.** It lives in `<agent-home>/.vibe/.env`, as
  `MISTRAL_API_KEY=…`, mode `0600`, owned by the agent user.
  - **Key entry is a named action, never a pane paste** (seat 4).
    `do_set_mistral_key` (new `set-mistral-key.func.sh`, built in its own
    fast-tracked lane, not T004) reads the
    key with `read -s`, then writes `.vibe/.env` as the agent user with
    `install -m 0600`. Why not paste: a key pasted into `vibe --setup` inside
    an agent tmux window lands in the scrollback, and 38 orc `.sh` files run
    `capture-pane` (`grep -rl capture-pane csi-spl-orc/src/bash --include=*.sh | wc -l` -> 38).
  - **If the owner uses the browser sign-in instead,** `vibe --setup` runs in
    a plain ssh session as the agent user, never in a fleet window. The
    browser flow mints a key against the owner's Mistral account. Section 5
    covers which plan.
  - **One key per box, named after the box** (e.g. `spool-<box>`), even on
    one Pro account. One box can then be revoked without stopping the other.
  - **The launcher unsets `MISTRAL_API_KEY`** (`env -u MISTRAL_API_KEY vibe …`).
    An env var beats `.env` (2.1), so a stray export in the tmux global env
    or a profile would silently swap the account.
  - The launcher never passes the key on a command line, where `ps` would
    show it. This is qwen's rule.
  - The key is never copied into git, a brief, a spool message or a log.
  - **Accepted risk, said aloud.** Every lane runs as the same agent user, so
    any lane (qwen included) can read `.vibe/.env`. That is true of every
    vendor login today, and this spec does not change it.
- **A tracked `.vibe/` dir is refused** by `do_check_dist_hygiene` (seat 4,
  T004).
  - Why: `trust-workdir.sh` trusts every worktree (3.3), and a trusted
    folder's `.vibe/{config.toml,hooks.toml,AGENTS.md}` is read first.
  - So without the gate, one commit to trunk could change the model, add an
    MCP server, or run a `pre_tool` hook on every m- seat.
  - Control: a planted `.vibe/hooks.toml` turns the gate red.
- **The auth marker.** cnf `env.box.agent_split.auth_marker.mistral:
  .vibe/.env`. A box without it skips mistral, the same as grok, agy and
  qwen today.
- **The config.** `<agent-home>/.vibe/config.toml` holds no secrets and is
  written by the install action:
  - `active_model` is pinned (cnf `env.box.mistral_vibe.model`, default
    `mistral-vibe-cli-latest`). That turns off the server-side model routing
    for an unset model.
  - The `[[mcp_servers]]` spool entry, written by T008.
  - Session logging stays on: the mirror reads the session files.
- **The satellite.** It needs its own login: its own Team seat (D3) and its
  own key. One key per box means one can be revoked without stopping the
  other.

### 2.4 Install test

`csi-spl-orc/src/bash/tests/install-mistral-vibe.tst.sh` is a pair:

- **Test.** It stubs `uv`/`pipx` (PATH stub, `SPOOL_TEST` guard), then
  asserts the exact install line (`mistral-vibe==2.26.0`), that the
  `config.toml` model pin is written, and that nothing outside the stubbed
  home was touched.
- **Control.** A cnf pin of `latest` or an empty pin is refused (exit 2),
  and so is python 3.11.
- **Key leak.** The plan text and the log never contain `MISTRAL_API_KEY=`
  followed by a value: a planted fake key in the stub home is grepped for in
  the output, n = 1.
- **Env override** (seat 4). With `MISTRAL_API_KEY` exported in the test
  env, the planned launch line carries `env -u MISTRAL_API_KEY`. The control
  is a launch line without it, which the test fails.
- **Key entry.** `do_set_mistral_key` fed a fake key on stdin writes a
  `0600` file, and the fake key appears in no output. The control is a
  `0644` result, which fails.

The live proof (`vibe --version` on both boxes) is part of T014, not a CI
test.

### 2.5 Egress, cost cap, dead key (seats 2 and 4)

- **Egress is measured before the switch.** T005 records the hosts one `-p`
  run contacts (`ss -tnp` or `strace -f -e trace=connect`, n = 1). If
  telemetry goes to a non-Mistral host, its off switch goes into
  `config.toml` before T014.
  - **Measured (T005, 2026-10-08, vibe 2.26.0, n = 1 per row)** with
    `strace -f -e trace=connect,sendto` on `vibe -p '<one word>'
    --auto-approve --max-turns 1`, the DNS names read from the queries:

    | run | DNS queries | TCP 443 connects |
    |---|---|---|
    | defaults | `api.mistral.ai` x10, `chat.mistral.ai` x2, `experiments.mistral.services` x2 | 39 |
    | the four `VIBE_*` switches in the env (the launch line) | `api.mistral.ai` x2, `chat.mistral.ai` x2 | 14 |
    | the same switches in a project `.vibe/config.toml` | `api.mistral.ai` x2, `chat.mistral.ai` x2 | 14 |

  - Every host is Mistral's: `api.mistral.ai` is the model API (and the
    telemetry endpoint), `chat.mistral.ai` the admin managed-config fetch
    (Team org settings, kept). Sentry (`ingest.de.sentry.io`) is contacted
    only on a crash and only while telemetry is on: the switch covers it.
  - **The off switch is in the launch env, not `config.toml`:**
    `VIBE_ENABLE_TELEMETRY=false VIBE_ENABLE_UPDATE_CHECKS=false
    VIBE_ENABLE_AUTO_UPDATE=false VIBE_EXPERIMENTS__ENABLE=false`
    (`spawn-mistral.sh`; restore takes the same prefix in T007).
- **Cost cap.**
  - Pro overage bills pay-as-you-go "at API rate" (section 5), so a
    runaway lane at a 55 % share bills without limit.
  - The adapter therefore passes `--max-price` from cnf
    `env.box.mistral_vibe.max_price`, or the owner sets a spend limit in
    the Mistral console.
  - **Measured (T005): vibe enforces `--max-price` in `-p` mode only.** An
    m- seat is interactive, so the flag there is a record of the cnf value
    (`5.00`), not a cap. **The console spend limit is the cap that holds**;
    T014 sets it before the first lane.
  - T014 records which of the two is in force.
- **A dead key is its own state, not a retry loop.**
  - T006 records the 401 / invalid-key text from a real pane (revoke a
    test key, n = 1).
  - agent-state then reports `auth`, and the watchdog does NOT respawn.
    The lane sends a `blocker` to the dispatcher, and lane-mix skips
    mistral until the owner re-keys.
  - The auth marker (2.3) proves the file exists, not that the key is valid.

## 3. Integrate: the fifth agent kind

qwen is the template. Running `git grep -il qwen -- ':!*.md'` at `0b38b6ff3`
lists **109 files**. A separate `git grep -l acgq -- ':!*.md'` lists
**31 files**, and **20 of those are not on the qwen list**. Those 20 read the
id grammar without naming qwen; section 3.2 names them.

### 3.1 Identity

| item | today | becomes |
|---|---|---|
| letter | a c g q | **m** (kind `mistral`) |
| Go `agentid.newRe` / `newAnyCaseRe` | `^[acgq]-[0-9]{3}$` / `^[ACGQacgq]-…` | `^[acgmq]-[0-9]{3}$` / `^[ACGMQacgmq]-…` |
| Go `agentid.kinds` | 4 entries | + `'m': "mistral"` |
| legacy prefix | `CLE/AGY/GRK/QWN` | **none**. Legacy ids ended at `2026-10-03T20:59:59Z`; no `MST-` is ever minted, and `legacyKinds` is unchanged |
| role seats | `001..003` reserved for every kind (061 Q1) | same for `m` |
| tmux window | `<tag>: c-004 <title>` | `<tag>: m-004 <title>` |
| agent ceiling count | `grep -cE '…([acgq]-[0-9]{3}\|…)'` | `[acgmq]`; the repo CLAUDE.md and the spawn skills' count text change with it |

**Spec 061 section 0 grammar.** It changes from `^[acgq]-[0-9]{3}$` to
**`^[acgmq]-[0-9]{3}$`**, and spec 061 gets a one-line dated amendment
pointing here. Built by T011, doc only.

Other docs carry the literal grammar too:

- `SPEC-spool-identity-routing.md`
- `SPEC-spool-fleet-roles.md`
- `SPEC-agent-identity-map.md`
- the three `isg/*-agent-setup.ISG.md`
- spec 068

A new `isg/mistral-agent-setup.ISG.md` is added.

### 3.2 Who reads the grammar, outside the qwen list (20 files)

| layer | files | note |
|---|---|---|
| **rdb (DDL, lands FIRST)** | `0101` CHECKs `roster_agent_id_check`, `issues_assignee_check` (re-made in `0102`), `fleet_lanes_agent_id_check`, `fleet_asks_{from_agent,acked_by,closed_by}_check`, `agent_id_aliases.new_id`; `0110` function `messages_claim_defaults()` + its backfill regex | **These refuse an `m-NNN` row today.** A new forward-only migration re-makes each CHECK with `[acgmq]` and `CREATE OR REPLACE`s the function. It must be applied on dev AND prd before any `m-` agent registers: DDL first, then the code that writes it |
| hub Go | `store/flow_mentions.go` (+test: the `"acgq"` rune set, which mirrors the WUI regex), `store/message_claim.go` `odSeatRe ^[acgq]-00[1-4]$` | |
| orc | `spool-send.sh`, `asks.sh`, `spool-mcp.sh` (`ID_RE` + window sed), `spool-mirror.py` `PID`, `agent-name-resume.sh`, `scripts/spl-session-prune.sh`, `run/spl-{dispatch-rotate,orch-rotate,orch-load-report,peer-poll,role-id-switch,unanswered-sweep}.func.sh` | the per-kind role-seat loops (`c-001`..) are unchanged: mistral holds no role seat in v1 |
| tests | `test-agent-name-shape.sh`, `peer-poll.tst.sh`, iac `help-connect-agent.tst.sh` | each gains an `m-004` case and a control (`x-004` refused) |

`next-agent-id.sh` is on the qwen list. Its machine-scope counter
`SCOPE=acgq` and the `SPOOL_ID_ROLE_LETTERS` check become `acgmq`.

### 3.3 Launcher, restore, skill

- **`spawn-mistral.sh`** is an adapter of `spawn-core.inc.sh`, a twin of
  `spawn-qwen.sh`:
  - `SPAWN_KIND=mistral`, `SPAWN_BIN_VAR=MISTRAL_BIN`, `SPAWN_NAME_FLAG=`
    (no session-name flag is known, so the tmux window carries the name).
  - `SPAWN_RESUME_FLAG=--resume`, `SPAWN_CONTINUE_FLAG=--continue`.
  - **Permissions:** `--auto-approve`, the fleet's bypass rule in Vibe's
    terms. No other mode.
  - **Launch line:** `env -u MISTRAL_API_KEY vibe --auto-approve
    --max-price <cnf>`. Both are explained in 2.3 and 2.5.
    - Built (T005) as `exec env -u MISTRAL_API_KEY VIBE_ENABLE_TELEMETRY=false
      VIBE_ENABLE_UPDATE_CHECKS=false VIBE_ENABLE_AUTO_UPDATE=false
      VIBE_EXPERIMENTS__ENABLE=false bash spool-harness.sh --as m-NNN
      --mirror -- <vibe> --auto-approve --max-price <cnf> "<seed>"`.
    - The `env` goes BEFORE the harness (core `SPAWN_EXEC_PREFIX`), so the
      harness still sees `vibe` as its command (the mirror keys on its
      basename); `--max-price` is core `SPAWN_EXTRA_FLAGS`. Both are empty for
      the four other adapters, whose dry-run output is byte-identical.
    - A missing or non-numeric cap refuses the spawn
      (`SPOOL_MISTRAL_MAX_PRICE` overrides the cnf for one run).
  - **The prompt flag: none (measured, 2.1).** A positional prompt seeds the
    interactive TUI, so `SPAWN_PROMPT_FLAG=` and no pane typing.
  - **`SPAWN_ID_PREFIX`.** It is a legacy-prefix field, and core uses it for
    the `<P>_TMUX_PANE` env name and the title check. Mistral has no legacy
    prefix, so T005 makes the core take a kind-derived env name
    (`MISTRAL_TMUX_PANE`) and validates the title by letter `m`, without
    breaking the four existing adapters.
    - Built: `SPAWN_ID_PREFIX=` + `SPAWN_ID_LETTER=m`; a `q-004` title is
      refused with "does not carry the mistral letter m-".
- **`restore-mistral.sh`** is the twin of `restore-qwen.sh`. `restore-core`,
  `spl-agent-restart`, `spl-agent-boot-restore` and
  `spl-agent-identity-restore` learn the kind.
- **The `/mistral-spawn` skill.** `assets/commands/mistral-spawn.md` is
  ported like `qwen-spawn.md`, plus a `harness-parity.tsv` row each for
  `spawn-mistral.sh`, `restore-mistral.sh` and the skill. `/spawn-an-agent`
  names it.
- **`trust-workdir.sh`** writes the worktree into
  `<agent-home>/.vibe/trusted_folders.toml`, so the first run does not stop
  on the trust prompt.
- **`spool-harness.sh` / `spool-agent.sh` / `agent-state.inc.sh`** learn the
  kind for the pane, state and usage-limit detection. T006 records the limit
  text from a real pane.
- **`tmux-close-window.sh`** gets the kind case.

### 3.4 Hooks, MCP, mirror

- **hook-ping.** A new `hook-ping/mistral.sh` is a `post_tool` entry in
  `~/.vibe/hooks.toml`, and `spl-hook-ping` / `live-one.sh` learn the kind.
  Spec 093 7.3 contract: a random token recorded under `HOOK_PING_DIR`. If
  2.1 shows Vibe cannot inject context, the ping proves "the hook ran" only,
  and the spec says so.
- **MCP.** `spl-agent-mcp-install` writes the spool MCP server as a
  `[[mcp_servers]]` stdio entry in `~/.vibe/config.toml`, and
  `mcp-start.sh` / `mcp-start-chrome.sh` learn the kind.
- **The mirror.** `spool-mirror-hooks.inc.sh`, `agent-mirror-check.py` and
  `agent-identity.py` read the transcript from
  `$VIBE_HOME/logs/session/<session_id>` (the hook stdin gives
  `transcript_path` directly).
- **The watchdog.** `watchdog/situations/{lib.inc.sh,s3.sh}`,
  `spl-watchdog`, `spl-wd-takeover` and `spl-standby-bench` learn the kind.

### 3.5 Lane mix and the cnf split (D1)

- **cnf.** `all.env.yaml` `env.box.agent_split` gains `mistral` and
  `auth_marker.mistral: .vibe/.env`, and the rendered `dev.env.json` /
  `prd.env.json` follow via tpl-gen.
  - **Two steps.** T003 adds `mistral: 0`. **T013 (the switch, D4)** then
    moves `grok: 55 -> 0` and `mistral: 0 -> 55`. That happens as soon as
    T001 (DDL), T003 (cnf) and T013a (lane mix) are on trunk. It does not
    wait for the login.
  - **The missing-login rule changes for mistral** (T013a). Today a kind
    whose auth marker is absent is skipped, and its share goes to claude
    (the cnf comment). Under D4, a skipped mistral's pick falls down its
    chain instead: agy, then claude. Until the Team login exists on a box,
    that box's 55 points go to agy first.
- **`spl-lane-mix.func.sh`.** `LANE_MIX_VENDORS` becomes 5 kinds and
  `LANE_MIX_SPLIT` reads `claude=N grok=N agy=N qwen=N mistral=N`.
  - The 4-number form stays accepted for one release, with mistral 0.
  - **The default pick.** "difficulty unset -> grok" becomes **"-> the
    highest-share of grok/mistral"**, which after T013 is mistral. It is not
    hard-wired to mistral, so moving the share back restores grok without a
    code change.
  - **The chain.** `mistral -> agy -> claude`, with grok keeping
    `grok -> agy -> claude`.
- **`spl-agent-split-show`** prints five numbers.
- **`spl-hub-agent-kinds`** and **`spl-dispatch-lease`** learn the kind.

### 3.6 Hub

- **`store.AgentKinds`** gains `mistral`. `fleet_agent_kinds_off` changes:
  rdb 0149's array CHECK gets `'mistral'`, and "never all four" becomes
  "never all five". The `badFleetLoad` text and the pause `lane` kind
  message are updated.
- **`hubclient/host.go`** probes `{"mistral", ["vibe","--version"], true}`.
- **tenant_settings.** `AgentSplit.Mistral`, `agentSplitJSON` and the PATCH
  body require five numbers.
  - A 4-number PATCH from an old WUI is refused (`bad_split`, five names in
    the text), so T009 (hub) and T010 (WUI) land in the same deploy window:
    hub first, WUI right after.
  - Old WUIs show "Not sent", the hub-refusal path.
- **Migration (T001).** Next free prefix at commit time:
  - `ADD COLUMN agent_split_mistral smallint NOT NULL DEFAULT 0` with a
    0..100 CHECK.
  - `DROP CONSTRAINT tenants_agent_split_sum_check`, re-added over five
    columns.
  - Existing rows keep their sum, since mistral is 0.
  - **No data UPDATE of any workspace's split.** D1 for a workspace is its
    admin's act on the settings screen. For the owner's workspace the owner
    does it, or T013 does it through the PATCH route as admin. D4 is that
    go.

## 4. Settings (the WUI)

- **The split screen** (`pages/tenant-settings/split.vue`) gets a fifth
  input, `data-test="tenant-split-mistral"`, labelled `split_mistral`. The
  page header comment and the sum message name five vendors.
- **`utils/tenant-settings.mjs` and its mock**, five numbers.
  `tenant-settings.test.mjs` (unit + e2e) adds a case: mistral 55, grok 0,
  save, reload, values kept. The control is a sum of 99, which is refused.
- **Kind labels.** `agent-kind.mjs` maps `m-` to the label key
  `agent_kind_mistral` ("Mistral"), and ChannelSidebar shows it.
  `agent-id.mjs` `AGENT_ID_SRC` becomes `[acgmq]` (gate FR-005 with Go).
  `rail-order.mjs`, `fleet-load.mjs` and `mjs-shims.d.ts` learn the kind.
- **Fleet load screen.** The kinds-off and pause lists include Mistral.
- **i18n.** 2 keys × 19 locales. Locale messages are their own lazy chunk
  (`nuxt.config.ts`, `lazy: true`), so this does not grow the initial
  download.
- **The 155 KB initial-download gate is red today.**
  - `split.vue` is a route chunk, lazy by construction.
  - The only initial-chunk change is one letter in two regexes and one map
    entry: a few bytes.
  - T010 measures the initial JS before and after (`initial-js-trims`) and
    reports the delta. A delta over 100 B means something leaked into the
    initial chunk, and the task is not done.
  - No new component is added to ChannelSidebar.

## 5. Subscriptions (read 2026-10-08, `mistral.ai/pricing`)

| plan | price | Vibe CLI | for unattended agents |
|---|---|---|---|
| Free | $0 | "Limited coding sessions" | too small for a lane |
| **Pro** | **$14.99/mo** (students $5.99) | "Full access to Vibe for all-day coding" + **$15/mo API credits** | one account. The limit is "fair usage", **no number published**. Over-limit runs on PAYG credits "at API rate" |
| **Team** | **$24.99/user/mo** | "Even higher limits" | one seat per box (Q2). The admin can turn training off org-wide |
| Enterprise | contact | — | out of scope |
| API PAYG | Medium 3.5: **$1.50 in / $7.50 out / $0.15 cached** per 1M tokens | key from the console | **NOT on an official price page**: the numbers are from the Vibe source price table. Devstral 2 prices are not on Mistral's site |

- **Training.** The pricing table says "Model training: Opt-out" for every
  plan (help article 455207). Consumer plans are **not** opted out by
  default, Team admins can opt out the whole org, and Enterprise is opted out
  by default. **The Vibe and API toggles are separate.**
  - T014 includes turning both off, the owner's act in the account UI.
- **Limits.** No published Vibe limits per plan; the ToS has no
  automated-use clause (5.1). A lane at grok's 55 % share is a heavy user. The Pro "fair usage"
  ceiling is unknown until measured, so T014 records the first usage-limit
  hit with its time, and that sets the share.

**T014 has three preconditions** (seat 4). Under D4 they no longer hold
back the share move: a mistral lane only runs once a key exists. So no key
is entered, and no lane runs, until all three hold:

1. The owner confirms that BOTH training toggles (Vibe and API) are off.
2. Someone reads the Mistral ToS clause on automated / agent use and quotes
   it here, in section 5.
3. The API data-retention period is read from docs.mistral.ai and quoted
   here. Seat 4 believes, unchecked, that it is 30 days for abuse
   monitoring.

**DECIDED (D3): Team, yearly, one seat per box.** The Team admin turns
training off for the whole org (precondition 1).

### 5.1 T014 record (c-595, read 2026-10-08)

| item | state | source |
|---|---|---|
| 1. training toggles (Vibe + API) off | **WAIVED by the owner**: "N no, Mistral can train or whatever we do, no problem." The toggles need not be off. Asked via c-002 (post 817d1623); relayed by c-002 (msg 67a8fc13) | owner HUM-10, t1 5c3bb16a, msg 3e6decdf, 2026-10-09T05:1xZ |
| 2. ToS clause on automated use | **quoted below**: no clause bars automated or agent use | `legal.mistral.ai/terms/commercial-terms-of-service`, effective 2026-09-25, read 2026-10-08 |
| 3. API retention | **30 rolling days** for abuse monitoring (quoted below) | `legal.mistral.ai/terms/privacy-policy`, effective 2026-09-03, read 2026-10-08 |
| 4. plan the installed key bills to | **Team** (`plan_name: TEAM`, `plan_type: CHAT`, `organization_kind: S`, customer id prefix `06650ce8`) | live `GET console.mistral.ai/api/vibe/whoami` with the satellite key, as the agent user, 2026-10-08T21:01Z, HTTP 200 (n = 1) |
| cost cap in force | the **console spend limit, 20 a month** | owner HUM-10, t1 5c3bb16a, msg e147e6f2 |

- **ToS, automated use.** Team is a commercial plan, so the Commercial Terms
  apply. Their Use Restrictions (2.2) do not mention automated, scripted or
  agent use. They name agents only as input: Customer Data includes "coding
  environment, fine-tuning data, or agent instructions" (3.1). The nearest
  clauses: 2.2 (g) "use any method to extract any content from the Mistral AI
  Products other than as permitted through the Mistral AI Products in
  accordance with these Terms"; (h) "buy, sell, or transfer API keys or any
  type of Mistral AI account from, to, or with a third party"; (i)
  "integrate or combine Vibe with your own products you offer to
  third-parties [...] nor grant any third party access to the Mistral AI
  Products without our prior written authorization". The fleet uses Vibe
  internally and gives no third party access, so none of them applies. The
  Usage Policy (effective 2026-06-11) has no automated-use clause either.
- **API retention** (Privacy Policy, section 5): "Except for specific APIs,
  we keep your Input and Output for the period necessary to generate the
  Output and then for thirty (30) rolling days to monitor abuse (unless zero
  data retention is activated). If you use our Agents API, we keep your Input
  and Output until you terminate your account." Seat 4's belief (30 days) is
  now checked. Vibe sessions are not the Agents API.
- **Key and plan.** The installed key file on both boxes has the same sha256
  prefix `38bbe6fd0a60` (c-002, n = 1). That is the hash of the `.env` file.
  vibe's own `whoami_cache.json` keys an entry by `sha256(key)[:32]`, which is
  `a94344cfb43b...` for this key, and it caches the same TEAM payload. The
  earlier "[Subscription] Pro" label is not what this key reports today.
  vibe maps `CHAT`/`INDIVIDUAL` to "Pro" and `CHAT`/`TEAM` to "Team"
  (`resolve_user_plan`). So no Team key needs to be minted. The main box was not
  queried directly: the satellite cannot reach it by ssh. The file hash is the same,
  so the key is the same.
- **`--max-price`** caps only `-p` runs, not an interactive seat (c-584,
  n = 1). So the console limit is the cap that holds.
- **Keys** were installed by `do_set_mistral_key` (c-560, 64963b526), then
  replaced by the owner. Both boxes run vibe 2.26.0, the pin, for the agent user.
- **Pilot:** m-595 (main box) took a doc seat (spec 111 s111-5, 5bace0c59). It
  took about 18 min, needed one nudge, and left 0 watchdog lines.

**Live run (7i, n = 1 per box, 2026-10-09).** c-001 spawned both seats from
one brief, `dispatch/brief-5c3bb16a-t014-live-mlane.md`. A lane may not
spawn: `spawn-window.sh` refuses with "requester c-595 is a lane".

| | main box | satellite |
|---|---|---|
| seat | m-629 | m-627 |
| spawned (UTC) | 05:11:04Z | 05:11:10Z |
| `vibe --version` | `vibe 2.26.0` (= the pin) | `vibe 2.26.0` (= the pin) |
| commit, on master | `bf9e78fa4` at 05:11:53Z (+49 s), one file `live/m-629.md` | `b72f877e6` at 05:12:18Z (+68 s), one file `live/m-627.md` |
| report to c-595 | 05:12:18Z (+74 s) | 05:12:4xZ |
| nudges | 0 | 0 |
| (a) tmux window | `m-629@<main-box> t014-live %141` (checked on the main box by c-002 and c-003, n = 1 each) | `m-627@sat t014-live %31`, seen 05:11:13Z (+3 s) |
| (b) desk roster (prd/t1 `.hub/roster.json`, the hub view the WUI reads) | first seen 05:12:53..05:13:23Z (+109..139 s) | first seen 05:16:14..05:16:24Z (+304..314 s, one desk tick) |
| (b) WUI roster screenshot | **open**: needs a member session (the owner) | **open**: same |
| first usage limit (429) | none hit | none hit; 0 pane lines match `429`, `rate limit`, `usage limit` or `quota` |

The m- pilot findings, checked for each seat:

- **False "done" / invented sha:** none. Each full sha resolves
  (`git rev-parse --verify`), is an ancestor of origin/master, and touches
  only that lane's file.
- **Deleting other work:** none. Each commit adds one 4-line file.
- **Unquoted shell in a send:** none seen. Both bodies are plain text.
- **Stopping mid-task / strays:** none. `git status --porcelain --ignored`
  shows nothing on the main box. On the satellite it shows only the ignored
  `csi-spl-iac/dat/`.
- **Wrong topic:** m-629 replied on task `654597dd`, not on the brief's
  `dispatch-5c3bb16a`. Minor: the body was right.

m-627 was closed and retired at 05:17:01Z. c-001 closes m-629. The
satellite has no dev desk roster: the owner's desk is prd/t1.

## 6. Data rule

**DECIDED (D2, msg 803c3b38): mistral lanes may take personal-data and
secret work**, as claude lanes do.

- This is an exception to the fleet's global data rule, which says such
  work goes only to claude. qwen stays excluded: its provider is Chinese.
- The rule text is changed in two places: the repo `CLAUDE.md`, by T011,
  and the global agent `CLAUDE.md` outside the repo, which is the owner's
  file and is reported to the orchestrator.
- `do_spl_lane_mix` still routes `kind=secrets` to claude by default.
  Picking mistral for secrets is a dispatcher's choice (`/mistral-spawn`),
  not a lane-mix change in this spec.

**What leaves the box** (seat 4) is every prompt plus every tool result:

- the files the lane reads, git diffs, spool bodies and MCP replies;
- `AGENTS.md` and the brief.

The session logs (`$VIBE_HOME/logs/session`) keep all of it on disk. They
are mode `0700`, and `spl-session-prune.sh` prunes them like the other
kinds' logs (seat 2, T012).

## 7. Tests (each a pair with its control)

| # | test | control | n |
|---|---|---|---|
| a | Go `agentid` accepts `m-004`, `m-004@box`, Kind = mistral | `x-004`, `M-04`, `m-000` refused | 1 each |
| b | rdb: insert `m-004` into roster, issues.assignee, fleet_lanes, fleet_asks (postgres) | the same insert BEFORE the migration fails (the test applies up to N-1 first) | 1 per CHECK |
| c | tenant split PATCH with five numbers summing to 100 is stored | four numbers / sum 99 refused `bad_split` | 2 |
| d | lane-mix with `mistral=55 grok=0`: default pick mistral; a skipped mistral falls to agy | `grok=55 mistral=0`: default pick grok (no code change) | 1 each |
| e | spawn dry run `spawn-mistral.sh m-004 …` plans `vibe --auto-approve …` | title `q-004` refused by the mistral adapter | 1 |
| f | install (2.4) | the 2.4 controls | 1 |
| g | WUI split e2e (section 4) | sum 99 | 1 |
| h | initial JS delta <= 100 B | — (a measurement; the number is in the report) | 1 |
| i | live: `m-004` on each box answers a spool task (T014) | — | 1 per box |

## 8. Owner questions (at most 3)

c-002 posted three open points (ba65a562): who signs up and logs in, the
starting share, and personal data. The share is now decided by D1, so it is
not asked.

**ANSWERED by the owner, msg 803c3b38: "q1 yes , q2 b , q3 b"**, as
recorded in D2-D4 (section 0). That overrides the (a) that all three review
seats had picked. The table below is kept as asked (c-002 post a264eef5,
with the key-entry correction in 0f0555bb).

- **Q1. Data rule.** May mistral lanes take personal-data or secret work, as
  claude does?
  - (a) **No**: keep it like grok, as section 6 says *(recommended until the
    EU residency is verified)*.
  - **(b) Yes. <- DECIDED (D2)**
  - (c) Yes, after a Team plan with training turned off org-wide.
- **Q2. Plan and login.** The owner signs up and runs `vibe --setup` as the
  agent user. Which plan?
  - (a) **Pro**, one account, main box first *(recommended)*.
  - **(b) Team, one seat per box. <- DECIDED (D3), yearly**
  - (c) API pay-as-you-go key only.
- **Q3. Timing of the switch (T013).**
  - (a) **The share moves only after the live proof (T014) on the main box**
    *(recommended; until then grok's 55 goes to claude because grok is off)*.
  - **(b) Move it now. <- DECIDED (D4)** Lane-mix skips mistral (no auth marker) and falls to
    agy, then claude, until the login exists.

## 9. Review (one row per seat)

| seat | agent | verdict | changes asked | folded in v1.0 |
|---|---|---|---|---|
| 1 drafter | claude c-569 | v0.1 (`568f0b835`), folded to v1.0 | — | — |
| 2 | a-572 agy | agree with changes | 1. T004: Verify Vibe CLI telemetry (unverified in 2.1) and disable it via `config.toml` or env to maintain privacy. 2. T012: Ensure `spl-session-prune.sh` explicitly prunes `$VIBE_HOME/logs/session`. 3. Owner Qs: Q1(a), Q2(a), Q3(a). | yes: telemetry 2.1/2.2/2.5 + T004/T005; session-log prune 6 + T012 |
| 3 | agy a-573 | agree | 1. None. Recommend Q1: (a), Q2: (a), Q3: (a). The hand-over is safe and gracefully handles quota limits.  | — (no changes asked) |
| 4 | claude c-558 (security + data) | **agree with changes** | **1. Key entry is a named action, never a pane paste.** `do_set_mistral_key` reads the key with `read -s` and writes `<agent-home>/.vibe/.env` with `install -m 0600`, as the agent user. `vibe --setup` with a pasted key inside an agent tmux window puts the key in the scrollback, and 38 orc `.sh` files run `capture-pane` (`grep -rl capture-pane csi-spl-orc/src/bash --include=*.sh \| wc -l` -> 38). If the owner uses the browser sign-in instead, run it in a plain ssh session, not a fleet window. **2. The launcher unsets `MISTRAL_API_KEY`** (`env -u`) before it starts `vibe`. 2.1 says an env var beats `.env`, so a stray export (tmux global env, a profile) would silently swap the account. The 2.4 test adds this case. **3. A tracked `.vibe/` dir is refused by `do_check_dist_hygiene`.** `trust-workdir.sh` (3.3) trusts every worktree, and a trusted folder's `.vibe/{config.toml,hooks.toml,AGENTS.md}` is read first. So one commit to trunk could change the model, add an MCP server, or run a `pre_tool` hook on every m- seat. Control: a planted `.vibe/hooks.toml` turns the gate red. **4. The flag contract is checked after every install.** `do_install_mistral_vibe` greps `vibe --help` for `--auto-approve`, `--resume`, `--continue` and `-p`. It refuses the pin if one is missing, and `do_spl_box_update` never moves past the cnf pin. T005 also checks for a Vibe self-update and turns it off. Transitive deps float under `==2.26.0`, so the report prints the `uv`/`pipx` dependency list. **5. A dead key is its own state, not a retry loop.** T006 records the 401 / invalid-key text from a real pane (revoke a test key, n = 1). agent-state reports `auth`, the watchdog does NOT respawn, the lane sends a `blocker` to the dispatcher, and lane-mix skips mistral until the owner re-keys. Per the fleet rule, a missing key is an owner blocker. The auth marker (2.3) proves the file exists, not that the key is valid. **6. Egress is measured before the switch.** T005 records the hosts one `-p` run contacts (`ss -tnp` or `strace -f -e trace=connect`, n = 1). If telemetry goes to a non-Mistral host, its off switch goes into `config.toml` before T013. 2.1 lists telemetry as unverified. **7. What leaves the box goes in 6.** It is every prompt plus every tool result: the files the lane reads, git diffs, spool bodies and MCP replies. It also includes `AGENTS.md` and the brief. Session logs (`$VIBE_HOME/logs/session`) keep all of it on disk: mode `0700`, pruned by `spl-session-prune.sh` like the other kinds. **8. T013 gets three preconditions.** The owner confirms BOTH training toggles are off. Someone reads the Mistral ToS clause on automated/agent use and quotes it in 5. The API retention period is read from docs.mistral.ai (I believe, unchecked, that it is 30 days for abuse monitoring). **9. Cost cap.** Pro overage bills PAYG "at API rate" (5), so a runaway lane at a 55 % share bills without limit. The adapter passes `--max-price` from cnf `env.box.mistral_vibe.max_price`, or the owner sets a spend limit in the console. T014 records which. **10. One key per box, named after the box** (e.g. `spool-<box>`), even on one Pro account, so one box can be revoked without stopping the other. Accepted risk, said aloud: every lane runs as the same agent user, so any lane (qwen included) can read `.vibe/.env`. That is true of every vendor login today, and this spec does not change it. **Q1 → (a) No.** Keep mistral like grok until EU residency, retention and the training opt-out are verified in writing. Then re-ask as (c). **Q2 → (a) Pro**, main box first, one key per box (change 10). Move to Team when the satellite joins, for the org-wide training opt-out. **Q3 → (a)** after T014, plus the change 8 preconditions. | yes, all 10: 1 key entry 2.3 + T004; 2 env -u 2.3/3.3 + T005; 3 hygiene gate 2.3 + T004; 4 flag contract 2.2 + T004/T005; 5 dead key 2.5 + T006; 6 egress 2.5 + T005; 7 what leaves 6; 8 T013 preconditions 5 + T013; 9 cost cap 2.5 + T005/T014; 10 key per box 2.3 + T014 |

Links: [spec 048](../048-agent-harness-parity/spec.md) (harness parity, the
qwen adapter), [spec 061](../061-agent-id-rename/spec.md) (id grammar),
[spec 093](../093-agent-watchdog/spec.md) (hook-ping),
[spec 098](../098-tenant-settings-jsonb/spec.md) (tenant_settings), and
specs [107](../107-hours-tracking/spec.md) / [108](../108-workspace-owned-boxes/spec.md)
/ 109 (not touched; 109 is not on trunk yet).
