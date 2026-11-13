# Feature Specification: @ Mention Picker Everywhere and the Mention Poke

**Feature ID**: `042-spool-mention-poke` · **Milestone**: M3 · **Status**: Partial (see `tasks.md`)
**Created**: 2026-09-26 · **Lane**: MENTIONS (browser) · **Issue**: SPL-985 (epic 40, spec 022)
**Authority**: this file for the rule; `tasks.md` for what is built and where.

Status vocabulary follows `../README.md` §2.3.

## 1. The owner's request, verbatim

prd t1 `#spool-hub-devel`, topic `3aba968b-b791-4cf3-a398-80d15bcc4962`, 2026-09-26:

> not only in the omnibox, but in any of the descriptions or msgs or cards where text can
> be input, typing the @ should invoke the drop box to select, which contains agents or people

> and those agents or people should get poked in their personal msgs

> to know that they have been addressed and they should do something

## 2. The picker (one component)

- **P1** Typing `@` at the start of a field or after whitespace, in ANY text field
  where a person writes (the top-bar omnibox, thread / topic replies, DM and channel
  lines, an issue description, an issue comment, the new-issue editor, the subtask
  title, the message edit box, the new channel description) opens ONE list:
  the tenant's people and agents (avatar, online dot, display name / id), filtered by
  what follows the `@` (id, label or chosen display name, any script).
- **P2** ArrowUp / ArrowDown move the highlight; Enter or Tab pick; Escape closes;
  a click outside (the field loses focus) closes. The pick replaces the `@fragment`
  with the full tag (`@CLE-35017`, `@CLE-3994@box-desk`, `@HUM-10`) and a space.
- **P3** While the list is open, Enter and Tab pick. They never send or save,
  whatever Settings -> Behaviour -> "Text fields" says (SPL-976). When the list is closed,
  that setting decides exactly as before. The picker is `composables/useMentionPicker.ts`
  plus `components/MentionList.vue`; the omnibox uses the same pair. There is no second copy.
- **P4** No list inside a ``` code block or on a `/search` line (unchanged omnibox rule).
- **P5** A stored mention renders as a highlighted mention (`MessageRuns` / `MarkdownBlock`, unchanged).

## 3. The poke

- **K1** When a message, a comment, an edit, an issue description or a new issue is
  stored, the author's browser sends one **direct message** from the author to each
  mentioned person or agent:
  `<author-id> needs you in <link>: "<excerpt>"`.
  The wording is an ACTION request: the author is asking them to act.
  - `<link>` is absolute: `<origin>/t/<task_id>` for a card or reply, and
    `<origin>/issues?issue=<KEY>` for an issue.
  - `<excerpt>` is the first 200 characters of the text, one line (newlines -> spaces).
  - The body is English on purpose: agents parse it, and it is content, not UI chrome.
- **K2** For an agent that DM is an ordinary DM to that agent: the hub dispatches it to the
  agent's box, the desk writes it to the inbox, and the pane is poked (spec 028). Only
  the owner's per-agent `.no-poke` mutes it, as for every other DM.
- **K3** Not poked:
  - the author (a self-mention);
  - the agent that the send already addresses (a leading `@CLE-7 ...` in a channel is
    already a dispatch to CLE-7);
  - on an edit, anyone the text mentioned before the edit (no duplicate poke);
  - an id twice in one text (one poke per id).
- **K4** Access: nobody receives an excerpt of something they cannot read.
  - A **channel** that is not a default channel: people must be in the channel's member list,
    and agents in its agent list (`GET /v1/channels/{id}/members`).
    A default channel reads as everyone in the tenant.
    Exception (CLE-77852, owner bug t1 e6c13767): an agent **seated in the workspace**
    (in the tenant roster) but not in the channel is still poked by DM, with no confirmation.
    The author sees a notice (`mention.sent_direct`) instead of the warning.
    Channels stay dispatcher-only, and the orchestrator must still hear its @-mentions.
  - A **DM**: only its two ends can read it, so any third party is refused.
  - An **issue** is tenant-wide (reserved `issues` channel): everyone in the tenant.
  A refused id is not poked. The author sees one warning naming who was not told
  (`mention.not_told`). The stored text is unchanged.
- **K5** Marker: the poke DM is unread in the recipient's direct messages until they open it.
  Opening the DM clears it, and the link inside takes them to the card. That is the
  "needs you" marker, and it adds no new hub state.
- **K6** A poke that fails to send is reported once (`mention.poke_failed`); the author's own
  message is already stored and is not rolled back.

- **K7** A **person** mentioned in a members-only channel they are not in (SPL-2419,
  owner HUM-10, t1 `170c444e`, msg 2ad2a99f): K4 checks agents only, since spec 067 never
  pokes a person, so nothing told the author. The **hub** now posts one automatic line
  right after the stored post, in the same topic: from `HUB-0`, kind note, no agent and
  no AI, naming every such person once:
  `FirstName LastName and nameless do not belong to this channel and cannot see these messages.`
  (`does not belong` for one; three read `A, B and C`). Each person is named by name,
  never by id (SPL-2426, msg a3fe13e3): the display name on file, else the part before
  `@` of the sign-in address, else `a person with no name on file`. Its msg_id is seeded by the post's, so a resend adds none.
  No line for members, the author, agents, a default channel or a DM. Browser sends
  only (`wuiSend`); an edit adds none. Code `internal/hub/mention_non_member.go`, tests
  `mention_non_member_test.go`; the mock twin is `mockNoteNonMembers`
  (`csi-spl-wui/src/utils/spool-client-mock.mjs`, e2e `mention-direct.test.mjs`).
  The line is English on purpose, like K1: it is content, not UI chrome.

## 3a. Note to self (SPL-5372)

The owner, t1 `#spool-hub-bugs` topic `df36f210-eb7c-4ec0-8b58-fc8a6b08e345`,
2026-11-12. A status post meant for himself was taken as an ask, and tagging his
second account got the K7 "does not belong to this channel" line. His picks:

- msg `76800948-b88b-484d-9ee6-a8a128a54b6d` (A): "As proposed: a post tagged only
  to yourself is a note to self, no agent answers".
- poll `f0fc6d7f`, 11:51:26Z (B): "Yes, A and B: also let me tag my second account
  outside the channel".
- poll `3193d41f`, msg `20528286` (C): "Operator-set link only, no self-service
  (quickest)".

The rule:

- N1 A person's browser post addressed only to the person, or the person's linked
  accounts (N4), is a **note to self**. Addressed is every @mention of the body,
  plus the addressee (`to`) when it is a person: the WUI sends a leading @tag as the
  addressee and strips it from the body. A post that also tags anyone else, agent
  or person, is a normal post.
- N2 The hub decides it once, at the send (`wuiRoute`,
  `internal/hub/note_to_self.go`), and stores it as `messages.note_to_self`
  (rdb `0277`). No agent gets it: no dispatch (an explicit addressee is dropped, as
  SPL-2423 does in a humans-only channel), no topic-agent reply, no channel fan-out,
  no fallback. The operator replay of unsigned posts skips it.
- N3 Every other reader honours the flag: the WUI marks the line ("note to self",
  `feed.note_to_self`), and the unanswered sweep counts it `self` and never lists it
  (`do_spl_unanswered_sweep`). A real unanswered ask before the note is still
  listed, aged from that ask.
- N4 Two accounts of one person are linked only by an operator, on a human's order:
  `do_spl_human_link` (`POST /v1/operator/humans/{human_id}/links`, table
  `human_links`, both directions). There is no self-service link and no email
  matching. A link changes no membership.
- N5 K7: neither the author nor a linked account of the author gets the "does not
  belong to this channel" line. Someone else's account outside the channel still
  does.
- N6 The picker offers the reader as `me` (`composer.mention_me`): first on a query
  that starts "me", last on one that matches the reader's own id or name; never on
  an empty query. Picking it writes the reader's own tag.

Tests: hub `note_to_self_test.go` (no agent, no fallback, the flag; the linked
account; controls: self + agent is delivered, an unlinked outsider gets K7),
`human_links_operator_test.go`; sweep `unanswered-sweep.tst.sh` section 14 and
`unanswered-sweep-pg.tst.sh` section 10; action `spl-human-link.tst.sh`; WUI
`mention-autocomplete.test.mjs` (the `me` row).

## 4. Out of scope

- A hub-side poke (MCP / CLI / box senders): the owner's ask is about the fields a person
  types in. The poke itself needs no DB migration; the hub's parts are K7's line and
  section 3a's note to self.
- The message card header (CLE-35016), the submit-key helper (CLE-35017).

<!-- version: 0.3.0 · updated: 2026-11-12 -->
