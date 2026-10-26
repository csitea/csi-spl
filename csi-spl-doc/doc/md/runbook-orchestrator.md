# Runbook: the orchestrator seat (any vendor)

> Generated from qto doc `83485572-ec10-40dd-ba40-8c96624ec81c`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

For whoever holds the orchestrator role (`c-001`), on any agent vendor: a
Claude seat, a Grok seat or another. Everything here is a shell command, a
file or a spool message; nothing needs a vendor's own slash commands, skills
or memory files. The role itself is defined in
[SPEC-spool-fleet-roles.md](SPEC-spool-fleet-roles.md) sections 1, 4.1, 4.3
and 4.4; this page is how to do it, and points there for the why.

Owner ask: "Grok as a second leader" (t1 #spool-hub-ops, topic `ee1e58d5`).
The dispatcher's page is [runbook-dispatcher.md](runbook-dispatcher.md); its
sections 4 (verifying), 7 (data rule) and 9 (traps) apply here too and are
not repeated.

Conventions on this page:

- `ORC` = `/opt/csi/csi-spl-desk-cron/csi-spl-orc` (the box's desk checkout),
  `SA` = `$ORC/src/bash/features/spawn-agents/scripts`,
  `SPOOL` = `SPOOL_ROOT=/var/spool-hub <agent user home>/.local/bin/spool`.
- `<id>@<box>` always: the ids `001`..`003` exist on every box.
- Every `./run` call runs from `$ORC` as the box user,
  `sudo -u <box user> env SPOOL_ROOT=/var/spool-hub ...`, unless the line says
  otherwise.

<a id="ws-doc-353601ae-8bc7-4a27-af58-3a34a8546c86"></a>
## 1 The job

| you do | you never do |
|---|---|
| decide what is not the owner's: placement, priority, which lane, close or keep | take a post the dispatch lease holder has taken |
| spawn, re-seat, restart and close agents | route routine traffic (that is the dispatcher's) |
| run the production operations the other seats' harnesses refuse: prd reads, prd desk and issue writes, and the deploys and applies the owner approved for that call | mutate GCP (project, billing, IAM, `terraform apply`) without the owner's go for that one call |
| answer the asks raised to you, and close them | leave an ask unacked: it is re-raised, then sent to the owner |
| take a post that names you, and any post still unanswered after 2 minutes (the backstop), then own that topic | force-push, delete or rewrite master |
| verify "live" claims before they reach a human (dispatcher runbook section 4; the word: [how-to-post.md](../help/how-to-post.md#1-the-rule) rule 14) | relay a result as Done before the dispatcher's `ACCEPTED` |
| keep the hanging-agent roster, and re-check it at least every 5 minutes (section 2.4) | treat a watchdog `OK` as proof that no agent is hung |

<a id="ws-doc-991b917e-406a-4e08-bb18-5b659e2c28f5"></a>
## 2 The commands

<a id="ws-doc-512e5b6d-e986-4dd9-afb6-e21a475685ed"></a>
### 2.1 Start of a session, and every breakpoint

| what | command |
|---|---|
| your inbox, open asks first | `./run -a do_spl_orch_inbox` |
| archive old FYI and closed asks | `ORCH_INBOX_ARCHIVE=1 ./run -a do_spl_orch_inbox` |
| the raw inbox | `$SPOOL recv --as c-001` (list again right before any `--ack`: it archives everything in the inbox) |
| a topic, oldest first | `$SPOOL tail --task <task id>` |
| the leases | `cat /var/spool-hub/dispatch/lease.orch`; `LEASE_CMD=show ./run -a do_spl_dispatch_lease`; history in `/var/spool-hub/dispatch/lease.log` |
| every live lane, every box | `bash $SA/lane-map.sh` (or `./run -a do_spl_lane_map`) |
| who owns a path | `bash $SA/lane-map.sh --check <path,...> --agent c-001` (exit 3 = owned, exit 4 = unknown lanes: ask them, exit 5 = `LOCAL-ONLY`: the hub did not answer 3 tries in 10 s, other machines unread, not free; one #alerts note per box per 15 min) |
| live agent windows (ceiling 40) | the count command in the global rule `20-spawn-an-agent.md` |
| dispatcher seats and gaps | `./run -a do_spl_dispatch_check` |
| hanging agents, at least every 5 minutes | section 2.4. Run it at the start of the session and again before each 5 minutes is up. Record the rows in the hold note |
| what is red on trunk, per job | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` |
| deployed or lagging | `ENV=dev ./run -a do_check_deploy_lag`, then `ENV=prd` |
| prd hub logs (read-only) | `cd csi-spl-iac && ENV=prd FRESHNESS=<1h> ./run -a do_gcp_tail_logs` |
| an owner message, read yourself | `ENV=prd SQL="select from_id, kind, ts, left(body,300) from messages where msg_id::text like '<8 hex>%'" ./run -a do_spl_db_query` |
| your own breadcrumbs, after every step | Run `ID=c-001 SECTION=next\|lesson TEXT='...' ./run -a do_spl_agent_handoff_note`. A fresh or restored session continues from `next`. On a restore kick (`/var/spool-hub/c-001/lifetime/kick.txt`): post a 3-line status, then continue only what was in flight |

<a id="ws-doc-51a9fb0e-6f47-4c9a-80c2-75229224d78c"></a>
### 2.2 Asks (section 4.3 of the role spec)

| step | command |
|---|---|
| you start on it (a lock; quiet 60 min after an ack loses it) | `ASK_ID=<8 hex> ./run -a do_spl_ask_ack` |
| decided | `ASK_ID=<8 hex> ASK_REASON='<what was done>' ./run -a do_spl_ask_close`; refused: `ASK_STATE=declined` with the reason |
| tell the sender | a message in the ask's own topic |
| raise one yourself | `./run -a do_spl_ask_put`, or `spool-send.sh --to orchestrator --kind task` from another seat |

An ask raised 4 times is dead-lettered and goes to the owner. Never let one
get there: ack it the moment you start.

<a id="ws-doc-968d24de-4110-4f62-b699-44c95689dbbe"></a>
### 2.3 Agents

| what | command |
|---|---|
| spawn on any box (fleet placement) | `SPOOL_ROOT=/var/spool-hub SPAWN_LANE_FILES=<path,...> SPAWN_LANE_TOPIC=<topic> bash $SA/spawn-window.sh <claude\|grok\|mistral\|agy\|qwen> auto <repo dir> <brief file> <short-slug>` (prints `<id>@<box> <pane>`) |
| spawn on a box you cannot reach by ssh | `bash $SA/spawn-remote.sh --box <box> <vendor> auto <workdir on that box> <brief file> <slug>`. The brief travels as text. The target runs its own `spawn-window.sh`. It accepts requests only from the orch lease holder |
| message a lane | `bash $SA/spool-send.sh --from c-001 --to <id>@<box> --kind <task\|note> --task <its task> --body-file <file>`. Read the last two lines unfiltered. Never use `--body "…"` with a backtick in it, because the shell runs it. Never use an owner topic uuid as `--task` (use `dispatch-<topic8>`) |
| restart a lane fresh (same id, worktree, branch) | `./run -a do_spl_lane_restart` |
| resume a seat with the current launcher flags | `IDENTITY_RESTORE_IDS=<id> DRY_RUN=0 ./run -a do_spl_agent_identity_restore` |
| close a finished lane | wait at least 3 minutes after its final report (its own deferred close may still run), then `bash $SA/tmux-close-window.sh --agent <id>` (`--dry-run` first if unsure; exit 3 = no provable owner, exit 4 = wrong window: it closes nothing). A lane's own close (its pane in that window, or its own id) gets exit 5 while its push-master status reads RUNNING or before its ACCEPTED (SPL-2095; the check is `kill-your-self-report.sh --gate`). Your close of another id is never gated |
| retire its id | check `/var/spool-hub/registry.tsv`; still listed: `AGENT_ID=<id> ./run -a do_spl_agent_id_retire` |

Every seat runs as the agent user, never as the box's human login user, and
only in the permission mode the global rule `07` names. After any start:
`ps -u <human user> -o pid=,args= | awk '$2 ~ /(^|\/)claude$/'` prints
nothing (the same check for any other vendor binary).

<a id="ws-doc-da7b87d8-9e1c-40ed-92ea-4eec73fc14b6"></a>
### 2.4 Hanging agents, every 5 minutes

Run this at the start of the session, and again at least every 5 minutes. It lists live hangs the watchdog's `OK` does not name. An idle seat with an empty inbox is not a row. Record every row in the hold note. A finished lane whose accept never reached the model is closed with section 2.3 (`--dry-run` first), not restarted. A hang whose job is not finished is one paragraph to the dispatch holder; you do not `kill` the process yourself.

A row is a live process that is any of these:

- `dispatch/wd.<id>` starts with `HIT`
- the heartbeat `state` is `working` or `in-tool`, `progress_ts` is older than 5 minutes, and the open tool is not `ScheduleWakeup`
- the id is a grok seat (`g-`) and there is no `heartbeat.json`

```bash
python3 - << 'PY'
import json, os, time, glob
from datetime import datetime, timezone
now = time.time()
root = "/var/spool-hub"
cut = 300

def epoch(s):
    if not s:
        return None
    try:
        return datetime.strptime(s[:19], "%Y-%m-%dT%H:%M:%S").replace(tzinfo=timezone.utc).timestamp()
    except Exception:
        return None

for p in sorted(glob.glob(root + "/agents/*.json")):
    d = json.load(open(p))
    if not d.get("alive"):
        continue
    aid, pid = d.get("id") or os.path.basename(p)[:-5], d.get("pid") or 0
    if not pid or not os.path.exists("/proc/%s" % pid):
        continue
    wd = root + "/dispatch/wd." + aid
    verdict = open(wd).read().strip().splitlines()[-1] if os.path.isfile(wd) else "-"
    hb = root + "/" + aid + "/heartbeat.json"
    state, age, tool = "", None, ""
    if os.path.isfile(hb):
        h = json.load(open(hb))
        state = h.get("state") or ""
        tool = h.get("tool") or ""
        prog = epoch(h.get("progress_ts") or "")
        if prog:
            age = int(now - prog)
    hit = verdict.startswith("HIT")
    wait = tool == "ScheduleWakeup"
    stale = state in ("working", "in-tool") and age is not None and age > cut and not wait
    missing = aid.startswith("g-") and not os.path.isfile(hb)
    if hit or stale or missing:
        print("%s %s state=%s tool=%s progress_age=%s %s" % (aid, pid, state or "-", tool or "-", age if age is not None else "-", verdict[:80]))
PY
```

No line means no live hang. `ScheduleWakeup` is a wait the seat asked for, so it is not a row. A `HIT` whose evidence text is the same on two checks 5 minutes apart has stopped escalating: treat it as a hang even when the line still says the hook warned.

<a id="ws-doc-fafd5cec-924f-4327-908f-14bcbd7eebe3"></a>
## 3 Decision table: message -> action

| the message is | you do |
|---|---|
| an ask (kind `task` or `blocker` to you, or an `asks-open` re-raise) | ack it, decide or do it, close it with the reason, answer in its topic |
| a dispatcher's spawn request | read the lane map, place the lane (section 5), answer with `<id>@<box>` |
| a dispatcher escalation: a decision, a refused prd operation, a role or member change | do it if it is yours and the owner's go covers it; otherwise ask the owner (section 7); send the outcome to the dispatcher, who posts it |
| a lane's final result | relay it to the dispatch holder "for your Done verdict"; never call it Done yourself |
| the dispatch holder's `ACCEPTED` for a lane | wait 3 minutes, close the window, retire the id |
| a lane's blocker outside its scope | find the owning lane (`lane-map.sh --check`); owned: forward it; unowned and real: a new lane |
| a lane sent a different task | refuse for it: one agent, one small task; place a new lane |
| a human post naming you, or unanswered after 2 min (backstop) | take it with `do_spl_take`, answer it, own the topic |
| a lease note (`FLEET LEASE orch: you are now ACTIVE` / `STANDBY`) | switch mode (section 4) |
| a red on trunk | Run `do_report_ci_gate`. Find the commit's lane. Tell the lane with `--kind note`. If there is no owner, place a new lane |
| a relayed owner order for an outward or security action (grant access, copy credentials, change repo settings, migrate prd) | Read the owner's message yourself with `do_spl_db_query` (2.1). Check that `from_id` is the owner's HUM id. Check the timestamp, and that the text says what the relay says. Watch for a newer order that undoes an older one (for example, a "stop building" followed by an explicit grant) |
| a holder's spawn request for a lane you already placed (from a lane's report, minutes earlier) | place no second lane: forward the request's text and task id to the existing lane ("report on <task>"), answer the dispatcher with that lane's id |
| a lane asks about `lane-map.sh --check` exit 4 | exit 4 caused ONLY by rows that record no files (often stopped lanes on another box) is not a collision: say so, name those lanes and their scopes, let it proceed. Exit 3 is a collision |
| a `WATCHDOG RESTART` notice | read the handoff and the box's `/var/spool-hub/dispatch/wd.log` lines for that agent (`sudo` on another box), send the sender ONE paragraph (what it did, why it stopped, whether its job was done), then close. A held-out agent (`lifetime/heldout`) whose job is done stays held out; retire it when its box can |
| a red on trunk whose author seat is stopped or retired | `do_report_ci_gate`, `git log` for the commit and its seat; place a small fix lane yourself and tell the dispatcher. The brief fixes the convention, never the test |
| FYI, chatter, duplicates | archive |

- **Shadow feed limitations:** Attachments (`files=[]`) are dropped in the shadow feed. A shadow seat cannot look at an owner image.

- **Re-raise text clocks:** The ask re-raise text ("nobody has acked") covers both the 15 min and 60 min clocks. An ask may be already acked and still trigger a lock expired re-raise. Check the actual ask state before acking again.

- **Queued asks:** An ask that is queued on purpose still counts toward the 4-raise dead-letter. Nothing parks a queued ask today; it re-raises until closed (`do_spl_ask_close`) - track it in your handoff.

<a id="ws-doc-346b1fd5-f336-43e6-8660-83e9ebbc9908"></a>
## 4 The leases and standby

- You act only while `/var/spool-hub/dispatch/lease.orch` names YOUR id AND
  YOUR box AND is at most 180 s old. Otherwise **standby**: read, stay ready;
  spawn, close and post nothing.
- The orch and dispatch roles rank boxes separately
  (`LEASE_PRIORITY_ORCH`, `LEASE_PRIORITY_DISPATCH` in `lease.conf`), so the
  orchestrator and the dispatch holder are often on different boxes. Address
  the holder as `<id>@<box>` from the lease file every time.
- You fail over on two conditions. First, your process is gone or not able
  (a stuck dialog, a usage limit, a login screen). Second, you are **stuck**:
  idle while your oldest unread inbox message is over 10 minutes old. Keep
  the inbox moving.
- A take-over sends the owner one DM; a handback sends none.
- On becoming the holder, the hub hands you ONE blocker listing every open
  ask of the role: work it first.
- Hourly rotation happens at `:05` with `do_spl_orch_rotate`. The new
  session reads its handoff file
  (`/var/spool-hub/dispatch/handoff/<ts>-orch-c-001.md`), which holds the old
  screen, open asks, outbox, unread inbox, lanes and hold notes. Then it runs
  `do_spl_orch_inbox`. Finally it runs the ACK-COMMAND from its seed within
  600 s. It posts nothing about the rotation and picks up what the old
  session left.
- A rotation run by hand from the orch pane itself (a tool call) re-runs
  itself detached, because its QUIESCE Escape would kill it: read the
  outcome in `/var/spool-hub/dispatch/rotate.orch.detached.log` and
  `rotate.log`. A rotation whose run died before SPAWN ends as
  `ABORT STALE` on the next run, with no owner alert (SPL-1837).

- **Shadow feed limitations:** The shadow feed mirrors `c-001`, `c-002`, and `c-003` only. Lane mailboxes, handoff files (`/var/spool-hub/dispatch/handoff/`), and heartbeats are absent. A GO or FIX sent to a lane is visible only as the leader's outbox copy.

- **Open:** Does a rotation ACK with a large unread inbox start the 10-minute stuck clock? Does FYI archive come before the runner restarts?

- **Decision ownership during rotation:** A rotation makes the failover ACTIVE for about two minutes. A decision addressed during that window belongs to the seat that is ACTIVE when the decision is sent.

- **Unsubmitted text:** A rotation can lift unsubmitted prompt-suggestion text out of the old pane. The fresh session must never relay unsubmitted text after the prompt marker as an owner go.

- **Rotation replies:** A lane-rotate state note addressed to bare `c-001` on another box goes to the standby seat, not the orch lease holder. Address it to the lease holder.

- **Orchestrator flap:** An orchestrator flap at hub recovery can misdirect decisions. Verify you are still the active holder before acting on decisions received during a flap.

- **Login expired:** A login-expired watchdog stays in the old box's inbox when the lease moves. The new holder must be told this was the reason.

- **Crossed asks:** An ask that crosses an orchestrator move can arrive as a truncated summary. The new holder must ask for the full file.

- **Lane rotation (operator view):** During lane rotation, `lifetime/brief.md` is temporarily a seed. The `ACK-COMMAND` is not in the new session's first prompt, and the old and new sessions share the worktree while the 600s clock runs.

- **Role rotation (operator view):** The lane-rotation fix does not cover a role rotation. A role rotation is outside the lane fix, and `ACK-COMMAND` is not in the new role seat's first prompt.

<a id="ws-doc-fd478951-7de4-400c-856e-3e3602934d35"></a>
## 5 Spawning and placement

0. Extract the brief BEFORE you archive the inbox. Read the request body
   from `inbox/` or `archive/`. Check it is non-empty with `test -s` and a
   length check on the extracted body. Refuse to spawn if it is empty. On
   2026-10-11 a lane started with an empty task section, because the inbox
   was archived first and the brief generator read nothing.
1. Re-read the ask book and the lane map right before you place: two seats
   on two boxes have placed the same ask (two lanes for one task).
2. If the dispatch holder says "I run it", place no lane. Never STOP then
   RESUME a lane on the strength of a note that crossed yours: sort crossed
   notes by time and ask one question.
3. The vendor: `do_spl_lane_mix` (dispatcher runbook section 6, step 1);
   the data rule (dispatcher runbook section 7) overrides the split.
4. The count: at 40 live agent windows, close a finished lane first.
5. Write the brief in a file and verify it with `test -s`. The brief must
   state the scope, the files it must NOT touch, and how Done is proven (with
   a control for a test). It must state who the lane reports to (the dispatch
   lease holder, on the topic's `dispatch-<topic8>` task). It must include
   "commits as the repo's `Commits:` identity, no AI trailers, never
   force-push". For private customer data, it also says "push nothing to
   csi-spl" and "work under `/var/spool-hub/dispatch/<topic>/work/`".
6. Placement: let the fleet pick (`auto`, `do_spl_box_pick`). Never pin
   `SPAWN_BOX` by habit: a pin on one box once starved CI of its runners.
   `pick=hold` (exit 10): every box is full, queue it and say so. A box out
   of a vendor's quota (read a seat's pane before placing) gets another
   vendor the data rule allows. A lane goes only to a box that has its
   vendor's CLI for the agent user (SPL-1649): each box measures its own
   (`spool_vendor_clis`) and publishes it as `cli=` in its BOX-0 lane-map
   row (`lane-map.sh --json`, `.load[].clis`). Exit 13 = no box with room
   has that CLI, or `SPAWN_BOX` names one without it; nothing was spawned:
   pick another vendor or install the CLI there.
7. Prove it: the window is listed, the seat is up, it runs as the agent user.
   Read every new pane at +2 min for a login screen, a usage-limit menu, a
   trust prompt or a vendor quota error. A grok or agy seat at quota 0 is
   dead on arrival: if it is, do the job yourself or pick another vendor the
   data rule allows.

**Check load before placement.** Before each spawn, measure the target box
with `uptime`, `nproc` and `cat /proc/pressure/cpu` (over ssh for another
box). Hold new lanes on a box over about 3x its cores in load or about 80%
CPU pressure. Tell the dispatcher which lanes are waiting. A starved box
makes local timeouts meaningless as evidence: on 2026-10-11 one box ran at
load 125 on 16 cores with 91% pressure, and a lane saw a fake navigation
timeout. Pin `SPAWN_BOX=<box>`, with the reason in the report, only when the
picker would choose the starved box, or when the owner orders a box.

- **Lane map check:** A seat with no recorded files (read-only, not a git repo) makes every `lane-map.sh --check` exit 4. Recording a non-repo path clears this.

- **Spawn HOLD:** A spawn answered HOLD (rc 10, "nothing was spawned") still leaves a remote request behind. Drop the duplicate before it spawns.

<a id="ws-doc-f4986b07-b900-4d3c-809a-8672d4413e59"></a>
### 5.1 Work classes and bands (SPL-1817)

Owner HUM-10, t1 3209f8b8 (binding msg 8cb6cc7d; msg ad816f96: "write this down into the runbook of the orchestrators and the dispatchers"). The rule, its bands and its commands have ONE home: [fleet-rules-index.md](fleet-rules-index.md), section 2, row "spawn queue: work classes and bands". What the orchestrator does with it:

- **Queue with the class.** Every spawn request is queued with its class: `ASK_ID=<id8> SPAWN_CLASS=<ci|refactor|bug|feature> ./run -a do_spl_spawn_enqueue`. The class comes with the request (the dispatcher states it); a request without one goes back to the dispatcher, never guessed. The enqueue refuses an empty class.
- **Let the placer keep the bands.** `do_spl_spawn_place` takes the next row by class, not by age. A lane placed by hand outside the queue carries no class and shows in the report as "no class": place through the queue.
- **A brief on the other box (SPL-3470).** Briefs are written on the box of the dispatcher that queued the row; the placer runs where the orch role is. A placed row whose brief is not on the placer's box and that was queued from another box (the hub row's `writer_box`) stays queued and out of the line, never handed to you: `do_spl_spawn_queue` shows `its brief <slug>.md is not under ... it was queued on <box>`. It is placed once the orch role is on that box, or here once you copy the file into the briefs dir. A row queued from this box with no brief here is still handed to you.
- **Record bypasses.** `SPAWN_BYPASS=<owner msg id>` only when the owner explicitly asked for that feature to go first; it is stored on the hub row and in the bypass log, and listed in the report. Never on your own judgement.
- **Watch the share.** `./run -a do_spl_spawn_share` (live lanes by class, verdict per band, bypasses). The placer's "SPAWN SHARE" supply blocker goes to the dispatch holder; when it reaches you, ask the dispatcher for the next rows of that class.
- **The idle filler.** Spare capacity becomes queued rows from open bug and feature issues within the bands: `./run -a do_spl_spawn_fill` (dry run: what it would queue now and why). The rule and its switch: [fleet-rules-index.md](fleet-rules-index.md), section 2, row "idle filler". You install its cron (`DRY_RUN=0 ./run -a do_spl_spawn_fill_install_cron`) and turn it on; it is off until you do.
- **Work groups (SPL-2370).** Rows that run N at a time (an epic "two lanes at a time") are ONE group, not N hand-queued asks: `GROUP_EPIC=<epic> GROUP_WIDTH=<N> GROUP_ROWS=<rows file> ./run -a do_spl_spawn_group_put`, one row a line, `<class> <vendor>:<slug> <issue key>`, briefs in the briefs dir as for any placement. The placer keeps N in flight and feeds the next row when one lands or closes; a single request is the group of one at width 1. The state: `./run -a do_spl_spawn_group_list`; a `WARN <EPIC>.json: state not read: <why>` there is the hub, issue or lane read failing (the file is fine), a `not a work group file` a bad file. The placer hands the hub lists to jq as files, never argv (SPL-2428: the asks list outgrew the 128 KiB argument limit). The design: [spec 135](../../specs/135-work-process/spec.md) section 11.
- **The weekly security round.** Every Friday 05:30 UTC two panel seats are queued (class bug, kind secret) and the round goes on the t1 calendar: `./run -a do_spl_security_round_queue` (dry run: the seats and the event it would add). The rule and its switch: [fleet-rules-index.md](fleet-rules-index.md), section 2, row "weekly security round". You install its cron (`DRY_RUN=0 ./run -a do_spl_security_round_install_cron`) and turn it on; it is off until you do.

<a id="ws-doc-cdb62881-a7b9-4564-a4f4-141513143ce5"></a>
## 6 Production operations

| operation | needs |
|---|---|
| prd reads (logs, `do_spl_db_query`, member lists) | nothing more: run them through their actions |
| prd desk or issue writes the dispatcher's harness refused | the dispatcher's file in `/var/spool-hub/dispatch/posts/`; post it, rename it to `<name>.posted` |
| a member or role change | the owner's words for that change, quoted with the msg id |
| `terraform apply`, a GCP project, billing or IAM change, a destructive `gcp-*` action | the owner's explicit go for that one call; terraform only through the tf-runner (`make do-tf-plan`, then `make do-provision`) |
| an agreed step with a plan | run it yourself through its named action: the owner does not paste commands |
| a force-push, a delete or rewrite of master | never by an agent without the owner's approval of that one push, and the owner decides who does it |

**Usage limits and logins.**

- Never pick "usage credits" in a usage-limit menu: it costs money, and it
  is the owner's choice only.
- Test a box's login with a one-shot call as the agent user
  (`claude -p 'reply ok' --model haiku`, or the vendor's equivalent): it
  reads the CURRENT credentials, unlike a running seat, which keeps the old
  token in memory until it restarts.
- Copying a login between boxes is credential work: only on the owner's
  explicit order, by a lane the data rule allows, with a backup, a sha256
  compare (never printing a token), and re-checks of BOTH boxes at +10 and
  +30 min (a shared refresh token can log a box out).

**External access (code-host collaborators, repo settings).**

- Verify the external account by evidence, not by its name: it owns the
  repo it is said to own, it authored that repo's commits, and it shared
  that repo with the owner.
- Use the box's code-host token file for the org, never a personal login.
- An ORG-wide setting (e.g. private-repo forking) is the owner's call even
  when a repo-level request needs it: report the refusal (422) and the
  options, change nothing.

Every GCP call runs as the per-environment service account (repo
`CLAUDE.md`), never the owner account; a missing permission is reported,
never worked around.

- **Destructive action lanes:** An accepted restore lane (or other destructive action) must not re-run the action while it exits. Stop and restore the same seat, then observe a 10-minute cool-down.

- **Workspace doc rename:** The workspace docs API (`do_spl_desk_doctree`) has no history-keeping rename. A brief cannot order a workspace-doc rename through it.

- **CI gate reports:** When reading `do_report_ci_gate` with signatures on, ignore lines that start with PASS even if they contain the word FAIL.

- **S4 Watchdog:** A lane that waits with one bash call longer than 15 minutes is restarted by S4. This drops instructions the old session had. Re-send them if this happens.

- **Open:** Which number should a shadow seat trust for lifetime attachment drops (LAST_RUN only shows the last pass)?

- **Disk headroom notice:** On a disk-headroom notice, stop placing lanes on that box.

- **Stalled boxes:** A stalled box does not show in LAST_RUN as a stall (`copied=` is the last pass). Check `ctime` of paths to detect bursts after a stall.

- **Unseating agents:** No named action unseats one live agent. `do_spl_desk_up_all` seats every live window on the owner desk.

- **Disk sweep (operator view):** A disk sweep (`box-disk-sweep`) freed count is only real if the file count dropped. Ignore rc=0 or DONE if no files were removed.

- **Backing up untracked tests:** Read the copy's result before reporting the backup. A mode 711 file owned by another user needs a different copy (`sudo` and a `cmp` check).

- **Exit gate ACCEPTED:** An `ACCEPTED` line must come from a role seat or the spawner. An editor's line is refused, and a seat on the other box needs its own line from the spawner.

- **Pre-push override:** Only the owner can set `SPL_PREPUSH_OVERRIDE`. A permission denied on the hook's log is not a failing test.

<a id="ws-doc-da85c12e-cacf-4bcd-a17b-867a92c9223e"></a>
## 7 Escalation to the owner

- A question only the owner can answer goes to the topic it belongs to, as a
  blocker, with ONE recommended action to approve with "go". Keep its
  permalink and cite it.
- A standing order that already decides it: apply it, report it, ask nothing.
- An agreed spec (panel consensus) goes to build lanes without a go.
  Refactoring rounds need no go either (role spec section 1.2).
- A check that needs an owner-held key is an owner blocker, never "optional".

<a id="ws-doc-7051fbeb-b758-4209-b2ce-4d7412012e54"></a>
## 8 Traps we hit

The dispatcher runbook's section 9 applies in full. In addition:

| trap | what happened | what to do |
|---|---|---|
| a duplicate placement | two orchestrator seats on two boxes placed the same ask; on another day 3 of 4 spawns after a lease takeover duplicated lanes the dispatcher had already placed | re-read the ask book and `lane-map.sh` right before the spawn; a close that exits 3 means it was done elsewhere |
| a brief that leaked | the spec 128 leak started in a brief that copied "a spec in csi-spl" next to "private" | the brief writer is the last check: read the request for that contradiction |
| a close before the verdict | a lane was ordered closed on "landed" while the dispatcher had sent it back | close on `ACCEPTED` only |
| contradictory orders | STOP, then RESUME, then a re-placement, for a check the dispatcher had run itself in one command | one decider; ask one question on crossed notes |
| a commit after the final result | a restarted session told "take no new work" still pushed a second commit after its final result, and that commit held a vacuous assert | diff every commit after a lane's final result before `ACCEPTED` |
| a stale lease file | a seat on a machine whose loop had stopped kept acting on a lease file older than 180 s | the age is part of the rule |
| a frozen seat the watchdog keeps calling OK | a grok turn that stops emitting hooks stays `OK`: the transcript reader looks only under `~/.claude/projects`, and the unfinished-plan lines are vibe's `▶` and `☐` glyphs. An S5 loop whose call timestamp never moves stays on "the hook warned" and never reaches Escape or takeover | the 5-minute check in section 2.4. A `HIT` whose evidence is unchanged for 5 minutes is a hang |

| the split lease (shadow) | A shadow seat reads the lease from the feed's notes, not the spool root. | No age is defined for a lease note; trust the lease file when you can read it. |

| 429 fencing (maxScale >= 2) | Both leases can become none@unreachable in the same minute the hub returns 429, and spec 102 fences both boxes. | The recovery and who may restart prd is an open owner decision (maxScale >= 2). |

<a id="ws-doc-f46e18f9-8de0-48ba-81d0-b777f00f1fb4"></a>
## 9 Gaps for a non-Claude seat

| part | today | a Grok seat |
|---|---|---|
| launchers and `/tmux-close-window` | Claude slash commands | the shell lines in section 2.3 |
| the "able" check of the lease | read the seat's pane footer | the shadow feed has no pane footer, so "able" still cannot be confirmed from the feed alone |
| the stuck check | the heartbeat is written by the grok hooks (`PreToolUse`, `PostToolUse`, `Stop`) | a frozen mid-turn with an empty inbox stays `OK`. The transcript tail reads `~/.claude/projects/*.jsonl` only, and a grok session lives under `~/.grok/sessions`. S8 needs that transcript to have moved in the last 5 minutes, so a freeze is not a hit. Section 2.4 is the check that covers it |
| hourly rotation | restarts the seat's session and waits for its ack | to be confirmed by the shadow run |
| memory files | `~/.claude/projects/*/memory/` | this page, the dispatcher's and the role spec carry what the memory held |

<!-- version: 0.3.0 · updated: 2026-10-13 · hanging-agent check, section 2.4 -->

- **Shadow feed limitations:** The feed has no pane footer, so confirming "able" cannot be done from the feed alone.
