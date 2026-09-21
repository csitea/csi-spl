# Feature Specification: the owner acceptance register — every case the owner stated, and the test that proves it

**Feature ID**: `031-spool-owner-acceptance` · **Milestone**: M3
**Created**: 2026-09-21 · **Lane**: OWNER-ACCEPTANCE-TESTS (CLE-3438)

**Owner input (verbatim, 2026-09-21)**: "those testing cases which we
specified" — and, on how the run should be watchable: "put the same bot into
the the web ui", "and start testing with it all of those terminal to msg
cases", "here and make it do all of the test ases", "for te showing up of the
messages ...", "one agents send another oo".

## 0. The gap this closes

The owner has stated acceptance criteria in conversation across several days.
Some of them already had tests; some had a test nobody could name; some had
none. Chat history is not a test suite: a case stated in a message is proven
only for as long as somebody remembers it, and the memory belongs to whichever
agent happened to be in the room.

This spec makes the list a **file in the tree**, `cases.tsv`, with one row per
case and the path of the test that proves it — and a gate,
`csi-spl-iac/src/bash/tests/owner-acceptance-register.tst.sh`, that fails the
build when a row names a test that is not there. The register cannot decay
into a list of promises, because the promise and the proof are checked against
each other on every push.

## 1. Requirements

- **FR-001** — Every acceptance case the owner has stated is a row in
  `cases.tsv`, with a stable `OA-NN` id, the spec that owns it, the test that
  proves it, its status and its owning lane.
- **FR-002** — A row whose `status` is not `PENDING` names a test path that
  **exists in the tree**. The gate fails otherwise.
- **FR-003** — A case that is not yet automated is `PENDING` and names the
  **intended** test path and an owning lane, so the gap has an addressee.
  A case whose test is in the tree but has not yet been run against the live
  env is `UNVERIFIED` — a distinct status, because "a test exists" and "the
  case is proven" are different claims and collapsing them is how a register
  starts lying. Neither is ever a reason to soften the case.
- **FR-004** — A case that **cannot** be automated is `MANUAL` and carries a
  procedure a human can follow, in §5 of this page.
- **FR-005** — This page and `cases.tsv` cannot drift: every `OA-NN` in one
  appears in the other, and the gate checks both directions.
- **FR-006** — The gate is hermetic (no network, no GCP, no browser) and runs
  in the `iac-suite` job of `10 ci: quality gate` on every push to master.
- **FR-007** — The message-display and terminal-delivery cases are additionally
  exercised END TO END by a **WUI-driving bot** (§3) that signs in to the
  deployed dev WUI as its own member, sends in the owner's thread, and asserts
  both halves: the message in the WUI and the message in the recipient agent's
  pane.

## 2. The register

`cases.tsv` is the register; this section is its reading, not a second copy.
The gate keeps the two in step.

| area | cases | where the proof lives |
|---|---|---|
| terminal delivery (028) | OA-01 OA-02 OA-03 OA-04 OA-05 OA-06 OA-07 OA-08 OA-09 | the Go notify hook tests, the `do_spl_m3_e2e` step `f`, and the spawn-agents notify test |
| the notice pane (028) | OA-10 OA-11 OA-12 OA-13 | CLE-3434's desk work — `PENDING` |
| latency (030) | OA-14 | CLE-3435's budget — `PENDING` |
| newest first (013) | OA-15 OA-16 OA-17 OA-18 | the WUI unit suite and two live proofs |
| code blocks (013) | OA-19 OA-20 OA-21 OA-22 OA-23 | the WUI unit suite and the live code-block proof |
| send reliability (013) | OA-24 OA-25 | the WUI unit suite and the live send-failure proof |
| UI rules (013 / 022) | OA-26 OA-27 OA-28 OA-29 OA-30 | the WUI unit suite |
| the WUI bot (this spec) | OA-31 OA-32 OA-33 OA-34 OA-35 | `csi-spl-wui/tests/e2e/owner-acceptance-bot.proof.mjs`, run by `do_spl_owner_acceptance` |
| the run is one named action | OA-36 | `csi-spl-orc/src/bash/tests/owner-acceptance.tst.sh` |
| a real IdP sign-in | OA-37 | `MANUAL`, §5 |
| the owner's own thread URL | OA-38 | the bot — **PASS** since `7044c2e0`, §3.1 |
| attachments survive a send | OA-39 | **PASS** on `713d6a8` — §3.2 |
| an attached file round trips | OA-40 | the half OA-39 does NOT prove — `PENDING`, §3.2 |

### 2.1 Why the terminal cases are `orc-e2e` and not CI

OA-02..OA-05 and OA-07 run inside `do_spl_m3_e2e`, which needs a tenant root
key, a live hub and a tmux server. None of the three exists on a GitHub
runner, so those rows are **proven on the box and recorded here** rather than
gated in CI; what CI gates is the layer underneath them — the notify hook
(`go`) — and the register itself. A row that claims CI coverage it does not
have would be worse than a row that says where it really runs.

## 3. The WUI-driving bot (the owner's addition)

The owner asked for the suite to be driven "in the web ui", in **their own
thread**, so the run can be watched where they are already looking:
`https://dev.spool-hub.ai/dm/CLE-00@box-desk?thread=<the owner's thread>`.

- **FR-B01** — The bot signs in over native auth (015) as **its own dedicated
  member**, created the way the e2e harness creates one. It never uses the
  owner's account.
- **FR-B02** — The bot opens the thread it was given (`OWNER_THREAD`), and
  every message it sends is **labelled** — `case N/M: <what this proves> —
  <what to expect>` — so the owner can read the run as a transcript.
- **FR-B03** — After each case the bot posts a single `PASS`/`FAIL` line into
  the same thread, so the result is visible where the owner is looking. The
  evidence (pane captures, screenshots, timings, `results.json`) goes to the
  proof dir, not into the thread.
- **FR-B04** — The cases are run **slowly enough to follow** (a settling pause
  between cases, configurable) and there are few of them; the register, not
  the thread, is the exhaustive list.
- **FR-B05** — Both halves of every message case are asserted: the WUI row for
  the sender, and the recipient agent's pane via `capture-pane`. A case that
  can assert only one half says so in its evidence rather than passing on the
  half it could see.
- **FR-B06** — The agent-to-agent cases (OA-01, OA-02) use **throwaway** agent
  ids and boxes. They never poke a live lane's pane and never write into
  another tenant.

### 3.1 OA-38 — the owner's URL does not do what it looks like (FAIL, 2026-09-21)

**Fixed in `c689a52`, measured PASS on build `7044c2e0`.** CLE-3433 confirmed
the ancestry rather than either of us guessing:
`git merge-base --is-ancestor c689a52 7044c2e0` -> exit 0. The row cites the
build this lane actually measured, not the later one that also carries it.

The owner asked the bot to "make it communicate with you" at
`/dm/CLE-00@box-desk?thread=<id>`. The run found that **a message sent from
that page does not join that thread**: the DM page never reads
`route.query.thread`, and each send starts a new task.

Measured, on tree `f76f648`, `ENV=dev TENANT_ID=t1 … do_spl_owner_acceptance`,
n=1:

- `grep -n 'query.thread\|route.query' csi-spl-wui/src/pages/dm/\[peer\].vue`
  -> no hits; the page's `onSend` is `channel.send(text)` with no parent task.
- `grep -n 'task_id: parentTaskId || newId()' csi-spl-wui/src/stores/channel.ts`
  -> 1 hit (line 278): with no parent task, every send mints a new one.
- the run's own evidence: 12 messages in `CLE-00`'s inbox from that one page,
  each carrying a DIFFERENT `task` in its poke line.

The consequence for the owner is exactly the symptom they described: messages
sent from that URL scatter into separate conversations, and an agent's reply
into one of them does not appear beside the others. **This was reported to
CLE-3433 (the WUI send lane), not fixed here** — this lane records cases, and
a fix in someone else's file is a rebase conflict for them.

CLE-3433's nuance is the better description of the defect, and is why it hid
for so long: **the thread PANE composer was always correctly bound**
(`:parent-task-id`), so the feature looked like it worked. What was broken is
that the big top box wrote somewhere other than where the URL said you were.

Until it is fixed, the bot's reply case answers the task its OWN message
created, read off the row's `data-task-id`, so the reply leg is testable on
its own rather than failing for this unrelated reason.

### 3.2 OA-39 — the same two handlers dropped ATTACHMENTS (CLE-3433)

Found by CLE-3433 while fixing OA-38, and recorded here because it is the same
owner case in a different costume: *the composer said it was sent, and it was
not*. Their measurement, on deployed `bb20552`, signed in, every outgoing WS
frame captured and held back, n=1 per route: `/lobby` 1 frame with 1 file;
`/dm` 1 frame with **0** files; `/channel` 1 frame with **0** files — and the
file chip vanished from the composer in all three, so it looked sent.

Two causes, both fixed in `a3b703b`: the handlers did not accept the `files`
argument, and `stores/channel.ts` never uploaded a `File` to `/v1/files` the
way `stores/live.ts` does. Types could not catch it, which is why it is worth
a case rather than a comment: a handler with fewer parameters is assignable to
`(text, files) => unknown`.

**PASS**, measured on deployed `713d6a8` (built 13:46:31Z, run 35607565054),
same held-back-frame script, n=1 per route:

| route | before (`bb20552`) | after (`713d6a8`) |
|---|---|---|
| `/lobby` | 1 file | 1 file — the CONTROL, unchanged |
| `/dm/<peer>` | **0 files** | 1 file |
| `/channel/lobby` | **0 files** | 1 file |

The control is what makes the pair readable: a route that was already correct
stayed correct, so the two that moved moved because of the fix and not because
the script changed. Ancestry was checked rather than assumed —
`git merge-base --is-ancestor a3b703b 713d6a8` -> exit 0, and
`git merge-base --is-ancestor bb20552 a3b703b` -> exit 0 — so the after-build
carries the fix and the before-build genuinely predates it.

**Two limits CLE-3433 stated with the evidence, kept here because dropping
them would overstate it**: n=1 per route with one 27-byte text file, so it
proves the ref reaches the frame and not that a large or binary upload
survives; and the frame was HELD BACK, so it proves the CLIENT puts the file
on the wire and not that the hub stores and serves it. That second half is
**OA-40**, and it is `PENDING` rather than folded into OA-39 — "the file was
sent" and "the file arrived" are different claims, and this register exists to
stop exactly that kind of merge.

## 4. Success criteria

- **SC-001** — `bash csi-spl-iac/src/bash/tests/owner-acceptance-register.tst.sh`
  is green, its four planted controls are each rejected, and it runs in the
  `iac-suite` job on every push.
- **SC-002** — Every non-`PENDING` row's test is in the tree; the count of
  `PENDING` rows is the honest size of the gap, reported to the owner.
- **SC-003** — `ENV=dev ./run -a do_spl_owner_acceptance` drives the deployed
  dev WUI in the owner's thread and prints one PASS/FAIL line per case, with a
  `results.json` under the proof dir.

### 4.1 Verified status — 8 of 8, twice, 2026-09-21

`ENV=dev TENANT_ID=t1 OA_THREAD=0cd6b6d2-… DRY_RUN=0 ./run -a do_spl_owner_acceptance`
against `https://dev.spool-hub.ai`, WUI build `713d6a8`, tree `99a8fcb`,
**n=2** (16:50:35 and 16:52:5x EEST, 8/8 both times). Evidence:
`~/.local/share/<org>-<app>/cloud/dev/owner-acceptance/t1/<utc>/results.json`
plus seven screenshots per run.

| case | result | evidence |
|---|---|---|
| OA-31 signed in as its own member, thread open | PASS | one sign-in attempt, no retry needed |
| OA-32 in the thread at once, exactly once | PASS | `wui_ms` 23 / 25, `copies` 1 |
| OA-33 visible in the agent's pane with its msg_id | PASS | `pane_ms` 293, notice pane `%78` |
| OA-34 the agent's reply comes back to the thread | PASS | `reply_ms` 6500 / 5695 |
| OA-19 code block in the DM composer | PASS | opened, held Enter, closed, rendered as code |
| OA-24 a send lands or visibly fails | PASS | outcome `landed` |
| OA-35 a PASS/FAIL line per case in the thread | PASS | 7 verdict lines posted |
| OA-38 the owner's `?thread=` URL | PASS | requested and actual task ids equal |

**The three timings are reported apart and never added**, which is the owner's
own rule and the reason they are useful: `wui_ms 25` (the sender's own row),
`pane_ms 293` (delivery and visible in the terminal), `reply_ms 5695` (how
long the agent took to answer). Blending them would produce ~6 s and hide that
the transport legs are fast and the *thinking* is what takes the time.

**What `pane_ms 293` does and does not say.** It is an **upper bound at n=2**,
not an instrumented figure: `pane-seen.sh` polls every 250 ms, so the true
value is anywhere at or below 293 ms and the resolution is the poll. It is
enough to say the terminal leg is not seconds-slow — which is what the earlier
`32 s` reading turned out to be measuring (a stranded sidecar, §4.2) — and it
is **not** enough to claim the 0.3 s budget is met. OA-14 stays with CLE-3435,
whose instrumented harness is the thing that should answer that.

### 4.2 The stall OA-33 / OA-34 hit — an 11-minute DEAFNESS, not message loss

**Fixed on trunk: `1dfaf71` (CLE-3436, the client keepalive) and `e52bf02`
(CLE-3434, `do_spl_desk_check`).**

The bot found a desk that had stopped delivering while its process stayed
alive and its own log still read `hub session up`. Measured on dev, tree
`ed74ce7`, n=1:

- `ps -eo pid,etimes,args | grep hub-run` -> one process, pid 2492877,
  `etimes` 992 at 16:27:23: alive since 16:10:51, never restarted.
- the sidecar log's last session line is `16:10:51 INF hub session up`; the
  only entry after it is, at 16:25:52,
  `WRN pin refresh error="hub refused: door (a valid upload token is required)"`.
- `ls --time-style=+%H:%M:%S .../spool/CLE-00/inbox | tail -1` -> newest file
  **16:19:18**, still 16:19:18 at 16:27:23 — eight minutes of silence across
  a run that sent eight messages.
- CLE-3434 added the two facts that settle it: `GET /v1/view/roster` read
  `box-desk online=FALSE, last_hello 13:10:51Z` while `ss -tnp` still showed
  the socket `ESTAB`. The hub had no session, the client believed it had one.

**The correction this lane got wrong, and it matters.** This was first reported
— by this lane — as "the hub accepted it, the agent never received it", which
reads as LOSS. It was not. CLE-3436 checked the inbox after the restart and
every 16:26 message was there, written at the instant the sidecar reconnected:
the hub queued them and the drain delivered them. The DURABLE path did its
job; the LIVENESS path did not. Those have different fixes, and only one of
them was broken.

The measurement that produced the wrong reading was a correct one taken at the
wrong moment: `grep -rl <msg_id> .../CLE-00/` found nothing **while the box was
deaf**, and "missing now" was read as "lost". The check that tells the truth is
the same grep after the box reconnects. That distinction is now the rule this
lane applies: **a stall is only loss if the message is still missing once the
box is back.**

Cause (CLE-3436): the hub has pinged its peers since 017 FR-SEC-004; the client
never did, so a socket that black-holed left the sidecar blocked in
`wsjson.Read` on a session it believed was up. A box session now pings every
30 s and closes on a missing pong, which bounds the stall at about 40 s rather
than ending it — and `do_spl_desk_check` names the state (`ok | stranded |
down | unpinned | agent-missing`) in one line when it happens again.

**The trap CLE-3434 caught, worth keeping.** `do_spl_desk_up` rebuilds the
binary, so a restart normally picks up trunk — but a restart that happens
*before* the fix lands produces a healthy sidecar running the old code, and a
re-run then measures the old code and reports the fix as ineffective. The
check is the binary, not the restart:
`strings <state>/bin/spool | grep -c "did not answer a ping"` -> 0 before,
1 after.

## 5. Manual procedures

### OA-37 — a real human Google / Microsoft / LinkedIn sign-in

**Why this cannot be automated.** The IdP consent screens are served by
Google, Microsoft and LinkedIn, behind bot detection, and a scripted sign-in
to them would be both fragile and against those providers' terms. What the
spool controls — the callback host, the state cookie, the session it mints and
the avatar route — is covered by the 010/018/019 tests; what it does not
control is the consent screen itself.

**Manual procedure** (about two minutes, per provider):

1. Open `https://dev.spool-hub.ai/login?tenant=t1` in a normal browser
   profile that is NOT signed in to the spool.
2. Click the provider's button. Expect the provider's own consent screen on
   the provider's domain.
3. Complete the sign-in. Expect to land back on the WUI, signed in, with the
   user menu showing the account's name and picture.
4. Reload once. Expect to stay signed in (the `__session` cookie survived).
5. Record the provider, the date, the WUI build (`/build.json` `commit`) and
   the outcome in this section.

| date | provider | build | outcome |
|---|---|---|---|
| — | — | — | not yet recorded this cycle |

## 6. Assumptions and decisions (auto-mode, logged)

- **D-01 A TSV, not a markdown table.** The gate has to parse it, and a
  markdown table drifts the moment somebody re-aligns the pipes. The prose
  lives here; the machine reads `cases.tsv`.
- **D-02 The gate lives in the iac suite.** It is a hermetic file check over
  the whole repo, which is exactly the shape of that job (`rdb-no-store-entities.tst.sh`
  reaches into `csi-spl-rdb` the same way), and that job already runs on every
  push with no identity.
- **D-03 `PENDING` is a first-class status.** The alternative — leaving a
  stated case out of the register until someone automates it — is how the list
  got lost the first time. A `PENDING` row with an owner is a handoff; an
  absent row is an amnesia.
- **D-04 The pane assert stays in bash.** The bot is a node process driving a
  browser and cannot read tmux. The 028 pane rules — the box-tag prefix on the
  window name, the `@spool_notices` pane, and the hard wrap that splits a word
  across lines — already exist in `desk-probe.py` and `spool-notify.sh`, so the
  bot shells out to `csi-spl-orc/src/bash/scripts/pane-seen.sh` rather than
  carrying a second copy that would drift from them.
- **D-05 The bot runs in the owner's thread, not a private one.** The owner
  asked to watch it. The cost is that the thread carries test traffic, so
  every bot message is labelled as a case and the agent-to-agent cases use
  throwaway ids that touch no live lane.

<!-- version: 1.0.0 · updated: 2026-09-21 · last-edit: 2026-09-21T13:20:00Z -->
