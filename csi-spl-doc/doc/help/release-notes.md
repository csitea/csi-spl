# How to write the release note of a commit (agents and humans)

This is the ONE place that says how a commit carries its release note. Seed
prompts, gate messages and other docs point here instead of repeating it.

Owner decision, 2026-10-03 (topic 4a31aa83, spec 065, Q1, Q2, Q3, Q5): every
commit explains itself twice, first in plain words for a reader who never
saw the code, then in technical terms. The note rides in the commit message
as trailers; the hub reads them into the release notes table the WUI shows.

## Reading them in the app

Click the version at the bottom of the left pane. On a phone it is on the
status strip. Choose **Release notes**.

The dialog is one table of the 30 latest changes, newest first, already
open: nothing to expand. Its columns:

| column | shows |
|---|---|
| `#` | the change's number, counted from the oldest change (1) up, so the newest row has the highest number and a change keeps its number |
| Version | the version it shipped in, `v1.3.1` |
| Commit | the short commit hash |
| Change | the title of the change; click it for the note: what, how and why, in plain words and then technically |

A version's own row sits above its changes and carries only the version;
on a phone the Version column folds into that row. Closing the dialog (the
X, Escape, or Back on a phone) returns to where you opened it, and **All
versions** in a note returns to the row you clicked.
**you are here** marks the version this tab is running. A change with no
note says **no note**.

The address `/releases/<ref>` opens the same dialog on one change (seven or
more hex characters) or one version (`v` and three numbers); the title of
each row links there. **Copy the link to this note** copies that address.

The rest of this page is how a commit carries the note the dialog shows.

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

## 4. A note that is wrong or missing after the push

A pushed message cannot be edited and history is never rewritten. Attach a
git note carrying the same trailers and push it; the ingest prefers the note
over the message:

```text
git notes --ref=release-notes add -m "Lay-What: ..." <sha>
git push origin refs/notes/release-notes
```

## 5. Where it is enforced

| place | effect |
|---|---|
| pre-push gate, lint part `release-note` | checks every commit in the pushed range for the six trailers (or a form from section 3); it starts as a warning and starts refusing one week after it goes live (owner answer Q4 in the spec) |
| CI, workflow 10 | the backstop for a push that bypassed the hook |
| deploy (20 / 30) | never blocked: a commit without a note is shown with `state=missing` |

## 6. Where it is implemented

The spec is `csi-spl-doc/specs/065-release-notes-table/spec.md`
(sections 4 and 5 hold this rule; section 12 lists the build lanes: the
gate part, the `release_note` table, the hub endpoints, the deploy ingest
and the WUI dialog). How a spool post is written is a different rule:
[how-to-post.md](how-to-post.md).
