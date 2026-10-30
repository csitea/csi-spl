# 168 Owner-order ledger: an explicit owner order is written down, copied into every brief, and gated

Version: v0.2 (2026-10-30). Status: **Draft**, for R7 re-review. v0.2 folds
the R7 review of c-697 on v0.1 (FAIL, its W1-W12; its log
`review-s168-d65c6c7d2.md` in c-697's spool dir) and the dispatch
holder's fix list (c-002, msg a25f69ef). Built: B1, B2 (section 6; B2
SPL-4357, how it was built: section 4.1 and 3.6), B3 (SPL-4372, section 5.1).
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

On 10-29 (msg 6f9ae3ad) the owner ordered that a run-book folder of a
`<CUSTOMER-REPO>` keep its contents and change only its file structure. The
order lived only in chat. A sub-lane's brief did not carry it, and two
commits in `<CUSTOMER-REPO>` changed a run-book's contents after the
order. Nothing
in the fleet held the order where the next agent would meet it: not the
brief, not the seed, not a gate.

## 3. The ledger (part a)

### 3.1 Home: outside git, per box

The ledger is data, not code: `${OWNER_ORDER_DIR:-$SPOOL_ROOT/owner-orders}/<repo>.jsonl`,
one file per repository, mode 660, group `spool-agents` like the rest of
the spool root.

`<repo>`, the **repo key**, is the basename of the directory that holds the
repository's git common dir:
`basename "$(dirname "$(git rev-parse --path-format=absolute --git-common-dir)")"`.
Every worktree of csi-spl gives `csi-spl`; the top-level directory of a
worktree would give the worktree's own name (`c-697-rv`) and find no ledger
(c-697 W3). The action derives it from `ORDER_REPO_DIR=<any checkout>`;
callers never compute it themselves.

- An order on a customer repository quotes the customer's paths and often
  the customer's words. csi-spl is public, so no ledger file is ever
  committed, for any repository: csi-spl holds only the code that reads and
  writes it, and its tests use synthetic orders.
- The ledger lives on the box that holds the repository's checkouts. A
  repository checked out on two boxes needs its ledger on both; the copy is
  build row B2 (section 6), because the copy-in of part (b) is its first
  reader on another box: `ORDER_CMD=sync` (section 3.6).

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
| `gate` | `go` (part c refuses any uncited change to a covered path), `content` (a pure rename or move passes; a change to a file's content needs the go; section 5) or `none` (parts a and b only) |
| `ts` | when the owner sent it (ISO 8601 UTC) |
| `owner`, `topic` | the owner's id (`HUM-<n>`) and the topic's task id |
| `expires` | optional ISO time after which the order no longer applies; empty = until lifted |
| `note` | optional: the writer's one line on why these paths, or the owner's words that set `expires` |
| `by`, `at` | the agent that wrote the line, and when |

`lift`, at most one per order: `op`, `order`, `lift_msg` (the owner's
message that lifts it), `source` (`hub` or `given`), `reason`, `by`, `at`.

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
  message id (`ORDER_LIFT_MSG`) and a reason. A `go` or `content` order is
  lifted only with `ORDER_FROM_HUB`: the action reads the lifting message
  from the hub and refuses one that is not on it or not from an owner
  (`HUM-<n>`); without a hub it refuses (c-697 W2). A `none` order may be
  lifted without the hub; its lift line says `source: given`. No agent
  lifts an order because it seems done or old.
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
| `add` | appends one `add` line; a dry run unless `DRY_RUN=0` | 0 added, 0 the same order already there (idempotent), 3 the id is there with another text, paths or gate, 2 ledger unreadable, 1 refused input |
| `list` | the active orders (all repos, or `ORDER_REPO`); `ORDER_ALL=1` adds lifted and expired | 0, 2 a ledger unreadable |
| `lift` | appends one `lift` line; a dry run unless `DRY_RUN=0` | 0, 3 already lifted, 2 ledger unreadable, 1 refused |
| `match` | the active orders of the repo whose globs match any of the paths (`ORDER_PATHS` comma-separated, or `ORDER_PATHS_FILE` one per line) | 0 none match, 3 one or more match, 2 ledger unreadable or malformed, 1 refused input |

- `match` is the one reader parts (b) and (c) call, so both read the same
  rule of what is covered.
- **Fail closed** (c-697 W1): a ledger that cannot be read, or holds a line
  that does not parse, is exit 2, never 0. Parts (b) and (c) treat every
  exit but 0 and 3 as REFUSE: a broken ledger stops the spawn or the push
  and names the file, it never reads as "no order" (W9: a refused path is
  exit 1, which also refuses).
- **No order text in a log** (c-697 W8): `./run` copies stdout to its log
  under `$HOME/var/log`, so `list`, `match` and a dry-run `add` print the
  id, state, gate, source, owner, time and paths, never the text. The full
  orders, text included, go as JSON lines to `ORDER_OUT=<file>` (mode 600)
  for the program that asked.
- Exit 3 of `match` makes `./run` print its `ERROR ... status 3` lines; for
  a caller that is the answer "covered", not a fault (c-697 W10).

### 3.6 The copy to the other box (B2)

`cd csi-spl-orc && ORDER_CMD=sync TO_BOX=<box> DRY_RUN=0 ./run -a do_spl_owner_order`
copies, both ways, the lines one box's ledger lacks from the other's, over
the ssh link this box has to `TO_BOX` (`BOX_SSH_<BOX>`, else the satellite
alias; the satellite cannot reach the PC, so the PC runs it). The far box
must answer with its own `BOX_TAG` from its box env file; the far step runs
as that file's `OWNER_USER`, the spool's owner.

- **Append-only, idempotent**: a line is only ever appended. A line already
  on the other side (the same `op` and `order`, and the same text, paths,
  gate and repo, or the same `lift_msg`) is skipped, so a second run copies
  nothing and changes no byte.
- **Conflict**: the same order with another text, paths, gate or lift
  message on the two boxes is exit 3 and nothing is written on either side;
  the owner decides which is his.
- **Not more trusted on arrival** (c-697 N3): a copied line keeps its own
  `source` and gains `synced_from` (the box it was read on) and `synced_at`.
  A hand-appended `source: hub` lift on one box arrives marked as a copy on
  the other; B3 re-reads every lift on the hub, never trusting the word.
- **Verified or refused**: each append runs under the ledger's flock and
  only while the file still has the sha256 the plan was made against (else
  `result changed`, run again); then the file is read back, and every copied
  line must be in it and the file must parse. A sync that cannot verify the
  far file refuses (exit 1).
- Exit: 0 synced or nothing to copy, 1 refused input, the box unreachable or
  not verified, 2 a ledger unreadable or malformed on either box, 3 a
  conflict. stdout carries counts and ids, never an order's text.
- A dry run (the default) reads both ledgers and prints the counts
  (`sync <repo> here=<box> box=<box> push=<n> pull=<n>`), writing nothing.
- Test: `csi-spl-orc/src/bash/tests/spl-owner-order-sync.tst.sh`.

## 4. The brief copy-in (part b)

A brief names every repository the lane works in on a `Repo: <key>` line
(one per repository; `csi-spl` too). The spawn cannot learn from prose that
a lane works in `<CUSTOMER-REPO>`, which is the 10-29 case (c-697 W4).

When the spawn starts a lane (`sa/scripts/spawn-window.sh`, next to
`sw_issue`, which already reads the brief at that point), a new step
`sw_owner_orders` runs `match` for each `Repo:` of the brief with every
repo-relative path the brief names. A repository the brief names with no
path gets all its active orders. A brief with no `Repo:` line gets the
active orders of every ledger on the box: a lane whose scope is unknown
gets them all. A `match` exit that is not 0 or 3 refuses the spawn. Each
match is appended to the brief file, before the seed is written, as:

    ## Owner orders on these paths (copied by the spawn from the ledger; obey them word for word)

    - <msg id> (<ts>, <owner>, repo <key>, gate <go|content|none>, source <hub|given>), paths <globs>:
      > <text, every line quoted>

- The section is written by code, so no lane, orchestrator or relay has to
  remember the order. A sub-lane goes through the same spawn, so it gets
  the same section.
- A hand-off by message only (no spawn) is memory again (c-697 W12), so
  `spool-send.sh` gets the same step: a `--kind task` message whose body
  carries a `Repo:` line has the matching orders appended by code before
  it is sent. B2 builds both.
- The seed says, in one line, that the brief may carry owner orders and
  that they rank above the rest of the brief.
- The spawn prints `PLAN owner-orders <n> copied` in its plan, and the
  count lands in the spawn journal, so a reviewer sees it was done.
- Collision note: `place_box` of `spawn-window.sh` belongs to another lane
  today (c-688); B2 adds a separate function and one call next to
  `sw_issue`, and checks the lane map first.

### 4.1 As built (B2)

- The reader is one file, `sa/lib/owner-orders.inc.sh` (`oo_section`),
  called by `sw_owner_orders` in `sa/scripts/spawn-window.sh` (right after
  `sw_issue`) and by `send_owner_orders` in `sa/scripts/spool-send.sh`. It
  runs `do_spl_owner_order` in a subshell, not through `./run`, so no order
  line reaches a `./run` log.
- The paths of a brief are the words with a slash in them that are not
  absolute, not a URL and hold no `..` (`oo_text_paths`). A directory named
  in a brief matches only an order glob that matches the directory's own
  path; R2 stays open.
- Refusals: a ledger that refuses (any exit but 0 and 3), or a brief the
  orders cannot be written into, stops the spawn with exit 15, the claim
  released; spool-send refuses the task with exit 3, nothing written.
- Nothing twice: a brief (or a task body) that already carries the section
  gets nothing more, and a respawn (`SPAWN_REUSE_ID=1`) keeps its brief.
- A dry run changes no brief: it prints `PLAN owner-orders <n> copied ->
  <brief>`; `SPAWN_OWNER_ORDERS_PREVIEW=<file>` receives the brief as the
  spawn would write it. A real spawn prints the same line on stderr (its
  stdout stays `<ID> <PANE>` for its callers).
- The spawn journal (`$SPOOL_ROOT/dispatch/attempts.tsv`) row of
  `spawn-window.sh` has an 8th column, `owner_orders=<n>`; every reader
  reads columns 1 to 6.
- The seed line is written only when the brief carries the section (the
  seed size cap of `test-spawn-seed-size.sh` left a mistral seed 17 bytes):
  "Your brief carries OWNER ORDERS ...: obey them word for word; they rank
  above the rest of the brief and above this seed."
- A placed lane gets its orders on the box that launches it (the remote
  serve's own spawn-window), from that box's ledger: section 3.6 keeps the
  two ledgers equal.
- Test: `sa/tests/test-owner-orders-copy-in.sh`.

## 5. The gate (part c)

A change to a path covered by an active `gate: go` order is refused unless
the commit cites the owner's go for that change: a trailer
`Owner-go: <msg id>` naming an owner message (not the order's own id)
whose body names the order's id8, in any topic (a go given in a lane topic
or as a poll answer counts when it names the order; c-697 W11).

- **Both sides of a rename** (c-697 W5): the changed paths are read with
  `git diff --name-status --no-renames` (or both columns of
  `--name-status`), never `--name-only`, which shows only the new side: a
  file moved out of a covered folder and edited in the same commit would
  escape. B3's test carries that case.
- **`gate: content`** (c-697 W6): the 10-29 order was "contents frozen,
  structure may change". A change passes when every covered path is a pure
  rename or move (`R100`, the same blob on both sides); any content hunk on
  a covered path needs the go. With `gate: go` every rename needs the go
  too, so the owner would pay for what he allowed.
- **A section inside a file** ("do not touch section 3") cannot be
  expressed by paths: such an order is copied into briefs (part b) and its
  keeping is a review question; the gate covers the whole file or nothing.

- **csi-spl**: a part of the pre-push hook (`sa/hooks/pre-push`): for each
  commit being pushed, `match` its changed paths; a covered path with no
  `Owner-go:` trailer refuses the push and prints the order's id and the
  trailer to add. `SPL_PREPUSH_OVERRIDE` does not pass it (the same rule as
  the force-push part). `git push --no-verify` skips every hook, so the
  harness guard below covers csi-spl as well.
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

### 5.1 As built (B3)

- **One decision, three callers.** `ORDER_CMD=gate` of `do_spl_owner_order`
  (`orc/run/spl-owner-order-gate.func.sh`) reads the ledger, the paths, the
  trailers and the hub. Its callers only find the commits, all through
  `sa/lib/owner-order-guard.inc.sh`:
  - the pre-push hook (`sa/hooks/pre-push`, `oog_pre_push`): every pushed
    ref but a delete and `refs/heads/wip/*` (the watchdog's backup of
    unfinished work, spec 102 5.4), `<remote sha>..<local sha>`, or for a
    new ref every commit no remote-tracking ref holds. It runs before every
    override branch: `SPL_PREPUSH_OVERRIDE=1` does not pass it;
  - the `owner-orders` part of `do_check_pre_push`
    (`csi-spl-iac/src/bash/run/check-pre-push.func.sh`): `PRE_PUSH_BASE..HEAD`,
    every tier and mode, right after `stale-tree`, never cached;
  - the harness guard `owner_order_guard_check "<command>" [<cwd>]` and its
    hook `sa/scripts/owner-order-guard-hook.sh <claude|grok|agy|qwen>`.
- **Which paths (N2).** `gate: go` reads `git diff --name-status
  --no-renames`: both sides of a move, so a file moved out of a covered
  folder is covered, edited or not. `gate: content` reads rename detection at
  100% (`-M100%`): an `R100` pair (the same blob) passes on both sides, every
  other change of a covered path needs the go. Merge commits are not read
  (their first-parent diff is the other side's work); the commits they bring
  are, one by one.
- **The go.** A trailer `Owner-go: <msg uuid>` on the commit (`git log
  --format=%(trailers:key=Owner-go)`); for a commit not made yet, every
  `Owner-go: <uuid>` (or `--trailer Owner-go=<uuid>`) in the command text,
  heredoc bodies included, and in a `-F` file. It must be a full uuid and
  not the order's own id.
- **The hub check (N1, N3).** `ORDER_GO_HUB` = `dev`, `prd` or `none`; unset
  is `prd` when the box holds the prd project's SA key (the one
  `do_spl_db_query` reads), else `none`. The pre-push hook, the
  `owner-orders` part and the harness guard pass a caller's `ORDER_GO_HUB`
  on only as `dev` or `prd` (R7 c-718 W1): a pusher's own `none` is ignored,
  said in the output, and the box default applies. With a hub the cited
  message must be on it, from an owner (`HUM-<n>`), and its body must carry
  the marker for the order, as whole words, case-insensitive: a go
  `go <id8>` (also `go for <id8>`, `go: <id8>`) or a lift `lift <id8>`
  (`lift order <id8>`); a lift counts as a go, a go never lifts. A bare
  mention ("keep <id8>, do NOT change it") or a negated one ("do not go
  <id8>") is no go (c-718 N3, c-001 053664e0).
  The same check re-reads every lift of a go or content order: a lift whose
  message fails it does not lift (the gate prints `WARN ... does not hold`),
  whatever the ledger line's `source` says. `ORDER_CMD=lift` with
  `ORDER_FROM_HUB` now refuses a lifting message that does not name the
  order too. Without a hub only the form is checked, and every PASS line
  says `NOT hub-checked`; the pre-push hook prints those lines on a pass too
  and logs it (`PASS-UNCHECKED` in its pre-push.log). A hub read that fails refuses (rc 1); each
  message is read once per run.
- **Exit and output.** 0 passed, no ledger, or nothing covered; 3 refused;
  2 the ledger is unreadable or malformed, or its dir cannot be searched
  (c-718 W2: never read as "no ledger"; the harness guard refuses a ledger
  dir it cannot list); 1 refused input or a failed hub
  read. Every caller refuses on anything but 0. A refusal prints the commit,
  the order's id8, gate, source and the covered paths (at most 5), and the
  line to add; never the order's text.
- **The commit guard reads the index**, which the harness hook sees before
  the command runs: a `git add` / `rm` / `mv` earlier in the same command,
  `commit -a`, a pathspec, `--include` or `--only` make it read every
  tracked change plus the untracked files instead (a superset, fail closed).
  `--amend` reads against `HEAD^`.
- **A repository with no ledger is never asked**: the lib checks for
  `<OWNER_ORDER_DIR>/<repo key>.jsonl` before it starts `./run` (about 1.5 s,
  plus about 4 s per hub read).
- **A caller's seams never hide the box ledger** (R7 c-718 W3). The pusher's
  own `OWNER_ORDER_DIR` or `SPOOL_ROOT` picks the caller's ledger dir, so the
  lib also reads the box ledger dir `/var/spool-hub/owner-orders` whenever
  the caller's is another one, and runs the gate once per dir that holds the
  repo's ledger (pre-push hook, `owner-orders` part and harness guard). Every
  seam not at its default (the caller's ledger dir, `OOG_BOX_LEDGER_DIR`, the
  tests' stand-in for the box dir, and `OOG_ORC_DIR`, the dir whose `./run`
  runs the gate) prints an `owner-orders: NOTE` line on every run; the
  pre-push hook prints it on a pass too and logs it (`PASS-SEAM` in its
  pre-push.log), with or without a ledger found.
- **Installing the harness hook is the owner's step** (R5, R6). Nothing in
  the fleet adds it. For claude, one entry in `PreToolUse` of the harness's
  `settings.json`, next to the force-push guard's:
  `{"matcher": "Bash", "hooks": [{"type": "command", "command": "bash <csi-spl checkout>/csi-spl-orc/src/bash/features/spawn-agents/scripts/owner-order-guard-hook.sh claude"}]}`
  (grok, agy and qwen: the same script with their name, in their own hook
  config, as for `force-push-guard-hook.sh`).
- Tests: `orc/tests/spl-owner-order-gate.tst.sh` (the decision, the hook and
  the guard on a fixture repo, synthetic orders, a hub stub),
  `csi-spl-iac/src/bash/tests/check-pre-push-owner-orders.tst.sh` (the
  part), `orc/tests/spl-owner-order.tst.sh` (N1 for lift).

## 6. Build rows

| row | builds | test | lands |
|---|---|---|---|
| B1 | the ledger format, `do_spl_owner_order` (add, list, lift, match; `ORDER_FROM_HUB`), the seed entries of section 7 written on the box that holds `<CUSTOMER-REPO>` | `orc/tests/spl-owner-order.tst.sh`, each refusal with a red control | this lane, after the spec is accepted |
| B2 | `sw_owner_orders` in the spawn (section 4), the seed line, the `PLAN` line; the ledger copy to the other box (`ORDER_CMD=sync` over the box link) | a spawn dry run with a fixture ledger: a matching brief gets the section, a non-matching one does not; CONTROL: an empty ledger adds nothing | built (SPL-4357, sections 3.6 and 4.1) |
| B3 | the pre-push part for csi-spl and the harness guard for other repositories (section 5) | a fixture repo: an uncited change to a covered path is refused, the cited one passes, an uncovered path passes; CONTROL: `gate: none` is never refused | built (SPL-4372, section 5.1); the harness hook install is the owner's |

## 7. The seed entries (B1)

Written to the ledger of `<CUSTOMER-REPO>` on its box, never to git, with
`ORDER_FROM_HUB=prd`, so their texts come from the hub and this spec quotes
none of them: the five orders the brief lists (6f9ae3ad, 41c3e63f,
55358cc0, f23f4159, c16f3a1d) plus 8618db98, which the channel's relay seat
named as the second half of f23f4159 and the dispatch holder confirmed
(msg eaa69bc8). Gates: 6f9ae3ad `content` (`<RUNBOOK-DIR>`), every other
one `none`. Their paths are chosen at write time and shown in the B1
report, outside git.

## 8. Risks and open checks

- R1: two boxes, two ledgers. B2's sync (3.6) copies them, but only when
  it is run: an order added on one box is unknown to a spawn on the other
  until the next sync. Running it on a schedule is not built yet.
- R2: a brief that names no path gets every order of its repository (4).
  For a repository with many orders that is noise; if it is, B2 narrows by
  the brief's `Paths:` line, not by guessing.
- R3: `match` uses globs; an order whose words cover more than its globs
  (a writer's narrow pick) is gated narrower than the owner meant. The
  writer picks the globs; the reviewer of the add (the relay's reply shows
  them) catches a wrong pick.
- R4: an owner-go trailer can be forged by an agent. The hub check of 5
  makes the forgery a citation of a real owner message that names the
  order; whether that message was a go for this change stays a review
  question.
- R5: no gate on `<CUSTOMER-REPO>` until the owner installs the harness
  guard of B3 (an owner step, like spec 093's agent hook). Until then that
  repository has parts (a) and (b) only; B3's report asks for the install
  and names the window.
- R6: `git push --no-verify` skips the csi-spl pre-push part; only the
  harness guard catches it (5), so the same install closes it for csi-spl.
- R7: the copy-in reads the brief's `Repo:` lines. A brief written without
  one gets every ledger's orders (4): noisy, never silent.
