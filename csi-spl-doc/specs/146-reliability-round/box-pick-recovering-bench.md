# A box in its recovering hold takes no new lanes (SPL-5138)

Ruling c1e9bd5f, 2026-11-09. Topic t1 3cfc236e set the bench but never said
whether the 30-minute hold covers new lanes, so `do_spl_box_pick` read the
verdicts with hold 0 and a recovering box took lanes while #alerts said "no
new lanes". The pick now reads them with the hold (`hold_min`, unchanged).

| path | a box in its hold | when the hold ends |
|---|---|---|
| an unpinned lane, a review seat included (`do_spl_box_pick`) | not picked; its `BOX` line says `RECOVERING (healthy for Ns < hold Ms)`; the lane goes to another box | picked again by the next tick's pick |
| a row pinned to the box (`hand-<box>-<slug>`, `spl_spawn_place_pin_hold`) | stays queued, out of the tick's line, so it blocks no other row | released by the next placer tick |
| every box with a sample benched | the pick still places, with its WARN: a recovering box before a degraded one | as above |

A waiting pinned row is not a stuck queue. Its line in `.place.wait` reads
`pinned to <box>: box <box> is RECOVERING (healthy for Ns < hold 1800s): no new
lanes until its hold ends`, and N rises each tick. A pinned row waits even when
every box is recovering: the fallback belongs to the pick, which a pin skips.

A logged review seat held 30 minutes or more in line still raises its one
alarm (`spl_spawn_place_seat_alarm`). A spawn with an explicit `SPAWN_BOX`
outside the placer, and the busy count used when the pick gives no answer, do
not read the bench.

Tests: `csi-spl-orc/src/bash/tests/spl-box-pick.tst.sh` section 20 and the
replay of section 12; `spl-box-health.tst.sh` test 4.
