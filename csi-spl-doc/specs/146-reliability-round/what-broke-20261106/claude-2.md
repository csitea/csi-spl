# What broke on 2026-11-06: seat claude-2, lens "the path to land"

**Answer.** The owner is right about the output: 11-06 landed 36 commits and 22 issues, against 161 and 65 on 11-05 and a 10-day median of 108 and 57.5 (about 3x lower than a normal day, 4.5x lower in commits than 11-05).
**The path to land did not get slower.** Spawn to land stayed flat (p50 85 -> 89 min, n=91 and 29), and so did first commit to land (95 -> 91 min). No gate, push worker or review commit lines up with the drop.
**The fleet lost working hours instead.** The PC box was gone for 14 h 44 min (Wi-Fi down 00:20-07:14Z, lid closed 14:32-18:50Z and 19:25-22:55Z), and the Claude weekly hold stopped new lanes from about 09:05Z to 16:12Z, including three R7 reviewer seats that then waited 320-406 min. The reading was true until the credential change at 13:57Z and stale only after it (corrected, section 8).
**Only review push to land grew** (p50 66 -> 132 min), and outside those windows it is back to 70 min (n=24). Load fell to 5-9 on 16 cores at 11-16Z: lanes were waiting, not computing.
**"3 times slower" is true of the output, not of the speed of the work.** Not established: why the Wi-Fi dropped, and how much of 11-05's high count was a backlog being released.

Tree: `origin/master` at `04a51b255` (fetched 2026-11-07 00:58Z). All times UTC. Read 00:58-01:15Z on 2026-11-07. "PC box" is the laptop that holds part of the fleet; "sat" is the satellite box.

## 1. Timeline of 2026-11-06

| time (Z) | event | source |
|---|---|---|
| 00:20:10 | PC box uplink probe flips from `0 1` to `100 0` in columns 2-3; interface column `-` from 00:21 | `uplink-probe/<box>.tsv` |
| 00-07 | PC box lanes log "Can't reach the API server" 13 times an hour | transcripts, `isApiErrorMessage`, n=87 |
| 01-06 | PC box writes no `box_stats` row; 0 gate starts | `box_stats`, `pre-push.log` |
| 07:14:42 | PC box Wi-Fi reconnects | journal, NetworkManager |
| 08-09 | 13 new lanes start on the PC box, its only starts of the day before 19Z | transcript first timestamps |
| about 09:00-09:20 | the placer starts printing `HOLD (waiting: claude weekly >= 90% ...)` | `spawn-place/cron.out` (clock proxy, section 6) |
| 09:26, 10:12, 11:00 | R7 reviewer asks for SPL-4911, 4912, 4909 are raised | `fleet_asks.created_at` |
| 11-14 | both boxes idle: load 5-9 on 16 cores with 23-25 agents up; 1 commit lands between 09:20 and 16:12 | `box_stats`, `git log` |
| 14:32:02 | PC box: `Lid closed`, suspend | journal, `systemd-logind`, `PM: suspend entry` |
| 16:12 | the kept row is removed by hand; the three reviewers start at 16:12, 16:15, 16:20 | commit `fe0455e48`, transcripts |
| 18:50-19:25 | PC box awake for 35 min | journal, `Lid opened` / `Lid closed` |
| 22:55:44 | PC box awake again, 19 "Login expired" in its 22Z lanes | journal, transcripts |
| 23Z | landings resume: 10 commits in the hour | `git log` |

## 2. Evidence

### 2.1 Output

`git log origin/master --format=...`, by committer date (a rebase re-stamps it, so it is the last rebase, not the exact land):

| day | 10-27 | 10-28 | 10-29 | 10-30 | 10-31 | 11-01 | 11-02 | 11-03 | 11-04 | 11-05 | **11-06** |
|---|---|---|---|---|---|---|---|---|---|---|---|
| commits | 141 | 161 | 98 | 210 | 103 | 87 | 99 | 72 | 113 | 161 | **36** |
| issues cited | 96 | 97 | 60 | 84 | 55 | 44 | 54 | 40 | 53 | 65 | **22** |

11-05 is a high day, so comparing with it alone overstates the drop. 11-06 against the 10-day median is 3.0x (commits) and 2.6x (issues).

Commits per hour, same source:

```
hour    00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23
11-05    2  4  8  7  7  2 27 13  1  9  0 14  5  3  1  3  5  4  4 15  9 10  4  4
11-06    0  0  0  1  2  1  0  5  4  3  0  0  0  0  0  0  0  5  2  1  2  0  0 10
```

Gate starts per hour (`hygiene` PART lines, `$HOME/.cache/csi-spl/pre-push.log` on each box):

```
hour      00 01 02 03 04 05 06 07 08 09 10 11 12 13 14 15 16 17 18 19 20 21 22 23
PC 11-05  18 16 15 14 19  7 14 17  6 17  9 21 10  7  3 11 11 16  9  6 24 13 15 17
PC 11-06   2  0  0  0  0  0  0  9 14 13  4  0  0  0  0  0  0  0  0  0  0  0  0  3
sat 11-05  3 13 12  7  7  4  9  4  1 10  8  5  7  8 12  7  9  4  8  7  6  6  9  2
sat 11-06 12  3  5  3  8  7  5  3  4  1  0  0  0  0  0  0  7 10  8  7  7  2 11 19
```

The gaps match the outages to the hour. Both boxes stop at 10-11Z, sat restarts at 16Z, the PC box at 23Z.

### 2.2 The path to land, step by step

Method: for each lane transcript on both boxes (PC n=1174, sat n=1083 session files changed since 11-04) I took the `Bash` commands and their timestamps. The land time is the last commit on master citing the lane's seed issue. The lane set is every lane whose seed issue landed that day, so an issue with lanes on both boxes counts once per box.

| step (minutes) | 11-04 p50 / p90 | 11-05 p50 / p90 | 11-06 p50 / p90 | n (04, 05, 06) |
|---|---|---|---|---|
| spawn -> land | 82 / 476 | 85 / 575 | 89 / 610 | 67, 91, 29 |
| 1st commit -> land | 67 / 413 | 95 / 669 | 91 / 595 | 51, 67, 25 |
| 1st commit -> 1st push | 14 / 37 | 9 / 31 | 10 / 44 | 43, 57, 23 |
| **review push -> land** | 63 / 384 | 66 / 649 | **132** / 564 | 56, 76, 24 |
| review push -> land, outage windows removed | | | **70** / 256 | 24 |
| gate commands per lane | 5 / 10 | 4 / 12 | 4 / 11 | 67, 91, 29 |

Windows removed: the hold (09:20-16:12) for every lane; link down and both suspends for PC box lanes only, counted once where they overlap.

**Survivorship:** this table counts lanes that landed. It cannot see a lane still waiting. Lanes starved by the outages show up in the output table, not here.

Issues landed that had a lane on each box: PC 58 -> 11, sat 33 -> 18. Whole-gate passes per day from `pre-push.log`: PC 187 -> 29, sat 76 -> 56.

### 2.3 Wait for a reviewer seat

Join of `OK ask <id> placed: <lane>@<box>` (placer log), `fleet_asks.created_at` and the lane's first transcript line. Asks whose summary names a review:

| lane start day | n | p50 wait (min) | p90 wait (min) |
|---|---|---|---|
| 11-04 | 56 | 33 | 4515 |
| 11-05 | 91 | 28 | 459 |
| 11-06 | 26 | 115 | 829 |

The three that crossed the hold on sat, demonstrated (n=3):

| asked | started | wait (min) | seat | for |
|---|---|---|---|---|
| 09:26 | 16:12 | 406 | c-253 | SPL-4911 |
| 10:12 | 16:15 | 364 | c-254 | SPL-4912 |
| 11:00 | 16:20 | 320 | c-255 | SPL-4909 |

A fourth, asked at 09:19 (a language review), started at 23:08 on the PC box.

What lanes said at noon: I read the last assistant text before 12:00Z of the 14 live lanes that had pushed a review branch (a rough set, from a text marker). Five author lanes (c-456, c-444, c-454, c-148 and c-156 on the PC box) say they wait on a review or a GO; two reviewer seats (c-232, c-225 on sat) wait for a verdict or an input; the rest are standing seats or other work. The authors of SPL-4912, 4911 and 4909 (c-456, c-454, c-444) are among the five, so the hold reached work already written. n=5, read by hand. These lanes went on rotating and acking while they waited.

### 2.4 Lanes (sample)

The `gate cmds` and `push cmds` columns count Bash commands naming the action, polls of a gate included. The `idle turns` column sums the gaps after a turn ended with no tool call.

#### 2.4.1 Lanes landed on 11-05 (every 4th of n=98 with a commit, in land order)

| lane | box | issue | start | 1st commit | gate cmds | push cmds | 1st review push | idle turns (min) | landed |
|---|---|---|---|---|---|---|---|---|---|
| c-164 | PC | SPL-4818 | 11-04 18:05 | 11-04 18:12 | 3 | 2 | 11-04 18:20 | 268 | 00:02 |
| c-342 | PC | SPL-4829 | 11-04 23:32 | 11-04 23:45 | 5 | 1 | 11-04 23:58 | 99 | 02:08 |
| c-129 | PC | SPL-4811 | 11-04 16:58 | 11-04 17:34 | 5 | 12 | 11-04 17:45 | 452 | 03:03 |
| c-155 | PC | SPL-4816 | 11-04 17:58 | 11-04 18:18 | 18 | 5 | 11-04 18:19 | 410 | 03:33 |
| c-160 | sat | SPL-4821 | 03:41 | 04:08 | 4 | 0 | 04:08 | 11 | 04:09 |
| c-428 | PC | SPL-4804 | 02:07 | 02:15 | 2 | 0 | - | 0 | 06:20 |
| c-496 | PC | SPL-4834 | 04:03 | 04:09 | 4 | 6 | 04:49 | 103 | 06:43 |
| c-145 | sat | SPL-4808 | 01:31 | 01:33 | 4 | 0 | 01:38 | 2 | 06:48 |
| c-097 | sat | SPL-4797 | 11-04 13:31 | 11-04 13:53 | 20 | 15 | 11-04 13:53 | 711 | 07:00 |
| c-165 | sat | SPL-4824 | 04:50 | 05:06 | 8 | 0 | 05:35 | 111 | 07:39 |
| c-931 | PC | SPL-4782 | 11-04 09:52 | 11-04 10:24 | 15 | 12 | 11-04 10:49 | 1021 | 09:35 |
| c-114 | sat | SPL-4813 | 11-04 17:46 | 11-04 18:21 | 19 | 9 | 11-04 18:20 | 654 | 09:47 |
| c-760 | PC | SPL-4847 | 11:12 | 11:19 | 3 | 0 | 11:19 | 1 | 11:23 |
| c-756 | PC | SPL-4852 | 11:03 | 11:51 | 0 | 0 | 11:50 | 35 | 11:57 |
| c-181 | sat | SPL-4846 | 09:44 | 09:55 | 6 | 1 | 10:07 | 112 | 12:24 |
| c-813 | PC | SPL-4860 | 12:30 | 12:32 | 3 | 1 | 13:02 | 48 | 13:23 |
| c-873 | PC | SPL-4869 | 14:36 | 15:01 | 3 | 3 | 15:22 | 38 | 15:48 |
| c-192 | sat | SPL-4867 | 14:20 | 14:33 | 4 | 6 | 14:36 | 73 | 16:10 |
| c-971 | PC | SPL-4877 | 17:23 | 17:32 | 6 | 3 | 17:34 | 19 | 18:01 |
| c-164 | sat | SPL-4810 | 04:46 | 06:14 | 13 | 0 | 05:32 | 595 | 19:00 |

#### 2.4.2 Lanes landed on 11-06 (every 1th of n=39 with a commit, in land order)

| lane | box | issue | start | 1st commit | gate cmds | push cmds | 1st review push | idle turns (min) | landed |
|---|---|---|---|---|---|---|---|---|---|
| c-227 | sat | SPL-4902 | 02:23 | 02:35 | 3 | 0 | 03:09 | 70 | 03:52 |
| c-221 | sat | SPL-4902 | 11-05 23:13 | 11-05 23:59 | 11 | 6 | 11-05 23:59 | 217 | 03:52 |
| c-219 | sat | SPL-4900 | 11-05 23:05 | 11-05 23:34 | 5 | 3 | 11-05 23:55 | 185 | 04:09 |
| c-230 | sat | SPL-4892 | 03:36 | 03:39 | 3 | 0 | 04:22 | 38 | 04:50 |
| c-213 | sat | SPL-4892 | 11-05 22:05 | 11-05 22:26 | 8 | 6 | 11-05 22:51 | 287 | 04:50 |
| c-233 | sat | SPL-4901 | 04:27 | 04:28 | 0 | 0 | 04:46 | 66 | 05:56 |
| c-220 | sat | SPL-4901 | 11-05 23:09 | 11-05 23:59 | 13 | 2 | 00:02 | 247 | 05:56 |
| c-150 | PC | SPL-4896 | 11-05 22:36 | 11-05 22:43 | 3 | 4 | 11-05 22:43 | 80 | 07:21 |
| c-157 | PC | SPL-4896 | 11-05 22:47 | 11-05 22:51 | 0 | 0 | 11-05 22:51 | 42 | 07:21 |
| c-237 | sat | SPL-4904 | 04:53 | 04:56 | 5 | 5 | 05:46 | 84 | 07:41 |
| c-098 | PC | SPL-4888 | 11-05 21:04 | 11-05 21:20 | 7 | 13 | 11-05 21:50 | 157 | 08:02 |
| c-152 | PC | SPL-4888 | 11-05 22:40 | 11-05 22:56 | 4 | 0 | 11-05 22:56 | 113 | 08:02 |
| c-425 | PC | SPL-4907 | 08:15 | 08:18 | 3 | 0 | 08:18 | 16 | 08:36 |
| c-243 | sat | SPL-4907 | 08:31 | 08:35 | 3 | 0 | - | 0 | 08:36 |
| c-160 | PC | SPL-4899 | 11-05 22:51 | 11-05 23:23 | 10 | 9 | 11-05 23:41 | 83 | 08:37 |
| c-226 | sat | SPL-4899 | 02:20 | 03:27 | 6 | 0 | 03:06 | 265 | 08:37 |
| c-419 | PC | SPL-4903 | 08:07 | 08:26 | 4 | 0 | 08:26 | 27 | 08:58 |
| c-235 | sat | SPL-4903 | 04:30 | 04:41 | 12 | 8 | 04:41 | 128 | 08:58 |
| c-422 | PC | SPL-4906 | 08:11 | 08:45 | 4 | 2 | 08:49 | 40 | 09:01 |
| c-447 | PC | SPL-4906 | 08:57 | 09:00 | 2 | 0 | 09:00 | 2 | 09:01 |

## 3. Commits since 10-28 against the drop

`git log origin/master --since=2026-10-28 -- <gate, push worker, review GO, placer, quota files>`, read in full; the ones that could matter:

| commit | when | change | cost measured | fits the drop? |
|---|---|---|---|---|
| `8e1454e2b`, `c39a3278b` SPL-4040 | 10-28 | fast-tier iac and orc budgets scale with load | orc p90 was high before and after (4.1) | no: chronic |
| `d07ea410a` .. `1c46e0d71` SPL-4101, 4251, 4316, 4427 | 10-28..30 | automatic review GO | 18 automatic GOs on record, 205 refused for a shared vendor; the holder sends the rest (4.3) | no: holder GO is fast |
| `a6eaedb43` SPL-4066 | 10-28 | the push gate refuses a void review line | not measured | no: a week before |
| `e2fa11144` .. SPL-4372 | 10-30 | owner-orders part | p50 0 s | no |
| `3e8300d17`, `5e742b010`, `01f79c5f8` SPL-4437 | 10-30 | push worker knobs and log | none visible | no |
| `c7286f4c2` SPL-4570 | 11-01 | review/ push skips the R7 line check | none visible | no |
| `ff214f089`, `873a7fa68` SPL-4789 | 11-04 22:36Z | commit-links part | p50 5-7 s per run (sat 1147 s on all of 11-05) | no: too small, and 11-05 ran with it |
| `e696477ab` SPL-4826 | 11-05 01:27Z | agy takes grok's coding share | see 4.2 | no |
| `b7cf7c82e` SPL-4797 | 11-05 | the placer launches no lane with no discussion or issue | not measured | no: 11-05 is the good day |
| `76ce2e9b7` SPL-4820 | 11-05 | rotation never cuts a running gate | none visible | no |
| `8b5be1fd6`, `85b489a23` SPL-4876 | 11-05 17:59Z | vendor split copy check before the push | iac-cross p50 3 s PC, 7 s sat, unchanged | no |
| `fe0455e48` SPL-4932 | 11-06 23:41Z | the fix for the kept reading | | the repair, after the fact |

11-05 ran with nearly all of these and was a top day, so the drop needs something that began on 11-06. A code change on these paths is not it, on this evidence.

## 4. What I ruled out

### 4.1 The gate got slower: no

Parts that passed or failed, p50 seconds, from `pre-push.log`:

| part | PC 11-05 (n) | PC 11-06 (n) | sat 11-05 (n) | sat 11-06 (n) |
|---|---|---|---|---|
| orc | 157 (57) | 210 (10) | 387 (43) | 166 (29) |
| api | 280 (48) | 235 (15) | 475 (43) | 582 (24) |
| wui-e2e | 481 (53) | 386 (3) | 672 (7) | 619 (13) |
| orc-features | 177 (42) | 161 (7) | 245 (33) | 274 (28) |
| hygiene | 5 (315) | 6 (45) | 13 (168) | 15 (122) |

The reported "full gate about 50 min" is real, but it is the tail and it is old. orc p90 on sat: 10-26 3159 s, 10-28 3027 s, 11-04 4401 s, 11-05 2910 s, 11-06 4481 s. Longest orc run on 11-06 10378 s, on 11-04 10764 s. It deserves its own lane; it did not cause this drop.

### 4.2 Agy taking grok's share starved the queue: no

Placer lines say `agy is out of quota until ...` (10677 lines, 50 asks). But of 124 asks still queued at the read, 120 are placed as claude, 3 as agy, 1 as mistral (`fleet_asks`, `state='queued'`). The queue is a Claude queue.

### 4.3 Waiting for the holder's GO: no

From `spool-send` commands in transcripts, matched by issue key, PASS -> GO p50: 11-04 1.5 min (n=7), 11-05 0.8 min (n=4), 11-06 1.8 min (n=2). n is small and the match is by text, so this is suggested, not demonstrated. Holder GOs fell with the work: 35 on 11-05, 13 on 11-06.

### 4.4 Refused pushes: no

Corrected, section 8. Pushes retried by the worker (`try N/4: push` with N of 2 or more, in each lane's `push-master/log`, by file date, `.retired` included): 11-05 8 in 65 logs, 11-06 2 in 22. Each log holds its lane's last push only, so this undercounts.

Gate refusals are a different number: real `REFUSE` lines (trees under `/tmp` removed) 38 on 11-05, 18 on 11-06, 54 of the 56 reading "deploy-gate FAILED". The count fell with the work; per whole-gate pass it rose, 38/263 = 0.14 to 18/85 = 0.21. That is suggested at most, and it is not a cause of this drop.

### 4.5 Model or box speed: no

From transcripts, tool result or message -> next assistant line, seconds, p50 / p90: PC 11-05 3.1 / 6.9 (n=16429), 11-06 3.2 / 7.6 (n=4240); sat 11-05 3.1 / 6.7 (n=16718), 11-06 3.0 / 7.4 (n=11311). The p90 is up about 10%, far too small for this. Sessions are binned by the day they started. The `Read` tool median stayed 0.3-0.4 s. This does not contradict the overload seen on sat at 00:40Z on 11-07: load 55-61 is real, and it is the hours after the drop.

### 4.6 A lost login on sat: no. A real limit: yes, until 13:57Z

API error lines on sat since 11-05: 4, all on 11-05. PC box: "Login expired" 22 on 11-06, 19 of them in the 22Z hour, as the box woke.

Corrected, section 8: the limit was real for most of the hold. I had read `fe0455e48` alone and called all of it a stale row.

## 5. Other findings, not causes of this drop

- **A backlog older than the outage.** Queue depth last seen per day from the placer's `position 1 of N`: 10-29 61, 10-30 22, 11-02 102, 11-03 119, 11-04 130, 11-05 113, 11-06 129. It matches the reported p90 jump on 11-03. 11-05 was a top day with this queue, so it did not cause the drop, but 29 asks from 11-02 were still queued at the read.
- **The agy "until" never arrives.** `until` moves forward with the clock while the banner text stays the same: `until 2026-11-10T12:37:50Z (a-208 banner, Resets in 104h20m20s)`, then `until ...12:38:48Z (a-208 banner, Resets in 104h20m20s)` (`grep -a 'out of quota' spawn-place/cron.out`). The same trap as the kept 97%: an old screen is read as a current fact. I did not check whether agy really is out of quota.
- **The weekly hold came back.** With the clock proxy (section 6), the placer printed `claude weekly` again at about 23:10Z on 11-06 (4 lines). `fe0455e48` says a pane banner can still re-keep a %. I did not trace these lines.
- **Automatic GO is refused for same-vendor reviews.** 205 of the refusals in `review-go/cron.out` are rc 2; the ones I read say "shares the vendor". With grok off, the holder does this by hand. It looks fast today (4.3), but it is a dispatch seat's time.

## 6. What I could not read

- **Why the Wi-Fi dropped at 00:20Z.** The PC box's system journal has nothing between 11-05 evening and 04:01Z on 11-06 (about 511 MB kept, older entries gone). Not established.
- **Why the lid closed** is not in a log. The journal says only `Lid closed`, twice.
- **The hold's start.** 09:20 is from the brief. The placer's log has no timestamps, and my clock proxy (`until` minus `Resets in`) puts the first line at about 09:00, with an error I cannot bound. Hourly counts from that proxy are coarse, so I use them for no duration above. The end, 16:12, is in `fe0455e48` and agrees with c-253 starting at 16:12.
- **The push worker's own logs.** Corrected, section 8: they survive under `.retired`, which my search depth missed. A text marker I first used for "landed" disagreed with master on 6 of 24 lanes, so I dropped it, and every land time above comes from git.
- **Reviewer start to verdict.** `messages.body` matched nothing for my pattern in the hub DB, so verdict times come only from `spool-send` text, which is thin.
- **The READY step.** Lanes do not send a uniform READY (1 match in 3 days), so it has no number.
- **How much of 11-05 was backlog.** 27 commits landed in 06Z alone. Commits per issue was 2.5 on 11-05 and 1.6 on 11-06. So the commit ratio overstates the drop, and the issue ratio (3.0x) is the better one.
- **The evening.** 17-23Z landed 20 commits against 50 on 11-05, with the PC box asleep for most of it. I did not separate "sat alone" from "lanes still recovering".

## 7. How not to repeat it

These are proposals; this seat changed nothing.

1. **The laptop is not a server.** The PC box had a lane on 58 of the 91 box-counted issues on 11-05 and went away twice for ordinary laptop reasons. Either keep it awake with the lid closed and give it a wired or failover link, which is the owner's call and an `/etc` change, or move the steady load off it. I found nothing that tells the fleet a box is asleep on purpose; that search was not exhaustive.
2. **Alarm on the outcome, not on the parts.** "Queue above 0, load below 25% of cores, 0 landed for 30 min" would have fired by about 11:30Z. Both boxes sat at load 5-9 with 100+ queued for hours, and the owner found it by hand.
3. **A reading that blocks work must carry its age and expire.** The 97% row after 13:57Z and the agy `until` are the same defect: a past screen stopped future work. Rule: a hold states its source and age, and lapses unless re-read. `fe0455e48` fixes one path and names what it leaves open.
4. **A review seat should not queue with new work.** R7 seats finish work already written: 3 reviewers held 5-7 h stopped lanes that had already paid for their gates. Let a review seat pass a capacity hold, or at least alarm at 30 min of wait.
5. **Keep the push worker's log after a lane ends** (`pushes.log`, `log`), so the next such question can be measured.
6. **Separately:** the gate's orc p90 of 50-75 min and the backlog of 100+ since 11-02 are real and older. They are not what broke on 11-06, and should not be fixed under this banner.

## 8. Corrections after the editor's check (2026-11-07)

1. **"Stale 97% from about 09:20" was wrong.** Sat's `weekly-limit-alert/cron.log` reads claude 81, 84, 90, 96, 97, then 0%, in that order; the clock times (90% at 09:00, 97% at 13:55) are the editor's. The kept row's own read time, 1793973488, decodes to 13:58:08Z (`date -u -d @1793973488`), just after the credential change at 13:57Z (`agent-login-check/cred.log`). So the hold was true for about 4 h 50 and stale for about 2 h 15. The step tables are unchanged: they remove the whole hold window either way.
2. **"Only 8 `pushes.log` remain" was wrong.** `find /var/spool-hub -name pushes.log -newermt 2026-11-05` -> 60 on the PC box (54 under `.retired`), 36 on sat (32). My search stopped at `-maxdepth 4`.
3. **"Fewer refusals" answered the wrong question.** Those lines are gate failures, and I gave a raw count. Section 4.4 now holds the worker's retries, and the rate.
