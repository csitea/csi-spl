# How to be a dispatcher: a guide for a new seat

For a seat that has never dispatched, on any vendor. It teaches the job as
the claude dispatchers do it today. It adds no rule: every rule here has its
home in another file, named in brackets, and where this page and that home
disagree, the home wins. The commands themselves are in
[runbook-dispatcher.md](runbook-dispatcher.md); this page is the why and the
order.

Owner ask (HUM-10, t1 topic 99ffa592, msg 1515a472, 2026-10-25): a guide for
how to be a dispatcher, kept in Qto and exported as markdown, and the start
of the training of an agy seat for the role. Discussion: t1 #spool-hub-ops
topic 2144cff4.

How to read it: sections 1 to 4 are the daily loop, 5 to 9 the rules around
it, 10 the mistakes we made, each with its fix, and 11 the training steps.
Examples are by id only (message, topic, lane); the full story is in the
master dispatcher's hold note of 2026-10-25 1015Z (`dispatch/hold/` on the
orch box), cited below as "hold note line N".

## 1. The job in one page

You are the front door of the fleet. Every human post and every agent
report reaches you, and you decide what happens to it.

- **The seats.** `001` is the orchestrator, `002` the master dispatcher,
  `003` the failover dispatcher. The letter is the vendor: `c-002` is a
  claude seat, `a-002` an agy seat ([SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md)
  section 1, table at line 31).
- **You take every new post** (a new topic, or a topic no seat owns) while
  you hold the dispatch lease. A post in a topic another seat owns is
  theirs. A post naming the orchestrator is the orchestrator's (roles spec
  section 3, table at line 204).
- **What you take, you own.** You answer it yourself, keep its context and
  answer its follow-ups, until a human closes the topic. You never hand the
  conversation to another agent (roles spec section 3).
- **You do the work yourself** when it fits your session: an answer, a
  status, a lookup, a check. Real lane work (a change to build, test, land,
  deploy) gets a NEW lane, which you start (section 6).
- **You never** run a prd operation your harness refuses, run terraform,
  change members or roles, close agents, or decide for the owner. Those go
  to the orchestrator (section 7).

## 2. What comes in

| channel | what it looks like | where you read it |
|---|---|---|
| the spool | v:1 JSON files in your inbox | `spool recv --as <your id>` |
| a poke line | `: 'SPOOL <your id>: ...'` typed into your pane | only a doorbell: the file is the message; run `spool recv` |
| a channel post | a human post in any workspace, mirrored into your inbox (every role seat is in every channel, roles spec section 2.1) | the same inbox; the whole topic with `spool tail --task <topic>` |
| the unanswered sweep | a note listing topics whose last message is a human's that nobody answered (roles spec section 3.2) | treat each item as a new delivery |
| lease notes | `FLEET LEASE dispatch: you are now ACTIVE` or `STANDBY` | switch mode (section 8); the lease FILE wins over the note |
| queue notes | "SPAWN QUEUE, for a human sender": a human's request was queued or placed | post it as **In progress** in that topic |

Read your inbox at every natural breakpoint: after each post, after each
spawn, before you say anything is done. List it again right before you ack:
`--ack` archives every message in the inbox, also the ones that arrived after
your read ([runbook-dispatcher.md](runbook-dispatcher.md) section 2.1).

## 3. The 3-minute rule

**Every human post is answered within 3 minutes** (owner, t1 d40c3e2f,
2026-10-03; roles spec section 3). After 2 minutes with no agent reply, the
orchestrator takes the post as the backstop and owns the topic.

- The first thing you do with a new topic is **take** it: `do_spl_take`
  posts one line the human sees ("Taken by <id>@<box>: <plan>"), once per
  topic (roles spec section 3, "Taking is a named action").
- A real answer comes next. When the full answer needs a lane, the first
  answer says so and what the lane will deliver.
- The sweep shows an owner post older than 5 minutes while another seat
  holds the lease: hand it to that seat AND escalate at once. A broken
  3-minute rule is worse than a double post
  ([runbook-dispatcher.md](runbook-dispatcher.md) section 5).

## 4. One message, one action

For every message do exactly ONE of these, then archive it
([runbook-dispatcher.md](runbook-dispatcher.md) section 3 has the full
table).

| the message is | you |
|---|---|
| a question or ask you can answer or do now | **answer it yourself**, in the topic |
| real lane work, even in a live lane's code or topic | **spawn a NEW lane** (section 6), say so in the topic, stay the owner, post the result |
| a follow-up to a live lane's own task (an answer it asked for, a correction to the same ask) | **forward it** verbatim to that lane, with topic id and msg id |
| a decision, an approval, a refused prd operation, a role or member change | **escalate** to the orchestrator in one message (section 7) |
| a duplicate, chatter, a poke about something already handled | **archive** it, no reply |

Three tests decide the hard cases:

1. **New work never goes to a running lane.** One agent, one small task
   (roles spec section 1.1). A running lane gets only what belongs to its
   own brief.
2. **A short owner answer** ("A", "yes", "2") answers a question you asked:
   find which one, and state your reading in the reply so the owner can
   correct it.
3. **Never guess who owns a lane.** Read `lane-map.sh`, the registry and the
   topic; when none of them says, ask the orchestrator.

## 5. Verify before GO, ACCEPTED or "Live"

You judge Done. A lane says "landed"; that is its word, not your verdict
([runbook-dispatcher.md](runbook-dispatcher.md) section 4). Three words
need proof you ran yourself.

### 5.1 GO: a lane may push what was reviewed

A reviewer seat (another vendor) reads a lane's review branch and answers
PASS or FAIL. Before you send the lane GO:

- the PASS names a sha, and that sha is the head of the lane's review branch
  now: `git fetch origin && git rev-parse origin/review/<branch>` prints the
  same sha. A push after the review is not reviewed;
- the reviewer RAN the red controls, not only read the author's log
  (case 10.3);
- the GO names its conditions ("1 file, suite and gate green"), so the
  landed result can be checked against them (hold note line 9).

### 5.2 ACCEPTED: the landed commit is the reviewed one, and it works

Before a message whose body starts with `ACCEPTED`:

| check | command |
|---|---|
| on master | `git fetch origin master && git merge-base --is-ancestor <sha> origin/master` exits 0 |
| the landed patch equals the reviewed one | `git show <reviewed sha> \| git patch-id --stable` and the same for the landed sha print the same id; or `git range-diff` of the two |
| nothing empty or clobbered | `git show --stat <sha>`; `wc -l` of a file the lane says it only added to |
| CI | `gh run list --commit <sha>`: every run `completed success` |
| served, when it has a build input | `cd csi-spl-orc && ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd` |

The body STARTS with `ACCEPTED`, or the lane will not exit: lane seeds exit
only on that first word ([runbook-dispatcher.md](runbook-dispatcher.md)
section 4). To refuse, send the lane the exact missing proof.

### 5.3 "Live": on master and served on dev and prd

"Live" means on master AND deployed on both environments. A pushed-only
commit is "on master"; a docs-only commit stays "on master"
([how-to-post.md](../help/how-to-post.md) rule 14). A Live post carries a
sha, a `checked:` line and a `not checked:` line, or the desk action refuses
it (rule 16).

## 6. Starting a lane: the queue

Real lane work is spawned by the dispatcher that took it (roles spec
section 3). Today a lane is a row in the spawn queue that the placer
launches.

1. **One ask, one lane.** Write the brief to
   `/var/spool-hub/dispatch/briefs/<slug>.md` on the orch box, then
   `test -s` it: the spawn starts even when the write failed.
2. **The brief carries** a line-start `Epic: SPL-<n>`, a `Spec:` folder, a
   `Class:` and a `Kind:`; the scope, the files it must NOT touch, how Done
   is proven, the topic it reports on, and "report to the dispatch lease
   holder". `do_spl_spawn_enqueue` refuses a brief without `Epic:` and
   `Spec:` ([developer-guide.md](developer-guide.md) section 2.10.1).
3. **The class** is `ci`, `refactor`, `bug` or `feature`, never guessed
   (`SPAWN_CLASS`). The bands: refactor 20-30%, bug 20-30%, feature the
   rest. `SPAWN_URGENT=1` lifts an owner-reported prd break over its band;
   that is your call. `SPAWN_BYPASS=<owner msg id>` lifts a feature over its
   band ONLY on the owner's explicit ask, never on your own judgement
   ([fleet-rules-index.md](fleet-rules-index.md) section 2, row "spawn
   queue: work classes and bands").
4. **The vendor** comes from the kind: `do_spl_lane_mix` picks it. Personal
   data or secrets go to claude, grok or mistral only, never agy or qwen
   ([runbook-dispatcher.md](runbook-dispatcher.md) section 7).
5. **Enqueue** with `SPAWN_PLACE=<vendor>:<slug>`, so the placer launches it
   itself. Without it the placer hands the row to the orchestrator for a hand placement.
6. **Say in the topic** that a lane has it: one line, what it will deliver.

A **combined seat** is one reviewer that takes several rows at once (for
example one agy seat for rows 1 to 7). It saves seats; its brief lists every
row. Placed on another box, it cannot read your brief files: send each row's
checklist in the message body (hold note line 106).

## 7. Escalation and the never-list

### 7.1 Escalate in one message

To the orchestrator (`--to orchestrator` finds the orch lease holder on any
box), `--kind task`, ONE message: who asked, where (workspace, topic, msg
id), the exact words, what you think it needs. You keep the topic and post
the outcome ([runbook-dispatcher.md](runbook-dispatcher.md) section 8). An
ask is tracked: re-raised while nobody acks it, and sent to the owner after
4 raises (roles spec section 4.3, line 722). Do not chase it by hand.

A question only the owner can answer is posted in the topic as a blocker,
as a `poll` form with every choice an option (section 9).

### 7.2 Never

- a prd mutation, a terraform plan or apply, an IAM or member change
  without an owner message id for THAT operation. "The owner's go" means a
  msg id you can cite; the hold note cites them so (lines 125 and 146);
- force-push in any form (`--force`, `--force-with-lease`, `+ref`), or
  `SPL_PREPUSH_OVERRIDE`
  ([lane-integration-rules.md](lane-integration-rules.md) section 3.2);
- another lane's files: check with
  `lane-map.sh --check <paths> --agent <you>`; exit 3 names the owner,
  exit 4 means ask first ([developer-guide.md](developer-guide.md)
  section 2.1.2);
- a post, a spawn or a route while you are on standby;
- a decision that is the owner's, or an option menu on something a
  standing order already decides.

## 8. The lease, standby and handoff

- **The lease file** `/var/spool-hub/dispatch/lease` holds
  `<id>@<box> <epoch>`. You are the holder only while it names your id AND
  your box AND is at most 180 s old. Read it with
  `LEASE_CMD=show ./run -a do_spl_dispatch_lease` before every post, spawn
  or route ([runbook-dispatcher.md](runbook-dispatcher.md) section 5; roles
  spec section 4.1).
- **Standby**: you read and stay ready. You do not route, spawn or post. If
  you acted while not the holder, stop and tell the orchestrator.
- **Failover** is automatic after 180 s without renewal. A seat stuck on a
  usage-limit banner, a dialog or a login screen is not able, and the lease
  moves: do not fight it.
- **Handoff**: when you lose the lease mid-work, write your open list (owner
  items, GOs owed, landings to check) to a file and send it to the new
  holder. When you get the lease back, re-read the other holder's outbox
  since the handover before you act (hold note lines 31 and 114).
- **Hourly rotation**: a fresh session takes your id. It reads the handoff
  file, then the inbox, then runs the ACK-COMMAND from its seed within
  600 s, and posts nothing about the rotation.

## 9. Posting to the owner

The one rule is [how-to-post.md](../help/how-to-post.md). The parts a
dispatcher uses every hour:

- **State first, in bold**: **Planned, not built yet.** / **In progress** /
  **Landed, not live yet.** / **Live** (rule 15). Until it is live, write
  "will".
- **A Live post carries its proof**: a sha, `checked:` and `not checked:`
  (rule 16).
- **Every question is a `poll` form**, every choice an option; never "say 1
  or 2" (rule 10 and section 7 of that page).
- **Times come from `date -u`**, written with the `Z` (rule 6). Never type
  a time from memory (case 10.2).
- **No filler**: a post that only acknowledges is not sent (rule 7).
- **Cite by id**: `msg:<uuid>`, `topic:<uuid>` (rule 11); a question's own
  `permalink` when you refer to it again (rule 9).
- **No personal data across workspaces, no secrets, no hosts**; write
  "workspace", never "tenant".

## 10. Common mistakes, with the fix

Real cases of 2026-10-25 unless marked; ids only.

### 10.1 A 404 read as a routing bug

The calendar callback answered 404, and the owner was told the route was
broken. The real cause was the feature switched off on the hub; the status
code alone proved nothing. It was corrected in a new owner post with a new
poll (hold note line 145). **Fix:** read the body and the log behind a
status code, or ask the lane that owns the code, before you name a cause.

### 10.2 Times typed instead of read

After a restore, times were written from memory; they were 30 to 60 minutes
late in two owner topics, and both needed a correction (hold note line 128).
**Fix:** every time comes from `date -u` at the moment you write it.

### 10.3 A reviewer that only read the red control

A reviewer answered PASS on a row; its red controls had only been read from
the author's log, not run. Sent back, it ran them and PASSed again; only
then did the lane get GO (hold note lines 165 and 170). **Fix:** a PASS says
what the reviewer ran; a control that was not run is not proof.

### 10.4 Rows lost to a false queue decline

Thirteen queued rows were declined as missing their brief while every brief
was on the orch box. The dispatcher proved it (`test -s` and `wc -l` of each
brief), told the orchestrator, re-queued all thirteen and queued a bug row
for the placer (hold note lines 114 to 117). **Fix:** a decline is a claim
too: check it before you accept the loss.

### 10.5 ACCEPTED sent to a seat still needed

An `ACCEPTED` released a reviewer seat that had been kept for a later
review; the seat exited and the review had to be queued again (hold note
line 41). **Fix:** a seat kept for more work gets a plain verdict ("Verdict
GOOD, NOT an exit"), never a body that starts with `ACCEPTED`.

### 10.6 Landed taken for Done

A lane was about to be closed on "landed" while it had already been sent
back (runbook section 9, 2026-10-11). **Fix:** relay a lane result as "for
your Done verdict"; close only after `ACCEPTED`.

### 10.7 An apply-only lane and its issue

A lane that only runs an apply (no code commit) lands nothing that cites its
issue, so the closer never sets it done. The orchestrator sets the issue
done on the hub, and the lane's exit gate then passes
([lane-issue-and-docs.md](lane-issue-and-docs.md) row 1.6; hold note line
134). **Fix:** when you accept an apply-only lane, say who closes its issue.

### 10.8 A filtered send hid a refusal

`spool-send.sh ... | grep delivery` printed nothing; the send had been
refused and the reviewer was never asked (runbook section 9). **Fix:** read
the send's last two lines unfiltered, and write bodies with `--body-file`:
a backtick inside `--body "..."` runs as a command.

## 11. Training: how an agy seat starts

1. **Read** this page, then [runbook-dispatcher.md](runbook-dispatcher.md),
   then roles spec sections 1, 3 and 4. The first reading is a review of
   this page: say what is unclear or wrong.
2. **Shadow**: on standby, read the master's traffic and write down, per
   message, the one action of section 4 you would take. Compare it with
   what the master did.
3. **Drill**: hold the lease for a short, watched window; the orchestrator
   grades the practice against this page.
4. **Never** take work that carries personal data or secrets: those lanes
   and answers are claude, grok or mistral only (section 6, step 4).
