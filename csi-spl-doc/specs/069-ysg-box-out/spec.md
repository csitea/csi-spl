# 069: ysg-box out - every spool dependency on ysg-box moves into csi-spl

Status: **v0.3, owner answered Q1..Q4 (section 6); inventory measured on `<pc box>` and on sat (section 2.9, by `do_check_ysg_box_deps`).**
Spec only: no code, no crontab, no home-dir file, no ysg-box file was touched by
this lane. Draft 2026-10-03, c-138 (v0.1 `6f9fe600`); v0.2 folds in the owner's
answers, HUM-10 at 14:37Z, topic `828d50b1`.
Related: [068 peer seats](../068-peer-seats/spec.md) (acceptance check 8.1,
"every OD script lives in source"), [048 agent harness parity](../048-agent-harness-parity/),
the 2026-09-28 order that made the AI CLI harness canonical in csi-spl and froze
ysg-box for it (`844b088`).

Placeholders (box tags, OS users and home dirs are banned literals in this tree):

| placeholder | stands for |
|---|---|
| `<pc box>` | the PC's box tag |
| `<box-user>` | the box owner OS user (runs tmux, cron, the desks) |
| `<agent-user>` | the OS user every agent seat runs as |
| `<engine>` | the frozen ysg-box engine checkout, `/opt/<box-user>/ysg-box` |
| `<overlay>` | the csi overlay checkout `/opt/csi/ysg-box` (repo `csitea/ysg-box-csi`) |
| `YB:` | `<engine>/ysg-box-orc/src/bash/features/` |

## 1. Why

### 1.1 What the owner asked (HUM-10, verbatim)

> 14:30Z: "there seem to be quite a lot of dependencies from the ysg-box -
> scripts and configs to the functioning of the whole spool-hub.ai system -
> ALL of those must be made part of the spool project ... all"

> 14:23Z: "make sure all of the scripts are in the source code of the project"

### 1.2 What "done" means

The spool-hub.ai system (hub, WUI, desks and sidecars, dispatchers,
orchestrators, spawn harness, agent seats, crons, boot restore) runs on a box on
which `<engine>` and `<overlay>` **do not exist**. Section 7 makes that a
check, not a claim.

## 2. Inventory - measured, not guessed

Measured on `<pc box>` 2026-10-03 ~14:20..14:35Z, origin/master `fd0a49300`.
Each subsection names the command and lists the **whole population** it
returned, so absence is shown by the listing, not asserted. `grep` below is
`/usr/bin/grep` (the box's `grep` shim skips git-ignored files).

### 2.1 csi-spl source naming ysg-box

`git grep -l -E 'ysg-box|/opt/<box-user>/' origin/master -- ':!*.md' | wc -l` -> **15**
(45 including `.md`; c-001's 14:30Z count reproduces).

| # | file | kind | runtime dependency? |
|---|---|---|---|
| S1 | `csi-spl-iac/src/terraform/060-gcp-vm-satellite/box-playbook.yaml` | clones `csitea/ysg-box` (engine) and `csitea/ysg-box-csi` (overlay) onto the satellite | **yes** |
| S2 | `.../060-gcp-vm-satellite/roles/05_users/tasks/main.yml` | reads the box users from the overlay's `boxes/<box_tag>/box.env` | **yes** |
| S3 | `.../060-gcp-vm-satellite/roles/07_ysg_box/tasks/main.yml` | runs the engine's `claude-config/scripts/claude-apply.sh` (renders CLAUDE.md, settings, skills) | **yes** |
| S4 | `csi-spl-orc/src/bash/features/spool-install/render-yield.sh` | works around S3 (drops the engine's stale harness copies from its render) | yes, as a workaround |
| S5 | `csi-spl-iac/src/bash/tests/satellite-ansible.tst.sh` | asserts S3's `claude-apply.sh` line | test of S3 |
| S6 | `csi-spl-iac/src/bash/tests/satellite-actions.tst.sh` | asserts the S4 yield | test of S4 |
| S7 | `csi-spl-api/src/bash/tests/no-ysg-box-ref.tst.sh` | gate: spool Go source carries no ysg-box path | guard, keep |
| S8 | `csi-spl-api/src/bash/tests/run-all-tests.sh` | runs S7 | guard, keep |
| S9 | `.github/workflows/10_ci-quality.yml` | runs S7 as its own job | guard, keep |
| S10 | `csi-spl-orc/src/bash/features/mcp-bot/tests/test-hygiene.sh` | gate: no path into the engine | guard, keep |
| S11 | `csi-spl-orc/src/bash/features/spawn-agents/tests/test-hygiene.sh` | same gate for spawn-agents | guard, keep |
| S12 | `csi-spl-api/src/go/spool-hub-api/internal/spool/spool.go:543` | comment: `readLegacyMD` ingests legacy `.md` messages | no (comment) |
| S13 | `csi-spl-api/src/bash/tests/spool-smoke.tst.sh` | comment | no |
| S14 | `csi-spl-iac/src/bash/tests/check-dist-hygiene.tst.sh` | comment | no |
| S15 | `csi-spl-orc/src/bash/features/spawn-agents/tests/test-strip-two-way.sh` | comment | no |

Runtime dependencies in source: **S1..S4** (all the satellite path). The other
11 are guards or prose.

### 2.2 Crontabs

`crontab -u <u> -l | grep -nE 'ysg-box|/opt/<box-user>/'` for `<box-user>`,
`<agent-user>`, root; `grep -rlE ... /etc/cron*`.

| # | user | schedule | runs | used by |
|---|---|---|---|---|
| C1 | `<box-user>` | `* * * * *` | `YB:claude-sessions/scripts/claude-save-sessions.sh` | snapshots every tmux window + agent session id (feeds C2); its log reads `11 windows (9 with a live agent session)` |
| C2 | `<box-user>` | `@reboot` | `YB:claude-sessions/scripts/claude-sessions-boot.sh` | **boot restore of the whole fleet** (tmux socket dir, landing session, resume every saved seat) |
| C3 | `<box-user>` | `*/15 8-19 * * *` | `YB:graft/scripts/graft-cron.sh` | graft code index refresh (agents' `graft` skill) |
| C4 | `<box-user>` | `0 20 * * *` | same, final run | same |

Population: `<box-user>` has 16 non-comment lines - these 4, 7 csi-spl lines
(desk-reconcile dev+prd, agent-identity-reconcile, unanswered-sweep,
orch-rotate, dispatch-rotate, spawn-remote: all on csi-spl already), 1
owner-utility creds backup and 4 other-project lines (not ysg-box, out of scope).
`<agent-user>`: 1 line (csi-spl `tmp-scratch-sweep`). root: none. `/etc/cron*`:
no hit. **Note:** c-001's 14:30Z figure was 8; this anchored count is **4**.

### 2.3 Symlinks from the two homes into ysg-box

`find ~<u> \( -path ~<u>/.cache -o -name node_modules -o -path ~<u>/go -o -path ~<u>/.claude/projects \) -prune -o -type l -print`, keeping targets matching `ysg-box|/opt/<box-user>/|/tmp/tmp.*`, with `test -e` for liveness.

`~<box-user>`: **18**, all resolve. `~<agent-user>`: **14**, 12 of them **broken**.
(c-001's 14:30Z figure was 13 per home.)

| # | link (both homes unless noted) | target | live use |
|---|---|---|---|
| L1 | `~/.local/mcp-bot/mcp-start.sh` (`<box-user>`) | `YB:mcp-bot/scripts/mcp-start.sh` | **every agent's `firefox` MCP server** (`~<agent-user>/.claude.json` `mcpServers.firefox` runs it via `sudo -u <box-user>`) |
| L2 | `~/.local/mcp-bot/mcp-start-chrome.sh` (`<box-user>`) | `YB:mcp-bot/scripts/mcp-start-chrome.sh` | **every agent's `chrome` MCP server**; csi-spl already has `csi-spl-orc/.../mcp-bot/scripts/mcp-start-chrome.sh`, but the link still points at the engine |
| L3 | `~/.local/wa-bot/wa_send.py`, `wa_start.sh` (`<box-user>`, 2 links) | `YB:wa-bot/scripts/` | WhatsApp send; overlay skill `whatsapp-send-msg`; not a spool path |
| L4 | `~/.claude/skills/graft` | `YB:graft/assets/skills/graft` | agents' `graft` skill |
| L5 | `~/.gemini/config/rules/graft.md` | `YB:graft/assets/agy-rules/graft.md` | agy agents' graft rule |
| L6 | `~/.tmux/scripts/{agent-name,agent-state.inc,agent-top,riname,tmux-sort-windows,tmux-sort-pause,tmux-window-color,tmux-window-event}.sh` (8) | `YB:spawn-agents/scripts/`, `YB:tmux-windows/scripts/` | `<box-user>`: resolve, but **not sourced** (see 2.5). `<agent-user>`: all 8 **broken** |
| L7 | `~/.tmux/{agent-status,tmux-windows,tmux-window-events,window-sort}.conf` (4) | `YB:.../assets/` | `<box-user>`: not sourced. `<agent-user>`: **broken**, and `~<agent-user>/.tmux.conf:155,160` sources two of them |

The 12 broken `<agent-user>` links point into
`/tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/...` (mtime 2026-09-18 10:48): an
engine test ran its tmux install against the real home instead of a sandbox
`HOME`, then deleted its temp tree. Harmless today only because the tmux server
runs as `<box-user>`; an `<agent-user>` tmux server would start with errors.

### 2.4 Files in the homes that call into ysg-box

`grep -nE 'ysg-box|/opt/<box-user>/'` over `.bashrc .profile .bash_profile .zshrc .tmux.conf`, `~/.local/bin/*` (text), `~/.claude/{CLAUDE.md,settings.json,commands/*,skills/*/SKILL.md}`, `~/.claude.json` `mcpServers`, `/etc/profile`, `/etc/bash.bashrc`, `/etc/profile.d`.

| # | file | calls | live use |
|---|---|---|---|
| H1 | `~/.local/bin/graft` (both) | `exec bash <engine>/.../graft/scripts/graft-safe.sh` | the `graft` CLI every agent runs |
| H2 | `~/.bashrc` (both) | sources `<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash` | `./run -a` tab completion (humans) |
| H3 | `~<box-user>/.bashrc:237` | `YB:dotfiles/scripts/wifi-up.sh` | personal wifi helper, not spool |
| H4 | `~<agent-user>/.claude/commands/signed-prompt.md` (lines 48, 56, 70) | `YB:directive/scripts/directive-session.sh`, `directive-sign.sh` | **`/signed-prompt`: owner-signed directives to another box** |
| H5 | `~<agent-user>/.claude/skills/tmux-color/SKILL.md:31` | `YB:tmux-windows/scripts/tmux-window-color.sh` | `/tmux-color` on every agent |
| H6 | `~<agent-user>/.claude/CLAUDE.md`, `settings.json`, skills `graft`, `tmux-color`, `paste-html-into-chrome`, `spec-kit-tasks`, command `signed-prompt` | rendered by the engine's `claude-config` (`claude-render.sh` / `claude-apply.sh`) from `YB:claude-config/assets/claude-md/*` (e.g. `20-spawn-an-agent.agent.md`, `30-cross-lane-findings.agent.md`) plus `<overlay>/claude/{claude-md,settings,skills}` | **every agent's standing orders and its Stop/UserPromptSubmit hooks** (spec 067's `spool-mirror.py` hook comes from `<overlay>/claude/settings/30-spool-mirror.agent.json`) |

Classified by the `spool-install` marker (`grep -c spool-install`): of the 15
command/skill files under `~<agent-user>/.claude`, 10 are csi-spl's
(`install.sh` step 5b) and 5 are the engine's (H4, H5, graft,
paste-html-into-chrome, spec-kit-tasks).

No hit in `.profile`, `.bash_profile`, `.zshrc`, `/etc/profile`,
`/etc/bash.bashrc`, `/etc/profile.d`. `~<box-user>/.claude/statusline-title.sh`:
no hit. `~<box-user>/.claude.json` `mcpServers`: one entry, no engine path.
The `~/.claude.json` `projects` keys naming `/opt/<box-user>/ysg-box-wt/*` are
session history, not dependencies.

### 2.5 tmux runtime (the live server)

`tmux show-hooks -g | grep '\['` -> 5 hooks (`after-new-window[0..1]`,
`after-rename-window[0]`, `window-linked[0]`, `window-unlinked[0]`), **all**
call `csi-spl-orc/.../spawn-agents/scripts/{tmux-sort-windows,agent-identity-reconcile}.sh`.
`show-options -g | grep -E '\.sh|#\('` -> `status-right` calls csi-spl
`agent-top.sh`. `~<box-user>/.tmux.conf` sources only
`~/.local/share/spool-agent/tmux-agent-status.conf` (csi-spl `install.sh`).
**The live tmux server has no ysg-box dependency.** It has one at boot, through C2.

### 2.6 systemd, env files, processes

- `grep -rlE ... /etc/systemd /lib/systemd/system ~/.config/systemd`: no hit.
  `systemctl list-units --type=service | grep -iE 'spool|spl|<box-user>|claude'`: 4
  GitHub runner units, none touching ysg-box.
- `ps -eo user,args | grep -E 'ysg-box|/opt/<box-user>/'`: no long-running
  process; C1 runs once a minute and exits.

### 2.7 State dirs

`/var/<box-user>/ysg-box/{claude-sessions,tmux-windows,ysg-box-orc,ysg-box-utl}`:
C1/C2 write `claude-sessions/` (save.log, boot.log, the snapshot the restore
reads). It moves with C1/C2.

### 2.8 Population summary (`<pc box>`)

| group | measured | runtime deps |
|---|---|---|
| csi-spl source | 15 files | 4 (S1..S4) |
| crontab | 4 lines | 4 |
| symlinks | 18 + 14 | L1, L2, L4, L5 live; L6/L7 dead or broken; L3 non-spool |
| home files calling in | 6 | H1, H4, H5, H6 spool; H2 human; H3 personal |
| tmux live / systemd / processes | 0 / 0 / 0 | - |

**33 inventory rows** (S1..S15, C1..C4, L1..L7, H1..H6, the state dir).

### 2.8.1 Reproduced by `do_check_ysg_box_deps` (Y9) on `<pc box>`

`cd csi-spl-orc && ./run -a do_check_ysg_box_deps`, run as `<box-user>`
2026-10-03 ~14:50Z on lane Y9's tree (`a7f4cfff5` + the action), n=1 run,
default pattern `ysg-box(-[a-z]+)?/|/opt/<box-user>/` (a PATH into the engine;
a file merely NAMED `ysg-box-*`, e.g. a brief, is no row). Exit **1**,
**96 rows**:

| kind | `<box-user>` | `<agent-user>` | root | matches section |
|---|---|---|---|---|
| cron | 4 | 0 | 0 | 2.2: C1..C4, reproduces 4 |
| link | 18 (all live) | 14 (12 BROKEN) | - | 2.3: reproduces 18 + 14, 12 broken |
| home | 54 lines in 15 files | 6 lines in 4 files | - | 2.4: H1, H2, H4, H5 on `<agent-user>`; H1..H3 on `<box-user>` |
| tmux / systemd / proc | 0 / 0 / 0 | 0 / 0 / 0 | 0 | 2.5, 2.6: reproduces 0 |

**New against 2.4:** `~<box-user>/.claude/` carries 12 command/skill files that
call into the engine (`agy-spawn`, `claude-spawn`, `grok-spawn`, `riname`,
`signed-prompt`, `spawn-an-agent`, `tmux-close-window` commands; `exit-clean`,
`kill-your-self`, `login-to-claude`, `tmux-color`, `whatsapp-send-msg` skills):
51 of the 54 `<box-user>` home lines. 2.4 grepped only `~<agent-user>/.claude`.
These are the box user's own Claude config (the human's sessions), not the
agent seats; Y4's scope decides whether they move (Q4 kept personal fragments out).

Output, users/homes/engine replaced by this spec's placeholders (`YB:` =
`<engine>/ysg-box-orc/src/bash/features/`), details cut at 160 chars by the action:

```text
cron	<box-user>	crontab:44	* * * * * /bin/bash 'YB:claude-sessions/scripts/claude-save-sessions.sh' >> '/var/<box-user>/ysg-box/claude-sessions/save.l
cron	<box-user>	crontab:45	@reboot /bin/bash 'YB:claude-sessions/scripts/claude-sessions-boot.sh' >> '/var/<box-user>/ysg-box/claude-sessions/boot.log
cron	<box-user>	crontab:49	*/15 8-19 * * * YB:graft/scripts/graft-cron.sh # graft:index-refresh
cron	<box-user>	crontab:50	0 20 * * * YB:graft/scripts/graft-cron.sh # graft:index-refresh-final
home	<agent-user>	~<agent-user>/.bashrc:106	[ -r "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash" ] && . "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash"
home	<agent-user>	~<agent-user>/.claude/commands/signed-prompt.md:48	bash YB:directive/scripts/directive-session.sh --status
home	<agent-user>	~<agent-user>/.claude/commands/signed-prompt.md:56	bash YB:directive/scripts/directive-session.sh --minutes 60
home	<agent-user>	~<agent-user>/.claude/commands/signed-prompt.md:70	bash YB:directive/scripts/directive-sign.sh --reply-to <pc box> <target> "<the owner's literal text>"
home	<agent-user>	~<agent-user>/.claude/skills/tmux-color/SKILL.md:31	bash YB:tmux-windows/scripts/tmux-window-color.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
home	<agent-user>	~<agent-user>/.local/bin/graft:4	exec bash 'YB:graft/scripts/graft-safe.sh' "$@"
home	<box-user>	~<box-user>/.bashrc:138	[ -r "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash" ] && . "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash"
home	<box-user>	~<box-user>/.bashrc:237	bash "YB:dotfiles/scripts/wifi-up.sh" "${1:-YG-21}"
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:116	(`sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh --from AGY-01 CLE-04 "…"`) — allowed by the
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:136	| `YB:spawn-agents/scripts/next-agent-id.sh` | Allocate the next agent id from registry.tsv and CLAIM its inbox dir 
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:137	| `YB:spawn-agents/scripts/spawn-agy.sh` | Window command: worktree (if git), inbox dirs, restore stub, launch as ai
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:138	| `YB:spawn-agents/scripts/inbox-send.sh` | The file based inbox protocol sender (file + poke) |
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:139	| `YB:spawn-agents/scripts/riname.sh` | Rename window to `AGY-0n <title>` |
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:149	YB:spawn-agents/scripts/next-agent-id.sh --kind agy)
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:168	(`YB:spawn-agents/tests/test-next-agent-id.sh`,
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:194	S=YB:spawn-agents/scripts
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:218	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:96	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:131	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:171	sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh \
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:190	YB:spawn-agents/scripts/next-agent-id.sh --kind claude)
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:209	(`YB:spawn-agents/tests/test-next-agent-id.sh`,
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:216	scripts in the engine's spawn-agents feature (`YB:spawn-agents/scripts/`):
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:250	S=YB:spawn-agents/scripts
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:313	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:400	YB:mcp-bot/scripts/mcp-start.sh`, an entry in `<agent-user>`'s `~/.claude.json`) drives a
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:405	`ysg-box-orc/src/bash/features/mcp-bot/scripts/mcp-start.sh`) therefore gives **each agent its
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:433	MCP_BOT_AGENT_ID=CLE-07 sudo -u <box-user> -H --preserve-env=MCP_BOT_AGENT_ID YB:mcp-bot/scripts/mcp-start.sh
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:113	(`sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh --from GRK-01 CLE-04 "…"`) — allowed by the
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:121	| `YB:spawn-agents/scripts/next-agent-id.sh` | Allocate the next agent id from registry.tsv and CLAIM its inbox dir 
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:122	| `YB:spawn-agents/scripts/spawn-grok.sh` | Window command: worktree (if git), inbox dirs, restore stub, launch as a
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:123	| `YB:spawn-agents/scripts/inbox-send.sh` | The file based inbox protocol sender (file + poke) |
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:124	| `YB:spawn-agents/scripts/riname.sh` | Rename window to `GRK-0n <title>` |
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:134	YB:spawn-agents/scripts/next-agent-id.sh --kind grok)
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:153	(`YB:spawn-agents/tests/test-next-agent-id.sh`,
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:179	S=YB:spawn-agents/scripts
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:202	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:93	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/riname.md:18	bash YB:spawn-agents/scripts/riname.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
home	<box-user>	~<box-user>/.claude/commands/signed-prompt.md:48	bash YB:directive/scripts/directive-session.sh --status
home	<box-user>	~<box-user>/.claude/commands/signed-prompt.md:56	bash YB:directive/scripts/directive-session.sh --minutes 60
home	<box-user>	~<box-user>/.claude/commands/signed-prompt.md:70	bash YB:directive/scripts/directive-sign.sh --reply-to <pc box> <target> "<the owner's literal text>"
home	<box-user>	~<box-user>/.claude/commands/spawn-an-agent.md:82	sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh CLE-03 "the message"
home	<box-user>	~<box-user>/.claude/commands/tmux-close-window.md:18	bash YB:spawn-agents/scripts/tmux-close-window.sh $ARGUMENTS
home	<box-user>	~<box-user>/.claude/skills/exit-clean/SKILL.md:199	bash YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>
home	<box-user>	~<box-user>/.claude/skills/exit-clean/SKILL.md:40	bash YB:spawn-agents/scripts/kill-your-self-report.sh 2>/dev/null || true
home	<box-user>	~<box-user>/.claude/skills/exit-clean/SKILL.md:43	bash YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:164	bash YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:31	`YB:spawn-agents/scripts/kill-your-self-report.sh`  
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:35	`YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>`
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:71	bash YB:spawn-agents/scripts/kill-your-self-report.sh 2>/dev/null || true
home	<box-user>	~<box-user>/.claude/skills/login-to-claude/SKILL.md:35	sudo -u <box-user> bash YB:claude-login/scripts/claude-login-cli.sh --status
home	<box-user>	~<box-user>/.claude/skills/login-to-claude/SKILL.md:42	sudo -u <box-user> bash YB:claude-login/scripts/claude-login-cli.sh
home	<box-user>	~<box-user>/.claude/skills/tmux-color/SKILL.md:31	bash YB:tmux-windows/scripts/tmux-window-color.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:27	sudo -u <box-user> bash YB:wa-bot/scripts/wa_start.sh
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:44	- Attach-and-send script: `YB:wa-bot/scripts/wa_send.py`
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:45	- One-time launcher: `YB:wa-bot/scripts/wa_start.sh`
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:60	sudo -u <box-user> bash -c "\$HOME/.local/wa-bot/venv/bin/python YB:wa-bot/scripts/wa_send.py --to '+<country><number>' --m
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:64	sudo -u <box-user> bash -c "\$HOME/.local/wa-bot/venv/bin/python YB:wa-bot/scripts/wa_send.py --to 'FirstName LastName' --m
home	<box-user>	~<box-user>/.local/bin/graft:4	exec bash 'YB:graft/scripts/graft-safe.sh' "$@"
link	<agent-user>	~<agent-user>/.claude/skills/graft	-> YB:graft/assets/skills/graft (live)
link	<agent-user>	~<agent-user>/.gemini/config/rules/graft.md	-> YB:graft/assets/agy-rules/graft.md (live)
link	<agent-user>	~<agent-user>/.tmux/agent-status.conf	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/spawn-agents/assets/tmux-agent-status.conf (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/agent-name.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/spawn-agents/scripts/agent-name.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/agent-state.inc.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/spawn-agents/scripts/agent-state.inc.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/agent-top.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/spawn-agents/scripts/agent-top.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/riname.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/spawn-agents/scripts/riname.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/tmux-sort-pause.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/tmux-windows/scripts/tmux-sort-pause.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/tmux-sort-windows.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/tmux-windows/scripts/tmux-sort-windows.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/tmux-window-color.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/tmux-windows/scripts/tmux-window-color.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/scripts/tmux-window-event.sh	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/tmux-windows/scripts/tmux-window-event.sh (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/tmux-window-events.conf	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/tmux-windows/assets/tmux-window-events.conf (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/tmux-windows.conf	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/tmux-windows/assets/tmux-windows.conf (BROKEN)
link	<agent-user>	~<agent-user>/.tmux/window-sort.conf	-> /tmp/tmp.2y0uw9Btmd/r10/engine/ysg-box-orc/src/bash/features/tmux-windows/assets/tmux-windows.conf (BROKEN)
link	<box-user>	~<box-user>/.claude/skills/graft	-> YB:graft/assets/skills/graft (live)
link	<box-user>	~<box-user>/.gemini/config/rules/graft.md	-> YB:graft/assets/agy-rules/graft.md (live)
link	<box-user>	~<box-user>/.local/mcp-bot/mcp-start-chrome.sh	-> YB:mcp-bot/scripts/mcp-start-chrome.sh (live)
link	<box-user>	~<box-user>/.local/mcp-bot/mcp-start.sh	-> YB:mcp-bot/scripts/mcp-start.sh (live)
link	<box-user>	~<box-user>/.local/wa-bot/wa_send.py	-> YB:wa-bot/scripts/wa_send.py (live)
link	<box-user>	~<box-user>/.local/wa-bot/wa_start.sh	-> YB:wa-bot/scripts/wa_start.sh (live)
link	<box-user>	~<box-user>/.tmux/agent-status.conf	-> YB:spawn-agents/assets/tmux-agent-status.conf (live)
link	<box-user>	~<box-user>/.tmux/scripts/agent-name.sh	-> YB:spawn-agents/scripts/agent-name.sh (live)
link	<box-user>	~<box-user>/.tmux/scripts/agent-state.inc.sh	-> YB:spawn-agents/scripts/agent-state.inc.sh (live)
link	<box-user>	~<box-user>/.tmux/scripts/agent-top.sh	-> YB:spawn-agents/scripts/agent-top.sh (live)
link	<box-user>	~<box-user>/.tmux/scripts/riname.sh	-> YB:spawn-agents/scripts/riname.sh (live)
link	<box-user>	~<box-user>/.tmux/scripts/tmux-sort-pause.sh	-> YB:tmux-windows/scripts/tmux-sort-pause.sh (live)
link	<box-user>	~<box-user>/.tmux/scripts/tmux-sort-windows.sh	-> YB:tmux-windows/scripts/tmux-sort-windows.sh (live)
link	<box-user>	~<box-user>/.tmux/scripts/tmux-window-color.sh	-> YB:tmux-windows/scripts/tmux-window-color.sh (live)
link	<box-user>	~<box-user>/.tmux/scripts/tmux-window-event.sh	-> YB:tmux-windows/scripts/tmux-window-event.sh (live)
link	<box-user>	~<box-user>/.tmux/tmux-window-events.conf	-> YB:tmux-windows/assets/tmux-window-events.conf (live)
link	<box-user>	~<box-user>/.tmux/tmux-windows.conf	-> YB:tmux-windows/assets/tmux-windows.conf (live)
link	<box-user>	~<box-user>/.tmux/window-sort.conf	-> YB:tmux-windows/assets/tmux-windows.conf (live)
INFO users: <box-user> <agent-user> root; pattern: ysg-box(-[a-z]+)?/|/opt/<box-user>/
FAIL 96 dependency row(s) on the ysg-box engine (one per row above)
```

### 2.9 sat - measured by `do_check_ysg_box_deps` (v0.3)

History: the inline probe sent to c-001@sat at 14:29Z (msg `578725d9`) was
refused by Claude Code's safety check (msg `7d447ce9`), so it became the named
read-only action of lane **Y9**. c-001@sat ran it 2026-10-03 ~14:55Z as the
sat box user, its checkout fast-forwarded to origin/master (includes
`24db15c23`), n=1 run, default pattern (msg `01ea9460`). Exit **1**,
**70 rows, all `home`**:

| kind | `<box-user>` | `<agent-user>` | root | vs `<pc box>` (2.8.1) |
|---|---|---|---|---|
| cron | 0 | 0 | 0 | pc: C1..C4. sat has **no** boot-restore, save-sessions or graft cron |
| link | 0 | 0 | - | pc: 18 + 14. sat has no `mcp-bot`, `graft`, `wa-bot` or `~/.tmux` links |
| home | 64 lines in 15 files | 6 lines in 4 files | - | same files as pc, plus `qwen-spawn.md` (11 lines) and a `graft` SKILL.md that is a FILE (one prose line) |
| tmux / systemd / proc | 0 / 0 / 0 | 0 / 0 / 0 | 0 | same: none |

Reading of the rows:

- `<agent-user>`: H2 (`.bashrc` completion), H4 (`signed-prompt.md`, 3 lines),
  H5 (`tmux-color` SKILL.md). No H1: sat has no `~/.local/bin/graft` calling the engine.
- `<box-user>`: H2 plus 14 command/skill files: the 12 of 2.8.1's "new"
  finding (the S3 render of the engine's `claude-config`, H6), `qwen-spawn.md`
  and the `graft` SKILL.md. No H3 (`wifi-up`) on sat.
- The `graft/SKILL.md:63` row on both users is prose naming `ysg-box-utl/...`
  in a quoted example, not a call: the one false positive of the default
  pattern on sat. It goes away when Y4 moves or drops that skill.
- So on sat every runtime dependency is a rendered `~/.claude` file or a
  `.bashrc` line: lanes Y4 (render), Y10 (completion) and the S1..S3 lanes
  cover them; sat needs no cron or link move.

Output, users/homes/engine replaced by this spec's placeholders (`YB:` =
`<engine>/ysg-box-orc/src/bash/features/`):

```text
home	<agent-user>	~<agent-user>/.bashrc:106	[ -r "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash" ] && . "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash"
home	<agent-user>	~<agent-user>/.claude/commands/signed-prompt.md:48	bash YB:directive/scripts/directive-session.sh --status
home	<agent-user>	~<agent-user>/.claude/commands/signed-prompt.md:56	bash YB:directive/scripts/directive-session.sh --minutes 60
home	<agent-user>	~<agent-user>/.claude/commands/signed-prompt.md:70	bash YB:directive/scripts/directive-sign.sh --reply-to sat <target> "<the owner's literal text>"
home	<agent-user>	~<agent-user>/.claude/skills/graft/SKILL.md:63	> "The index shows 3 call sites in `ysg-box-utl/src/bash/run/`. It only covers shell and
home	<agent-user>	~<agent-user>/.claude/skills/tmux-color/SKILL.md:31	bash YB:tmux-windows/scripts/tmux-window-color.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
home	<box-user>	~<box-user>/.bashrc:113	[ -r "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash" ] && . "<engine>/ysg-box-utl/lib/bash/completions/run.completion.bash"
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:117	(`sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh --from AGY-01 CLE-04 "…"`) — allowed by the
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:137	| `YB:spawn-agents/scripts/next-agent-id.sh` | Allocate the next agent id from registry.tsv and CLAIM its inbox dir 
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:138	| `YB:spawn-agents/scripts/spawn-agy.sh` | Window command: worktree (if git), inbox dirs, restore stub, launch as ai
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:139	| `YB:spawn-agents/scripts/inbox-send.sh` | The file based inbox protocol sender (file + poke) |
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:140	| `YB:spawn-agents/scripts/riname.sh` | Rename window to `AGY-0n <title>` |
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:150	YB:spawn-agents/scripts/next-agent-id.sh --kind agy)
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:169	(`YB:spawn-agents/tests/test-next-agent-id.sh`,
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:195	S=YB:spawn-agents/scripts
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:219	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/agy-spawn.md:97	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:138	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:178	sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh \
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:197	YB:spawn-agents/scripts/next-agent-id.sh --kind claude)
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:216	(`YB:spawn-agents/tests/test-next-agent-id.sh`,
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:223	scripts in the engine's spawn-agents feature (`YB:spawn-agents/scripts/`):
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:257	S=YB:spawn-agents/scripts
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:321	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:408	YB:mcp-bot/scripts/mcp-start.sh`, an entry in `<agent-user>`'s `~/.claude.json`) drives a
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:413	`ysg-box-orc/src/bash/features/mcp-bot/scripts/mcp-start.sh`) therefore gives **each agent its
home	<box-user>	~<box-user>/.claude/commands/claude-spawn.md:441	MCP_BOT_AGENT_ID=CLE-07 sudo -u <box-user> -H --preserve-env=MCP_BOT_AGENT_ID YB:mcp-bot/scripts/mcp-start.sh
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:114	(`sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh --from GRK-01 CLE-04 "…"`) — allowed by the
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:122	| `YB:spawn-agents/scripts/next-agent-id.sh` | Allocate the next agent id from registry.tsv and CLAIM its inbox dir 
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:123	| `YB:spawn-agents/scripts/spawn-grok.sh` | Window command: worktree (if git), inbox dirs, restore stub, launch as a
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:124	| `YB:spawn-agents/scripts/inbox-send.sh` | The file based inbox protocol sender (file + poke) |
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:125	| `YB:spawn-agents/scripts/riname.sh` | Rename window to `GRK-0n <title>` |
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:135	YB:spawn-agents/scripts/next-agent-id.sh --kind grok)
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:154	(`YB:spawn-agents/tests/test-next-agent-id.sh`,
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:180	S=YB:spawn-agents/scripts
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:203	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/grok-spawn.md:94	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:101	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:121	(`sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh --from QWN-01 CLE-04 "…"`) — allowed by the
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:141	| `YB:spawn-agents/scripts/next-agent-id.sh` | Allocate the next agent id from registry.tsv and CLAIM its inbox dir 
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:142	| `YB:spawn-agents/scripts/spawn-qwen.sh` | Window command: worktree (if git), inbox dirs, restore stub, launch as a
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:143	| `YB:spawn-agents/scripts/inbox-send.sh` | The file based inbox protocol sender (file + poke) |
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:144	| `YB:spawn-agents/scripts/riname.sh` | Rename window to `QWN-0n <title>` |
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:154	YB:spawn-agents/scripts/next-agent-id.sh --kind qwen)
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:173	(`YB:spawn-agents/tests/test-next-agent-id.sh`,
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:19	`<engine>/ysg-box-doc/doc/md/feature/spawn-agents/qwen-setup.md`. Two modes, selected by the first argument:
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:199	S=YB:spawn-agents/scripts
home	<box-user>	~<box-user>/.claude/commands/qwen-spawn.md:223	SEND=YB:spawn-agents/scripts/inbox-send.sh
home	<box-user>	~<box-user>/.claude/commands/riname.md:18	bash YB:spawn-agents/scripts/riname.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
home	<box-user>	~<box-user>/.claude/commands/signed-prompt.md:48	bash YB:directive/scripts/directive-session.sh --status
home	<box-user>	~<box-user>/.claude/commands/signed-prompt.md:56	bash YB:directive/scripts/directive-session.sh --minutes 60
home	<box-user>	~<box-user>/.claude/commands/signed-prompt.md:70	bash YB:directive/scripts/directive-sign.sh --reply-to sat <target> "<the owner's literal text>"
home	<box-user>	~<box-user>/.claude/commands/spawn-an-agent.md:84	sudo -u <box-user> bash YB:spawn-agents/scripts/inbox-send.sh CLE-03 "the message"
home	<box-user>	~<box-user>/.claude/commands/tmux-close-window.md:18	bash YB:spawn-agents/scripts/tmux-close-window.sh $ARGUMENTS
home	<box-user>	~<box-user>/.claude/skills/exit-clean/SKILL.md:199	bash YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>
home	<box-user>	~<box-user>/.claude/skills/exit-clean/SKILL.md:40	bash YB:spawn-agents/scripts/kill-your-self-report.sh 2>/dev/null || true
home	<box-user>	~<box-user>/.claude/skills/exit-clean/SKILL.md:43	bash YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>
home	<box-user>	~<box-user>/.claude/skills/graft/SKILL.md:63	> "The index shows 3 call sites in `ysg-box-utl/src/bash/run/`. It only covers shell and
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:164	bash YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:31	`YB:spawn-agents/scripts/kill-your-self-report.sh`  
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:35	`YB:spawn-agents/scripts/tmux-close-window.sh --defer --agent <YOUR-AGENT-ID>`
home	<box-user>	~<box-user>/.claude/skills/kill-your-self/SKILL.md:71	bash YB:spawn-agents/scripts/kill-your-self-report.sh 2>/dev/null || true
home	<box-user>	~<box-user>/.claude/skills/login-to-claude/SKILL.md:35	sudo -u <box-user> bash YB:claude-login/scripts/claude-login-cli.sh --status
home	<box-user>	~<box-user>/.claude/skills/login-to-claude/SKILL.md:42	sudo -u <box-user> bash YB:claude-login/scripts/claude-login-cli.sh
home	<box-user>	~<box-user>/.claude/skills/tmux-color/SKILL.md:31	bash YB:tmux-windows/scripts/tmux-window-color.sh --agent <YOUR-AGENT-ID> "$ARGUMENTS"
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:27	sudo -u <box-user> bash YB:wa-bot/scripts/wa_start.sh
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:44	- Attach-and-send script: `YB:wa-bot/scripts/wa_send.py`
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:45	- One-time launcher: `YB:wa-bot/scripts/wa_start.sh`
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:60	sudo -u <box-user> bash -c "\$HOME/.local/wa-bot/venv/bin/python YB:wa-bot/scripts/wa_send.py --to '+<country><number>' --m
home	<box-user>	~<box-user>/.claude/skills/whatsapp-send-msg/SKILL.md:64	sudo -u <box-user> bash -c "\$HOME/.local/wa-bot/venv/bin/python YB:wa-bot/scripts/wa_send.py --to 'FirstName LastName' --m
INFO users: <box-user> <agent-user> root; pattern: ysg-box(-[a-z]+)?/|/opt/<box-user>/
FAIL 70 dependency row(s) on the ysg-box engine (one per row above)
```

## 3. Inventory with decisions

Decision: **move** (copy into csi-spl, repoint, then delete the engine use),
**replace** (an existing csi-spl file already does it: repoint only),
**drop** (not a spool dependency, or dead), **keep** (guard/prose in csi-spl).

| item | used by | target in csi-spl | decision | risk |
|---|---|---|---|---|
| C1 save-sessions | boot restore | `csi-spl-orc/src/bash/features/box-sessions/scripts/save-sessions.sh` + state `/var/csi/csi-spl/box-sessions/` | move | high: a gap means the next reboot restores nothing |
| C2 sessions-boot | boot restore | `.../box-sessions/scripts/sessions-boot.sh` | move | high |
| C3, C4 graft cron | graft index | `csi-spl-orc/src/bash/features/graft/scripts/graft-cron.sh` | move (Q1: move) | low |
| the crontab lines themselves | C1..C4 | a named action `do_install_box_crons` writing marked lines from a csi-spl manifest | move | medium: the crontab is shared with other projects; edit only marked lines |
| L1 mcp-start.sh (firefox) | every agent's browser MCP | `csi-spl-orc/src/bash/features/mcp-bot/scripts/mcp-start.sh` | move | high: a broken link silently drops the MCP server |
| L2 mcp-start-chrome.sh | every agent's browser MCP | existing `csi-spl-orc/.../mcp-bot/scripts/mcp-start-chrome.sh` | replace | medium: diff the two first |
| L3 wa-bot | WhatsApp | - | drop from spool (Q2: yes); stays in ysg-box | none |
| L4, L5, H1 graft skill/rule/wrapper | agents | `csi-spl-orc/src/bash/features/graft/{scripts/graft-safe.sh,assets/}` installed by `install.sh` | move (Q1: move) | low |
| L6, L7 tmux links | nothing live | - (`install.sh` already ships the tmux snippet) | drop: remove the links, point `~<agent-user>/.tmux.conf:155,160` at the csi-spl snippet | low |
| H2 run completion | humans | `csi-spl-orc/lib/bash/completions/run.completion.bash`, sourced from `.bashrc` by an `install.sh` step | move (Q3: no, do not drop) | low |
| H3 wifi-up | personal | - | drop from spool (personal, like Q4) | none |
| H4 directive / `/signed-prompt` | cross-box owner directives | `csi-spl-orc/src/bash/features/directive/` + `spawn-agents/assets/commands/signed-prompt.md` | move | medium: signing key handling; the key stays out of git |
| H5 tmux-color | `/tmux-color` | `spawn-agents/scripts/tmux-window-color.sh` + `assets/skills/tmux-color` | move | low |
| H6 CLAUDE.md fragments + settings | every agent | `csi-spl-orc/src/bash/features/spool-install/assets/claude/{claude-md,settings}/` rendered by `install.sh` | move the fleet fragments (spawn, cross-lane, run-as-agent-user, push-and-deploy, spool-mirror settings); the personal ones (Slack, HTML docs, doc-hub) stay outside csi-spl (Q4: yes) | high: a half-rendered CLAUDE.md changes every agent's rules |
| H6 skills paste-html-into-chrome, spec-kit-tasks | agents | `spawn-agents/assets/skills/` | move | low |
| S1..S3 satellite clone + apply | sat provisioning | role 05 reads users from `csi-spl-cnf`; role 07 runs `install.sh` only | move | medium: re-provision test on a throwaway VM |
| S4 render-yield.sh | S3 workaround | - | drop once S3 is gone | low |
| S5, S6 | tests of S3/S4 | rewritten to assert the engine is NOT cloned | move | - |
| S7..S11 | guards | - | keep, and widen (section 7) | - |
| S12..S15 | comments | - | keep | - |
| state dir | C1/C2 | `/var/csi/csi-spl/box-sessions/` | move (copy the last snapshot once) | medium |

## 4. Migration lanes

Small and disjoint. None touches spec 068's files (`csi-spl-doc/specs/068-peer-seats/`,
hub claim columns / migrations, peer poll / restart / ensure, `spool-send.sh`,
`asks.sh`, the spawn launchers, `desk-reconcile*`) nor `restore-claude.sh`.
Each lane lands its scripts with a test, then a named install action applies
them to the homes; no lane edits a home or crontab by hand.

| lane | files (new unless said) | test | done when |
|---|---|---|---|
| Y9 gate + probe (first) | `csi-spl-orc/src/bash/run/check-ysg-box-deps.func.sh` (`do_check_ysg_box_deps`, read-only, lists sections 2.2..2.6) | plant one link + one cron line in a sandbox `HOME`/crontab file; it fails naming both | it runs on `<pc box>` and sat; sat's rows go into this spec as v0.2 |
| Y1 mcp-bot | `csi-spl-orc/src/bash/features/mcp-bot/scripts/mcp-start.sh`; an `install.sh` step links `~<box-user>/.local/mcp-bot/*` at csi-spl | `mcp-bot/tests/test-hygiene.sh` + a link test in a sandbox `HOME` | both links resolve into csi-spl; chrome + firefox MCP connect in a fresh agent |
| Y4 claude-config | `spool-install/assets/claude/{claude-md,settings}/`, `install.sh` render step | render into a sandbox `HOME`; diff vs today's `~<agent-user>/.claude/CLAUDE.md` = only the personal fragments | `CLAUDE.md` + `settings.json` carry the `spool-install` marker |
| Y5 skills + commands | `spawn-agents/assets/skills/{tmux-color,paste-html-into-chrome,spec-kit-tasks}`, `assets/commands/signed-prompt.md`, `scripts/tmux-window-color.sh`, `features/directive/` | `spawn-agents/tests/test-hygiene.sh` (no engine path) | all 15 files under `~/.claude/{commands,skills}` carry the marker |
| Y2 box-sessions | `csi-spl-orc/src/bash/features/box-sessions/{scripts/save-sessions.sh,scripts/sessions-boot.sh,tests/}` | save then restore in a private tmux socket and a private state dir | a reboot of `<pc box>` restores every seat from the csi-spl copy |
| Y3 box crons | `csi-spl-orc/src/bash/run/install-box-crons.func.sh` (`do_install_box_crons`) + manifest | dry run prints the diff; touches only `# csi-spl:` marked lines | C1..C4 run from csi-spl paths; `crontab -l \| grep -c '/opt/<box-user>/'` -> 0 |
| Y6 graft (Q1: move) | `features/graft/{scripts,assets}` | the wrapper runs `graft-safe.sh` from csi-spl in a sandbox | H1, L4, L5, C3, C4 point at csi-spl |
| Y7 tmux cleanup | `install.sh` removes engine-pointing `~/.tmux/*` links and repoints `~<agent-user>/.tmux.conf` | a sandbox `HOME` seeded with today's 12 broken links | 0 broken links in either home |
| Y10 run completion (Q3) | `csi-spl-orc/lib/bash/completions/run.completion.bash`; an `install.sh` step replaces the engine `.bashrc` line with a marked csi-spl one | completes `./run -a` for `csi-spl-iac/run` and `csi-spl-orc/run` in a sandbox shell; the `.bashrc` edit is idempotent | `grep -c '/opt/<box-user>/' ~/.bashrc` -> only the personal `wifi-up` line (H3) |
| Y8 satellite | S1, S2, S3, S5, S6; S4 deleted; users into `csi-spl-cnf` | `satellite-ansible.tst.sh`, `satellite-actions.tst.sh` assert no engine clone | sat re-provisions on a throwaway VM with no `<engine>` |

Order: Y9 (the probe, so sat is measured), then Y1, Y4, Y5 (live agent paths),
then Y2+Y3 together (boot), Y6, Y10, Y7, Y8. Y4 and Y5 both edit `install.sh`: run
them in sequence, not in parallel; so do Y6, Y7 and Y10, which also edit it.

## 5. Out of scope

the owner-utility creds backup cron, the four other-project crontab lines,
`~/.claude.json` project history, and any file of spec 068.

## 6. Owner questions - answered

Answered by the owner, HUM-10 at 14:37Z, verbatim: "1. move 2 y 3 n 4 y".

| Q | question | answer | effect |
|---|---|---|---|
| Q1 | graft (the code index tool the agents use): move into csi-spl? | **move** | Y6 is in scope |
| Q2 | wa-bot (WhatsApp send): drop from spool? | **y** | L3 dropped; stays in ysg-box |
| Q3 | `./run` tab completion in `.bashrc`: drop from spool? | **n** | H2 moves: lane Y10 |
| Q4 | personal CLAUDE.md fragments (Slack, HTML docs, doc-hub rules): stay outside csi-spl? | **y** | Y4 moves only the fleet fragments |

No question is open.

## 7. Acceptance check

`do_check_ysg_box_deps` (Y9) runs every section-2 command on the box and lists
the population; it passes only when **each list is empty**, on `<pc box>` and
sat. Then the proof the owner asked for: move `<engine>` and `<overlay>`
aside, reboot, and the fleet comes back (C2's job, now csi-spl's), agents
connect the chrome/firefox MCP, and `/signed-prompt` and `/tmux-color` work.
