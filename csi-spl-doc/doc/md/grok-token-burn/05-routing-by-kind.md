# Grok token burn 5/6: which task kinds go to Grok

SPL-2577, owner HUM-10 topic t1 bd5579e7 (plan msg 0467b8be, analysis item
3: "Route only tasks that genuinely need Grok's strengths to it"). Measured
2026-10-20 on the prd token record: **no task kind shows Grok over 2x Claude
per finished lane, so the routing in cnf `env.box.agent_split_by_kind` is
not changed.** The only kind where both vendors have n >= 3 is
`simple_coding`. There Grok costs 1.70x Claude (n=4 against 26), and 1.27x on
the unkinded lanes, which the picker routes as `simple_coding` too. The gap
that is there (about 3x the uncached tokens) is the same in every group and
on both boxes. It belongs to the vendor, not to a kind, and routing by kind
cannot remove it.

## 1. What is counted

`cd csi-spl-orc && ENV=prd ./run -a do_spl_token_burn_by_kind` reads the hub
through `do_spl_db_query` (read only):

- **A lane** is one (box, agent id, vendor) in `fleet_token_burn_events`
  (spec 140) over the window (`TOKEN_KIND_DAYS`, 7). Role seats 001..003 and
  unattributed rows are left out.
- **Finished**: its last minute is over 60 min old, and its first minute is
  over 60 min after both the window start and its vendor's first minute in
  the record. Claude's collector began 2026-10-16 13:46Z, so a Claude lane
  already running then is cut.
- **Its kind**: the branch in `fleet_lanes` names the brief slug. The kind
  is the brief's `Kind:` (the picker's own `spl_lane_mix_brief_kind`), else
  the kind its queue ask names (`fleet_asks`, "lane_mix simple_coding"),
  else `unkinded`.
- **Tokens**: total = in + out + cache read + cache write; uncached = total
  minus cache read. The cell value is the median per lane.
- **The verdict**: a kind is over when both cells hold n >= 3 and the median
  total of Grok is over 2x Claude's. The last line prints `grok_over=`.

## 2. The numbers

Window 2026-10-13 .. 2026-10-20, both boxes; `TOKEN_KIND_LANES=1` lists each
lane. Tokens in millions, median per finished lane:

| kind | claude n | claude total | grok n | grok total | ratio total | ratio uncached | verdict |
|---|---:|---:|---:|---:|---:|---:|---|
| specs_and_docs | 13 | 8.28 | 0 | - | - | - | n<3 |
| tests | 10 | 4.98 | 0 | - | - | - | n<3 |
| simple_coding | 26 | 10.66 | 4 | 18.08 | 1.70 | 2.90 | ok |
| complex_coding | 87 | 11.78 | 0 | - | - | - | n<3 |
| i18n | 1 | 6.17 | 0 | - | - | - | n<3 |
| secret | 4 | 17.49 | 1 | 8.41 | 0.48 | 1.58 | n<3 |
| orchestration | 0 | - | 0 | - | - | - | n<3 |
| unkinded | 144 | 14.80 | 18 | 18.74 | 1.27 | 2.92 | ok |

`grok_over=none`.

The uncached share of all tokens is 5.9% for Grok and 2.3% for Claude, the
same on sat and on the PC. Grok misses its cache about 2.5x as often as
Claude, in every kind measured.

## 3. What it does not show

- **Grok has no measured lane** in `tests`, `complex_coding`,
  `specs_and_docs` or `i18n`: no Grok lane of those kinds is in the record
  (Grok answered 402 "usage balance exhausted" from 10-14 until the owner
  turned it back on 10-17), so no ratio exists for them.
  Nothing there is moved: an absent measurement is not evidence that Grok
  costs more.
- **Most lanes carry no kind.** 18 of 23 Grok lanes and 144 of 285 Claude
  lanes have no `Kind:` in a brief this box can read, and no kind in their
  ask. The briefs of 12 of the PC's Grok lanes are not on sat, where this
  ran.
- **The time is not the same.** 18 of the 23 Grok lanes ran on 10-13 and
  10-14. That was before the 50% compaction of [2/6](02-context-growth.md)
  went live. Every Claude lane ran from 10-16 on.
- The numbers are token counts, not quota. Neither vendor's quota is
  published per token.

Run it again once Grok has worked a week in every kind. If a kind then shows
`grok over 2x` at n >= 3, lower Grok in that row of
`env.box.agent_split_by_kind` (spec 115) in the same commit, and keep the
owner's rules: no mistral coding, agy has the last word on languages, and
the data rule for `secret` and `orchestration`.

## 4. The check

`csi-spl-orc/src/bash/tests/spl-token-burn-by-kind.tst.sh` uses synthetic
query rows and a temp briefs dir. It covers the kind order (brief under a
dispatcher prefix, then the ask, then unkinded, and the alias `hard`), the
medians and ratios, the n < 3 rule, the excluded lanes and the verdict. Three
controls turn it red: dropping the record-edge cut fails 3 checks, dropping
the n < 3 rule fails 3, and dropping the dispatcher brief prefixes fails 3.
