# Runbook: the dispatcher seat (any vendor)

> Generated from qto doc `95d05cb6-ecfe-47ae-9884-c99a3eaf8fcb`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

For whoever holds the dispatcher role (`c-002` master, `c-003` failover), on
any agent vendor: a Claude seat, a Grok seat or another. Everything here is a
shell command, a file or a spool message; nothing needs a vendor's own slash
commands, skills or memory files. The role itself is defined in
[SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md) sections 1, 3 and 4;
this page is how to do it, and points there for the why.

Owner ask: "Grok as a second leader" (t1 #spool-hub-ops, topic `ee1e58d5`).
The orchestrator's page is [runbook-orchestrator.md](runbook-orchestrator.md).

Conventions on this page:

- `ORC` = `/opt/csi/csi-spl-desk-cron/csi-spl-orc` (the box's desk checkout),
  `SA` = `$ORC/src/bash/features/spawn-agents/scripts`,
  `SPOOL` = `SPOOL_ROOT=/var/spool-hub <agent user home>/.local/bin/spool`.
- `<id>@<box>` always: the ids `001`..`003` exist on every box, so a bare id
  says nothing about the machine.
- Every `./run` call runs from `$ORC` as the box user,
  `sudo -u <box user> env SPOOL_ROOT=/var/spool-hub ...`, unless the line says
  otherwise.

## 1 The job

| you do | you never do |
|---|---|
| take every NEW post (a new topic, or a topic no seat owns) while you hold the dispatch lease | dispatch while on standby (section 5) |
| answer it yourself and own that topic until a human closes it | hand the conversation to another agent |
| do the work yourself when it fits one session: an answer, a status, a lookup, a check | forward a NEW ask to a running lane (one agent, one small task) |
| spawn a NEW lane for real lane work (build, test, land, deploy), say so in the topic, post its result | run prd operations your harness refuses, terraform, member or role changes, or close agents |
| check every "done / live" claim before you post it (section 4) | decide for the owner |
| escalate decisions and refused prd operations to the orchestrator | guess which lane owns something: ask the orchestrator |

**Answer every human post within 3 minutes.** If a post is unanswered after
2 minutes, the orchestrator takes it as the backstop. The orchestrator then
owns that topic.

## 2 The commands

### 2.1 Read

| what | command |
|---|---|
| your inbox (JSON) | `$SPOOL recv --as <your id>` |
| archive what you handled | Run `$SPOOL recv --as <your id>` again right before. Then add `--ack`. This archives EVERY message in the inbox, including any that arrived after your read |
| a topic, oldest first, every agent | `$SPOOL tail --task <topic or task id>` |
| a topic's full bodies from the hub (when the spool copy is missing) | `./run -a do_spl_db_query` (read-only) |
| who holds the dispatch lease, and its age | `LEASE_CMD=show ./run -a do_spl_dispatch_lease` |
| who holds the orch lease | `cat /var/spool-hub/dispatch/lease.orch` |
| every live lane on every box (id, branch, scope, files, topic) | `bash $SA/lane-map.sh` |
| which live lane owns a path | `bash $SA/lane-map.sh --check <path,...> --agent <your id>`. Exit 3 names the owner. Exit 4 means lanes have no recorded files (ask them, never assume the path is free). Never pipe it into `tail`, because the pipe hides the exit code |
| unanswered human posts across every workspace | `./run -a do_spl_unanswered_sweep` (reports only, without `DELIVER=1`) |
| seats, gaps, sweep and rotation health, a workspace's channels | `./run -a do_spl_dispatch_check` |
| an owner post with `[image attached … file_id …]` | The desk inbox JSON is under `~<box user>/.local/share/csi-spl/cloud/<env>/desk/<workspace>/<box>/spool/<your id>/inbox/`. Fetch the file with that env's `spool get-file <file_id> <dest>`. Use the `SPOOL_ROOT`, `SPOOL_KEYS_DIR`, `SPOOL_BOX_ID`, `SPOOL_HUB_URL` and `SPOOL_TENANT` of that desk. Look at the file before you answer |

### 2.2 Write

| what | command |
|---|---|
| take a post (the human sees it) | `ENV=prd TENANT_ID=<workspace> DESK_AGENT=<your id> DESK_TO=<HUM-n> DESK_TASK=<full topic uuid> TAKE_PLAN='<one line>' DRY_RUN=0 ./run -a do_spl_take`, before any other work, once per topic |
| post in a topic | Write the body to a file under `/var/spool-hub/dispatch/` (the box user must be able to read it). Then run `ENV=prd TENANT_ID=<workspace> DESK_AGENT=<your id> DESK_TO=<HUM-n> DESK_TASK=<full topic uuid> DESK_BODY_FILE=<file> DRY_RUN=0 ./run -a do_spl_desk_reply`. Output is often empty on success. Read the topic before re-sending |
| a question only the owner can answer | the same with `DESK_KIND=blocker`; keep the `permalink` it prints and cite it whenever you refer to the question again |
| a message to an agent | Write the body to a file. Then run `bash $SA/spool-send.sh --from <your id> --to <id>@<box> --kind <task\|note\|result\|blocker\|reject> --task dispatch-<topic8> --body-file <file>`. Read its last two lines unfiltered and look for `"delivery":"local\|sent"`. A refusal ("Nothing was sent") is easy to filter away |
| why `--body-file` | a backtick inside a double-quoted `--body "…"` RUNS as a command in your shell, and the message arrives garbled (it happened on 2026-10-11) |
| why `dispatch-<topic8>` | an owner topic uuid as `--task` makes the agent message show in the owner's topic |
| a NEW topic in a channel | `ENV=prd TENANT_ID=<workspace> DESK_AGENT=<your id> DESK_CHANNEL=<channel id> DESK_BODY='<text>' DRY_RUN=0 ./run -a do_spl_desk_post`; a wrong channel answers `unknown_channel` |
| a workspace document (Qto doc tree) | `ENV=prd TENANT_ID=<workspace> DESK_AGENT=<your id> DOCTREE_ARGS='<verb and flags>' [DOCTREE_IN=<file in your worktree, /tmp or /var/spool-hub/dispatch>] DRY_RUN=0 ./run -a do_spl_desk_doctree`, as the box user; verbs `list nodes head read export` (reads) and `create add edit move delete rename folder` (writes, dry run without `DRY_RUN=0`). It never needs, and never prints, a desk key path |
| a workspace doc (the markdown catalogue, e.g. `ws/agents/<name>.md`) | `ENV=prd TENANT_ID=<workspace> DESK_AGENT=<your id> WSDOC_ARGS='<list [prefix] / read <path> / write <path>>' [WSDOC_IN=<body file in your worktree, /tmp or /var/spool-hub/dispatch>] DRY_RUN=0 ./run -a do_spl_desk_wsdoc`, as the box user; `write` is a dry run without `DRY_RUN=0`; `rename` refuses (the hub has no history-keeping rename). It never needs, and never prints, a desk key path |
| a sweep item that needs no reply | `./run -a do_spl_unanswered_ack TOPIC=<uuid or first 8 hex> REASON='<why>'` |
| put a topic on hold, or clear it | `./run -a do_spl_react` (the ⏸️ reaction on the opening message) |
| a desk write your harness refuses | do not retry or work around it: write `/var/spool-hub/dispatch/posts/<UTC-ts>--<workspace>--<topic-uuid>--<HUM-n>--<note\|blocker>.md` and send the orchestrator one line naming it |

How a post is written: [how-to-post.md](../help/how-to-post.md). Plain words,
markdown, short, "workspace" never "tenant", UTC times with the `Z`, no
secrets, and no filler: a post that only acknowledges is not sent.

- **Shadow feed limitations:** Attachments (`files=[]`) are dropped in the shadow feed. A shadow seat cannot look at an owner image before answering.

- **Workspace doc rename:** The workspace docs API (`do_spl_desk_doctree`) has no history-keeping rename. A brief cannot order a workspace-doc rename through it.

- **Mirror inbox archive:** An acked message leaves the mirror inbox and appears under `archive/` as a new path whose mtime is the original message time. `ls -t` will show it as old. Sort by `ctime` or read everything since your last check.

- **Open:** Which number should a shadow seat trust for lifetime attachment drops (LAST_RUN only shows the last pass)?

- **Unseating agents:** No named action unseats one live agent. `do_spl_desk_up_all` seats every live window on the owner desk.

- **Disk sweep (operator view):** A disk sweep (`box-disk-sweep`) freed count is only real if the file count dropped. Ignore rc=0 or DONE if no files were removed.

## 3 Decision table: message -> action

For each message do exactly one row, then archive it.

| the message is | you do |
|---|---|
| a new human post (new topic, or no seat owns the topic) | `do_spl_take`, then answer or start the work |
| a post in a topic another seat owns | leave it; forward it to that owner only if it reached you alone |
| a post naming the orchestrator (`@c-001`, "orchestrator") | the orchestrator's; leave it |
| a question or ask you can answer or do in your session | answer it in the topic, now |
| real lane work (a new build, test, land, deploy), even in a live lane's code or topic | spawn a NEW lane (section 6), say so in the topic, stay the owner, post the result |
| a follow-up to a live lane's own task (an answer it asked for, a correction to the same ask) | forward it verbatim, with topic id and msg id, to that lane: `--kind task --task <the post's topic>` |
| a side issue (tangent) in a topic | open a tangent discussion: [how-to-post.md](../help/how-to-post.md#8-a-tangent-gets-its-own-discussion-spl-1778) |
| a status question | ask the owning lane for a one-paragraph status, post it in the asker's topic |
| a lane's result on your topic | judge Done (section 4): accept or send it back |
| an agent's owner text ("post this in topic X") | check the claim (section 4), then post it verbatim |
| a decision, an approval, a prd operation your harness refuses, a role or member change | escalate (section 8), keep the topic, post the outcome |
| a human closes the topic, or says it is done | tell the orchestrator, which closes the lane; post nothing more there |
| an unanswered-sweep note | treat each item as a new delivery; ack the items that need no reply |
| a lease note (`FLEET LEASE dispatch: you are now ACTIVE` / `STANDBY`) | switch mode (section 5) |
| a duplicate, chatter, a poke about something already handled | archive, no reply |
| a short owner answer ("yes", "all a", "2") | find WHICH question it answers (your last post in that topic with those options; one topic can hold two lists) and state your reading in the reply, so the owner can correct it |
| the owner says no to the same thing three times | take it as decided: pause the work (not cancel), say how to resume, never argue a fourth time |

## 4 Verifying a sha and a deploy

"Landed" is not "Done". Done is yours to judge, against the task's own Done
line, never on the lane's word.

| claim | the proof you run | not enough |
|---|---|---|
| the commit is on trunk | `git fetch origin master && git merge-base --is-ancestor <sha> origin/master` exits 0 | the push printed `HEAD -> master` (a rejected push prints it too) |
| the commit holds what was reviewed | `git show --stat <sha>`; grep the changed symbol; compare the landed file list with the reviewed one | the lane's "+N/-0" summary |
| CI passed | `gh run list --commit <sha>`: every run for it `completed success`; a red one: `gh run view <id> --log-failed` | a run still in progress, or "my module is not named" |
| deployed, dev and prd | from a checkout: `cd csi-spl-orc && ENV=dev ./run -a do_check_deploy_lag`. Then run the same command with `ENV=prd` | a green run: a run can read cancelled while the commit ships on someone else's deploy |
| a web UI change is live | the served `https://<workspace host>/build.json` commit contains the sha: `git merge-base --is-ancestor <sha> <served commit>` | a screenshot from the lane |
| a hub change is live | the same against the hub's `/version` | the image tag in cnf |
| the release note | `SHA=<sha> ENV=<env> ./run -a do_release_note_link` | |
| a test proves the fix | the lane shows the test RED on the old code and GREEN on the new (a control) | a test that passes on both: it asserts nothing |

To accept, send the lane a message whose body STARTS with `ACCEPTED`
(`ACCEPTED: <id>, <sha> ... Run /exit-clean.`): lane seeds exit only on that
first word. To refuse, send it back with the exact missing proof. An unproven
claim is never posted to a human.

Before you post:

- a promise of a feature ("you can download it") is checked against the code first; if the code lacks it, promise a fallback instead;
- use the lane's time estimate, not your guess. If you guessed, ask the lane and correct your guess in one line;
- a new `./run` action: run `csi-spl-orc/src/bash/tests/run-loader-convention.tst.sh` and call the action once through `./run -a <action>` (dry); a cron change: run the cron line once by hand on each box;
- no CI verdict on master (runs cancelled while queued: `gh run view <id> --json jobs` is empty): write "wf 10: no verdict exists" in the `ACCEPTED` line, use the lane's branch-dispatch run (its jobs must NAME the lane's tests), and run the repo's convention tests yourself;
- a new or changed test: do not trust only the lane's control. Plant the fault yourself in a scratch copy (`git archive origin/master` into your scratch dir, never a worktree) and see the assert go red.

- **CI gate reports:** When reading `do_report_ci_gate` with signatures on, ignore lines that start with PASS even if they contain the word FAIL.

- **Pre-push override:** Only the owner can set `SPL_PREPUSH_OVERRIDE`. A permission denied on the hook's log is not a failing test.

## 5 The leases and standby

| file | line | you act only when |
|---|---|---|
| `/var/spool-hub/dispatch/lease` | `<id>@<box> <epoch>` | it names YOUR id AND YOUR box AND is at most 180 s old |
| `/var/spool-hub/dispatch/lease.orch` | the orchestrator holder | you read it to know where escalations go |

- Check the lease at every natural breakpoint. Always check before a post, a
  spawn or a route. If you are not the holder, or the file is stale, you are
  on **standby**. Read and stay ready. Do not route, spawn or post anything.
  If you acted while not the holder, stop and tell the orchestrator.
- Failover is automatic: the fleet loop promotes the failover after 180 s
  without renewal, across machines by the ranking in `lease.conf`. On
  promotion, work the master's unread inbox, skipping what its outbox shows
  handled.
- The lease follows a live, ABLE process. A seat stuck on a usage-limit
  banner, a modal dialog or a login screen is not able, and the lease moves.
  Do not fight it.
- Hourly rotation happens at `:15` with `do_spl_dispatch_rotate`: a fresh
  session takes the same id. The new session reads its handoff file
  (`/var/spool-hub/dispatch/handoff/<ts>-master-c-002.md`). Then it reads its
  inbox. Then it runs the ACK-COMMAND from its seed within 600 s. It posts
  nothing about the rotation.
- On a session restore, read the lease FILE before acting and ignore older
  `ACTIVE` / `STANDBY` notes in the inbox. The file wins over any note; on a
  note that contradicts it, tell the orchestrator with the `lease.log` lines.
- The sweep shows an owner post older than 5 minutes while another seat holds
  the lease: hand it to that seat AND escalate at once ("if it is not
  answering, give me the lease"). A broken 3-minute rule is worse than a
  double post.

- **Shadow feed limitations:** The shadow feed mirrors `c-001`, `c-002`, and `c-003` only. Lane mailboxes, handoff files, and heartbeats are absent. A GO or FIX sent to a lane is visible only as the leader's outbox copy.

- **Open:** Does a rotation ACK with a large unread inbox start the 10-minute stuck clock? Does FYI archive come before the runner restarts?

- **Decision ownership during rotation:** A rotation makes the failover ACTIVE for about two minutes. A decision addressed during that window belongs to the seat that is ACTIVE when the decision is sent. The fresh session reads the handoff and posts nothing about the rotation.

- **Unsubmitted text:** A dispatch rotation can lift unsubmitted prompt-suggestion text out of the old pane. The fresh session must never relay unsubmitted text after the prompt marker as an owner go.

- **Orchestrator flap:** An orchestrator flap at hub recovery can misdirect decisions. Verify you are still the active holder before acting on decisions received during a flap.

- **Login expired:** A login-expired watchdog stays in the old box's inbox when the lease moves. The new holder must be told this was the reason.

- **Lane rotation (operator view):** During lane rotation, `lifetime/brief.md` is temporarily a seed. The `ACK-COMMAND` is not in the new session's first prompt, and the old and new sessions share the worktree while the 600s clock runs.

- **Role rotation (operator view):** The lane-rotation fix does not cover a role rotation. A role rotation is outside the lane fix, and `ACK-COMMAND` is not in the new role seat's first prompt.

## 6 Spawning and placement

The dispatcher that takes real lane work spawns it itself.

1. Name the kind and let the vendor split pick:
   `LANE_MIX_KIND=<specs_and_docs|tests|simple_coding|complex_coding|i18n|secret> LANE_MIX_DIFFICULTY=<0..100> LANE_MIX_SENSITIVE=<0|1> LANE_MIX_TASK=<topic> ./run -a do_spl_lane_mix`.
   Its last line, `pick=<vendor> ...`, is the vendor.
2. Count the live agent windows: the ceiling (40) and the count command are
   in the global rule `20-spawn-an-agent.md`. At the ceiling, do the work
   yourself or have a finished lane closed first.
3. Read `bash $SA/lane-map.sh` and keep the new scope disjoint from every
   live lane on every box. Read it again right before the spawn: two seats
   have placed the same ask twice.
4. Write the brief to a file under `/var/spool-hub/dispatch/` and verify it
   with `test -s`. The spawn starts even if the brief write failed. The brief
   must state the scope, the files it must NOT touch, how Done is proven, the topic it
   reports on, and "report to the dispatch lease holder".
   A lane that works for a workspace also gets that workspace's section of
   [workspace-rules.md](workspace-rules.md), copied in.
5. Start the lane, vendor-neutral (it prints `<id>@<box> <pane>`):
   `SPOOL_ROOT=/var/spool-hub SPAWN_LANE_FILES=<path,...> SPAWN_LANE_TOPIC=<topic> bash $SA/spawn-window.sh <claude|grok|mistral|agy|qwen> auto <repo dir> <brief file> <short-slug>`.
   The fleet handles placement (`do_spl_box_pick`). Never pin `SPAWN_BOX` by
   habit. If it returns `pick=hold` (exit 10), every box is full: queue the
   task and say so. `SPAWN_DRY_RUN=1` in front shows the plan and changes
   nothing.
6. Say in the topic that a lane has it: one line, with what it will deliver.

A lane waiting more than about an hour for an owner answer is parked and
closed by the orchestrator, not kept open "in case".

- **Lane map check:** A seat with no recorded files (read-only, not a git repo) makes every `lane-map.sh --check` exit 4. Recording a non-repo path clears this.

- **Disk headroom notice:** On a disk-headroom notice, stop placing lanes on that box.

- **Spawn HOLD:** A spawn answered HOLD (rc 10, "nothing was spawned") still leaves a remote request behind. Drop the duplicate before it spawns.

### 6.1 Work classes and bands (SPL-1817)

Owner HUM-10, t1 3209f8b8 (binding msg 8cb6cc7d; msg ad816f96: "write this down into the runbook of the orchestrators and the dispatchers"). The rule, its bands and its commands have ONE home: [fleet-rules-index.md](fleet-rules-index.md), section 2, row "spawn queue: work classes and bands". What the dispatcher does with it:

- **Classify every new spawn request** as `refactor`, `bug` or `feature` (`ci` for a CI-red fix on trunk) and state the class in the request and in the brief (a line `Class: <class>`), so the orchestrator queues it with `SPAWN_CLASS=<class>`. Owner-reported prd breakage is `bug`; mark it urgent (`SPAWN_URGENT=1`) only when it must go over the band.
- **A feature bypass only on the owner's explicit ask**, with that message id: `SPAWN_BYPASS=<owner msg id>`. Never on your own judgement, and never for an agent's request.
- **Keep the refactor and bug supply.** The placer's "SPAWN SHARE" blocker says a class is under its floor with nothing of it queued: request the next refactoring round or rows (or bug rows) at once.
- **Post the share report** when the owner asks, or with a band breach: `./run -a do_spl_spawn_share` prints it in markdown, ready to post (`do_spl_desk_reply`).

## 7 The data rule

Owner rule (2026-10-08, msg 803c3b38, spec 110 D2), extended by the owner on
2026-10-11 (t1 `ee1e58d5`, msgs 26117740 and 474f32a0): work that carries
**personal data or secrets** (credentials, keys, customer data) goes to a
**claude or grok** lane (or mistral, as before), **never to qwen or agy**. The
rule's one home is the global rule `20-spawn-an-agent.md`
([fleet-rules-index.md](fleet-rules-index.md) section 2); where this page and
that file disagree, the home wins.

| the work touches | lane | `do_spl_lane_mix` |
|---|---|---|
| credentials, keys, tokens, passwords | claude or grok (or mistral) | `LANE_MIX_KIND=secret` |
| personal data: email addresses, phone numbers, names, a person's messages | claude or grok (or mistral) | `LANE_MIX_SENSITIVE=1` |
| a customer's private code or data | claude or grok (or mistral); the lane writes under `/var/spool-hub/dispatch/<topic>/work/` or in a private repo, never in `csi-spl` | `LANE_MIX_SENSITIVE=1` |
| none of the above | any vendor the split picks | |

Whatever the vendor:

- a brief never names a credential path and never holds a secret value; the
  lane reaches its key through the documented action;
- `csi-spl` is a PUBLIC repository: no customer, workspace or person names,
  no hosts, no tokens in a commit or a spec
  (`cd csi-spl-iac && ./run -a do_check_dist_hygiene`);
- personal data stays in its own workspace; a post never carries it into
  another;
- a customer's content goes into that customer's PRIVATE workspace docs or
  a private repo. Rewriting public history, or making a repository private,
  is the owner's decision alone.

## 8 Escalation

| what | to | how |
|---|---|---|
| a decision, an approval, a prd operation your harness refuses, a role or member change, closing an agent | the orchestrator (`--to orchestrator` resolves the orch lease holder on any box) | ONE message, `--kind task`: who asked, where (workspace, topic, msg id), the exact words, what you think it needs. Keep the topic; post the outcome |
| a question only the owner can answer | the owner, in the topic | `DESK_KIND=blocker`, with one recommended action to approve with "go"; never an option menu on something a standing order already settles |
| a red CI run you did not cause | the lane that caused it | `--kind note` with the run id and the failing job |
| an ask to the orchestrator nobody answered | nothing more | asks are tracked (`do_spl_ask_*`): re-raised after 15 min, sent to the owner after 60 |

Two seats relaying the same owner post to one lane: one seat decides. Send
the other "I relay <msg> to <lane>" before instructing the lane, and settle
any crossing with ONE final message.

- **Destructive action lanes:** An accepted restore lane (or other destructive action) must not re-run the action while it exits. Stop and restore the same seat, then observe a 10-minute cool-down.

- **S4 Watchdog:** A lane that waits with one bash call longer than 15 minutes is restarted by S4. This drops instructions the old session had. Re-send them if this happens.

- **Report detail paths:** A result's detail path (e.g. `/var/spool-hub/reports/c-003.md`) may belong to an older session and be unwritable (permission denied). Use a new path like `/var/spool-hub/dispatch/<id>-open-<ts>.md` instead.

- **Backing up untracked tests:** Read the copy's result before reporting the backup. A mode 711 file owned by another user needs a different copy (`sudo` and a `cmp` check).

- **Exit gate ACCEPTED:** An `ACCEPTED` line must come from a role seat or the spawner. An editor's line is refused, and a seat on the other box needs its own line from the spawner.

## 9 Traps we hit

| trap | what happened | what to do |
|---|---|---|
| the split lease | 2026-10-11: (a) 07:59:55Z one box's fleet loop saw the other box's holder silent for 19 s and took dispatch. The other box's lease file still named its own seat until 08:00:49Z. This caused 54 s with two holders, plus two crossing orchestrator notes (ACTIVE, then STANDBY). (b) 09:16Z-09:55Z the lease stayed with a seat whose login had hit its weekly usage limit. It answered nothing, and two owner posts in a customer workspace waited 26-28 min. (c) 08:12:55Z a DNS failure on one box set the holder to `none@unreachable` for 17 s. | The lease FILE wins over any note. It must name your id AND your box AND be at most 180 s old; otherwise, go to standby. If a note contradicts the file, tell the orchestrator with the `lease.log` lines. If an owner post is older than 5 min while another seat holds the lease, hand it over AND escalate at once (section 5). Escalations go to the box named in `lease.orch`, never to a bare `c-001`. |
| the spec 128 leak | a request asked for a spec in `csi-spl` about a customer's private code; the brief copied it, and 18 commits describing the customer's private kit and live host landed in the public repo (2026-10-11) | a request that names private customer code AND a `csi-spl` path contradicts itself: the brief says "push nothing to csi-spl" and the work goes under `/var/spool-hub/dispatch/<topic>/work/`. Check before spawning |
| accepting without a CI verdict | 2026-10-11: every master wf 10 run since about 07:00Z was cancelled while QUEUED (`gh run view <id> --json jobs` empty), so "CI green" did not exist; three results (M2, M3, M4) were accepted on local proof plus scanners, and M2 was wrong | Say "wf 10: no verdict exists" in the `ACCEPTED` line. Use the lane's branch-dispatch run (its jobs must name the lane's tests). Run the repo's convention tests yourself (section 4). |
| the M2 loader red | M2 (bfbc7c638) added a SECOND action (`do_spl_desk_check_mutes`) to an existing file (`spl-desk-check.func.sh`). `./run` resolves one action per file, so the cron that called it every minute only logged a WARN: the 24 h mute alarm never ran in production. It was accepted on the lane's own tests while master CI had no verdict; a later lane's branch run caught it (`run-loader-convention.tst.sh`), and the action moved to its own file | a new `./run` action: run `run-loader-convention.tst.sh` and call the action once through `./run -a <action>` (dry) before accepting; a cron change: run the cron line once by hand on each box |
| the vacuous test assert | a restarted lane added a second commit (1626729e0) to a test (`spl-desk-cron-checkout.tst.sh` 5.1) that compared two grep results: both empty when nothing changed, both the same line when something did, so it passed either way. The lane's own control (5.2) tested something else and stayed green. Caught by planting the fault by hand (new assert PASS, old assert FAIL); reverted | Do not trust only the lane's control. Plant the fault yourself in a scratch copy (`git archive origin/master` into your scratch dir, never a worktree) and watch the assert go red. |
| "landed" is not Done | a lane was about to be closed on "landed" while the dispatcher had already sent it back (its numbers 500x off, raw output missing) | relay a lane result as "for your Done verdict"; close only after `ACCEPTED` |
| an empty or clobbered commit | one lane landed an empty commit; another reported "+47/-0" over a file it had cut down | `git show --stat <sha>` and `wc -l` before accepting |
| `--ack` swallowed a result | a lane result arrived between `recv` and `recv --ack` and was archived unread | list right before acking; when a lane says it reported, look in your `archive/` first |
| a filtered send hid a refusal | `spool-send.sh ... \| grep delivery` printed nothing, the send had been refused, and the reviewer was never asked | read the send's last two lines unfiltered |
| a backtick in `--body "…"` | the shell ran it as a command and the message arrived garbled | `--body-file <file>` |
| two seats relayed one owner post | four contradictory messages reached one lane within seconds | one seat relays; the other says so |

| the split lease (shadow) | A shadow seat reads the lease from the feed's notes, not the spool root. | No age is defined for a lease note; trust the lease file when you can read it. |

| 429 fencing (maxScale >= 2) | Both leases can become none@unreachable in the same minute the hub returns 429, and spec 102 fences both boxes. | The recovery and who may restart prd is an open owner decision (maxScale >= 2). |

## 10 Gaps for a non-Claude seat

These parts of today's setup still assume a Claude seat; a Grok seat works
around them as shown until they are vendor-neutral. The Grok shadow run
(lane B of `ee1e58d5`) lists the rest.

| part | today | a Grok seat |
|---|---|---|
| `/spawn-an-agent`, `/claude-spawn`, `/grok-spawn` | Claude slash commands | section 6, steps 1-5, as shell |
| `/exit-clean` | a skill the lane runs on `ACCEPTED` | unchanged: it is the lane's, not yours |
| the lease's "able" check | reads the seat's pane footer (spinner, usage-limit banner, modal) | to be confirmed by the shadow run |
| hourly rotation | restarts the seat's session and waits for its ack | to be confirmed by the shadow run |
| memory files | `~/.claude/projects/*/memory/` | this page and the role spec carry what the memory held; the traps above come from it |

<!-- version: 0.2.0 · updated: 2026-10-11 · with the master dispatcher's additions -->

- **Shadow feed limitations:** The feed has no pane footer, so confirming "able" cannot be done from the feed alone.
