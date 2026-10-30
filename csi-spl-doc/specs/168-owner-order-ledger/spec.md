# 168 Owner-order ledger: an explicit owner order is written down, copied into every brief, and gated

Version: v0.1 (2026-10-30). Status: **Draft**, for R7 review. Nothing below
is built.
Issue SPL-4343 · Epic SPL-2398 · Spec home of the build:
[spec 157 dispatch automation](../157-dispatch-automation/spec.md) · Class
feature · Kind complex_coding · Placement slug `c001-s168-owner-order-ledger`
· Lead c-673.

Source: owner HUM-10, csitea topic `4027d060-2863-447a-9dd5-51aa2cdca419`.
Related: [lane issue and docs](../../doc/md/lane-issue-and-docs.md) (the
spawn files a lane's issue: the model for the brief copy-in),
[pre-push gate](../../doc/md/pre-push-gate.md), [fleet rules
index](../../doc/md/fleet-rules-index.md).

Placeholders, because the repo is public: `<CUSTOMER-REPO>` a source
repository outside csi-spl that the fleet works in, `<RUNBOOK-DIR>` a
run-book folder of it. Paths: `orc/` = `csi-spl-orc/src/bash/`, `sa/` =
`orc/features/spawn-agents/`. Every file named was read on origin/master
`c6b902ca7` (2026-10-30).

## 1. The owner's words (verbatim)

Topic 4027d060, 2026-10-30, read from the prd hub with `do_spl_db_query`:

- 5d07fc06 (08:23Z): "how can we ensure from now on ,when EXPLICITLY tell
  you to ensure / do somethign that you WILL DO IT"
- fa9108eb (08:26Z), poll 10af03a3: "Answer: A — Build (a) ledger + (b)
  briefs carry it + (c) commit/push gate, as its own lane"

The three parts as the poll put them:

- (a) a LEDGER of explicit owner orders: his msg id, the order word for
  word, the repo and the paths it covers;
- (b) every lane and sub-lane brief that touches a covered path carries the
  order WORD FOR WORD, copied in by the spawn, so no agent has to remember
  it;
- (c) a commit/push GATE that refuses a change to a covered path unless the
  commit cites his go msg id for that change.

## 2. Why: the case of 2026-10-29

On 10-29 (msg 6f9ae3ad) the owner ordered that the run-books of a
`<CUSTOMER-REPO>` keep their contents and change only their file
structure. The order lived only in chat. A sub-lane's brief did not carry
it, and the sub-lane removed a checkout step from one run-book and changed
its content after the order (two commits in `<CUSTOMER-REPO>`). Nothing
in the fleet held the order where the next agent would meet it: not the
brief, not the seed, not a gate.

## 3. The ledger (part a)

### 3.1 Home: outside git, per box

The ledger is data, not code: `${OWNER_ORDER_DIR:-$SPOOL_ROOT/owner-orders}/<repo>.jsonl`,
one file per repository, `<repo>` the basename of the repository's
top-level directory (`csi-spl`, `<CUSTOMER-REPO>`), mode 660, group
`spool-agents` like the rest of the spool root.

- An order on a customer repository quotes the customer's paths and often
  the customer's words. csi-spl is public, so no ledger file is ever
  committed, for any repository: csi-spl holds only the code that reads and
  writes it, and its tests use synthetic orders.
- The ledger lives on the box that holds the repository's checkouts. A
  repository checked out on two boxes needs its ledger on both; the copy is
  build row B2 (section 6), because the copy-in of part (b) is its first
  reader on another box.

### 3.2 Format: an append-only event log

Each line is one JSON object. Nothing is ever rewritten; the state of an
order is the fold of its lines.

`add`, one per order:

| field | what |
|---|---|
| `op` | `add` |
| `order` | the owner's message id, the full uuid (the order's key) |
| `repo` | the repository basename, the same as the file name |
| `paths` | the covered paths, repo-relative globs: `*` one path segment, `**` any depth, `?` one character |
| `text` | the order WORD FOR WORD: the message body, or a contiguous excerpt of it |
| `source` | `hub` (fetched from the hub and compared), or `given` (typed by the writer; see 3.3) |
| `gate` | `go` (part c refuses an uncited change to a covered path) or `none` (parts a and b only) |
| `ts` | when the owner sent it (ISO 8601 UTC) |
| `owner`, `topic` | the owner's id (`HUM-<n>`) and the topic's task id |
| `expires` | optional ISO time after which the order no longer applies; empty = until lifted |
| `note` | optional: the writer's one line on why these paths, or the owner's words that set `expires` |
| `by`, `at` | the agent that wrote the line, and when |

`lift`, at most one per order: `op`, `order`, `lift_msg` (the owner's
message that lifts it), `reason`, `by`, `at`.

An order is **active** when it has an `add`, no `lift`, and no `expires` in
the past.

### 3.3 Who writes an entry, and from what

- **Who**: the seat that receives the order in the owner's topic: the
  dispatch holder, or the relay seat of that channel. It writes the entry in
  the same turn it acknowledges the order, and says `Ledger: <id8>` in its
  reply.
- **From what**: the hub's copy of the owner's message, never the writer's
  memory or a relay's summary. `ORDER_FROM_HUB=prd` makes the action read
  the message from the prd hub (read-only `do_spl_db_query`), refuse a
  sender that is not an owner (`HUM-<n>`), and refuse an `ORDER_TEXT` that
  is not a contiguous part of the body. Without a hub (no key on the box)
  the writer types the text and the entry says `source: given`; B2 and B3
  print that word next to the order so a reader knows it was not compared.
- **What counts as an explicit order**: an owner message that tells the
  fleet to do, keep or never do something ("do not modify", "you MUST",
  "EACH TIME", "ensure"), or overrules an earlier rule. A question, an
  opinion and an approval of one change are not. When the receiving seat is
  unsure, it asks the owner with a poll (`how-to-post.md` section 7); it
  never decides an order away.
- **Which paths**: the narrowest globs that hold every file the order names
  or plainly means. A repository-wide order (a version bump on every push)
  covers `**`.

### 3.4 Lifted, expired, superseded

- Only the owner lifts an order: `ORDER_CMD=lift` needs the owner's lifting
  message id (`ORDER_LIFT_MSG`) and a reason. No agent lifts an order
  because it seems done or old.
- An order that is meant for a time ("today", "until the release") is
  added with `expires`; the writer quotes the owner's words that set it in
  `note`.
- An owner message that overrules an earlier rule of his is itself an
  order (gate `none`): it is added, and the order it overrules, if it is in
  the ledger, is lifted citing it.

### 3.5 The action

One named action, `cd csi-spl-orc && ./run -a do_spl_owner_order`
(`orc/run/spl-owner-order.func.sh`), `ORDER_CMD`:

| `ORDER_CMD` | does | exit |
|---|---|---|
| `add` | appends one `add` line; a dry run unless `DRY_RUN=0` | 0 added, 0 the same order already there (idempotent), 3 the id is there with another text, paths or gate, 1 refused input |
| `list` | the active orders (all repos, or `ORDER_REPO`); `ORDER_ALL=1` adds lifted and expired; `ORDER_JSON=1` prints the folded orders as JSON lines | 0 |
| `lift` | appends one `lift` line; a dry run unless `DRY_RUN=0` | 0, 3 already lifted, 1 refused |
| `match` | the active orders of `ORDER_REPO` whose globs match any of `ORDER_PATHS`, JSON lines | 0 none match, 3 one or more match |

`match` is the one reader parts (b) and (c) call, so both read the same
rule of what is covered.

## 4. The brief copy-in (part b)

When the spawn starts a lane (`sa/scripts/spawn-window.sh`, next to
`sw_issue`, which already reads the brief at that point), a new step
`sw_owner_orders` runs `match` for the lane's repository with every
repo-relative path the brief names. If the brief names no path, every
active order of that repository matches: a lane whose scope is unknown
gets them all. Each match is appended to the brief file, before the seed is
written, as:

    ## Owner orders on these paths (copied by the spawn from the ledger; obey them word for word)

    - <msg id> (<ts>, <owner>, gate <go|none>, source <hub|given>), paths <globs>:
      > <text, every line quoted>

- The section is written by code, so no lane, orchestrator or relay has to
  remember the order. A sub-lane goes through the same spawn, so it gets
  the same section; a lane that hands work on by message only (no spawn)
  quotes the section into its message.
- The seed says, in one line, that the brief may carry owner orders and
  that they rank above the rest of the brief.
- The spawn prints `PLAN owner-orders <n> copied` in its plan, and the
  count lands in the spawn journal, so a reviewer sees it was done.
- Collision note: `place_box` of `spawn-window.sh` belongs to another lane
  today (c-688); B2 adds a separate function and one call next to
  `sw_issue`, and checks the lane map first.

## 5. The gate (part c)

A change to a path covered by an active `gate: go` order is refused unless
the commit cites the owner's go for that change: a trailer
`Owner-go: <msg id>` naming an owner message (not the order's own id) in
the order's topic.

- **csi-spl**: a part of the pre-push hook (`sa/hooks/pre-push`): for each
  commit being pushed, `match` its changed paths; a covered path with no
  `Owner-go:` trailer refuses the push and prints the order word for word
  and the trailer to add. `SPL_PREPUSH_OVERRIDE` does not pass it (the same
  rule as the force-push part).
- **A repository outside csi-spl**: the fleet does not install hooks in it
  and never edits its `.git/config` (it may travel with the repository to
  another network). The gate is a harness guard instead, the shape of the
  force-push guard (`sa/lib/force-push-guard.inc.sh`): before an agent runs
  `git commit` or `git push` in a checkout whose repository has a ledger,
  it runs `match` on the staged or pushed paths and denies the command with
  the same message. Installing a harness hook is the owner's step (the
  agent hook of spec 093 needed it too); B3 lands the guard and its test,
  and asks for the install.
- **Verifying the go**: with a hub, the gate reads the cited message and
  refuses one that is not from an owner; without one it checks only the
  form and says so.
- Orders with `gate: none` are never gated: parts (a) and (b) only.

## 6. Build rows

| row | builds | test | lands |
|---|---|---|---|
| B1 | the ledger format, `do_spl_owner_order` (add, list, lift, match; `ORDER_FROM_HUB`), the seed entries of section 7 written on the box that holds `<CUSTOMER-REPO>` | `orc/tests/spl-owner-order.tst.sh`, each refusal with a red control | this lane, after the spec is accepted |
| B2 | `sw_owner_orders` in the spawn (section 4), the seed line, the `PLAN` line; the ledger copy to the other box (`ORDER_CMD=sync` over the box link) | a spawn dry run with a fixture ledger: a matching brief gets the section, a non-matching one does not; CONTROL: an empty ledger adds nothing | its own lane, placed by c-001 after B1 is accepted |
| B3 | the pre-push part for csi-spl and the harness guard for other repositories (section 5) | a fixture repo: an uncited change to a covered path is refused, the cited one passes, an uncovered path passes; CONTROL: `gate: none` is never refused | its own lane, after B2 |

## 7. The seed entries (B1)

Written to the ledger of `<CUSTOMER-REPO>` on its box, never to git: the
five orders the brief lists plus 8618db98, which the channel's relay seat
named as the second half of f23f4159 (same topic, one minute later). Their
texts are read from the hub at write time, so this spec quotes none of
them. msg ids: 6f9ae3ad (`<RUNBOOK-DIR>` contents frozen, gate `go`),
41c3e63f and 55358cc0 (the release run-book's first-time steps, gate
`none`), f23f4159 and 8618db98 (every push raises the version, `**`, gate
`none`: the version rule is a check of its own, not a go), c16f3a1d (an
earlier test rule on the prd release pages overruled, gate `none`).

## 8. Risks and open checks

- R1: two boxes, two ledgers. Until B2's sync lands, an order added on one
  box is unknown to a spawn on the other. B1 writes on the box that holds
  the repository; the report of B1 names the box.
- R2: a brief that names no path gets every order of its repository (4).
  For a repository with many orders that is noise; if it is, B2 narrows by
  the brief's `Paths:` line, not by guessing.
- R3: `match` uses globs; an order whose words cover more than its globs
  (a writer's narrow pick) is gated narrower than the owner meant. The
  writer picks the globs; the reviewer of the add (the relay's reply shows
  them) catches a wrong pick.
- R4: an owner-go trailer can be forged by an agent. The hub check of 5
  makes the forgery a citation of a real owner message; whether that
  message was a go for this change stays a review question.
