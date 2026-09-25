# Feature Specification: Download the Gist of a Topic

**Feature ID**: `034-spool-topic-gist` · **Milestone**: M3 · **Status**: Planned
**Created**: 2026-09-25 · **Lane**: topic-gist (docs only)
**Authority**: this file for the request and the open questions; `tasks.md` for
the build steps. Every one of them is Planned.

Status vocabulary follows `../README.md` §2.3: **Implemented** (cited), **Partial**
(missing part named), **Planned**. Nothing in this feature is built. The owner
decides how a download is performed; this file records the request.

## Naming

The owner wrote "jist". This spec spells the same word **gist**. The spelling
says nothing about what the file contains. That is OQ-1.

## The owner's request, verbatim (2026-09-25)

> add the functoinality to enable the download the jist of a topic - write this down in the git-spec I will figure out how exactly to perform that later on

## Clarifications

### Session 2026-09-25

- **The what is written down; the how waits.** **OWNER-STATED** (the quote
  above). Endpoint, renderer and file layout stay unnamed until the owner
  names them.
- **A topic is one `task_id`.** Spec 033: the level-1 opening message
  (`is_parent = 1`, the card in the middle pane) plus that topic's level-2
  lines (`is_parent = 0`, drawn only in the right-hand pane). A gist is of
  that one topic. **INFERRED** from 033, which already states the two levels.
  The level rule stays 033's.
- **Open and a download are different controls.** Spec 033 T016: Open is drawn
  on middle cards only and opens the right-hand topic pane. The pane-header
  link to `/t/<task_id>` was removed (`data-test="live-topic-open"` is absent
  from the topic pane; `LiveFeed` takes `openButton`). Where a download
  control sits is OQ-4.
- **Edits already have a register.** Spec 032: `message_revisions` is
  append-only. The view shows the latest body together with `edited_at`,
  `edited_by` and `revision`. Whether a gist carries the latest body or the
  history is OQ-6.
- **A read is per message.** Spec 003 `contracts/channels-v1.md` §7 (rdb
  `0028`): the topic read returns only the messages that principal may read.
  Refusing a topic does not tell "missing" apart from "not yours" (§7.1).
  Attachments follow §7.5 (rdb `0030`): knowing a `file_id` is not a grant.
  A download stays inside those two rules. Whether "may download" is exactly
  "may read", or a narrower grant, is OQ-7.

## Open questions for the owner

None of these is decided. A later edit records the answer beside the question.

| id | question | options named, none chosen |
|---|---|---|
| OQ-1 | What is the gist? | the full transcript of the topic; a summary; both |
| OQ-2 | When a summary is part of the gist, who writes it? | the hub; an agent; the browser. Falls away if OQ-1 is transcript only |
| OQ-3 | Which file format(s)? | md; txt; json; pdf; more than one of these |
| OQ-4 | Where does the control sit? | the topic pane header; a middle card; some other place. 033 T016 draws Open on middle cards only and leaves the topic pane header without that link |
| OQ-5 | What happens to attachments? | the file bytes are included; the gist carries links only |
| OQ-6 | What does an edit contribute (032 `message_revisions`)? | the latest body only; the revision history |
| OQ-7 | Which topics may a reader download? | The floor is already binding (FR-TG-007): the file contains only messages this reader may read under spec 003 §7 / rdb `0028` (per message, not per thread), and only attachments §7.5 / rdb `0030` already allows. Still open: whether download is exactly that read grant or a narrower one, and what a topic the reader can only partly read returns (the readable lines, or a refusal of the whole topic) |

## User stories

### US1 — download the gist of a topic (P1)

A reader who can already read at least one message of a topic asks for its
gist and receives a file of that one `task_id`. What the file contains is
OQ-1. Its format is OQ-3. The control they used is OQ-4.

### US2 — the file stays inside the read door (P1)

A message the reader cannot read stays out of the file, and so does any
attachment that message carries. A topic the reader cannot open is refused
under the same oracle rule as the topic read (003 §7.1): a missing topic and
a topic they may not read look the same. A topic the reader can only partly
read follows OQ-7, and the hidden lines stay out either way.

### US3 — edits and attachments follow the answer (P2)

Once OQ-5 and OQ-6 have answers, the file treats attachments and
`message_revisions` that way, and still obeys US2.

### US4 — the control sits where the owner says (P2)

The reader starts the download from the place OQ-4 names. Until that answer,
the product draws no download control.

## Functional requirements

| id | requirement | status |
|---|---|---|
| FR-TG-001 | A reader can download the gist of one topic: one `task_id`, its level-1 opening message plus its level-2 lines (033) | Planned — what "gist" contains is OQ-1 |
| FR-TG-002 | The download is a file in the format(s) the owner names | Planned — OQ-3 |
| FR-TG-003 | When the gist includes a summary, the producer is the one the owner names (the hub, an agent, or the browser). When OQ-1 is a transcript only, there is no summary | Planned — OQ-1, OQ-2 |
| FR-TG-004 | The control that starts the download sits where the owner names it. 033 T016 is the neighbouring control: Open is on middle cards only and opens the right pane; the pane header has no Open link | Planned — OQ-4 |
| FR-TG-005 | Each attachment is either included or linked, as the owner names, and remains subject to 003 §7.5 | Planned — OQ-5 |
| FR-TG-006 | An edited message contributes either its latest body or its `message_revisions` history (032), as the owner names | Planned — OQ-6 |
| FR-TG-007 | The file contains only messages this reader may already read (003 `channels-v1.md` §7, rdb `0028`, per message) and only attachments this reader may already fetch (§7.5, rdb `0030`). A refusal does not tell "no such topic" apart from "not yours" (003 §7.1) | Planned — this row is the floor; a narrower grant, and a partly readable topic, are OQ-7 |

## Success criteria

- **SC-TG-1**: After the owner answers OQ-1 through OQ-7, a reader who can
  read a topic receives a file that matches those answers, on dev and on prd.
  Not measured. `tasks.md` T010.
- **SC-TG-2**: A reader who cannot read a message of that topic receives
  neither that message nor its attachment in the file. The case already
  covered for the topic read is `TestMixedTopicHidesTheDMHalf`
  (`csi-spl-api/src/go/spool-hub-api/internal/hub/channel_privacy_test.go`):
  a reader who shares only the channel-tagged line of a topic receives that
  line and not the untagged half. Not measured for a download. `tasks.md` T009.

<!-- version: 0.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T12:11:33Z -->
