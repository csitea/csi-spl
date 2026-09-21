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

## 4. Success criteria

- **SC-001** — `bash csi-spl-iac/src/bash/tests/owner-acceptance-register.tst.sh`
  is green, its four planted controls are each rejected, and it runs in the
  `iac-suite` job on every push.
- **SC-002** — Every non-`PENDING` row's test is in the tree; the count of
  `PENDING` rows is the honest size of the gap, reported to the owner.
- **SC-003** — `ENV=dev ./run -a do_spl_owner_acceptance` drives the deployed
  dev WUI in the owner's thread and prints one PASS/FAIL line per case, with a
  `results.json` under the proof dir.

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
