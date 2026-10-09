# Spec 115: Vendor Split by Task Kind

Status: draft, reviewed by a panel (section 9). Draft by a-647 (agy seat),
renumbered from 114 (114 is the doc-privacy draft). Supersedes spec 110 D5
for docs and specs (section 0.2). Nothing here is built yet; the code named
below is what exists on master at 5b49a31a9.

## 0. Owner words and what they change

### 0.1 Verbatim (HUM-10, t1 #spool-hub-devel topic d4981656, 2026-10-09)

- topic 5c3bb16a msg 4f07eb34: "...The anti-gravity to have much more weight
  on the documentation specifications - Mistral to have much more weight on
  the actual coding - Claude to have much more weight on the actual hardcore
  coding Simple coding and regular stuff should go to Mistral. Complex coding
  and hi-fi stuff should go to Claude. Something like that. AGI should not
  even do coding for now."
- topic 5c3bb16a msg 396d92c6: "So these categories: - specs and
  documentation - tests - execution of tests and simple coding tasks -
  complex coding At least those categories."
- topic b1ab562b msg fb9e228c: "we should have a main and a backup vendor,
  and the backup vendor should take over after two failed tries of the main
  vendor. For some of the tasks, even simple tasks, it might be that some
  agents will get stuck, and it will be better that the clever Claude will go
  and help them."
- topic f4d53ac4 msg eba98069: "definitely translations should always go to
  the AGY, and as a backup, vendor Claude."

### 0.2 Earlier rules this meets

| rule | source | here |
|---|---|---|
| D5: docs and specs go to mistral first, then agy | spec 110, msg c7970593 | **superseded for docs and specs** by msg 4f07eb34 (agy has "much more weight on the documentation specifications"); mistral keeps a weight there (section 2). D5's low-level coding to mistral stays. |
| D2: mistral may take secret and personal-data work | spec 110, msg 803c3b38 | the secret kind's backup is mistral |
| Data rule: secrets go to claude or mistral only, never qwen, grok or agy | global CLAUDE.md "Spawn an agent", spec 110 D2 | holds in every path, the fallback included (section 5) |
| Language rule: agy has the final word on multilingual text | t1 msg 296582df, 2026-10-08 | i18n main is agy; a claude draft waits for an agy review |
| Claude is the default vendor and the last fallback | t1 65f75266, spec 110 D4 | the last fallback for every kind except secret, which holds |

## 1. Goals

| id | goal | measured by |
|---|---|---|
| G1 | Each task kind has its own vendor weights, out of 100. The main vendor is the one with the highest weight. | `do_spl_lane_mix` prints the kind's row and its main |
| G2 | agy writes no code: its weight is 0 in every coding kind, and no fallback path reaches it for one | counting test T1 (section 8) |
| G3 | The backup takes over after 2 failed tries of the main on the same task | journal rows (section 6) and test T4 |
| G4 | A vendor that is out (quota, sign-in, dead key, switched off) is skipped at once, with no 2-try wait | test T5 |
| G5 | The data rule holds under every combination of vendors that are out | test T2 |

## 2. Kinds, weights, main and backup

Grok and qwen hold 0 in every kind (today's cnf: `grok: 0`, `qwen: 0`). They
stay in the table so that an admin can give them points again.

| kind | covers | agy | mistral | claude | grok | qwen | main | backup |
|---|---|---|---|---|---|---|---|---|
| `specs_and_docs` | specs, docs, plans, reviews of those | 70 | 20 | 10 | 0 | 0 | agy | claude |
| `tests` | writing tests | 0 | 30 | 70 | 0 | 0 | claude | mistral |
| `simple_coding` | running tests, simple and routine coding | 0 | 80 | 20 | 0 | 0 | mistral | claude |
| `complex_coding` | hard coding, architecture, hi-fi work | 0 | 20 | 80 | 0 | 0 | claude | mistral |
| `i18n` | translations, the language review of multilingual text | 100 | 0 | 0 | 0 | 0 | agy | claude, then an agy review |
| `secret` | secrets, personal data (`LANE_MIX_SENSITIVE=1` with any kind) | 0 | 0 | 100 | 0 | 0 | claude | mistral |

Rules on the table, enforced by the cnf validator and the hub PATCH:

- Each row sums to 100, every cell 0..100, and one vendor holds the strict
  maximum, so main is never a tie.
- `backup` is a vendor other than main. With weight 0 it may still serve as
  the backup: the secret row's mistral is the backup and is never in the mix.
- In `simple_coding`, `complex_coding` and `tests`, agy is 0 and is never the backup.
- In `secret`, only claude and mistral may be non-zero or the backup.
- **Multilingual personal data** (an `i18n` task that is also `secret`): claude or mistral drafts the text under the data rule, then agy reviews a masked copy. The masking is a coded step with a test, and what counts as personal data for the mask must be named or listed as a build-time detail.

Old kind names stay as aliases, so no caller breaks: `spec` is
`specs_and_docs`, `hard` is `complex_coding`, `default` (or unset) is
`simple_coding`, and `i18n` and `secret` keep their names. `tests` is new.
A `LANE_MIX_DIFFICULTY >= 60` with no kind means `complex_coding`. Below 60
with no kind it means `simple_coding`.

### 2.1 Why weights, not only main and backup (settled on the code)

The draft dropped weights and kept main and backup only. The Mistral seat's
item 6 would apply weights to the easy nudge only. **This spec keeps
per-kind weights.** The owner said "much more **weight**", not "only", and
the code already has the machinery:

- `_spl_lane_mix_easy` (csi-spl-orc `spl-lane-mix.func.sh`) picks the vendor
  furthest below its target by more than the tolerance, and otherwise the
  largest share. Run per kind, the same function does what the owner
  described: with mistral 80 / claude 20 for `simple_coding`, about 1 lane
  in 5 goes to claude when that kind's actual mix drifts.
- With main and backup only, claude would get 0% of simple coding until 2
  tries had failed. The owner wants claude to "go and help" stuck lanes,
  which is the backup rule (section 6), and also a share of the work, which
  is the weight.

Change from today: a kind no longer forces its first vendor (D5's "the kind
picks the FIRST vendor"). The weighted nudge now works inside each kind,
and with no drift beyond the tolerance it picks the main. This needs
per-kind actuals, so each registry row records the kind (section 4).

## 3. Configuration

### 3.1 cnf (`csi-spl-cnf/csi-spl/all.env.yaml`, next to `env.box.agent_split`)

```yaml
env:
  box:
    agent_split_by_kind:
      specs_and_docs: { agy: 70, mistral: 20, claude: 10, backup: claude }
      tests:          { claude: 70, mistral: 30, backup: mistral }
      simple_coding:  { mistral: 80, claude: 20, backup: claude }
      complex_coding: { claude: 80, mistral: 20, backup: mistral }
      i18n:           { agy: 100, backup: claude }
      secret:         { claude: 100, backup: mistral }
```

A vendor left out of a row is 0. `tolerance`, `window` and `auth_marker`
stay under `agent_split` and apply to every kind. The flat
`agent_split` vendor numbers are kept for one release, as the row for a
kind the picker does not know, and are then removed.

### 3.2 Hub (rdb)

0109 and 0155 hold one five-column split per tenant
(`tenants.agent_split_{claude,grok,agy,qwen,mistral}` with a sum CHECK).
They do not extend to per-kind rows. A new forward-only migration adds
`tenant_agent_split_kind(tenant_id, kind, vendor, weight, is_backup)` under
RLS, following the tenant-isolation pattern. Its CHECKs are the table rules
of section 2. The old columns stay until the WUI settings screen moves to
the new table. `do_spl_agent_split_show` gains `--kind <k>` and prints
`LANE_MIX_SPLIT` per kind.

Stale fact found in review, to be fixed in the build commit: the 0109
header comment and the cnf comment above `agent_split` still describe the
2026-10-04 split ("everything else, tests included, defaults to grok").
The numbers below that comment are claude 60, agy 20, mistral 20.

### 3.3 The instance setting beats all of it

The rdb 0149 instance setting, read with `spool fleet-load get`, is applied
first, as it is today. A vendor switched off or paused there counts as
**out** in every kind (section 5). It is never picked, and its weight in a
row goes to that row's backup, or to claude when the backup is also out.

## 4. Picker (`do_spl_lane_mix`)

Inputs: `LANE_MIX_KIND` (new names or aliases), `LANE_MIX_SENSITIVE`,
`LANE_MIX_DIFFICULTY`, and the new `LANE_MIX_TASK` (the task_id, needed for
the try count of section 6).

1. Resolve the kind. Sensitive data overrides any kind and makes it `secret`.
2. Read that kind's row (cnf, or `LANE_MIX_SPLIT_KIND` from the hub).
3. Apply availability (section 5) to get the effective weights.
4. Count this task's failed tries per vendor from the journal (section 6).
   - With 2 or more failed tries for main, pick the backup (section 5 order).
   - With fewer than 2 and at least 1 try on the task, retry the same main.
   - With no try yet, run the per-kind weighted nudge over vendors with
     weight > 0 that are available.
5. Print the per-kind table, then `pick=<vendor> launcher=/<vendor>-spawn
   kind=<k> reason=...`, or `pick=hold`.

Per-kind actuals: `spawn-window.sh` appends the kind as a new last column
of the `registry.tsv` row (today the row ends with the requester).
`_spl_lane_mix_actual` then counts the last `window` rows of that kind. A
row with no kind counts as `simple_coding`.

## 5. One rule for "out" and "failed"

Today there are two mechanisms: the availability skip (CLI, sign-in, S2
`kind=auth` and `kind=limit` verdicts, instance off or paused) and the
fixed chain `grok|mistral -> agy -> claude` (`_spl_lane_mix_next`).
**This spec keeps the skip and retires the fixed chain.** The chain is
wrong under the owner's words: with mistral out, today's `default` kind,
which is coding, falls to agy, and agy "should not even do coding".

The one rule: for a kind, the order of candidates is main, then backup,
then claude. Pick the first candidate that is:

- **available**: not out under the existing checks, and
- **not exhausted on this task**: fewer than 2 failed tries (section 6).

| case | result |
|---|---|
| main out (quota, sign-in, dead key, switched off) | backup at once; out is not a failed try |
| main failed 2 tries on this task | backup |
| backup also out or exhausted | claude, the default and last fallback (t1 65f75266) |
| `secret`: claude and mistral both out or exhausted | `pick=hold`: queue the work and send a blocker to the orchestrator. Never agy, grok or qwen. |
| `i18n` served by claude | the lane's result is flagged `needs_agy_review`, and the text does not ship until an agy lane reviews it (language rule) |
| claude itself out, last in line | `pick=hold`, as today |

A vendor out of every row (for example grok at 0) never enters the order.

## 6. "Failed try": what counts, and where it is read

A **try** is one lane id spawned for a `task_id` with a kind and a vendor.
It **fails** on exactly one of these signals. Each is read from something
that exists today:

| signal | source today | counts as failed when |
|---|---|---|
| F1 spawn fail | `spawn-window.sh` exit code: 11 is START FAIL (a dialog), and any non-zero except 10 | the exit is non-zero and not 10. **Gap:** printed on the spawner's stderr only, not persisted; the build writes the journal row. Exit 10 is HOLD (box load), which says nothing about the vendor. |
| F2 stuck | the watchdog's single counter `$SPOOL_ROOT/<id>/lifetime/restarts` (`<epoch> <cause>`; S1, S3, S4, S5 and S9 takeovers) and `<id>/lifetime/heldout`, written at `RESTART_MAX_PER_HOUR` (default 3); `do_spl_lane_restart` GATE FAIL "split this task" at `lane_restarts_before_split` (spec 063 R-L2) | the id is held out, or the lane restart refuses at the split count. One takeover alone is the watchdog's recovery, not a failure. |
| F3 red or nothing landed | CI on the lane's pushed sha (`gh run list --commit <sha>`, job-level as `do_report_ci_gate`); `/exit-clean` writes `<id>/lifetime/done` | at done, the lane's last landed sha has a red job that the lane caused and did not fix, or the lane exits with nothing landed (`git-fetch-fresh.sh --landed` non-zero) |

**Not a failed try:** any S2 verdict (`kind=limit`, `kind=auth`,
`kind=login`). Each one means the vendor is out, which section 5 already
handles. A red caused by another lane on trunk does not count either.

**Journal:** `$SPOOL_ROOT/dispatch/attempts.tsv` holds one row per try,
`task_id kind vendor id start_epoch outcome source`, with outcome `run`,
`ok` or `fail:<F1|F2|F3>`. The spawn writes `run`; the watchdog (held out),
`do_spl_lane_restart` (split) and `/exit-clean` (done, checks F3) close it.
These are coded checks with tests, never an agent's judgement (owner
10-07, "orchestration = code").

## 7. Migration

1. Write cnf `agent_split_by_kind`, the validator rules and `tpl-gen` for
   the dev and prd tfvars, if any read it.
2. Picker: per-kind rows, aliases, the one rule of section 5, and the
   journal reader. Remove `_spl_lane_mix_next` and the D5 `first=` map.
3. Writers for the journal: spawn-window (F1 and `run`), the watchdog
   (F2), lane restart (F2) and exit-clean (F3).
4. The rdb table and hub route, then the WUI settings screen, then the
   old five columns are dropped (forward-only, a later migration).
5. Update the fleet rules: the global CLAUDE.md "Spawn an agent" section and
   its source `20-spawn-an-agent.md`, and `/spawn-an-agent`, which today say
   specs go to agy and default work to grok or mistral by share.
   `do_check_fleet_rules_drift` pins the per-kind main.

## 8. Tests (each with its control)

| id | test | control (must turn it red) |
|---|---|---|
| T1 | 1,000 simulated picks per coding kind (`tests`, `simple_coding`, `complex_coding`), under every combination of mistral and claude being out: agy count is 0 | set agy 10 in `simple_coding` |
| T2 | `secret` (and `LANE_MIX_SENSITIVE=1` with every kind) under all 2^5 combinations of vendors out: the pick is in {claude, mistral, hold} | make the backup agy |
| T3 | per-kind nudge: with `simple_coding` actuals at 100% mistral over the window, the next pick is claude | weights ignored, so the pick is always main |
| T4 | 2 journal rows `fail:F2` for mistral on task X, so the pick for X is claude; with 1 row it is mistral | threshold at 3 |
| T5 | an S2 `kind=limit` verdict on a mistral lane gives an immediate backup and no journal `fail` | count S2 as F2 |
| T6 | `i18n` with agy out gives claude plus `needs_agy_review` | drop the flag |
| T7 | aliases `spec`, `hard` and `default` give the same pick as the new names | remove an alias |
| T8 | the validator refuses a row that does not sum to 100, a tied main, agy > 0 in a coding kind, or a secret backup outside {claude, mistral} | accept a tie |
| T9 | `i18n` combined with `secret`: agy receives no unmasked personal data | send unmasked personal data |

## 9. Panel

| seat | agent | verdict | changes it brought |
|---|---|---|---|
| author (agy) | a-647 | draft | kinds, main and backup, 2 tries, the data and i18n rules |
| Claude | c-649 | agree with changes | renumbered to 115; weights kept per kind, with main = highest weight (2.1); the fixed chain retired for one rule, since it sent coding to agy (5); F1-F3 named on real sources, with S2 excluded and the F1 gap stated (6); D5 superseded for docs (0.2); stale 0109 and cnf comments; `tests` main decided by owner |
| Mistral | m-650 | agree with changes | the secret backup to mistral (the picker holds today; D2 allows it: taken); the instance setting documented (3.3: taken); legacy and unclassified tasks via aliases (2: taken); the i18n review flag and tests (5, T6: taken); test cases T1, T2 and T6 (taken); the `tests` main decided by owner. Item 1, the missing `tests` kind, was not taken: the draft had it. Item 6, weights for the easy nudge only, was not taken: see 2.1. |

## 10. Owner decisions (2026-10-09)

**Q1. Who writes tests?** (msg 82e2db70)
"1b" - claude main (70), mistral 30, backup mistral. Tests guard correctness.

**Q2. Multilingual text that carries personal data.** (msg 8c99399f)
"2b" - the language rule wins; agy reviews the text after the personal data is masked out.