# How to write the release note of a commit (agents and humans)

> Generated from qto doc `1a149a6e-9ded-40a5-87ee-b05668d169a0`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

This is the ONE place that says how a commit carries its release note. Seed
prompts, gate messages and other docs point here instead of repeating it.

Owner decision, 2026-10-03 (topic 4a31aa83, spec 065, Q1, Q2, Q3, Q5): every
commit explains itself twice, first in plain words for a reader who never
saw the code, then in technical terms. The note rides in the commit message
as trailers; the hub reads them into the release notes table the WUI shows.

<a id="ws-doc-b39cd2f2-a665-4456-8fc0-5505d3fd1e28"></a>
## Reading them in the app

Click the version at the bottom of the left pane. On a phone it is on the
status strip. Choose **Release notes**, on the right of the card's last
row (**Powered by Csitea** is on its left).

The dialog is one table of the 30 latest changes, newest first, already
open: nothing to expand. **Load older versions** at the end of the table
reads the next older versions; keep going until the table ends with
**This is the first entry**, the oldest change kept. Its columns:

| column | shows |
|---|---|
| `#` | the change's number, counted from the oldest change (1) up, so the newest row has the highest number and a change keeps its number |
| Version | the version it shipped in, `v1.3.1` |
| Commit | the short commit hash |
| Committed | when the change was committed, `YYYY-MM-DD HH:MM` in your time zone; hover for the seconds |
| Change | the title of the change; click it for the note: what, how and why, in plain words and then technically |

A version's own row sits above its changes and carries only the version.
Closing the dialog (the X, Escape, or Back on a phone) returns to where you
opened it, and **All versions** in a note returns to the row you clicked.
**you are here** marks the version this tab is running. A change with no
note says **no note**.

On a phone the list is tighter and has no header row. Each version's row
stays at the top while you scroll its changes, and shows the time of its
newest change. A change is one line: its title (cut short when it is long)
and its time, with its `#` and short commit hash in small print below. Tap
anywhere on the row to read the note; the note shows the full title and
**Committed** with its time. **Load older versions** is the wide button at
the end of the list.

On a desktop the keys `j` and `k` move between the version rows (past the
last one they load older versions), `Enter` opens that version alone, `h`
and `l` there show the older and the newer version, and `Escape` goes back
to the list; `Escape` in the list closes the dialog. **Settings →
Behaviour → Keyboard shortcuts** turns the letter keys off. All keys:
[keyboard-shortcuts.md](keyboard-shortcuts.md), section 9.

The address `/releases/<ref>` opens the same dialog on one change (seven or
more hex characters) or one version (`v` and three numbers); the title of
each row links there. **Copy the link to this note** copies that address.

The rest of this page is how a commit carries the note the dialog shows.

<a id="ws-doc-a835da78-2fa9-47e4-8d41-3848e07c7086"></a>
## 1. The rule

1. The note is the LAST paragraph of the commit message: six trailers, one
   per line, nothing after them.
2. The six keys, spelled exactly: `Lay-What:`, `Lay-How:`, `Lay-Why:`,
   `Tech-What:`, `Tech-How:`, `Tech-Why:`.
3. Each trailer is ONE line (a trailer cannot wrap), at most ~200
   characters, and never empty.
4. The `Lay-*` lines use no code names, file names, ids, acronyms or jargon.
   Test: would someone who has never seen the code understand it?
5. The `Tech-*` lines name the module, the mechanism and the root cause.
6. No personal names, box tags, hostnames or customer names in any trailer:
   the row is shown in the WUI, so the shipped-tree bans apply to it.
7. The subject line and the optional technical body stay as they are today.

<a id="ws-doc-16a6fa34-e1d0-454f-b6a5-b4bba2e411bc"></a>
## 2. Example

```text
fix(wui): the unread badge stays after a channel is read

<optional technical body, as today>

Lay-What: The red "unread" dot now disappears once you have read a channel.
Lay-How: The app now tells the server you read it, the moment you open it.
Lay-Why: You saw a dot for messages you had already read, so it was useless.
Tech-What: WUI marks the channel read on open; the hub clears unread_count.
Tech-How: ChannelView calls POST /v1/channels/{id}/read on mount; the store resets the counter in one UPDATE.
Tech-Why: The read call was only sent on scroll-to-bottom, so short channels never sent it.
```

<a id="ws-doc-15c9c3a2-8593-40cc-8b46-6ce4161dcaf5"></a>
## 3. Special commits

| case | what the note needs | shown as |
|---|---|---|
| merge commit | nothing (trunk is linear; one that appears is skipped) | not shown |
| revert | the `git revert` message plus one `Lay-Why:` line | `state=revert`, linked to the reverted row |
| doc-only (every touched path is `.md`) | `Lay-What:` and `Lay-Why:` suffice (the "how" of a doc change is "edited the text") | a normal row |
| test-only, CI-only, lint baseline bump | `Release-Note: skip` plus one `Lay-Why:` line | `state=skip`, collapsed |

Example of a skip:

```text
test(iac): cover the empty-range case of check-pre-push

Release-Note: skip
Lay-Why: Adds a test only; nothing a user sees changes.
```

<a id="ws-doc-bf253d8c-10b8-4674-a204-13932caf84cd"></a>
## 4. A note that is wrong or missing after the push

A pushed message cannot be edited and history is never rewritten. Attach a
git note carrying the same trailers and push it; the ingest prefers the note
over the message:

```text
git notes --ref=release-notes add -m "Lay-What: ..." <sha>
git push origin refs/notes/release-notes
```

<a id="ws-doc-390ed6f6-9ad1-4386-81e7-6866ef8025a2"></a>
## 5. Where it is enforced

| place | effect |
|---|---|
| pre-push gate, lint part `release-note` | checks every commit in the pushed range for the six trailers (or a form from section 3); it starts as a warning and starts refusing one week after it goes live (owner answer Q4 in the spec) |
| CI, workflow 10 | the backstop for a push that bypassed the hook |
| deploy (20 / 30) | never blocked: a commit without a note is shown with `state=missing` |

<a id="ws-doc-393e4721-7d9b-4ca8-a830-106faae76bd0"></a>
## 6. Where it is implemented

The spec is `csi-spl-doc/specs/065-release-notes-table/spec.md`
(sections 4 and 5 hold this rule; section 12 lists the build lanes: the
gate part, the `release_note` table, the hub endpoints, the deploy ingest
and the WUI dialog). How a spool post is written is a different rule:
[how-to-post.md](how-to-post.md).
