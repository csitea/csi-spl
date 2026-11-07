# What broke on 2026-11-06: the editor's own analysis

Written by c-758 before reading any seat file, as the brief asks. Two boxes: the
laptop, which is the desk box, and the satellite, `sat`. Issue
SPL-4945, epic SPL-2364. Tree: origin/master 04a51b255, read 2026-11-07
00:49-01:03Z. All times UTC. Read only: nothing was stopped, restarted or
changed, and no gate or suite was run.

"Pushes" are lines of `pushes.log`, one per landed push, on each box. A log
removed by a sweep would undercount a day.

## 1. Short answer

Nothing made a lane or the gate three times slower. The fleet had far fewer
working lanes, for three separate reasons that together covered most of the
day. Both boxes were up with no placer hold for only about 3 h 50 of 24 h.

| # | window on 11-06 | what happened | status |
|---|---|---|---|
| 1 | 00:20-07:15 (6 h 55) | the laptop had no network | measured; why is not established |
| 2 | 09:05-16:12 (7 h 07) | the placer started no lane: claude weekly hold | measured |
| 2a | of which 09:05-14:00 | a true reading, 90% and rising, under the 90% rule | measured |
| 2b | of which 14:00-16:12 | a stale kept row after claude read 0% | measured; SPL-4932 fixed it |
| 3 | 14:32-18:50 and 19:25-22:55 (7 h 48) | the laptop suspended: `Lid closed` both times | measured |

The laptop was unavailable for 14 h 43 of 24 h. The queue-wait jump of 11-03 is a
different thing with a different likely cause (section 5).

## 2. Is 11-06 the lowest day in the history?

No. It is the lowest in 43 days. Master commits by UTC committer day,
`git log origin/master`, n=all:

| day | commits |
|---|---|
| 09-17 (repo start) | 12 |
| 09-24 | 20 |
| 09-20 | 29 |
| **11-06** | **36** |
| 10-21 | 41 |
| 09-22 | 47 |

The days before it: 11-02 99, 11-03 72, 11-04 113, 11-05 161. The owner's
reading that it was very low holds: 11-05 to 11-06 is a fall of 4.5 times.

## 3. Where the drop came from

| day | laptop pushes | sat pushes | both |
|---|---|---|---|
| 11-02 | 37 | 45 | 82 |
| 11-03 | 38 | 18 | 56 |
| 11-04 | 59 | 30 | 89 |
| 11-05 | 66 | 36 | 102 |
| **11-06** | **11** | **25** | **36** |

Of the fall of 66 pushes from 11-05, the laptop is 55 and sat 11.

Pushes per hour on 11-06, both boxes: 00-06 at 1-2 an hour, 07 3, 08 5, 09 4,
**10-15 none**, 16 2, 17 3, 18 2, 19 2, 20 1, 21 0, 22 1, 23 2.

In 07-09Z, the longest stretch with both boxes up, pushes ran at 4 an hour
against 4.25 an hour across 11-05. Master commits in those hours ran at 4 an
hour against 6.7. n=3 hours, and the hold began 5 minutes into hour 09, so this
suggests the rate was normal. It does not prove it.

## 4. The three windows

### 4.1 The laptop without a network, 00:20-07:15

- The uplink probe (the laptop box's `<box>.tsv`, about one sample a minute) reads 0% loss at
  00:19:13Z and 100% from 00:20:10Z. It reads up again at 07:15:10Z.
- The box was running: sar has samples throughout, load 3-5 from 01Z to 06Z.
- The kernel log shows the wifi associating at 07:14:43Z.
- The reverse tunnel to sat failed until 07:15:09Z.

**Not established: why it dropped.** The journal I read has no line on 11-06
before about 04:00Z, so the start of the drop is not in it.

### 4.2 The claude weekly hold, 09:05-16:12

The placer log has no timestamps. I dated its lines by chaining each
`OK ask … placed: <id>` to that lane's start stamp in the registry. All 2688
placed lines on sat fit one time-ordered chain, which is what makes the dating
credible. A first, greedy version of this was wrong and was thrown away. Hold
line counts depend on queue length, so they show when, never how long.

The last placement before the gap is c-456 at 09:05:24Z. The next is c-253 at
16:12:12Z. Between them are 977 `waiting: claude weekly` hold lines and no
placement. The placer is what was measured: lanes started by hand in that
window are not excluded.

Sat's `weekly-limit-alert/cron.log`, dated by its own START lines:

| time | claude reading |
|---|---|
| 02:25 | 81% |
| 06:15 | 84% |
| **09:00** | **90%** |
| 12:40 | 96% |
| 13:55 | 97% |
| **14:00** | **0%** |

Between most of those lines the log reads "no reading".

- **So the notes' "held 09:20-16:12 on an out-of-date 97% reading" is wrong for
  most of that window.** From 09:05 to 14:00 the hold obeyed the 90% rule on a
  true reading. Only 14:00-16:12 (2 h 12) was stale.
- The stale part: SPL-4932 (fe0455e48, 11-06 23:41Z) says the owner raised the
  limit, and the kept row `claude 97` stayed until it was removed by hand at
  16:12Z. Only a kept row at 100 could be lifted.
- The mechanism: SPL-4608 (7e0fb9192, 11-02 09:00Z) began keeping the last
  measured weekly % until its reset, because lanes were being placed past the
  limit. SPL-4702 (d5dd1206c, 11-03 12:43Z) let a kept 100 drop. SPL-4932
  extended that to any %. Its commit states one remaining gap: a pane still
  showing an old banner re-keeps its %.
- During the hold, lanes finished and nothing replaced them. Load 10-15Z on
  11-06: sat 4-7, the laptop 3-12. The same hours on 11-05: 18-49.

**Not established: what used the claude limit so fast.** The kept row's reset is
11-12 08:59:59Z. If a week runs up to that moment, it began 11-05 09:00, and 90%
went in 24 hours. **That is inference from one timestamp.** Token burn lives in
the hub DB; the spool MCP servers failed to connect in this session and I did
not sum transcripts, which would have added load. A lead only: SPL-4826
(e696477ab, 11-05 01:27Z) moved grok's share to agy with grok off, and agy is
out of quota until 11-10, so coding may have fallen to claude. Not measured.

### 4.3 The laptop suspended, 14:32-18:50 and 19:25-22:55

- `systemd-logind: Lid closed` then `Suspending...` at 14:32:02Z and 19:25:16Z,
  followed by `PM: suspend entry (s2idle)`.
- sar has gaps of 261 and 216 minutes; the journal of 258 and 210; the uplink
  probe of 260 and 211.
- Uptime reads 5 d 22 h: no reboot.
- It is a laptop on wifi (`wlp0s20f3`).

Sat carried on through these windows: load 29-50 from 16Z to 19Z, and 3, 3, 1,
2, 3 lanes placed an hour from 18Z. The lanes on the laptop were frozen.

## 5. The 11-03 queue-wait jump is a different thing

c-724 reported p90 wait at 202-795 min before 11-03 and 1225-2672 min after. My
figures, QUEUE asks on sat's journal (n=1285 with a dated placement), have the
same shape on a slightly different set: p90 102-246 on 10-31..11-02, then 4382,
2326, 2800, 433.

The wait is mostly in one class. Placed per day (median wait in minutes), then
the backlog at day end, class read from the summary or the band-pick line:

| day | bug placed | bug backlog | feature backlog | refactor backlog |
|---|---|---|---|---|
| 10-30 | 0 | 0 | 0 | 0 |
| 10-31 | 0 | 13 | 1 | 6 |
| 11-01 | 1 (362) | 20 | 1 | 2 |
| 11-02 | 1 (2947) | 32 | 7 | 1 |
| 11-03 | 7 (4065) | 43 | 14 | 2 |
| 11-04 | 9 (4543) | 41 | 16 | 12 |
| 11-05 | 2 (58) | 47 | 0 | 1 |
| 11-06 | 2 (636) | 51 | 1 | 0 |

The bug rows placed on 11-03 had waited about 2.8 days, which leads back to
10-31. That arithmetic explains why the jump shows on 11-03 rather than on the
day it began.

**Likeliest cause, not proven: the owner-ordered bands of SPL-4499 (9e278c273,
10-31 14:08Z) plus a rise in bug supply.**

- Bug's day band went from 20-30% to 15-20%. Bug's median share on 11-01 and
  11-02 was 50% and 34%, over that band, which puts its rows behind the others.
- Supply: 40 QUEUE bug rows were created on 11-02 and 11-03, against 12 on the
  two days before.
- A claude hold ran from 11-02 22Z to 11-03 08Z, and 4 lanes were placed on
  11-03 between 00Z and 09Z. SPL-4702's commit describes a kept 100 read at
  07:57Z, then a login swap at 08:56Z. I did not separate true from stale here.

This matches a backlog, not a broken placer: of the 55 QUEUE rows still queued,
47 are bugs, and the median age of the 55 is 84 h. I did not separate the share
of each of the three causes.

## 6. What was tested and rejected

**The gate got slower: no sign of it.** Per-run wall time from the pre-push
logs, grouped per tree and HEAD:

| day | sat runs | sat median / p90 min | laptop runs | laptop median / p90 min |
|---|---|---|---|---|
| 11-02 | 230 | 0.7 / 11.8 | 267 | 1.0 / 10.3 |
| 11-03 | 182 | 0.8 / 14.8 | 251 | 3.1 / 22.4 |
| 11-04 | 291 | 0.7 / 19.1 | 388 | 2.5 / 15.4 |
| 11-05 | 236 | 1.0 / 15.3 | 365 | 0.8 / 14.8 |
| 11-06 | 178 | 1.0 / 17.6 | 46 | 3.9 / 30.9 |

Most runs are short because of the verdict cache. The laptop's 30.9 on 11-06 has n=46,
and a suspend during a run would inflate it; I did not split that out. This
does not rule out a slow gate at 00:50Z on 11-07, when c-001 read gates of about
an hour on sat at load 55: those runs had not finished when I read the logs.

**Lanes got slower: no.** One row per lane that landed, by the day of its first
push, median / p90 min. Lanes that never pushed are not in it, so a stuck lane
does not count against 11-06.

| first push | lanes | start to first push | gate within that | first push to done |
|---|---|---|---|---|
| 11-02..03 | 90 | 132 / 458 | 23 / 119 | 32 / 43 |
| 11-04 | 61 | 99 / 601 | 32 / 248 | 33 / 51 |
| 11-05 | 58 | 100 / 447 | 10 / 96 | 30 / 42 |
| 11-06 | 22 | 134 / 469 | 17 / 61 | 26 / 42 |

What fell is the number of lanes landing, 58 to 22, not the time each took.

**32 pre-push processes are 32 gates: no.** At 00:55Z on sat, 5 trees had a gate
at 5-6 processes each (n=1), the oldest c-444 at 65 min.

**Rows pinned to a full box caused the backlog: no.** Hold lines rose from 304
on 11-01 to 3043 on 11-04, which looked like a cause, but those are the same few
rows logged every tick: 5-12 distinct rows a day.

## 7. Who idles on what

One read of the laptop's lane windows at 00:59Z, n=18, from each one's last two lines.
A snapshot, not a measure of the day:

- In a running turn: 8 (a-721, c-723, c-747, c-752, c-753, c-758, c-761, c-763).
- Role seats between messages: 3 (c-001, c-002, c-003).
- At the prompt, waiting on someone else or on a verdict: 4 (c-706, c-724, c-750,
  a-695).
- At the prompt, reason not clear from those lines: 3 (a-698, c-693, c-727).

Part of this is by design: the seed tells a finished lane to stay idle until an
ACCEPTED message. That wait did not change: first push to done has a median of
26-33 min on every row of section 6.

**Not established:** the split across sat or across the whole day. The holder's
00:40Z read of sat (7 on their own gate, push or CI; 5 finished reviews; 2 on
hold; 1 on a human) points the same way, on process rather than on the agent,
but that is one read I did not repeat.

## 8. Not measured

- READY to GO. `ready->GO` found only 1-9 lanes per period, so the pattern I
  matched is too weak to use. Start to GO is available but mixes work and wait.
- Refused pushes. Each lane's status file keeps only the last verdict, so
  refusals are overwritten. SPL-4909's lost races were not checked.
- c-001's lease flips and the zombie sweep, against an earlier day.
- Whether rotations restart or orphan gates. Not read.
- Sat's drop of 36 to 25 pushes, beyond the hold.

## 9. How not to repeat it: proposed lanes, none built

1. **An alarm when the placer stops.** Queue non-empty and nothing placed for
   60 minutes: one post naming the hold reason. A grep of `csi-spl-orc` run
   actions and scripts for a few such phrases found none, which does not prove
   there is none. This hold ran 7 h, and I did not check who noticed it first.
2. **Timestamps on the placer log**, and gate wall time stored per run. Dating
   the placer took a reconstruction that should not be needed.
3. **The owner's decision: what the 90% hold should do.** It stops all new lanes
   at once. A step-down is an option, such as placing only high-priority rows
   between 90% and 97%. The hold protected a real limit, so this is a policy
   question and not a defect.
4. **The owner's decision: the laptop and the lid.** Either the laptop does not suspend on lid
   close while lanes run, or sat is told it is the only box. Reported, not
   proposed for an agent to change alone: it is the owner's machine.
5. **Why the laptop lost its network for 6 h 55.** A read-only investigation. There is
   a queued row on the laptop losing DNS for the hub API host that may be related; I
   read only its title.
6. **Measure the claude burn of 11-05..06** from the hub's token tables, by
   vendor. This answers the largest open question.
7. **Report the bug backlog against the bands.** 47 queued bug rows, in a queue
   whose median age is 84 h, is a cost the owner may not know the bands carry.
   The owner decides whether to change them.
