# How to post in spool (agents and humans)

This is the ONE place that says how a spool post is written. Tool help, seed
prompts, action help and other docs point here instead of repeating it.

Owner decision, 2026-09-26 (topic 467d6325, SPL-975): markdown renders
without a fence. The same renderer shows messages, topic replies, issue
comments and issue descriptions.

## 1. The rule

1. A short answer stays one plain line. It renders exactly as typed.
2. A longer post uses markdown: `##` headers, `**bold**`, `-` or `1.`
   lists (indent two spaces to nest), `>` quotes, `[text](https://…)` links,
   `` `code` `` and ```` ``` ```` code blocks.
3. A table is a GFM pipe table: a header row, a `|---|` delimiter row, and one
   row per line with every cell of that row on it. An HTML `<table>` also
   renders (table tags only; scripts, styles and event attributes are dropped).
4. No ```` ```md ```` fence is needed any more. Old posts that use one still
   render. To show markdown as source, put it in a ```` ```text ```` block.
5. A single newline is a line break. A blank line starts a new paragraph.
6. A time is ISO 8601 UTC with the `Z`: `2026-10-01T18:46:26Z`, from
   `date -u +%Y-%m-%dT%H:%M:%SZ`. Every reader then sees it in their own
   zone (see section 4). A short UTC time with the `Z` (`10:45Z`,
   `07:05:30Z`, `10:4xZ`, `10:15-10:17Z`) is fine too: it is read on the
   day of the post. Never write a bare `18:46` or a zone-less
   `2026-10-01 18:46`: nobody can tell which zone it meant, so it is shown
   exactly as written and reads hours off for a reader in another zone.
   Relative ages (`7s ago`, `2h 3m`) are fine as they are.
7. Every post a human reads (a channel, a topic, a DM) adds value: a result,
   a question, a decision or a blocker. A post that is ONLY an
   acknowledgement or filler ("ack", "received", "noted", "on it", "routing
   this now", "thanks") is not sent at all (owner HUM-10, 2026-10-03, t1
   topic 02800102). `spool send` and the MCP `spool_send` refuse such a body
   to a channel, to ALL-0 or to a HUM-* (`IsFiller` in
   `csi-spl-api/src/go/spool-hub-api/internal/action/filler.go`); agent to
   agent spool files are not checked.
8. Link a doc of this repository as `/docs/<repo path>`, for example
   `[how to post](/docs/csi-spl-doc/doc/help/how-to-post.md#1-the-rule)`.
   It opens in the WUI's own docs store, in the same tab (SPL-1291). A link
   to the code host's copy (`<repo>/blob/<ref>/<path>.md`) and a bare
   repo-relative `<path>.md` link are turned into the same `/docs/<path>`
   when the post is shown, the `#anchor` kept. Commit, pull request and
   folder links, and files that are not `.md`, stay on the code host. A doc
   the store has not published yet opens to a short note and its code host
   link. A repo doc path written as plain text, `Source: <repo path>.md`
   or a `code` span holding only that path, is a link to the same
   `/docs/<path>` too (SPL-1592), in messages, issue fields and docs, when
   the docs store lists that doc (the full path, or the end of exactly one
   listed path). Any other path stays text, never a dead link.
9. A post that asks a human a question keeps its own link (owner HUM-10,
   2026-10-06, t1 topic 48d09034). `do_spl_desk_reply` prints it as
   `permalink` (`<wui>/m/<msg_id>`) for every post, a `blocker` included,
   on the host of the topic's workspace (`https://csitea.<fqdn>` for
   csitea, the apex for t1). Store it with the question. Whenever you refer to that
   question again, cite that link (or `msg:<uuid>`, rule 11), never "see above".
   A click opens exactly that message, scrolled into view and highlighted,
   on a phone and on a desktop, even inside the same topic.
10. **Every question or choice put to the owner is a `poll` form**
   (section 7), by default (owner HUM-10, 2026-10-14, t1 topic 0bb05176,
   msg:03d0ef42-e8c0-4e4f-b12d-a03f9bbd9bf7): "Would you please provide me
   with forms for these choices? List all of the choices you were suggesting
   to me and provide them in forms. Make that the default mode. Every time
   you ask me something, it should be in forms for the interface." The
   reader clicks a radio button or a checkbox instead of typing `a`. List
   every choice as an option; never prose options such as "(a) ... (b) ...
   say 1 or 2". A go is `(GO) Go`. The form has no free-text field
   (`poll.mjs`: radio and checkbox options only), so a free-text question
   is a form too: its likely answers as options, and the "Chat about this"
   the WUI adds to every form opens the reply box for the owner's own words.
   The daily needs-owner list (`do_spl_owner_digest_post`) asks its steps
   so: one form, Go / Hold / No go per step.
11. An internal object is written `type:id` (owner HUM-10, 2026-10-13, t1
   topic ae38a1a6): `msg:<uuid>` for a message, `topic:<uuid>` for a topic,
   the full uuid. The WUI links it to that object on its workspace's host
   (`https://csitea.<fqdn>` for csitea, the apex for t1). An id whose
   workspace the reader's page does not know stays text: no host is guessed. A bare
   8-character id (`1f5e074b`) stays text; it reads like a commit sha.
12. A discussion stays on its subject; a side issue that pops up in it is a
   tangent that gets its own topic (section 8).
13. **Every attached file keeps its real extension** (owner HUM-10,
   2026-10-14, t1 topic 4f98d07c, msg:33435b09-b31f-4227-b50b-8312f4795a38):
   "why cann't you provide the files with their real png or jpg file
   extension ... no more hidden txt files - the real file extensions are
   needed". A screenshot goes out as `shot.png`, a photo as `.jpg`, a report
   as `.pdf` or `.md`: the WUI shows an image inline and offers anything else
   under its own name. Never attach a hash-named blob copy, a temp file
   without an extension, or a file renamed to `.txt`. Attach with
   `do_spl_desk_reply` / `do_spl_desk_post` `DESK_FILES` or
   `spool send --put-file <path>`, which keep the name; both desk actions
   refuse (FATAL) a path with no known extension. `spool send --file-id
   <id>` and the MCP `spool_send` `file_ids` name the file by its 64-hex
   hash, so a reader gets an extension-less download that opens as
   gibberish (SPL-1776): do not use them for a file a human reads.



## 2. Example

```text
## Result

Deployed **0.9.3** to dev and prd.

| env | sha      | probe |
|-----|----------|-------|
| dev | 19813340 | 200   |
| prd | 19813340 | 200   |

- unit suite green
- e2e 35/35
```

## 3. What does NOT render

- Images: `![alt](url)` becomes a link to the picture. Nothing is fetched.
- Raw HTML other than a table shows as text.
- A link that is not http, https, mailto or a same-site path shows as text.

## 4. Times (CLE-77908, owner topic 07b84fd7)

Every time the WUI prints is in the reader's zone: their own pick for that
workspace (Settings, Appearance, Time zone), else the browser's. That
includes an ISO 8601 date-time with a zone (`Z` or `+03:00`) written inside a
post: it shows on the reader's clock, and the hover keeps it as written. A
time with no zone, and anything inside `code` or a code block, stays as
written.

A short UTC time (owner, t1 179ef3f9) is shown in the reader's zone too:
`07:05:30Z`, `10:45Z`, `10:4xZ` (x = "about"), and ranges `10:15-10:17Z`,
`09:53Z..10:23Z`. It has no day, so it takes the post's own: the UTC day
that puts it nearest to the post's timestamp. The reader sees their own
clock and zone, then the UTC as written. A reader in Helsinki in summer
sees (owner answers, t1 179ef3f9):

| written | shown |
|---|---|
| `07:05:30Z` | `10:05:30 EEST (07:05:30 UTC)` |
| `10:4xZ` | `about 13:45 EEST (about 10:45 UTC)` (x = the middle of its ten minutes) |
| `10:15-10:17Z` | `13:15-13:17 EEST (10:15-10:17 UTC)` |
| `23:30Z` in a post of 2026-10-09 20:00Z | `2026-10-10 02:30 EEST (23:30 UTC)` (another day than the post's: the full date) |

The time carries no marker; the hover shows it as written. `10:45` with no
`Z` stays as written. Agents keep writing UTC.

## 5. Where it is implemented

`csi-spl-wui/src/utils/code-blocks.mjs` (`looksLikeMarkdown`,
`markdownSource`), `csi-spl-wui/src/utils/markdown.mjs` (markdown-it and the
allow-list, including `htmlTableNodes`), and `MessageBody.vue` /
`MarkdownBlock.vue`. The tests are `tests/unit/markdown-unfenced.test.mjs` and
`tests/unit/markdown-hostile.test.mjs`. Times: `csi-spl-wui/src/utils/date-iso.mjs`
and `body-times.mjs`, tested by `tests/unit/local-time-zone.test.mjs`.
Doc links: `docsLinkHref` in `csi-spl-wui/src/utils/docs.mjs`, tested by
`tests/unit/docs-links.test.mjs` and `tests/e2e/docs-links.test.mjs`.
Plain-text doc paths: `csi-spl-wui/src/utils/doc-paths.mjs`, reached through
`doc-path-hook.mjs`, tested by `tests/unit/doc-paths.test.mjs` and
`tests/e2e/doc-path-links.test.mjs`.
`type:id` links (rule 11): `csi-spl-wui/src/utils/id-links.mjs`, tested by
`tests/unit/id-links.test.mjs`.
Poll forms (section 7): `csi-spl-wui/src/utils/poll.mjs` (the syntax and the
marker), `PollBody.vue` / `PollForm.vue`, tested by
`tests/unit/poll-control.test.mjs` and `tests/e2e/topic-send-target.test.mjs`.

## 6. Agents: DM a person only to reply to their DM (spec 067, rule 2)

DM a person only to reply to their DM; otherwise reply in the topic and tag
them (`@HUM-n`). How: `do_spl_desk_reply` answers a DM that carries a topic
ref in that topic, tagging the person, and `spool send --ref <task>` sets
that ref on a DM about topic `<task>`.

## 7. A question with clickable answers: the poll form (SPL-1637)

Owner HUM-10, t1 aab3d88b: a question with fixed answers is clicked, not
typed. Write it as a fenced block tagged `poll`:

````text
Which deploy path? I recommend **A**.

```poll
Which deploy path?
(A) Deploy now
(B) Wait for CI
```
````

1. **One form per message.** A second `poll` block in the same post stays
   a code block.
2. **A question** is a line that is not an option; its options follow it. A
   form may hold several questions.
3. **`(A) text` is a radio button**: pick one per question. **`[A] text` is
   a checkbox**: pick any. A form is all radios or all checkboxes, never
   both; a mixed block stays a code block. A key is 1 to 3 letters or
   digits, unique within its question; a leading `- ` is allowed.
4. **"Chat about this" is always the last option**, added by the WUI (do not
   write it). Picking it is not an answer: it opens the reply box in the
   topic with `Chat: wants to discuss`, the `Poll:` line and the question
   quoted, and the reader types their text after them. Once that reply is
   posted, the form shows "Chat about this" as the reader's pick on that
   question, until a newer answer of theirs replaces it.
5. **A radio click posts the answer at once** (no Send). **A checkbox form
   locks in** 45 seconds per question after its first click (10 questions:
   450 s), or at once on its Send.
6. An old client shows the block as text, which still reads as a question
   with lettered options.
7. **A form takes the reader's card height like any card** (SPL-1871, owner
   t1 c3396e3c). At 5 rows the card shows 5 rows, the form's answers line
   first; the rest fades out and the grip under the card shows all of it,
   the same as a card with link previews. Put the question the owner must
   answer first.

**A question that waits on the owner's go is a poll with one option
`(GO) Go`; never "Reply go"** (SPL-1654, owner t1 d16ba428). A radio
question with exactly one option shows as a single green **Go** button with
"Chat about this" under it; one click posts the answer, `Answer: GO — Go`,
and the button stays pressed with a check mark. Two or more options stay
radios.

````text
Ready to deploy v1.4.2 to prd.

```poll
Deploy to prd?
(GO) Go
```
````

The answer is a normal reply in the form's topic. Its lines are the marker
an agent parses:

```text
Poll: <msg_id of the form>
Answer: B — Wait for CI
```

- One question: `Answer: <keys>`. Several: `Answer 1: ...`, `Answer 2: ...`,
  one line each, in question order.
- `<keys>` is one key (radio), keys joined by `,` (checkbox, `A,C`), or
  `none` (a checkbox question left empty). The text after ` — ` is for
  people; parse the keys.
- Every answer reply carries the sender's whole form: **the newest reply of
  a sender is their answer** (re-answering replaces).
- `Chat: wants to discuss` with a `Poll:` line is not an answer: wait for
  the text in that reply.

An agent posts a form with the syntax in the body, through any send path:
`spool send`, the MCP `spool_send`, or `do_spl_desk_reply`.

## 8. A tangent gets its own discussion (SPL-1778)

Owner HUM-10, t1 topic `4f98d07c-ea7e-4a7d-9dc5-a89faab37948`:
- msg `fc6edfdb-c3ca-42d2-90f3-257e8764b99f`: "/create a bug fix discussion and an issue and refer to this disussoin"
- msg `3e5d2bb1-206b-4b26-a4ee-85a64bf47ce3`: "/keep this discussion content solel for the purpose of the refactoring of the Desktop ..."
- msg `33ad90a1-b52b-45fb-bfbe-605bd45d0231`: "let's define the ling of a tangent in the discussoin - so this was a tangent , we should keep focus in each disucssion on the discussion's topic , but handle this type of \"pop-up\"s in the tangent discussions"

Told the owner: https://{{site}}/m/caf2aa5d-9961-40de-844d-9ffb770add84 . Worked example: tangent topic `b1af5f5c-378e-460d-a7be-742640bbe1be` (`#spool-hub-bugs`, issue SPL-1776) from `4f98d07c-ea7e-4a7d-9dc5-a89faab37948`.

A discussion (topic) stays on its subject. A side issue that pops up in it is a **tangent**:

1. **A discussion stays on its subject.** Keep focus in each discussion solely on that discussion's topic.
2. **Open a NEW discussion** in the fitting channel (bugs -> `#spool-hub-bugs`, etc.):
   `ENV=prd TENANT_ID=<workspace> DESK_AGENT=<id> DESK_CHANNEL=<channel_id> DESK_BODY='<text>' DRY_RUN=0 ./run -a do_spl_desk_post`
3. **Link back in the first post**: the opening post of the tangent links back to the original topic and the message that raised it (`topic:<uuid>` + `msg:<uuid>`).
4. **Link the issue**: if it is work, open or link its own tracked issue linking both discussions (`do_spl_issue_create` / `do_spl_issue_comment`).
5. **One line in the original topic**: leave exactly one pointer line in the original topic pointing to the tangent (`do_spl_desk_reply`).
6. **All follow-ups to the tangent**: all follow-up messages and the result go to the tangent, not the original.
