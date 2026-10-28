# The desk's human-to-human gate

SPL-3967. On 2026-10-27, in csitea #csi-fina (topic f21f5a07), a person
posted to another person (msg 23241cff, to_id HUM-10), and a desk answered
it (n=2 desk replies). The person then asked, in English: "I tagged @HUM-10
so the agent would not step in, and it was again taken as needing agent
action. Can the AI not reply in such a case?" The same thing happened once
before in another workspace (topic d6a1d959, 2026-10-21).

## 1. What the desk refuses

`do_spl_desk_reply` reads the topic (`spool hub-tail`) and takes the newest
human post since the last agent post there. It refuses the reply (exit 9,
nothing sent) when that post is addressed to people only:

| the post | example |
|---|---|
| its to_id is a person (`HUM-*`) | HUM-24 posts to HUM-10 |
| a channel post (`ALL-0`) that @-mentions people and no agent | `@HUM-10 install the new app` |

The FATAL names the msg id and says "addressed to HUM-n, not to the agents".

These go through:

- a channel post with no mention, or one that also names an agent
  (`@HUM-10 @c-002 ...`), or a DM to the agent;
- a later human post that is for everyone: it opens the topic again;
- any reply after an agent has already posted after the human-to-human post;
- `DESK_HUMAN_TO_HUMAN_OK=<msg id>` (or its first 8 characters): the case
  where that human then asks the agents. The answer is sent with a WARN.

`do_spl_take` and `do_spl_take_auto` post their take line through
`do_spl_desk_reply`, so a take of such a post is refused the same way and no
take is recorded. A topic the desk cannot read is let through with a WARN:
the [new-topic lease gate](desk-new-topic-lease-gate.md) already refuses an
unread topic to every seat but the holder.

## 2. What the seat sees

The poke line a seat gets for a person's channel post to another person names
that person, so the seat sees it before it acts:

`[channel post from HUM-24, to: HUM-10, topic <uuid>, msg <id> - addressed to a person, not to the agents; do not answer it (SPL-3967)]`

It is built on the box from the delivered envelope's `to`
(`spool_notify_frame` in
`csi-spl-orc/src/bash/features/spawn-agents/lib/spool-notify.inc.sh`).

## 3. Code and test

- Gate: `csi-spl-orc/lib/bash/funcs/spl-desk-human-gate.func.sh`
  (`spl_desk_human_gate`), one call in `do_spl_desk_reply` right after the
  lease gate.
- Test: `csi-spl-orc/src/bash/tests/desk-reply-human-to-human.tst.sh`, 18
  cases. With the gate call removed, 10 fail.
- Poke frame test: the SPL-3967 cases of
  `csi-spl-orc/src/bash/features/spawn-agents/tests/test-spool-notify.sh`.
  With the frame branch removed, 1 of 4 fails.
