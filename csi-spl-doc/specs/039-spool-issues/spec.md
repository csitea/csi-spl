# Feature Specification: Issues, the Way Linear Keeps Them

**Feature ID**: `039-spool-issues` · **Milestone**: M3 · **Status**: Implemented (MVP; "Next" list open)
**Created**: 2026-09-26 · **Lane**: issues (CLE-34993 lead, GRK-3519 web UI)
**Authority**: this file for the behaviour and its rules;
`contracts/issues-v1.md` for the wire; `tasks.md` for what is built, with the
sha and the check for each item. Status vocabulary: `../README.md` §2.3.

Builds on `003` (the hub, the view door, the browser socket), `005` (the
3-pane WUI), `025` (tenant roles), `033` (message levels), rdb 0021
(fail-closed RLS) and 0028 (the read door).

## The owner's request, verbatim (2026-09-26, prd #spool-hub-devel, topic 9c19bfe9)

> after the event log we must create the issues section in the left most bar ,
> the issues those must be shown the way Linear shows the issues , keeping
> still this 3 vertical lines structurre though , but with the attributes and
> behavious on how linear does that

Refined the same morning (binding where it differs from the first request):

> each issue must have prio , deadline , level , titgle , description ( which
> will be shown only on the right side always ), the deadline must be a
> calendar control , which has also time , one opened in the right side , one
> shoud be able to sor t the issues by prio , level , filter them by each
> attribute , once the agents start working on somehting instead of writing a
> "task" type of msg , they should formulate the issues and start working on
> them ... aka discussions where things are communicated should go into the
> discussions toipics and msgs , but concrete work , which has been specsed and
> advancedments of it must go to the issues section . The issues section should
> be third actually after the channels and not after the event log . Whenever
> something is not clear how it should wor on the issues - it should work as in
> the Linear SAAS , becuase it is he best

**Rule of interpretation (owner):** when this spec is silent, behave like Linear.

## Layout (3 panes kept)

- **Rail**: an `Issues` tab, the THIRD tab, directly after Channels.
- **Middle pane**: the issue list, grouped by status in workflow order, each
  group with its count, collapsible. A row shows the priority icon, the key,
  the title, the labels, the level, the deadline and the assignee. It never
  shows the description.
- **Right pane**: the opened issue: title and description (markdown) edited
  in place, every attribute as a picker, the deadline as a calendar control
  with time, then the issue's discussion.

## Attributes (FR-001)

| attribute | values | notes |
|---|---|---|
| key | `<prefix>-<number>`, e.g. `SPL-12` | one team per tenant for now, prefix `SPL`; numbers from a per-tenant counter, never reused |
| title | 1..255 characters | required |
| description | markdown, <= 20000 characters | right pane only |
| status | Backlog, Todo, In Progress, In Review, Done, Canceled | Linear's workflow; default Backlog |
| priority | No priority (0), Urgent (1), High (2), Medium (3), Low (4) | Linear's scale |
| level | none (0), XS (1), S (2), M (3), L (4), XL (5) | the owner's "level" = Linear's t-shirt estimate |
| assignee | a member `HUM-*` or a roster agent, or nobody | an id nobody in the tenant can act on is refused |
| labels | the tenant's label catalogue (name + colour), <= 20 per issue | |
| deadline | date AND time; stored UTC, shown in local time | a calendar + time control |
| parent | another issue of the tenant | sub-issues; no cycles. UI next |
| created by / at, updated by / at | | stamped by the hub |
| completed at / canceled at | | set when the status enters Done / Canceled, cleared when it leaves |
| discussion | an ordinary spool topic on the issue's `task_id` under the reserved channel id `issues` (§Discussion space) | comments are reply-level messages (033 level 2), so edit, emoji, files and agents work unchanged, and they never become cards in any feed |

## Behaviour

- **FR-002** List grouped by status in workflow order, with counts per group.
- **FR-003** Sort by priority (default; urgent first, no priority last), level
  (largest first), deadline (soonest first, none last), updated, created
  (newest first). Ties: the newest number first.
- **FR-004** Filter by EVERY attribute: status, priority, level, assignee
  (incl. `me` and `none`), label, deadline range. The hub answers the same
  filters (`GET /v1/view/issues?...`) so an agent gets what a person sees.
- **FR-005** Keyboard (list focused), Linear's keys: `C` create, `J`/`K`
  move, `Enter` open, `S` status, `P` priority, `L` label, `A` assign, `Esc`
  back. The same pickers inline on the row and in the right pane.
- **FR-006** Every change reaches every open tab of the tenant as a live
  `issue` / `issue_label` frame: no reload. A reload shows the same state.
- **FR-007** Access: every member reads (`topics.read`); a member writes with
  `notes.send` (every role, like Linear's "anyone on the team files an issue").
  A non-member reads nothing (403 at the tenant door, as every view); an
  issue number of another tenant reads 404.
- **FR-008** Agents do concrete, specced work as issues (owner): a seated
  agent creates and updates issues and posts its progress as a comment on the
  issue, over its own box socket, as itself (the agent must be one its box
  announced). Talk stays in topics and messages. Front ends: `spool issue`,
  the MCP tool, `do_spl_issue_*` desk actions.
- **FR-009** No delete: Canceled is the terminal status (Linear archives;
  archive is next).

## MVP now / next

- **Now**: FR-001..FR-009 except the sub-issue UI.
- **Next**: sub-issue UI, several teams / prefixes per tenant, cycles and
  projects, bulk select (`X`), archive, an activity history per issue,
  `is:issue` in the omnibox (with the search lane, CLE-34992).

## Discussion space (SPL-68)

Owner, 2026-09-26: "the tasks channel should be removed - issues should be
used for it".

Until hub 0.7.2 an issue's discussion was a topic in `#tasks`, a default
channel. `#tasks` is gone; the discussion is stored under the reserved
channel id `issues` (`store.ChannelIssues`), which is NOT a channel:

| rule | how |
|---|---|
| never listed | no `channels` row; `GET /v1/view/channels` drops it; no sidebar, picker or channel page shows it |
| never created | `CreateChannel` refuses it (`ChannelReserved`), and rdb 0050 adds `CHECK (channel_id NOT IN ('issues', 'tasks'))`, like `general` |
| readable | by every member of the tenant, exactly as the issue list is (topics.read): the read doors treat it as public (`store.PublicChannels`), so who may read the issue may read its thread |
| writable | a browser `send` with the issue's `task_id` and `channel` `issues` (the hub knows the id without a row); an agent comments through the `issue` frame, never by posting a box envelope into it (no agent is a member) |
| out of lists | `TopicQuery.NoIssues` still hides the topic from every list (§7 of issues-v1) |

The retired id `tasks` stays public, hidden and reserved in the hub so a hub
could roll before the data moved. rdb `0050_issue_channel_replaces_tasks.sql`
then moved every issue topic's messages (task or parent task = an issue's
`task_id`) to `issues`, moved every other `#tasks` message to `#lobby` (all of
them were live-proof artefacts, measured per env before writing it), dropped
`tasks` from the tenant seed trigger and deleted every tenant's `#tasks` row.

## Data

rdb `0047_issues.sql`: `issue_counters`, `issue_labels`, `issues`; RLS in the
0021 fail-closed form plus the operator policy on all three. Applied to dev
and prd with `do_spl_db_bootstrap` before any hub that reads them rolled.

<!-- version: 0.7.0 · updated: 2026-09-26 · last-edit: 2026-09-26T08:03:23Z -->
