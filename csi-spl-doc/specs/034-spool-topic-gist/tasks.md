# Tasks — `034-spool-topic-gist`

Ground rules: `../README.md` §2. Specs are docs; every code change is a task
here. Status: **Implemented** (cite the sha or the command), **Partial** (name
the missing part), **Planned**.

Every task below is **Planned**. Nothing in this lane is built. Where a task
names an open question, it waits for the owner's answer in `spec.md`. The
answer is recorded there. This list does not pick one.

## T001 — record the owner's answers

**Status**: Planned. Waits on the owner. Blocks T002, T004, T005, T006, T007,
T008, and the way T009 looks at the file.

Write the answer next to each of OQ-1 through OQ-7 in `spec.md`.

## T002 — the download contract

**Status**: Planned. Waits on OQ-1, OQ-3, OQ-5 and OQ-6, and on OQ-2 when a
summary is part of the gist.

After those answers, add the request and the file shape under this dir. The
verb, the path and the bytes stay unnamed until then.

FR-TG-001, FR-TG-002, FR-TG-005, FR-TG-006.

## T003 — keep the download inside the read door

**Status**: Planned. The floor does not wait. Anything narrower than the
floor waits on OQ-7.

The download uses the same per-message rule as the topic read (003
`contracts/channels-v1.md` §7, rdb `0028`): only messages this reader may
read, and only attachments §7.5 (rdb `0030`) already lets this reader fetch.
A `task_id` with nothing this reader may read is refused the way the topic
read refuses it, so "missing" and "not yours" stay indistinguishable
(§7.1). OQ-7 may narrow this (for example, refuse a partly readable topic
instead of returning the readable lines). It may not widen it.

FR-TG-007.

## T004 — the summary, when the owner wants one

**Status**: Planned. Waits on OQ-1 and OQ-2.

When OQ-1 is a transcript only, this task is dropped. When a summary is
included, the producer is whichever of the hub, an agent or the browser
OQ-2 names.

FR-TG-003.

## T005 — render the file

**Status**: Planned. Waits on OQ-3, and on OQ-1 for what the bytes contain.

Render the format or formats the owner names: md, txt, json, pdf, or more
than one. A format the owner did not name stays unbuilt.

FR-TG-002.

## T006 — attachments

**Status**: Planned. Waits on OQ-5.

Include the bytes, or emit links, as OQ-5 says. A link is not a grant:
003 §7.5 already treats a known `file_id` as not enough. The included or
linked file is still one this reader may fetch.

FR-TG-005.

## T007 — edits

**Status**: Planned. Waits on OQ-6.

Contribute the latest body (what the view shows) or the `message_revisions`
rows for that message (032: revision 1 is the original body, captured at the
first edit), as OQ-6 names.

FR-TG-006.

## T008 — the control

**Status**: Planned. Waits on OQ-4.

Draw the control where the owner says. The neighbouring fact, which is not
a placement: 033 T016 puts Open on middle cards only (`LiveFeed`
`openButton`, passed by the channel feed, the DM feed and the lobby) and
removed the pane-header Open link (`data-test="live-topic-open"` is absent
from the topic pane). Spec 005 draws the control OQ-4 names. The label
waits with the placement.

FR-TG-004.

## T009 — the download leaks nothing the reader cannot read

**Status**: Planned. The cases do not wait. The shape of the assertion waits
on OQ-3, because that answer says how a hidden line would have appeared.

Cover at least:

- a message the reader cannot read is absent from the file;
- an attachment of that message is absent;
- the mixed topic in `TestMixedTopicHidesTheDMHalf`
  (`internal/hub/channel_privacy_test.go`) contributes only the line that
  the reader may see;
- a `task_id` the reader cannot open is refused without admitting it exists
  (003 §7.1).

Run the cases on the same stores the topic-read tests already use.

SC-TG-2.

## T010 — measured on dev and on prd

**Status**: Planned. Waits on T002 through T009, and on the owner's answers
in T001.

After a build that follows those answers, a reader who can read a topic
receives a file matching OQ-1 through OQ-7 on dev and on prd, and the T009
cases pass against both. Record the build, the tree and n. This spec ships
no deploy of its own.

SC-TG-1.

<!-- version: 0.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T12:11:33Z -->
