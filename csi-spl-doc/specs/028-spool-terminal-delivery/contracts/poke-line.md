# Contract: the poke line — what the recipient's pane shows

**Spec**: `../spec.md` FR-002, FR-004 · **Implemented by**:
`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh`
(`spool_notify_render`, `spool_notify_poke`) · **Pinned by**:
`csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-notify.sh`

## 1. Shape

One line, sent to the pane with `send-keys -l` and then `Enter`:

```
: 'SPOOL <TO>: <KIND> from <FROM>[ task <TASK>][ msg <MSG>] :: <EXCERPT> :: run: spool recv --as <TO>'
```

| field | source | note |
|---|---|---|
| `<TO>` | the recipient agent id | also the id whose pane is resolved |
| `<KIND>` | `task` \| `result` \| `note` \| `reject` | `ping` when the caller gives none |
| `<FROM>` | the sender agent id | `?` when unknown. For a WUI human (014) this is the **session's** id, which is what the hub puts in `from` |
| `<TASK>` | `task_id` | omitted when empty |
| `<MSG>` | `msg_id` | omitted when empty |
| `<EXCERPT>` | the body, sanitised and bounded (§2) | `(no body)` when empty |
| the tail | literal | the command that prints the message in full |

The prefix `: 'SPOOL ` is load-bearing twice over: it makes the line inert in a
shell (`:` is the no-op builtin, the rest is one quoted argument), and
`spool-send.sh`'s unsent-text check treats a line already starting with it as a
previous poke rather than as a human's typing.

## 1.1 What a TUI prompt is given: the human's words, verbatim

**Owner rule, 2026-09-22** — "the input should be set on THIS here input where
a human would type this and an enter hit", "so that the communication would be
as a human would be typing into this chat textbox".

So the line above is not what an agent's prompt gets when the sender is a
human. `SPOOL_POKE_STYLE` decides:

| value | a TUI prompt is typed |
|---|---|
| `auto` (default) | the BODY verbatim when `from` is `HUM-*` / `GST-*`; the §1 poke line otherwise |
| `body` | the BODY verbatim, whoever sent it |
| `line` | the §1 poke line, whoever sent it |

Two limits are load-bearing, and each has a test that turns red without it.

**An agent sender keeps the §1 line.** `from` and the `run: spool recv --as
<TO>` tail ARE the inter-agent protocol; a bare body strips both and the
receiving agent cannot answer or find the message. Only a human's message is
the human's words.

**A verbatim body is typed ONLY into a pane whose `alternate_on` is 1.** This
is the whole safety argument for §1's inertness, not a tidy-up. The `: 'SPOOL
…'` line is shell-inert by construction; a raw body is not, and a pane sitting
at a shell prompt would EXECUTE it. A full-screen CLI paints on the alternate
screen buffer — every live agent pane on this box reported 1 and the one bare
shell reported 0 (measured 2026-09-21, recorded in `spool-poke-queue.inc.sh`).
So the verbatim body reaches a TUI input buffer, which parses nothing, and
never a shell. Anything not on the alternate screen falls back to the §1 line.

The body is still made single-line-safe (§2 steps 1, 2, 4 and a
`SPOOL_NOTIFY_PROMPT_MAX` bound, default 4000). Step 3 — `'` becomes `"` —
is **not** applied: it exists to keep the body inside a single-quoted shell
argument, and a TUI prompt has no shell, so applying it would only mangle
every apostrophe the human typed (`don't` → `don"t`).

`spool_notify_poke` leaves the line it actually chose in `SPOOL_POKE_LINE`, so
a refusal (§3 code 6) queues what would have been typed rather than
re-deriving it.

## 2. Sanitisation and bounds

Applied to the body, and to every interpolated field, in this order:

1. **ESC sequences out** — `ESC[…<letter>` and a bare `ESC` are dropped, so a
   body that carries colour codes cannot repaint the pane.
2. **Control characters out** — every byte below 0x20 except tab/newline/CR,
   plus DEL, is dropped. Tab, newline and CR become a single space, so the line
   cannot submit early (`send-keys -l` would treat a newline as Enter).
3. **`'` becomes `"`** — the only character that could end the quoted argument
   and let the rest of the body reach the shell as code. A double quote inside
   single quotes is an ordinary character.
4. **Whitespace collapsed** — runs of spaces become one; ends trimmed.
5. **Bounded** — the excerpt is cut to `SPOOL_NOTIFY_BODY_MAX` characters
   (default 600) and gains a trailing ` …` when it was cut. The whole line is
   then cut to `SPOOL_NOTIFY_LINE_MAX` (default 1200) as a backstop.

A body that survives all five unchanged is shown verbatim, which is the common
case for the one- and two-line messages agents actually send.

## 3. Outcomes

`spool_notify_poke` prints one `poke:` line and returns:

| code | meaning | the message |
|---|---|---|
| `0` | typed into the pane | delivered and visible |
| `5` | no live window carries `<TO>` | delivered; read on the next `spool recv` |
| `6` | REFUSED: the pane holds unsent typed text | delivered; never clobbered |
| `7` | the pane runs only shells (the agent has exited) | delivered |

Every one of them means the file was written: the notification is the second
leg, and 002 keeps the file as the record.

## 4. What it must never do

- Resolve a target by window **index**. Indices renumber; `spool_pane_of`
  returns a pane id (`%NN`) and checks the window still carries the id.
- Poke a pane with unsent text **on a TUI input line**. `send-keys` appends to
  the input line and the `Enter` then submits whatever the human had
  half-typed. Measured 2026-09-21 on a real pane showing `❯ half typed and never
  sent`: exit 6, the line untouched, the message still delivered.

  **The bound, measured rather than assumed.** The detector reads the last line
  carrying a TUI input marker (`❯`, or `> ` at the start of a line). A pane
  sitting at a bare SHELL prompt (`bash-5.2$ …`) has no such line, so
  type-ahead there is NOT detected and the pane IS poked - confirmed on this box
  the same day. That is a bound, not an exposure: a pane whose tty runs only
  shells is skipped as an exited agent (next rule), so the only way to reach it
  is a shell pane with a foreground job, which is not an agent session. Widening
  the detector to arbitrary `$`/`#`/`%` prompts was rejected: a shell pane shows
  command OUTPUT on that line far more often than type-ahead, and a false
  refusal silently drops the terminal leg.
- Poke a pane that has lost its agent (only `bash`/`sh`/`zsh`/`dash`/`login` on
  its tty). `sudo` and `su` on that tty are NOT that case: the launcher hops
  through them and the CLI runs on its own pty.
- Send more than one line, or a line whose inertness depends on the body.

<!-- version: 1.2.0 · updated: 2026-09-22 · last-edit: 2026-09-22T13:10:00Z -->
