# Grade of grok as the dispatcher, 2026-10-02 .. 2026-10-26

Lane c-271, issue SPL-3481, epic SPL-2398, spec
`csi-spl-doc/specs/060-role-rotation`. Asked by HUM-10 in t1 topic
99ffa592 (poll 6de8b12d, answer A, msg c9213bd2: "Grade grok's 58 hours").
Read-only: no hub write, no lease change, no message to a human.

**Vendors.** The author (c-271) and the reviewer are both claude; the
graded vendor is grok. A grok re-review is due when grok has usage again;
it does not block landing.

Measured 2026-10-26 on sat. The other box is written "pc box" (`@pc` in seat ids). Every number below comes from the two sources
in section 1 and the scripts kept in the lane scratch dir; the hand grades
in section 4 are one reader's (claude, c-271) judgement and say why.

## 1. Method

### 1.1 Holder timeline

Source: `/var/spool-hub/dispatch/lease.log` on sat (3,956 lines, mtime
2026-10-26T06:29Z; the box clock is UTC+2, the file listing shows 08:29). Every line matching
`^<ts> FLEET dispatch: <from> -> <to>$` is one transfer; the holder from
`<ts>` to the next transfer is `<to>`.

- 1,035 transfers, 2026-10-02T02:23:23Z .. 2026-10-26T06:23:23Z (the brief
  counted 1,021 at its time; the log has grown since).
- Vendor of the holder: `c-NNN` and the legacy `CLE-NN` = claude, `g-NNN` =
  grok, `none` = no holder. The `sat takes over from ...` lines carry no
  holder; each is followed by its own `A -> B` line in the same second.
- The last holder is counted up to the log mtime.
- **pc box copy: NOT CHECKED.** `ssh` to the pc box from sat fails (`Could not resolve
  hostname`), so the cross-check of one day against the pc box log did not run.

### 1.2 Human posts and their first reply

Source: prd hub, read-only,
`cd csi-spl-orc && ENV=prd SQL="..." ./run -a do_spl_db_query`.

- Every message with `from_id like 'HUM-%'` and `ts >= 2026-10-02`:
  7,471 rows, 2026-10-02T01:22:55Z .. 2026-10-26T06:24:32Z.
- For each, the first later message in the same tenant and `task_id` whose
  `from_id` is an agent id (`[acgmq]-NNN`, `CLE-`, `GRK-`, `AGY-`, `QWN-`).
  `HUB-0`, `RSP-` and `OPS-` rows are not agents and do not count.
- Delay = reply ts - post ts. No reply at all counts as "no reply".
- The holder at the post's ts comes from 1.1.

### 1.3 What was left out, and why

| left out | rows | why |
|---|---|---|
| HUM-51, the spool probe login (`[spool-probe] L1..L4` posts, channel `probe`) | 3,017 | synthetic, nobody is meant to answer it |
| HUM-1, the `e2e` workspace | 68 | the e2e test login |

That leaves **4,385 posts** by 7 humans (HUM-10: 4,216) in 10 workspaces
(t1: 3,280). Holder at the post: claude 4,207, grok 161, none 17.

### 1.4 Like hours

Grok-held posts fell on 7 UTC days (10-13, 10-18 .. 10-21, 10-24, 10-25;
grok also held on 10-14, when no counted post fell in its hours). Two
claude comparison sets:

- **matched**: claude-held posts on the days a grok-held post fell on,
  in the UTC hours of day a grok-held post fell in (n = 417).
- **same cell**: claude-held posts in the same date + UTC hour as a
  grok-held post (n = 35, small).

## 2. The holder hours

| vendor | hours held |
|---|---|
| claude | 520.6 |
| grok | 58.5 |
| none | 0.9 |

Grok per UTC day (the brief's 15.4 h / 17.1 h for 10-20 / 10-21 were cut
at another day boundary; split at 00:00Z they read):

| day | grok h | claude h |
|---|---|---|
| 10-13 | 5.7 | 18.3 |
| 10-14 | 1.9 | 22.1 |
| 10-18 | 3.7 | 20.1 |
| 10-19 | 4.7 | 19.3 |
| 10-20 | 15.1 | 8.6 |
| 10-21 | 17.3 | 6.7 |
| 10-24 | 5.9 | 18.1 |
| 10-25 | 4.2 | 19.8 |

Grok seats: g-002 and g-003, on both boxes: **pc box 18.2 h, sat 40.4 h**
(84 holds: g-002@sat 32, g-003@sat 22, g-002@pc 19, g-003@pc 11).

## 3. Answer times

Delay to the first agent reply in the topic, any agent. A p90 or median of
`>30m` means the value lies past 30 min or in the no-reply rows.

| set | n | answered <= 3 min | median s | p90 s | no reply in 30 min |
|---|---|---|---|---|---|
| claude-held, all | 4,207 | 3,590 (85.3%) | 32 | 365 | 289 (6.9%) |
| **claude-held, matched** | 417 | 331 (79.4%) | 40 | 541 | 29 (7.0%) |
| claude-held, same cell | 35 | 16 (45.7%) | 232 | >30m | 5 (14.3%) |
| **grok-held, all** | 161 | 31 (19.3%) | 481 | 1,251 | 14 (8.7%) |
| grok-held, holder on the pc box | 69 | 10 (14.5%) | 450 | >30m | 14 (20.3%) |
| grok-held, holder on sat | 92 | 21 (22.8%) | 526 | 1,111 | 0 (0.0%) |

HUM-10 only:

| set | n | <= 3 min | median s | p90 s | no reply in 30 min |
|---|---|---|---|---|---|
| claude-held | 4,046 | 3,502 (86.6%) | 31 | 276 | 229 (5.7%) |
| claude-held, matched | 405 | 325 (80.2%) | 40 | 455 | 23 (5.7%) |
| grok-held | 153 | 28 (18.3%) | 481 | 1,248 | 13 (8.5%) |

Who wrote the first reply:

| set | the holder itself | another agent | none |
|---|---|---|---|
| grok-held (161) | 106 (65.8%) | 52 | 3 |
| claude-held, matched (417) | 355 (85.1%) | 45 | 17 |

In the grok-held set the first other repliers were g-001 (14), c-002 (11),
c-613 (9), c-003 (5), c-450 (5).

## 4. Forty cases graded by hand

Sample: the 161 grok-held posts and the 417 matched claude-held posts, each
sorted by time and cut into 20 equal slices; the middle post of each slice
(no picking by outcome). For each case the agent replies in the topic for
60 min after the post were read (113 replies).

Score, routing only (the delay is its own column):
**2** = right route (answered itself, placed or fed the right lane, or the
right lane answered), clear; **1** = right route but duplicated by two
seats, contradicted, unclear or unchecked; **0** = wrong route, or the
holder never answered.

### 4.1 Grok-held

| msg | ts | holder | first reply, s | by | score | why |
|---|---|---|---|---|---|---|
| 8b6c6833 | 10-13T14:38Z | g-002@pc | 247 | g-001 | 1 | g-001 claimed "no extra lane", then g-002 seated two lanes (c-430, c-431): two seats, plan reversed |
| 12a809a6 | 10-13T14:51Z | g-002@pc | 902 | g-002 | 2 | listed the references in a new discussion and seated the renderer lane c-436 |
| 90347451 | 10-13T15:00Z | g-002@pc | 820 | g-002 | 2 | checked the step is absent, seated c-437 to plan it, nothing applied |
| d0432cf7 | 10-13T15:47Z | g-002@pc | 184 | g-002 | 2 | answered itself with the picture; publishing waits on a named commit |
| e41ad730 | 10-13T16:34Z | g-002@pc | 189 | g-002 | 2 | did the document move itself, layout sent to its own lane |
| 3ba2779f | 10-20T08:42Z | g-002@sat | 1,111 | g-001 | 1 | g-001 and g-002 both posted the status within 30 s: two seats on one ask |
| ca4f624e | 10-20T11:56Z | g-002@sat | 1,035 | g-002 | 1 | "membership was not changed" without saying none was needed; c-003 re-answered 7 min later |
| 3cb1628e | 10-20T16:46Z | g-002@sat | 624 | g-002 | 1 | "planned, not built", no lane or queue row named within 60 min for a UI ask |
| 76e42e4f | 10-21T06:44Z | g-002@sat | 481 | g-002 | 1 | answered itself correctly, but under a "Landed, not live yet" state for a question |
| 9505487e | 10-21T07:03Z | g-002@sat | 298 | g-002 | 2 | recorded the decision, nothing applied, followed the landing and the dev apply |
| 911b49b8 | 10-21T10:32Z | g-002@sat | 1,256 | g-002 | 2 | status with the issue, lane and sha |
| 5c1e774c | 10-21T11:24Z | g-002@sat | 79 | c-450 | 2 | the owning lane answered with its result |
| ab726197 | 10-21T11:31Z | g-002@sat | 178 | c-613 | 2 | the workspace seat answered and tied it to SPL-2765 |
| 0c33bce8 | 10-21T12:49Z | g-002@sat | 154 | g-002 | 0 | "I place one WUI lane", then 13 min later "no lane is placed"; g-001 posted a third answer |
| f1b5e981 | 10-21T13:02Z | g-002@sat | 1,091 | g-002 | 1 | status by pointing at the last note, with "not re-checked" |
| 8e89a5a3 | 10-21T13:21Z | g-002@sat | 152 | g-002 | 1 | "not built, no lane started" for a feature ask; neither placed nor queued |
| a5b0a9e3 | 10-21T16:41Z | g-002@sat | 311 | g-002 | 2 | answered a research question itself |
| 4cb5658b | 10-25T11:07Z | g-003@pc | 1,064 | g-003 | 2 | recorded that nothing waits on the owner, named the holding lane |
| 04900d93 | 10-25T11:55Z | g-002@pc | 76 | g-002 | 2 | took it and named the B3 lane c-424 (SPL-3338); checked: the only B3 lane, the row c-002 queued at 10:00Z (spawn request d51ab5ef), no duplicate; landed f0c811bd0 |
| c1630f08 | 10-25T14:44Z | g-003@pc | 3,936 | c-002 | 0 | the grok holder never answered; c-002@sat took it after 66 min |

Grok: **29 of 40 points (72.5%)**; 11 cases at 2, 7 at 1, 2 at 0.

### 4.2 Claude-held (matched)

| msg | ts | holder | first reply, s | by | score | why |
|---|---|---|---|---|---|---|
| c3e522f1 | 10-13T06:15Z | c-002@pc | 5 | c-002 | 2 | taken, lane c-915 placed within 2 min |
| 1c3b5b94 | 10-13T06:33Z | c-002@pc | 5 | c-002 | 2 | added to the running lane, draft posted |
| 0f7b0d3d | 10-13T06:47Z | c-002@pc | 21 | c-002 | 2 | answered a design question itself |
| 8f0da7ca | 10-13T07:16Z | c-002@pc | 24 | c-003 | 2 | each follow-up added to lane c-922's brief |
| 19f08cae | 10-13T08:48Z | c-002@sat | 22 | c-002 | 2 | saw the reply came as "chat about this", asked what next |
| 4add6eb4 | 10-13T11:47Z | c-002@pc | 144 | c-002 | 2 | a new lane builds it |
| 505370d8 | 10-13T12:28Z | c-002@pc | 206 | c-003 | 1 | c-003 took it, then c-002 posted 5 notes that changed the plan twice before asking 3 decisions |
| 5b29e9c7 | 10-13T14:14Z | c-002@pc | 182 | c-003 | 2 | taken; the language lane a-429 delivered (g-002 posted its progress) |
| 67e2017b | 10-13T20:37Z | c-003@pc | 27 | c-003 | 2 | added to the brief, lane c-451 placed |
| 9c595541 | 10-13T21:00Z | c-002@pc | 125 | c-002 | 2 | added, lane c-956 placed, built in 50 min |
| 20a0cea6 | 10-19T07:44Z | c-002@sat | 3 | c-002 | 2 | did the fix itself, filed SPL-2521, lane c-217 |
| f13c3d26 | 10-19T14:45Z | c-002@sat | 17 | c-002 | 2 | opened the follow-up discussion as asked |
| 9ee42217 | 10-19T16:04Z | c-002@sat | 295 | c-002 | 2 | closed as the poll chose |
| 409c7830 | 10-20T07:28Z | c-002@sat | 87 | c-423 | 2 | the workspace seat did the member change in the right workspace |
| 9808f12c | 10-20T12:53Z | c-002@sat | 17 | c-002 | 2 | diagnosed and queued a lane |
| c871ffa0 | 10-24T08:28Z | c-002@sat | 64 | c-002 | 2 | go taken, next build row started |
| 670050b7 | 10-24T09:21Z | c-002@sat | 16 | c-002 | 2 | status with the lane and its step |
| 0c37a4f6 | 10-24T14:06Z | c-002@sat | 220 | c-002 | 2 | read a bare "A" as the answer to poll 49126486 in another topic; right: the owner answered that poll A at 14:21Z (msg 6acb0489) |
| 5bfbf325 | 10-25T09:59Z | c-002@sat | 55 | c-002 | 2 | went on with the build, filed the side idea on hold |
| 0c510ff7 | 10-25T11:00Z | c-002@sat | 3,552 | c-002 | 1 | right route, but answered after 59 min |

Claude: **38 of 40 points (95%)**; 18 cases at 2, 2 at 1, 0 at 0.

## 5. Findings

1. Grok held the lease 58.5 h of 580 h (10.1%), on both boxes (pc box 18.2 h,
   sat 40.4 h), and two days over 10 h (10-20: 15.1 h, 10-21: 17.3 h).
2. Speed: 19.3% of posts answered within 3 min under grok against 79.4%
   for claude in the matched hours; median 481 s against 40 s.
3. Misses: 8.7% of grok-held posts had no reply in 30 min against 7.0%
   matched claude, but all 14 grok misses were under a grok holder on the pc box
   (20.3% there, 0 of 92 on sat).
4. The grok holder wrote the first reply on 65.8% of its posts (claude
   matched: 85.1%); g-001, outside the lease, answered 14 of them, and three
   graded cases had two grok seats answering the same post.
5. Routing by hand: grok 72.5%, claude 95%. Grok's lost points are double
   answers, a lane said placed and then not placed, and feature asks
   answered "not built" with nothing placed or queued.

## 6. What this could not measure

- The pc box copy of `lease.log` (section 1.1): NOT CHECKED.
- Shadow hours: the owner's "at least 10 hours as a shadow" (msg 7188af78)
  is about grok working alongside a claude holder. The lease log records
  only the holder, so the hours grok worked as a shadow are not in it and
  are not measured here.
- The first reply is any agent's: a lane answering in its own topic counts
  the same as the dispatcher. The dispatcher's own share is section 3's
  last table.
- Owner posting volume differs: 161 posts in 58.5 grok hours (2.8 per h)
  against 4,207 in 520.6 claude hours (8.1 per h). In the 35 posts that
  share a date + hour with a grok post, claude was slow too (45.7% within
  3 min), so part of the gap may be the hours, not the vendor; n = 35 is too
  small to say.
- The grades in section 4 are one claude reader's; a second claude seat
  reviews them before this lands, and grok re-reviews them later (header).
