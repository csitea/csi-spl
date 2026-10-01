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

## 4. Out of scope

- A hub-side poke (MCP / CLI / box senders): the owner's ask is about the fields a person
  types in. The hub is unchanged, and no DB migration is needed.
- The message card header (CLE-35016), the submit-key helper (CLE-35017).

<!-- version: 0.1.0 · updated: 2026-09-26 -->
