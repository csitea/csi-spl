# Feature Specification: terminal delivery — a message is VISIBLE in the recipient agent's pane

**Feature ID**: `028-spool-terminal-delivery` · **Milestone**: M3
**Created**: 2026-09-20 · **Lane**: MSG-TO-TERMINAL (CLE-3428)

**Owner input (verbatim, 2026-09-20)**: "we need to make sure that whenever a
msg between the agents is send, or between a human and an agent this gets
dispatched to the terminal as well" — and, on emphasis: "and it is visible on
the terminal as well".

**Builds on**: 002 (`contracts/local-folder-layout.md`: the file is the record,
the doorbell is explicitly out of scope there — this spec closes that hole),
003 (`spool hub-run`, the box sidecar that drains the hub queue),
012 (`spool-harness`, the one launcher; a box engine shells the spool verbs only),
014 (the hub signs a signed-in human's send with `box-wui`).

**Contracts (this dir)**: `contracts/poke-line.md` — the exact rendered line,
its sanitisation and its bounds.

## 0. The gap this closes (measured on one box, 2026-09-20)

Four hops carry a message to an agent on a box. Before this spec:

| hop | who writes the file | who rings the pane |
|---|---|---|
| agent -> agent, same box, via `spool-send.sh` | `spool send` | `spool-send.sh` — a **doorbell only**: `SPOOL <id>: task from <id> - run: spool recv` |
| agent -> agent, same box, via the `spool send` CLI or the `spool_send` MCP tool | `spool.Store.Send` | **nobody** |
| agent -> agent, **cross box** | `hub-run` -> `Session.receive` -> `spool.Store.DeliverTo` | **nobody** |
| human (WUI, 014) -> agent | the same `hub-run` path, envelope from `box-wui` | **nobody** |

So three of the four kinds never reached a terminal at all, and the one that
did carried no content: the agent had to be told, by a line it might not read,
to go and run a command.

## 1. Requirements

- **FR-001** — Every message that lands in a LOCAL agent inbox rings that
  agent's terminal pane, whatever hop wrote it: local `Store.Send` (CLI and
  MCP alike), and `Store.DeliverTo` (the hub sidecar: cross-box and `box-wui`).
  One hook, at the single inbox write (`spool.Store.writeBox`, box `inbox`).
- **FR-002** — The pane shows the message, not a doorbell: sender, kind,
  `task_id`, `msg_id`, a **bounded, sanitised excerpt of the body**, and the
  exact command that reads it in full. `contracts/poke-line.md` pins the shape.
- **FR-003** — A message that was NOT written (a hub redelivery already in the
  inbox or archive) rings nothing: the notification follows `wrote`, so a
  reconnecting sidecar does not re-ring an old message.
- **FR-004** — The safe-poke rules of `spool-send.sh` are reused, never
  reimplemented: registry-first pane resolution, pane id (`%NN`) not window
  index, no poke into a pane holding unsent typed text, no poke into a pane
  that runs only shells, and a shell-inert `: '…'` line **wherever the pane
  could be a shell** (`alternate_on` 0). See FR-009.
- **FR-009** (owner, 2026-09-22) — A message from a HUMAN reaches an agent's
  prompt as the human's own words, verbatim, followed by Enter — "as a human
  would be typing into this chat textbox". The `: 'SPOOL …'` wrapper of FR-002
  is what a human's message must NOT be dressed in: an agent reads a quoted
  no-op as noise and acts on none of it. `contracts/poke-line.md` §1.1 pins
  the rule, its two limits (agent senders keep the §1 line; a verbatim body is
  typed only onto the alternate screen) and the controls for both.
- **FR-005** — The notifier is off unless `SPOOL_NOTIFY_CMD` names it. A box
  gets it from `spool-harness` (which exports it for the agent session and for
  the `hub-run` sidecar it starts); `off` disables it; a CI or test process
  with the var unset behaves exactly as before.
- **FR-006** — The notification never fails a delivery. A notifier that is
  missing, slow (`SPOOL_NOTIFY_TIMEOUT`, default 10s) or non-zero is logged and
  the message stays delivered — the file is still the record (002).
- **FR-007** — Isolation: a message addressed to agent X rings X's pane only.
  No other pane on the box, and no other tenant's agent, sees it.
- **FR-008** — `spool-send.sh` keeps its own doorbell and its exit codes
  (0/5/6/7) by disabling the in-binary hook for its own send, so a message is
  rung exactly once.

## 2. Success criteria

- **SC-001** — On a live box, a cross-box message for a throwaway agent id
  appears, body and all, in that agent's pane within seconds of the sidecar
  receiving it. `capture-pane` is the evidence.
- **SC-002** — A WUI human task (014) for that agent appears the same way.
- **SC-003** — CONTROL: a message for a different agent never appears in that
  pane.
- **SC-004** — `do_spl_m3_e2e` asserts the terminal delivery, rather than a
  second harness being stood up next to it.

### Verified status (2026-09-21)

| SC | Status | Evidence |
|---|---|---|
| SC-001 cross-box message visible | **Met** | e2e step `f`, case `a`; and `live-terminal-proof.sh` case 2, 2.59 s, on the box user's real tmux |
| SC-002 WUI human task visible | **Met** | e2e step `f`, cases `b` (@mention note), `c` (directed task), `d` (DM note) |
| SC-003 another agent never sees it | **Met** | e2e `leaked_into_EZA-1_pane: []`; proof case 3 |
| SC-004 asserted inside `do_spl_m3_e2e` | **Met** | step `f-visible-in-agent-terminal` |

Run: `ENV=dev TENANT_ID=t1 ROOT_KEY_JSON=… ./run -a do_spl_m3_e2e` against
`https://dev.api.spool-hub.ai`, 2026-09-21T07:43Z, tree `8bb82ba`, n=1 — every
step PASS, `rc=0`. `live-terminal-proof.sh` 2026-09-21T07:51Z, tree `001ddca`,
n=1 — 5/5.

Deploy: the terminal leg runs in the box's own `spool` binary, not in the hub,
so nothing here waited on a Cloud Run roll. `d5b6042` shipped anyway with
CLE-3355's `0.1.17`: both hosts serve commit `39a5a25a` (2026-09-21T07:54Z) and
`do_check_deploy_lag` reads `hub current` with `rc=0` on dev and prd
(`tasks.md` T050).

## 3. Assumptions and decisions (auto-mode, logged)

- **D-01 The hook is in the binary, not a watcher.** A bash loop polling
  `$SPOOL_ROOT/*/inbox` would be a second source of truth for "is this new",
  would race the sidecar's write, and would need its own dedupe. The single
  inbox write already knows `wrote`, so FR-003 is free.
- **D-02 The renderer is bash, in `csi-spl-orc`.** The tmux rules are the
  ones `spool-send.sh` already proves; keeping them in one bash lib means the
  binary carries no tmux knowledge and a box can point `SPOOL_NOTIFY_CMD` at
  its own renderer.
- **D-03 Synchronous, bounded.** The notifier runs inline with a timeout, so
  the ordering "file written, then pane rung" is the observable one and a test
  never has to sleep on a background goroutine.
- **D-04 The excerpt, not the body.** An unbounded body typed into a pane is a
  hazard (newlines submit lines, quotes break inertness) and unreadable. The
  contract bounds it and names the command that prints the whole message.
- **D-05 (2026-09-22) The excerpt was the wrong shape for a HUMAN sender.**
  D-04 is right about the hazards and wrong about who the line is for. An
  agent's only input is its prompt, and what D-04 put there for a human's DM
  was a shell no-op quoting the message — which is exactly what the owner
  reported as "the msg is displayed in the tmux panel, but the agent does not
  understand the input". The hazards D-04 names are all real and all still
  handled: newlines and control bytes are still stripped, the body is still
  bounded, and inertness is still required wherever the pane could be a shell.
  What changed is that on a confirmed TUI, where nothing parses the bytes,
  inertness buys nothing and costs the message. FR-009 / poke-line.md §1.1.
- **D-06 (2026-09-22) `SPOOL_POKE=0` is a box-wide switch, and that is a
  defect in its own right.** There is ONE `hub-run` sidecar per box
  (`spl_desk_sidecar` reuses the live one under `flock`), so the value chosen
  by the FIRST `do_spl_desk_up` on that box is inherited by every agent seated
  there afterwards. Measured 2026-09-22 on `box-desk`: the sidecar carried
  `SPOOL_POKE=0`, chosen for the CLE-00 seat, and every other agent on the box
  silently lost its prompt leg with it — a WUI DM reached the inbox and the
  notice strip and no prompt at all. The owner's call the same day was to run
  the box with the prompt leg ON for every agent, CLE-00 included, rather than
  make the switch per-agent.
- **D-07 (2026-09-25) The garbled pane after a notice strip splits in was a
  missing SIGWINCH, not a limit of the TUI.** `8994a91` put the damage down to
  an Ink-style renderer that "holds no copy of the transcript" and so cannot
  repaint after a width change. That was measured on a synthetic painter, not
  on an agent CLI. The real cause: agents launched with `sudo su - <agent> -c`
  run in their own session with no controlling tty (`ps` TT `?`, TPGID -1), so
  tmux's resize never reaches them and an idle CLI keeps painting at the old
  width. Measured with Claude Code 2.1.282 on tmux 3.5a, 189x51 split
  `-h -l 48`, n=1 each: plain `su -` idle -> garbled; `su --pty` idle -> clean
  at 140 and back at 189; plain `su -` mid-turn -> clean (a busy renderer
  recovers). The launcher fix is ysg-box `d938aaa` / `5ed638c` (spec 001
  T013). The right-hand strip stays, and splitting it before the CLI paints
  stays too, but neither is needed for a correct repaint once the CLI hears
  the signal.
- **D-08 (2026-09-25) What reaches an agent, and how, after the owner's
  session with CLE-100.** Owner decisions, verbatim where quoted:
  - The box's last metre stays files + a prompt poke only as the doorbell;
    the agent's own client is an MCP server over the box's desk ("which will
    be FAST and asynchronously could save fiels a well"). `spool mcp` already
    existed in the binary and was wired into no agent; CLE-120 wired it
    (`spool-dev` / `spool-prd`, user scope), `779bbab` scopes a server to one
    seat (`--as <ID>`).
  - "whenever I type anyting in the terminal prompot of the ai agents it
    should be visible as me typing it here on the web ui": a terminal-typed
    line renders as the human, not the agent - spec 036 (`bc4413e`,
    `typed_by`).
  - The box is seated on **prd** too ("but you are not onine the prd
    instance"): `box-desk` pinned on prd t1 at 15:41:30Z.
  - Default channels start with no agents (`d357bab`); to reach agents a
    member picks them (`POST /v1/channels/<ch>/agents`).
  - Other boxes are deferred: "forget about the other boxes for now".

<!-- version: 1.4.0 · updated: 2026-09-25 · last-edit: 2026-09-25T16:10:00Z -->
