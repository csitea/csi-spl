# Feature Specification: Terminal ⇄ Web UI Mirror of a Seated Agent

**Feature ID**: `036-spool-terminal-mirror` · **Milestone**: M3 · **Status**: Partial
**Created**: 2026-09-25 · **Lane**: terminal-webui-mirror (CLE-3496)
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is
built, with the sha and the check for each item. Status vocabulary:
`../README.md` §2.3.

Builds on `028-spool-terminal-delivery` (web UI → terminal: the desk sidecar
types a human's DM into the agent's prompt). This spec adds the other
direction and the rules that keep the two from echoing each other.

## The owner's request, verbatim (2026-09-25)

> tell to all ofthe running agents on this box to upload their current sessions conversations to the direct messages between the human HUM-09@box-wui and them selves
> and start receiving and displaying the msgs the same way we have it here with you , aka the same msgs will be visible between me and you from this terminal interface and from the web ui interface as well ...

## Clarifications

- **The human.** The owner wrote HUM-09. There is no HUM-09; the owner's id
  is HUM-9 (a second identity of the owner, HUM-17, also DMs agents). The
  mirror default is `SPOOL_MIRROR_TO=HUM-9`, and it FOLLOWS the conversation:
  once a human sends the agent a direct message, that human and that topic
  are where the mirror posts (FR-004). **DECIDED** by this lane, with the
  choice stated to the orchestrator.
- **One topic, not one per session.** An agent's mirror posts into ONE DM
  topic: the one the human last wrote in, else the one the mirror used
  before (the backfill's topic, when a backfill ran). A new session of the
  same agent id continues that topic. **DECIDED**: the owner asked for "the
  same msgs visible" in both places, which one running conversation shows;
  a topic per session would scatter it.
- **A broadcast is not a DM.** A human message to `ALL-0` (a channel
  broadcast) fans out into every seated agent's inbox. It is typed into the
  prompt like any human message, but it never becomes the mirror topic:
  mirroring there would post every agent's session into a shared channel.

## Requirements

- **FR-001** Every prompt submitted in a seated agent's terminal is posted
  into its DM with the human, once, prefixed `[terminal] `.
- **FR-002** Every final answer of the agent (the text of its last message in
  a completed turn) is posted into the same DM, once per session. A subagent's
  turn and grok's session-end `Stop` (`reason` other than `end_turn`) are not
  answers.
- **FR-003** Nothing is posted twice:
  - a prompt line the desk TYPED (a human's web UI message) is recorded by the
    notifier before the paste (`<seat>/spool/<agent>/.mirror/typed/`); the
    prompt hook drops a line that matches one, consumes the record, and posts
    the rest. A record expires after one hour.
  - machine doorbell lines (`: 'SPOOL …'`, `INBOX <ID>: …`) are not posted.
  - the mirror post goes FROM the agent TO the human on `box-wui`; the hub
    never dispatches it to the desk, so the agent is not poked by its own post.
- **FR-004** Topic choice, in order: `.mirror/peer` (the human and topic of
  the last human DIRECT message, written by the notifier) → `.mirror/topic`
  (the topic this mirror or the backfill last posted in) → none, and the
  topic the hub mints is remembered.
- **FR-005** Every post, and the backfill transcript, is redacted by
  `lib/spool_redact.py` before it leaves the box (tokens, keys, JWTs, DSN
  passwords, `password=`-style assignments).
- **FR-006** The hook never blocks the CLI: it always exits 0, forks the post
  detached, and is a silent no-op when its script is absent.
- **FR-007** Opt-out per seat: `<seat>/spool/<agent>/.no-mirror`.
- **FR-008** The backfill (the session so far) and the checks are named
  actions (rule "nothing ad hoc"): `do_spl_desk_session_upload`,
  `do_spl_desk_mirror_settings`, `do_spl_desk_mirror_check`.

## Mechanism

| leg | who runs it | where |
|---|---|---|
| hook | the AGENT user, from the CLI's `UserPromptSubmit` and `Stop` hooks | `spool-mirror.py hook` |
| post | the BOX user (owner of the desk state), via `sudo -n -u <box user>` | `spool-mirror.py post` |
| typed / peer records | the desk sidecar's notifier | `lib/spool-notify.inc.sh` `spool_notify_mark_typed`, `spool_notify_mark_peer` |
| send | `spool send --to <human> --to-box box-wui` on the seat root; the seat's `hub-run` sidecar flushes it | the hub URL is read from the live sidecar's environment |

**One hook config serves both CLIs** (measured 2026-09-25): Claude Code reads
hooks from `~/.claude/settings.json` (or `--settings <file>`), and grok 1.0.41
reads the same file (`[compat.claude] hooks = true` by default; a project's
`.claude/settings.json` needs a git root and trust). Payloads, captured from
both CLIs: Claude `prompt` / `last_assistant_message` (snake_case); grok
`prompt` / `lastAssistantMessage` / `reason` (`end_turn` vs `shutdown`) /
`subagentType`. Both carry `hook_event_name` in PascalCase. The agent id comes
from `MCP_BOT_AGENT_ID`, which the box spawner sets for every claude and grok
window.

The hooks JSON is printed by `do_spl_desk_mirror_settings`:
`[ -r P ] && exec python3 P hook; exit 0` for both events, timeout 10s.

## Rollout

Running sessions pick the mirror up WITHOUT a restart (measured 2026-09-25:
the hooks were merged into the agent user's `~/.claude/settings.json` at
13:02Z and, within 30 minutes, six running Claude sessions - CLE-001,
CLE-3493, CLE-3494, CLE-3495, CLE-34961, CLE-3496 - had posted `OK prompt` /
`OK answer` lines in their seat's `.mirror/mirror.log`), once the hooks are in the agent user's
`~/.claude/settings.json` (the box's claude-config fragment, owned by the
org overlay; applying it is an owner action). The web UI → terminal leg
records `typed` / `peer` only when the desk's sidecar runs a notifier from a
tree at or after `f8da6b4`; `do_spl_desk_mirror_check` WARNs when it does not,
and when the sidecar runs a worktree's notifier (which disappears with that
worktree).

## Attribution: a terminal-typed line shows as the HUMAN (decided 2026-09-25)

Owner, ~15:57Z, verbatim: "also when I type on the terminal and you send the
msg in the thread it looks like you send it and that is a bug" / "whenever I
type anyting in the terminal prompot of the ai agents it should be visible as
me typing it here on the web ui".

Until this, a terminal prompt was posted `from=<agent>` with the body prefix
`[terminal] ` (measured by CLE-100 on dev and prd, n=3 each). The box signs
with its box key and can never mint a human's identity, so `from` stays the
agent and the attribution is a separate, hub-VERIFIED claim:

- **FR-009 `typed_by` on the send frame.** The mirror sends a terminal prompt
  with `typed_by=<HUM-n>` on the WS `send` frame, outside the box-signed
  envelope and the inner message: boxes decode those strictly (020), and
  neither changes. Frames are decoded leniently, so an older hub ignores the
  field and the post stays attributed to the agent, as before.
- **FR-010 the hub accepts it only when it can verify it**: the sending box's
  session is authenticated; `from` is an agent this box announced (roster);
  `typed_by` is a member of the tenant; and a BINDING says that human operates
  that box (`box_operators(tenant_id, box_id, human_id)`, granted by a tenant
  owner/admin - never by the box). Otherwise the send is refused with
  `typed_by_not_bound` and the mirror re-posts it without the claim.
- **FR-011 storage and rendering**: the hub stores `messages.typed_by`; the
  view API and the web UI live frame carry it; the web UI renders such a row
  as the HUMAN (avatar and name) with a small badge "via terminal <agent>".
  The `[terminal] ` body prefix is dropped when the claim is accepted.
- **FR-012 who is typing**: the seat's operator (`.mirror/operator`, set by
  `spool-agent --operator HUM-n` or the grant action), else the human the
  mirror posts to. A wrong guess is refused by FR-010, never displayed.
- Per env the human differs (e.g. prd and dev ids of one person); nothing
  hard-codes an id - the binding and the seat file carry it.

Found while mapping this (reported, not fixed here): the hub's `onSend` never
checks that `m.From` is an agent of the sending box, so any pinned box can
post as any agent id. FR-010 checks it for `typed_by` sends only.

## The wrapper: `spool-agent.sh` (2026-09-25, owner: "wgo")

One command starts claude or grok as a seated, mirrored agent:
`spool-agent.sh [--as ID] [--env dev|prd] [--no-mirror] [--no-seat] [--backfill] [--dry-run] claude|grok [args]`.

1. **id**: `--as`, else `MCP_BOT_AGENT_ID` (the box spawner's), else the next
   free `CLE-n` / `GRK-n`, CLAIMED on the desk (`next-agent-id.sh`), and above
   a spawner registry named in `SPOOL_AGENT_REGISTRY_DIR` so a spent id is never
   reissued.
2. **window**: renamed to carry the id (the box tag kept), because the desk
   finds the pane by window name; outside tmux a seat is refused.
3. **seat**: `do_spl_desk_up`, as the box user (`sudo -n -u` when needed).
4. **hooks**: claude `--settings <file>`, grok `~/.grok/hooks/spool-mirror.json`
   - and NEITHER when `~/.claude/settings.json` already carries the hook (both
   CLIs read it; two copies of different checkouts posted every line twice,
   measured). `spool-mirror.py` also posts one (session, event, text) once.
5. **CLI**: found via `CLAUDE_BIN` / `GROK_BIN`, PATH, then `~/.local/bin`.

The box spawner starts every claude / grok agent through it when the box env
sets `BOX_AGENT_WRAPPER` (engine `2946445`; this box: overlay `d68b8c0`). An
unreadable wrapper falls back to the plain CLI.

Proof, dev t1, tree `2205be3`: CLE-34965 started by the wrapper with no id
(claimed, window renamed `<box tag>: CLE-34965`, seated). Terminal prompt + answer:
one `OK prompt` + one `OK answer` in `.mirror/mirror.log` (n=1 each; the
earlier double post is the measurement behind step 4). Web UI -> terminal:
`do_spl_desk_probe` DM typed once in the pane, `skip prompt ... web UI (1)`,
answer posted to HUM-4's topic `743ebae2-…` (after the desk was repaired
from STRANDED - `do_spl_desk_check DESK_REPAIR=1`; lane CLE-34964).

## Proof (2026-09-25, dev, tenant t1, tree `5add6fb`)

Test agents seated on a dedicated desk `box-mirror` (its sidecar running this
tree's notifier), so the live `box-desk` and its seats were not restarted.

- **claude** (CLE-34960, Claude Code on haiku, launched with
  `--settings` = `do_spl_desk_mirror_settings`): `do_spl_desk_probe` — a real
  member HUM-4 DMs it, 9/9 PASS, typed into pane `%146`. Hub DB, topic
  `bfc5acf7-97ec-4590-bf50-0a5c4a0518a7`, n=8 rows: 1 from HUM-4, 7 from the
  agent (the probe's own `do_spl_desk_reply`, 3 answers, 2 `[terminal]`
  prompts, 1 driven Stop). `echoed_web_prompt = 0`, the agent's inbox holds
  1 message, the pane shows the web UI line once.
- **secrets**: a planted `ghp_…` token and a `password=` in terminal prompts
  arrived as `<redacted:github-token>` / `password=<redacted>`; a planted
  answer (the real hook fed a Stop payload, because the model refused to echo
  a credential) arrived as `<redacted> and password=<redacted>`.
  `leaked = 0` over the four planted strings.
- **grok** (GRK-34961, grok 1.0.41 headless, the same hooks in a project
  `.claude/settings.json`): topic `1cde2fe4-540b-4b38-8941-d6842a0af4c9`,
  n=2 rows — the `[terminal]` prompt and the answer; the session-end `Stop`
  posted nothing.

<!-- version: 1.0.0 · updated: 2026-09-25 · last-edit: 2026-09-25T16:20:00Z -->
