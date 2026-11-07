# What broke on 2026-11-06: seat claude-3 (the agent and placement)

**Answer.** The agent did not get slower in the way that cost the day; lanes stopped being placed. Placed lanes fell 161 -> 52 (3.1x), commits 161 -> 36, and the two track each other (r = 0.97, n = 7 days).
**Why, as lost placements against 11-05 (-109):** the PC box off its uplink 00:20-07:15Z: -45 (41%); the claude weekly hold, 09:12-16:12Z, nothing placed for 7h00m: -36 (33%); the PC box dark again 14:31-22:55Z, so the evening ran on sat alone: -28 (26%).
**The agent's own change is real but second:** from 14:00Z, on both boxes, a median step takes about 40% longer (3.8 -> 5.4 s; p90 8.4 -> 16.9 s) because each message carries 2.3x the output tokens. Its cause is not established, and 11-02 shows the same fingerprint on a day with 99 commits.
**The owner's claims:** "3 times slower" holds for throughput, against a peak (2.9x commits against the 6 days before). "Half the agents sit idle" holds but is not new: about 61-64% of session wall time was waiting for a message on the good day, 67-72% on 11-06, 88% on sat during the hold.
**Correction to the brief's reported fact:** the "out-of-date 97%" explains at most 2h14m of the 7h00m hold. The reading was true when the hold began: 90% at 09:00Z, 96% at 12:40Z. The rule did what it says, and nobody put the choice to the owner for 7h08m.

All times UTC. Read 01:07-01:40Z on 2026-11-07. Tree: origin/master at 8011a451e. Boxes: `sat` and "the PC box" (the box the brief names by its short name, which the doc hygiene rule keeps out of this file). Commits on 11-06 re-counted: 36 (the brief read 35).

## 1. Timeline, 11-06

| time | what | source |
|---|---|---|
| 00:20:01 | the PC box's probe of the vendor API starts failing; its uplink interface reads `-` from 01Z | uplink-probe `<box>.external-api.tsv`, `<box>.tsv` |
| 00:20-07:15 | 11 lanes placed 00-07Z, all on sat (11-05 same hours, both boxes: 56; sat alone: 26) | `fleet_asks` |
| 02:24-06:48 | sat holds: "no box below its overflow mark" and "at or over the disk headroom"; sat load1 hour means 23-69 on 16 cores, peak 97.5 | sat `spawn-place/cron.out`, `box_stats` |
| 07:15:02 | the PC box's probe answers again; it takes 12 lanes 08-09Z | probe, `fleet_asks` |
| 09:00, 09:05 | c-001 posts: claude 90% on sat, on the PC box ("New claude lanes skip a box at 90%+") | `messages` |
| 09:12:08 | last lane placed (c-460) | `fleet_asks` |
| 09:12-16:12 | **7h00m07s, nothing placed.** 977 hold lines "claude weekly >= 90%" for 8 distinct asks at the head of the line | sat `spawn-place/cron.out` anchored on `fleet_asks` |
| 10-16 | commits 0. Boxes near idle: sat load1 6-9, PC box 4-16; sat tool time 0.1-0.6 h per hour (11-05: about 1) | `git log`, `box_stats`, transcripts |
| 12:40 | c-001 posts 96% on both boxes | `messages` |
| 13:58:08 | the kept row's read time: `claude 97 ...` (epoch 1793973488) | commit fe0455e48 body |
| 14:00 | the agent's fingerprint changes on both boxes (section 3) | transcripts |
| 14:31:06 | the PC box's probe rows stop. Rows only 18:50-19:25, then from 22:55:48 | `<box>.tsv` |
| 16:08-16:11 | the holder asks the owner; the owner answers that the limit is raised | `messages` |
| 16:12:15 | kept row removed by hand at 16:12Z (fe0455e48); first placement at 16:12:15 (c-253) | commit body, `fleet_asks` |
| 16-23 | sat takes 19 (11-05: 16): sat lost nothing. The PC box takes 7 (11-05: 38) | `fleet_asks` |
| 23Z on | the PC box takes lanes again: 7 in 23Z, 11 in 00Z on 11-07 | `fleet_asks` |

## 2. What got slower, by how much

Placed against committed, per UTC day. `fleet_asks` (role orch, `reason like 'placed:%'`, by `updated_at`); `git log origin/master` by committer date.

| day | 10-31 | 11-01 | 11-02 | 11-03 | 11-04 | 11-05 | 11-06 |
|---|---|---|---|---|---|---|---|
| placed | 126 | 88 | 110 | 76 | 128 | 161 | 52 |
| commits | 103 | 87 | 99 | 72 | 113 | 161 | 36 |

Pearson r = 0.974, n = 7: a correlation over a week, not proof of cause. 11-05 was the best of the 7 days. Against the 6 days before 11-06 (mean 114.8 placed, 105.8 commits) the drop is 2.2x placed and 2.9x commits.

The -109, bin by bin, against 11-05 (per-hour counts, same query):

| hours | 11-05 | 11-06 | lost | reading |
|---|---|---|---|---|
| 00-07 | 56 | 11 | 45 | PC box off its uplink; sat alone, at its load and disk holds |
| 08-09 | 15 | 15 | 0 | both boxes up, no hold: a normal rate |
| 10-15 | 36 | 0 | 36 | weekly hold |
| 16-23 | 54 | 26 | 28 | sat 16 -> 19; PC box 38 -> 7 |

08-09Z is the control: with both boxes up and no hold, 11-06 placed exactly what 11-05 did.

Reading the bins as causes is my inference from the coincidence of times. The hold is direct (the placer says so). The PC box bins are indirect: I did not find, and did not search for, a placer line that says the box is unreachable.

## 3. Does a Claude turn take longer?

Source: every main-thread `~/.claude/projects/*/*.jsonl` touched since the day shown, on both boxes (PC box 2404 files, sat 2482, first pass; sat read over ssh, nothing written there). "Step" = user entry to the last assistant entry before the next user entry.

**By day, nearly flat in the median:**

| day | sat step n, p50, p90 (s) | PC step n, p50, p90 (s) | first block p50 sat / PC |
|---|---|---|---|
| 11-04 | 14731, 3.9, 8.3 | 17104, 3.9, 8.9 | 2.9 / 3.0 |
| 11-05 | 17137, 4.2, 9.0 | 18095, 4.0, 9.0 | 3.1 / 3.0 |
| 11-06 | 11392, 4.3, 11.2 | 4731, 4.3, 9.9 | 3.0 / 3.2 |
| 11-07 (to 01:07Z) | 641, 5.8, 16.9 | 726, 6.1, 25.8 | 3.1 / 3.5 |

**The change hides inside the day. Same hours on sat, 16-24Z:**

| | 11-05 | 11-06 |
|---|---|---|
| messages | 5694 | 4143 |
| output tokens | 2.27 M | 3.79 M |
| step p50, p90 (s) | 3.8, 8.4 (n 5557) | 5.4, 16.9 (n 4448) |
| Bash p50, p90 (s) | 0.8, 13.9 (n 4791) | 3.5, 33.2 (n 3551) |
| load1, mean of hour means | 36.7 | 43.0 |
| model / tool hours | 7.6 / 13.3 | 10.7 / 12.4 |

So time to first block is flat, the step is 1.42x longer, tokens per message 2.3x, and tokens per second up about 1.6x (messages of 300+ tokens, p50 about 100 -> about 160): 2.3 / 1.6 = 1.44, close to the 1.42. The vendor API did not get slower. Each message got bigger.

**The onset is sharp and on both boxes at once (30-minute bins of output tokens per message, n in brackets):**

| bin | sat | PC box |
|---|---|---|
| 13:00 | 278 (132) | 246 (117) |
| 13:30 | 285 (120) | 401 (110) |
| 14:00 | 691 (235) | 811 (77) |
| 14:30 | 502 (152) | 275 (7) |
| 16:00 | 1088 (292) | no data |

Bash command length, sat, p50 chars per 15 minutes: 13:30 191, 13:45 312, **14:00 581**, 14:15 648, then 294-523, 16:00 652, 16:45 830.

**It is not a change of lanes.** Role seats do the same job before and after, so they are the control. c-001..c-004 and the main checkout on sat, tokens per message by 3 h bin: 401-442 all of 11-05, 483 at 12Z, 835 at 15Z, 858 at 18Z, 912 at 21Z (n about 600 per bin). A caveat on the control: role seats may also have been busier with the hold itself. Lanes moved in the same bins. Sessions spanning the onset: all 3 rose (n = 3, too few to carry weight).

**It is not only agents writing more.** Tokens per second rises inside fixed message sizes, where a longer message cannot inflate it. Up to 11-06 13:59Z against 14:00Z to 11-07 00:30Z:

| output tokens | sat pre n, p50 | sat post n, p50 | PC pre n, p50 | PC post n, p50 |
|---|---|---|---|---|
| 300-599 | 15958, 97 | 2609, 134 | 14047, 96 | 317, 128 |
| 600-1199 | 6140, 112 | 4121, 161 | 5461, 110 | 577, 162 |
| 1200-2399 | 1499, 135 | 2175, 167 | 1515, 125 | 279, 176 |
| 2400+ | 343, 158 | 871, 149 | 477, 146 | 166, 154 |

**It has happened before.** 11-02 shows the same fingerprint on both boxes, and 11-03 is back to normal:

| day | Bash cmd p50 chars, sat / PC | tokens/s p50 (messages >= 300 tok), sat / PC |
|---|---|---|
| 11-01 | 295 / 303 | 100 / 105 |
| **11-02** | **665 / 799** | **127 / 118** |
| 11-03 | 326 / 272 | 112 / 102 |
| 11-05 | 265 / 250 | 103 / 103 |
| 11-07 | 682 / 737 | 153 / 177 |

11-02 had 110 placed and 99 commits, so this state does not by itself stop the fleet. Hence second in my ranking.

**What it costs.** Output per unit of work rises, so a weekly limit burns faster. On sat 16-24Z, 67% more output tokens on 27% fewer messages. Whether those bigger messages also do more work per message is not established: Bash commands are longer, so a call does more, and Bash p50 rose 4.4x with load up 17%. I cannot split that rise between "box load" and "longer commands".

**Cause: not established.** Unchanged across the onset: model id `claude-opus-5-5`; CLI per box (sat 2.1.292, PC box 2.1.311, so not a CLI bump: two versions moved together); `settings.json` (mtime 11-03 on both); global `CLAUDE.md` (10-27 on the PC box, 10-11 on sat); `service_tier` and `speed` in `usage` (standard, standard); the `effort` value in api-request entries (medium in every row read, n 4912 on the PC box, 11-06 08:00 to 11-07 01:00). The owner reports raising the limit, and the kept row is read at 13:58:08, 2 minutes before the onset. That timing is suggestive only: nothing I can read links an account change to the model's behaviour.

Contamination: from about 00:30Z on 11-07 this panel's seats (this one included) write long analysis scripts, so the post window stops there. 11-07 figures above are not evidence of anything.

## 4. Placer holds, cordons, lanes per hour

- Lanes per hour: 11-05 peaks at 13; 11-06 is 0 for 00, 01, 05, 07, 10-15, 17. The 3-minute floor allows 20 per hour and did not bind.
- During the gap, by count of hold lines in sat's `spawn-place/cron.out` (4721 lines between the last `OK ask` before the gap, 09:05:31, and the first after it): 977 weekly hold (8 asks), 267 "pinned to the PC box: past its overflow mark" and 153 "pinned to the PC box: CORDONED" (10 asks together), the rest mostly `placed as agy` noise (6 asks) and pick lines. Lines count retries, not lanes.
- Not found: 9ce3e998 (c-460, 09:12:08) in the sat log. The gap's end points come from the DB. Which process placed c-459 and c-460 is not established.
- Asks pinned to the PC box: the placer reports it at 120-191% of a 60% high mark during the gap, while `box_stats` hour means for 11-13Z are load1 5-6 on 16 cores. I did not read how that % is computed, so I do not call it stale. It did not decide the day: the weekly hold covered sat as well.
- The hold is not the queue. Depth is 109-130 at every 6 h sample from 11-05 00Z to 11-07 00Z, so the backlog is not new. p90 wait did jump on 11-03 (270 -> 1815 min, confirming the brief), but the best day, 11-05, ran at p90 1264 min.
- Cordon: `dispatch/cordon/` on sat is empty now (dir mtime 11-07 01:06Z). The marker existed at some point in the gap (153 lines). Its time and author are not established.

## 5. Weekly limit

- 11-03: both boxes hit it ("resets Nov 7"; 36 messages on the PC box, 26 on sat). 11-04 is at full volume again; how is not established.
- 11-06: 90% posted 09:00 and 09:05, 96% at 12:40, reset named 11-11T17:00Z. The kept row names reset 11-12T08:59:59Z. They differ by 15h59; I cannot explain it.
- Output tokens per day, both boxes: 11-04 12.7 M, 11-05 14.5 M, the highest in my 10-28..11-06 counts. How much of the weekly limit a token is worth I cannot read.
- The bound on "stale": at 13:58:08 the row is read at 97. The owner's first matching post is 16:09, and it says the owner had informed earlier (keyword search of `messages` by `from_id`, 3 rows; a keyword search cannot prove there is no earlier post). So the hold ran on a stale reading for at most 2h14m, and on a true reading for at least 4h46m. That the row came from the cache is itself inferred in fe0455e48 ("no log holds the read").
- `weekly-limit-alert` on sat reads "no reading" for all vendors in the 8 tail lines I read, while the hold says 90%. I did not read its 11-06 lines; flagged for whoever owns that alert.

## 6. Ruled out

| suspect | evidence | verdict |
|---|---|---|
| CLI version | one version per box, 11-03 to 11-07 (41 messages of 2.1.311 on sat, 11-06 13Z, under lane ids c-148, c-156; why is not established) | no |
| New hooks | Stop hooks: p50 0.04-0.18 s, p90 at most 0.35 s; under 11 minutes a day per box in total (n 2228-3089 per day) | no |
| Rotation | per-rotation time flat. sat `lane` 170 -> 233 at 48 -> 47 s, PC box `lane` 368 -> 70; sat `orch` 24 -> 24 at 140 -> 143 s; `master` 48 -> 47 at 570 -> 594 s (`dispatch/rotate.log`, DONE rows). Wall time only: what a restart costs in re-reading is not measured | no |
| Compaction | PC box 11 -> 5, sat none on either day | no |
| Vendor API errors | sat: none on 11-06. PC box: 730 `api_error`, 87 "can't reach" on the day it lost its uplink; likely an effect, not aligned by the minute | no |
| Vendor API latency | first block p50 flat (section 3) | no |
| Queue depth, the 3-minute floor | section 4 | no |
| agy quota | 6 asks of about 125; loud in the log | no |
| Time from placement to landing | p50 53 and 27 min on 11-06, 50, 29 and 30 on 11-05, but n is 10 and 6 and the join selects lanes with a key in the summary: suggestive only | no sign |

Not ruled out: box load after 16Z (another lens), the push and gate queue (another lens; I measured Bash calls only), login expiry on the PC box (22 messages on 11-06, time lost not measured).

## 7. What I could not read

- Turn time for non-Claude seats: this lens read Claude transcripts only.
- Sidechains and subagents: excluded from most step figures.
- Box of origin per commit: git does not record it, so the PC box's share of the commit drop is inferred from placements.
- Why the PC box's probe rows stop at 14:31 and 19:25 with no reboot (uptime 5d22h at 01:07Z). A sleeping box and a stopped cron look alike from here.
- The wait classes count a gap by the message that ended it, on the day it ended, and "mentions spool in its first 200 chars" is a loose test. Treat 61-88% as a range, not a figure.
- `organizationRateLimitTier` has no history I can read, so a tier change at 14:00Z can be neither shown nor excluded.

## 8. How not to repeat it

Proposals only; this lane changes nothing.

1. **At the 90% crossing, ask the owner at once, with the cost named.** The alert at 09:00Z was a post; the question came at 16:08Z. The hold stops every new claude lane, so its first minute is an owner blocker ("no new lanes until <reset>; raise, or wait?"). This alone was worth up to 36 lanes. Largest gain for the least code.
2. **Project the burn.** The fleet can compute when it will reach 90%. A line at 70% saying "at today's rate, 90% at <time>" gives the owner the day, not the hour.
3. **Keep fe0455e48 (SPL-4932) and watch its stated gap:** a pane still showing an old banner re-keeps its %. A hold over N hours should re-read at the source and state the reading's age in the hold line.
4. **One box's bad day must not take 41% + 26% of the placements.** With the PC box gone, sat took 11 lanes in 8 h at its load and disk holds, and asks pinned to the PC box waited for it. On a box dark for more than N minutes: alert, unpin what can move, and measure what sat can really carry. Whether sat can carry both is another lens's question.
5. **Track the agent's fingerprint daily:** Bash command p50 chars, tokens per message, tokens per second inside fixed sizes, per box. It costs a cheap transcript read (under 20 s on sat here). The state of 11-02 went unseen until this panel, and it changes the quota burn.
6. **Find out what the 11-02 and 11-06 14:00Z state is.** Look for a boundary on 11-02 by the hour, and ask whether anything on the account changed then. Not done here; this is the open question of this seat.
