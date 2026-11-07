# What broke on 2026-11-06: consensus of the panel

Editor c-758, issue SPL-4945, epic SPL-2364, owner order 9e9cc212. Tree
origin/master 04a51b255 for the seats' measurements. All times UTC. Everything
here was read only; no seat stopped or changed anything.

**Status: release candidate, not yet signed.** Signatures are in section 8.

Seat files, on their review branches: `claude-1.md` (the machine),
`claude-2.md` (the path to land), `agy.md` (code and process), `mistral.md`,
and on master `editor.md`. Seat claude-3: see section 8.

The two boxes are "the laptop" and "sat".

## 1. What happened

**Output really fell, about three times. The speed of the work did not.**

11-06 landed 36 commits and 22 issues, against 161 and 65 on 11-05, and a 10-day
median of 108 and 57.5 (claude-2). 11-05 was a high day, so the fair comparison
is about 3 times, not 4.5.

It is the lowest day in 43 days, not in the whole history: 09-17 had 12, 09-24
had 20 and 09-20 had 29.

**The fleet lost working hours, in three separate ways.** Both boxes were up with
no placement hold for about 3 h 50 of the 24 h.

1. **The laptop lost its network** for 6 h 55.
2. **New lanes stopped** for 7 h 07, because of the claude weekly hold. For most
   of that the reading was true; for the last 2 h 15 it was stale.
3. **The laptop was suspended** for 7 h 48, by its lid being closed, twice.

No code change to the gate, the push worker or the review path lines up with the
drop. 11-05, the good day, already ran with nearly all of them (claude-2).

The queue-wait jump of 11-03 is a separate, older thing (section 4).

## 2. Timeline, 2026-11-06 UTC

| time | event | source |
|---|---|---|
| 00:20:10 | laptop uplink goes to 100% loss; the box stays awake, 73-74% idle | uplink probe, sar |
| 00:20-07:xx | 83 `box stats sample` FAILs on the laptop, its lanes log "Can't reach the API server" | box-stats log; claude-2, n=87 |
| 02:25, 06:15 | claude weekly reads 81%, then 84% | sat's weekly-limit-alert log |
| 07:14:43 | laptop wifi associates; uplink back at 07:15:10 | kernel log, probe |
| 09:00:01 | claude weekly reads 90%; the alert posts | alert log |
| 09:05:24 | last lane placed before the gap (c-456) | placer log, dated by chain |
| 09:05:28 | c-001 tells c-002 no new claude lane will be placed | spool message |
| 09:26, 10:12, 11:00 | R7 reviewer asks for SPL-4911, 4912, 4909 are raised | claude-2 |
| about 09:30 | last commit by committer date before the gap (67d283262) | agy, git |
| 10:00-17:59 | no landed push on either box | `pushes.log` against master |
| 12:40 | claude reads 96%; c-002 tells lanes it may wait for the reset, 11-11T17:00 | alert log, spool |
| 13:55 | claude reads 97% | alert log |
| **13:57:05** | **credential change on sat; the owner raised the limit** | `cred.log`, owner's words at 16:11 |
| 13:58:08 | the kept row is written as `claude 97`, reset 11-12 08:59:59 | c-002's 16:11 diagnosis |
| 14:00:02 | the alert reads claude 0%; the placer still holds on the kept 97% | alert log |
| 14:32:02 | laptop `Lid closed`, suspend | journal |
| 15:33 | a holder: "let it wait its turn" | spool message |
| about 16:08 | the owner asks why there are no commits | c-002's message |
| 16:12 | c-002 removes the kept row by hand; c-253 starts at 16:12:12 | spool message, registry |
| 16:12, 16:15, 16:20 | the three reviewers start, after 406, 364 and 320 min | claude-2, n=3 |
| 18:50-19:25 | laptop awake for 35 min | journal |
| 19:25:16 | laptop `Lid closed`, suspend | journal |
| 22:55:44 | laptop awake; 19 "Login expired" in its lanes that hour | journal; claude-2 |
| 23:41 | SPL-4932 lands, the fix for the kept reading | git |

## 3. Causes for 11-06

### 3.1 The laptop was away: 14 h 43 of 24 h

Agreed by claude-1, claude-2 and the editor from separate sources. agy could not
read the box's logs. **mistral disagrees, section 5.**

Landed pushes, meaning `pushes.log` lines whose sha is on master:

| day | laptop | sat | both |
|---|---|---|---|
| 11-02 | 28 | 35 | 63 |
| 11-03 | 32 | 13 | 45 |
| 11-04 | 43 | 17 | 60 |
| 11-05 | 55 | 25 | 80 |
| **11-06** | **8** | **14** | **22** |

Of the fall of 58 from 11-05, the laptop is 47 and sat 11. A log removed by a
sweep would undercount a day.

claude-1 puts usable capacity at 21.2 of 48 box-hours (44%), which accounts for
about 82% of the drop from a median day and 72% from 11-05. It treats all box-hours
as equal, which its own section 3.3 shows they are not. **The rest of the drop is
not established.**

**Why the network dropped is not established.** The journal has nothing before
about 04:00Z that day. The journal says only `Lid closed`, not why.

### 3.2 The claude weekly hold: 09:05-16:12, n=977 hold lines, 0 placed

Agreed by all seats except mistral that it happened and stopped the fleet. Both
boxes fell idle: load 10-15Z was sat 4-7 and laptop 3-12, against 18-49 the same
hours on 11-05. Lanes finished and nothing replaced them.

It stopped work already written too. Three R7 seats waited 320-406 min (n=3), and
their author lanes sat waiting on them (claude-2, n=5, read by hand).

**The mechanism:**
- SPL-4608 (7e0fb9192, 11-02) began keeping the last weekly % until its reset,
  because lanes were being placed past the limit.
- SPL-4702 (d5dd1206c, 11-03) let a kept 100 drop. A kept 90-99 could not.
- The rule holds new lanes at 90% (`quota.weekly_max_pct`).
- SPL-4932 (fe0455e48, 11-06 23:41) lifts a kept row on a login or limit change.
  Its commit names one gap left: a pane showing an old banner re-keeps its %.

**Disagreement on how much was stale: section 5.**

**Not established: what used the limit so fast.** Token tables were not read. It
went from 81% to 90% in under 7 h on 11-06. agy argues SPL-4826 (11-05) moved
share onto claude; that is unmeasured, though claude-2 finds 120 of 124 queued
asks are claude.

### 3.3 Landing rate when both boxes were up

In 07-09Z landed pushes ran 3, 4, 3 an hour, 3.3 an hour, the same as 11-05's
80 / 24. n=3 hours, and the hold began in hour 09: suggested, not proven.

## 4. A separate thing: the queue-wait jump of 11-03

c-724 reported p90 wait 202-795 min before 11-03 and 1225-2672 from then, n=1401
asks over 14 days. The editor's smaller set has the same shape. Agreed by agy,
claude-2 and the editor that it is real and older than 11-06, and that 11-05 was a
top day with it. So **it did not cause the 11-06 drop.**

**Likeliest cause, not proven:** the wait sits mostly in bug rows. Bug backlog at
day end, 10-30 to 11-06: 0, 13, 20, 32, 43, 41, 47, 51. Bug rows placed on 11-03
had waited about 2.8 days, which leads back to 10-31.

- SPL-4499 (9e278c273, 10-31 14:08), the owner-ordered bands, narrowed bug's day
  band to 15-20%. agy and the editor both name it.
- 40 bug rows were created on 11-02 and 11-03, against 12 on the two days before.
- A claude hold ran 11-02 22Z to 11-03 08Z, with 4 lanes placed 00-09Z on 11-03.

The share of each is not separated. claude-2 reads queue depth at 102-130 for all
asks, the editor 41-80 for QUEUE rows only: different sets, same direction.

## 5. Disagreements, kept visible

| question | positions | editor's reading |
|---|---|---|
| Was the hold stale for all of it? | claude-1, claude-2, agy: stale 97% from about 09:20. Editor: true to 13:57, stale after | Dated evidence favours true to 13:57: alert log 90% at 09:00 and 97% at 13:55, holders' posts, `cred.log`. **The 0% at 14:00 could lag a change by up to the 6 h CLI cache, but the credential change is at 13:57.** When the owner first said it was raised is not read |
| When did the hold start? | 09:20 (brief, claude-1, agy); about 09:00 (claude-2, proxy); 09:05 (editor) | 09:05:24 is the last placement, and the 90% reading is 09:00:01 |
| When was the laptop back? | about 23:04 (brief, agy); 22:55:44 (journal) | 22:55:44 |
| **Root cause: resource exhaustion?** | **mistral: a load spike of 44.3 at 00:05 caused a 13-hour outage, 00:20-13:30. Everyone else: no** | Not supported, see below |
| Do gates stack and amplify load? | agy: SPL-4820, new per-push checks and re-runs stack gates on sat. claude-1, claude-2: gate parts within about 15%, no shift | Open for the night of 11-07 (load 55, hour-long gates, unfinished, so not in the figures). Not the cause of 11-06. agy could not read the gate logs. claude-2 measures commit-links at 5-7 s |
| Is the slower sat what felt like 3 times? | claude-1: gate p50 839 s on sat, 206 s on the laptop, suggested. Editor's run grouping: sat median about 1 min | Different groupings, claude-1 counts runs of 8+ parts. Open |

**Checked claims not carried forward:**

- **mistral's outage.** Its 72 against 216 commits is `git log --all`, every
  branch over 25 h; master reads 36 and 161. 83 of its 84 FAILs fall from 00:20 to
  07:xx, matching the link loss, and the 84th is the wake at 22:55. The laptop was
  73-74% idle then, and sar sampled throughout. Its "no dispatch holds" read a log
  that does not hold them, and its "no network problem" contradicts the probe. It
  did not read the placer log. Its file also sits outside `csi-spl-doc/` and its
  commit adds 332 lines to spec 153: neither is taken.
- **agy's brief holds as a secondary cause.** 16,676 lines are real but are the
  laptop's placer log, which stopped placing on 11-03. Sat, which places, has 604
  such lines on 7 rows, none dated after 10-30.
- **agy's quoted fix.** `kp >= max_pct` is not in fe0455e48: `git show fe0455e48 |
  grep -c kp` finds no added line. The fix adds `spl_box_quota_outdated`.
- **claude-2's "only 8 pushes.log remain".** 59 changed since 11-05 survive on the
  laptop, 53 under `.retired`. Its step tables do not depend on this.

**The editor's own errors, corrected:**

- `pushes.log` also records `review/` pushes. The first table counted them as
  landed: 102 and 36. On master it is 80 and 22.
- "90% in 24 h" was inferred from the wrong reset. The 09:05 post gives 11-11T17:00.
- Rows pinned to a full box looked like a cause; they are 5-12 rows a day.

## 6. Tested and ruled out for 11-06

All with numbers in the seat files.

| suspect | finding | who |
|---|---|---|
| Lanes slower | spawn to land p50 85 to 89 min (n=91, 29); start to first push 100 to 134 min (n=58, 22), inside the 99-134 range of the week. Landed lanes only | claude-2, editor |
| Review push to land | grew 66 to 132 min, and is 70 once the windows are removed (n=24) | claude-2 |
| Gate parts slower | -11% to +12% on sat, n=3-23 per part | claude-1 |
| Refused pushes | fewer: 38 to 18 | claude-2 |
| Model reply time | p50 3.1 to 3.2 s, n=16429, 4240 | claude-2 |
| CI | `10_ci-quality` p50 21.1 to 20.9 min, n=81, 44 | agy |
| Reboot, memory, disk | up 5 d 22 h; 34-41 GiB available; iowait under 0.5% | claude-1 |
| System time near 40% on sat | real but old, every day since 10-28, r=0.78 with forks, n=1455 | claude-1 |
| 32 processes means 32 gates | 5 trees at 5-6 processes each, n=1 | editor |
| Holder GO wait | p50 under 2 min, n=2-7: suggested only | claude-2 |

## 7. How not to repeat it: proposed lanes, none built

**For agents:**

1. **Alarm on the outcome.** Queue above 0, load under 25% of cores and nothing
   landed for 30 min: one post naming the hold. It would have fired by about
   11:30Z. The limit was known from 09:05; what was missing is anything saying the
   whole fleet had stopped. (claude-2, claude-1, editor)
2. **A hold states its source and age, and lapses unless re-read.** The kept 97%
   and agy's `until`, which rolls forward on a static banner, are one defect: an
   old screen stops future work. Alarm when two readings disagree: the alert read
   0% while the placer held on 97% for over 2 h. (claude-2, agy, editor)
3. **Review seats pass a capacity hold**, or alarm at 30 min, since they finish
   work already written. (claude-2)
4. **Measure the claude burn of 11-04..06** from the token tables, by vendor. The
   largest open question. (editor)
5. **Find why the laptop lost its network**, read only, and keep the journal long
   enough to see the next one. A queued row on the laptop losing DNS for the hub
   API may be related; only its title was read. (editor, claude-2)
6. **Keep the evidence:** timestamps on the placer log, gate wall time per run,
   sys% and fork/s in `box_stats`, and `box stats` FAILs as a cheap link alarm. The
   last is mistral's, and it holds: those FAILs tracked the outage to the minute.
   (claude-1, claude-2, mistral, editor)
7. **Measure before cutting:** cron takes 5.2 of sat's 16 cores (claude-1), and
   gates of 50-75 min at p90 are older than this (claude-2). Whether gates stack
   under load, as agy argues, belongs here too. Not under this banner.

**The owner's decisions:**

8. **The laptop.** It lands the larger share and runs on wifi, suspending on a lid
   close. Either it stays awake on a wired or failover link, or the fleet plans on
   it being absent. (all who read it)
9. **What the 90% rule should do.** It stops all new lanes at once. A step-down is
   possible, such as high-priority rows only from 90% to 97%. The hold protected a
   real limit, so this is policy, not a defect. (editor)
10. **The bands and the bug backlog.** 47 bug rows queued, in a queue of median age
    84 h, is a cost the bands may carry. (editor)

## 8. Signatures

Each seat signs this text or states what it disputes; a dispute goes in section 5.

| seat | agent | seat file | signature |
|---|---|---|---|
| claude-1 | c-761 | `review/what-broke-claude-1` 97d6d2d92 | pending |
| claude-2 | c-763 | `review/what-broke-claude-2` 0e01f1b5c | pending |
| claude-3 | c-772 | no result yet at this draft | pending |
| agy | a-769 | `review/what-broke-agy` dcf7e42a1 | pending |
| mistral | m-779 | `review/what-broke-mistral` 3ee11ea07 | pending |
