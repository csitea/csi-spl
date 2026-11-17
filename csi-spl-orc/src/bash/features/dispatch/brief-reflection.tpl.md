# Lane brief: the night's reflection, night of {NIGHT} (one small task, refactor, from do_spl_reflection_gather)

Class: refactor
Kind: specs_and_docs
Epic: SPL-2129
Spec: csi-spl-doc/specs/166-orchestrator-daily-rhythm
Discussion: {DISCUSSION}

Queued by `do_spl_reflection_gather` (spec 166 row B8, section 3.3), placement
slug `reflection-{NIGHT}`. Window: {SINCE} .. {UNTIL}, the last 24 h. Report
to the CURRENT dispatch lease holder (`cd csi-spl-orc && LEASE_CMD=show ./run
-a do_spl_dispatch_lease`) on task `dispatch-reflection-{NIGHT}`, kind result.
Never post in an owner topic or a channel.

## Why

Owner HUM-10, t1 msg 421e479a: "internal reflections ...
shoould be performed each 24h, starting from 20:00 till 07:00 CET". Poll
d102c775 Q4 A: "A Qto doc page per day in the system workspace, linked from
the morning owner digest; never git, the repo is public".

## Origin topics

The live topics of the night's owner messages (section 4 of the gathered
file), newest first, without the backlog topic, relay hashes and archived
topics. `Discussion: {DISCUSSION}` above is only the placer's fallback: it is
the workspace's backlog topic, and the commit-links gate refuses a commit
whose issue links nothing else (owner HUM-10, t1 ef94396b msg 61bf7791;
SPL-5829).

{ORIGIN_TOPICS}

## Do

0. Link your own issue to every origin topic above, as the discussions it
   came from: `spool issue link --ref <your key> --discussion <topic>` (it
   posts nothing in the topic). With none, your issue keeps the fallback
   only; nothing of yours lands, so no gate reads it.
1. Read the gathered file below (also on the queuing box at `{GATHER_FILE}`).
   For each owner message id in its section 4, read the message
   (`spool tail --task <topic>` on the hub) and mark the **corrections**: the
   owner saying a rule was broken or a result was wrong, each with its msg id.
2. Write ONE Qto doc page in the workspace `system`, titled
   `Reflection {NIGHT}`, through `do_spl_desk_doctree` under your own seat
   in the operator workspace: `ENV=prd TENANT_ID=t1 DESK_AGENT=<you>
   DOCTREE_FS=repo` (the system docs are that tree; `TENANT_ID=system` has no
   desk seat on either box). No seat of your own: send the `DRY_RUN=0`
   command list to the dispatch holder instead. Its sections: CI reds,
   reverts, lanes ended without
   landing, owner corrections (msg id each), what each correction asks the
   fleet to change, the class share and the zombie count, the stalled wip
   issues (its section 7: each key, its title and its last commit; nobody
   carries them, so the owner should not have to ask for their status), and
   at most 3 proposed rows.
3. Each proposed row is refactor or bug, one small task, with its own
   `Class:`, `Epic: SPL-<n>` and `Spec: <spec folder on origin/master>` lines, and a
   `Discussion: <topic>` line naming the live topic it came from: the origin
   topic of the owner message it answers, else the discussion of the issue or
   lane it fixes. Never `{DISCUSSION}` alone: its lane's issue would link only
   the backlog topic and its push would fail commit-links. The holder places
   the row on that line. A row with no such topic is not sent as a spawn
   request: name it on the page as a question for the holder.
   Send each to the dispatch holder as a spawn request (kind task); it goes
   through the normal enqueue gates (`do_spl_spawn_enqueue`,
   `SPAWN_CLASS=refactor|bug`), so it runs the same night.
4. **Never git**: no commit, no file in the repository, no branch. The owner's
   messages may carry private matter; quote ids, not text, outside the page.
5. Result: the page's doc id and title, the counts per section, the stalled
   wip keys (section 7), the rows sent.
   Nothing to land: end your issue with `LANE_ISSUE_OP=end` and the page id as
   the reason once the result is sent.

## The gathered file

{GATHER}
