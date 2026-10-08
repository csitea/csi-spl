# Spec 110: Mistral as the 5th agent vendor (Mistral Vibe CLI)

Version **v0.1** (draft, seat 1 claude c-569, 2026-10-08). Review seats and
the fold to v1.0: section 9. Build tasks: [tasks.md](tasks.md).

## 0. Owner asks and decisions (verbatim, HUM-10, t1 topic 5c3bb16a)

| msg | text |
|---|---|
| 12759536 | "add new AI vendor Mistral - discussion" |
| ff513efe | "ideally should be added via it's own cli tool - if it has one" |
| 6d3ab799 | "ideally with some kind of monthly subscription etc." |
| 99423692 | "so ideas how-to install it , how-to integrate it , implementations - needs to be added to the settings etc." |
| f4fd88fc | "I am considering the Mistral to take the place of grok even for now , because there seems to be some kind of problem with the payment of the overlimit for grok , it should have taken minutes , but it took several hoours" |
| **3393f016** | **DECIDED**: "so add it and so that it takes the current allocations from grok" |

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

**NOT verified** (open for the review seats):

- **Seeding an interactive session with a prompt.** It is unknown whether a
  positional prompt starts the TUI with the brief already sent, the way
  qwen's `--prompt-interactive` does. `-p` exits after one answer.
- **Hook output.** Whether a `post_tool` hook can inject context into the
  model, as claude's `additionalContext` does.
- **Telemetry.** Whether Vibe sends telemetry, and the switch that turns it
  off.
- **Automated use.** Whether the ToS limits automated or non-interactive
  agent use. Not read; the pricing page only says "Subject to fair usage
  limits and Mistral's Terms of Service".
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

### 2.3 Where the login lives

- **The key.** It lives in `<agent-home>/.vibe/.env`, as
  `MISTRAL_API_KEY=…`, mode `0600`, owned by the agent user.
  - **The owner** writes it, by running `vibe --setup` once as the agent
    user. The browser sign-in mints a key against the owner's Mistral
    account. Section 5 covers which plan.
  - The launcher never passes the key on a command line, where `ps` would
    show it. No env export of it either. This is qwen's rule.
  - The key is never copied into git, a brief, a spool message or a log.
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
- **The satellite.** It needs its own login, i.e. its own key minted by the
  owner. One key per box means one can be revoked without stopping the
  other. Q2 covers whether that needs one seat or two.

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

The live proof (`vibe --version` on both boxes) is part of T014, not a CI
test.

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
  - **The prompt flag is open (2.1).** If no seeded-interactive mode exists,
    the adapter starts the TUI and the core types the seed through the
    existing pane-injection path (`spool-notify.sh`), the way agy is seeded.
    T005 measures this first and records the answer here.
  - **`SPAWN_ID_PREFIX`.** It is a legacy-prefix field, and core uses it for
    the `<P>_TMUX_PANE` env name and the title check. Mistral has no legacy
    prefix, so T005 makes the core take a kind-derived env name
    (`MISTRAL_TMUX_PANE`) and validates the title by letter `m`, without
    breaking the four existing adapters.
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
  - **Two steps.** T003 adds `mistral: 0`. **T013 (the switch)** moves
    `grok: 55 -> 0` and `mistral: 0 -> 55`, and only after T014 shows
    Mistral logged in on both boxes. Otherwise the existing rule (missing
    marker -> share goes to claude) would quietly hand 55 points to claude.
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
    does it, or T013 does it through the PATCH route as admin, with the
    owner's go named in the brief.

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
- **Limits.** No published Vibe limits per plan, and the ToS was not read
  (2.1). A lane at grok's 55 % share is a heavy user. The Pro "fair usage"
  ceiling is unknown until measured, so T014 records the first usage-limit
  hit with its time, and that sets the share.

Recommendation: **Pro on one account for the main box first.** That is the
cheapest test of D1. Move to Team when the satellite needs its own seat, or
when Pro's fair-use ceiling is hit.

## 6. Data rule

Today's global rule: personal data and secrets go only to claude. qwen is
excluded too, because it is a Chinese provider. Mistral is an EU company, but
its EU residency is not verified (2.1). **Until the owner answers Q1, mistral
lanes are treated like grok lanes.** No personal data, no secrets, and no
brief that names a credential path. `do_spl_lane_mix` already routes
`kind=secrets` to claude, and that stays.

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

- **Q1. Data rule.** May mistral lanes take personal-data or secret work, as
  claude does?
  - (a) **No**: keep it like grok, as section 6 says *(recommended until the
    EU residency is verified)*.
  - (b) Yes.
  - (c) Yes, after a Team plan with training turned off org-wide.
- **Q2. Plan and login.** The owner signs up and runs `vibe --setup` as the
  agent user. Which plan?
  - (a) **Pro**, one account, main box first *(recommended)*.
  - (b) Team, one seat per box.
  - (c) API pay-as-you-go key only.
- **Q3. Timing of the switch (T013).**
  - (a) **The share moves only after the live proof (T014) on the main box**
    *(recommended; until then grok's 55 goes to claude because grok is off)*.
  - (b) Move it now. Lane-mix skips mistral (no auth marker) and falls to
    agy, then claude, until the login exists.

## 9. Review (one row per seat)

| seat | agent | verdict | changes asked | folded in v1.0 |
|---|---|---|---|---|
| 1 drafter | claude c-569 | v0.1 | — | — |
| 2 | a-572 agy | agree with changes | 1. T004: Verify Vibe CLI telemetry (unverified in 2.1) and disable it via `config.toml` or env to maintain privacy. 2. T012: Ensure `spl-session-prune.sh` explicitly prunes `$VIBE_HOME/logs/session`. 3. Owner Qs: Q1(a), Q2(a), Q3(a). | |
| 3 | grok (tbd by c-002) | | | |
| 4 | claude (tbd by c-002) | | | |

Links: [spec 048](../048-agent-harness-parity/spec.md) (harness parity, the
qwen adapter), [spec 061](../061-agent-id-rename/spec.md) (id grammar),
[spec 093](../093-agent-watchdog/spec.md) (hook-ping),
[spec 098](../098-tenant-settings-jsonb/spec.md) (tenant_settings), and
specs [107](../107-hours-tracking/spec.md) / [108](../108-workspace-owned-boxes/spec.md)
/ 109 (not touched; 109 is not on trunk yet).
