# Box beat gaps: the beat.log record

Row 07 of the [alerts fix round plan](alerts-fix-round-plan.md) v1.0
(SPL-3197, section 2.5). A box is benched when its beats leave a gap longer
than cnf `env.box.health.max_gap_s` (120 s), judged by
`csi-spl-orc/lib/bash/funcs/spl-box-health.func.sh`. Before this record a beat
that succeeded left no trace on the box (only a failure logged `BEAT ... no
ack` in `wd.log`, and `wd/beat.ack` keeps the last ack only), so nothing could
say which part of the watchdog tick used up the gap. This file is diagnostic
only. It changes nothing about when or how the beat is sent. The fix follows
the measurement.

## 1. What the log holds

The file is `<WD_DIR>/beat.log` (by default `$SPOOL_ROOT/dispatch/wd/beat.log`).
All watchdog instances (1..3) write to it. It is trimmed to its last
`WD_BEAT_LOG_MAX` lines (default 2000, about 5.5 h at 3 instances every
30 s). The code is in `csi-spl-orc/src/bash/run/spl-watchdog.func.sh`
(`spl_wd_beat`, `spl_wd_beat_log`, `spl_wd_tick_slow`). It holds two kinds of
line, with times in UTC and milliseconds.

### 1.1 BEAT: one line per beat

```text
BEAT 2 tick=2027-01-15T08:00:30.000Z sent=2027-01-15T08:00:41.512Z ack=2027-01-15T08:00:41.734Z ms=222
```

| field | meaning |
|---|---|
| `2` | the watchdog instance (`WD_INST`), `-` when there is a single one |
| `tick=` | the start of the tick that sent the beat (its `now`) |
| `sent=` | when the beat call started |
| `ack=` | when the hub's `"ok": true` answer came back, or `none` (no answer, a timeout after `WD_BEAT_TIMEOUT` 10 s, or an answer that is not ok) |
| `ms=` | how long the call took, answer or not |

A beat with `ack=none` also logs the `BEAT ... no ack` line in `wd.log`, as
before.

### 1.2 TICK: a tick that ran past WD_TICK

A tick that took longer than `WD_TICK` (30 s) appends its step times:

```text
TICK 2 tick=2027-01-15T08:00:30.000Z ms=95210 peers=12 update=3 ps=40 tmux=88 agents=410 fence=10230 boot=7 orch=15 judge=84300 log=25
```

`ms=` is the whole tick. Each `<step>=<ms>` is the time since the step
before. The steps follow the order of `spl_wd_tick`: `peers` (the other
instances), `update` (self-update), `ps`, `tmux` (the tmux lists), `agents`
(the agent list), `fence` (the beat and the fence, so the beat's own `ms=` is
part of it), `boot`, `orch` (the orchestrator outcome), `judge` (every agent
judged, the parallel jobs) and `log` (`wd.log` written and trimmed).

## 2. How to read a gap

1. Find the gap. Consecutive `BEAT` lines with an ack are the beats the hub
   saw. List the gaps between acks over 120 s, for any instance:
   `awk '/^BEAT / && $5 != "ack=none" {split($5, a, "="); print a[2]}' beat.log | sort | uniq | while read t; do date -u -d "$t" +%s; done | awk 'NR > 1 && $1 - p > 120 {print p, $1, $1 - p} {p = $1}'`.
2. Within the gap, look at the lines of each instance:
   - `ack=none` lines: the beat was sent and the hub did not answer. The cause
     is on the hub or the network side, not on the box.
   - `sent=` far after `tick=`: the steps before the fence were slow. The
     `TICK` line of that tick names the step.
   - no `BEAT` line at all for a while: no tick ran (a hung step, the watchdog
     down, or a box that slept: see `RESUME` in `wd.log`). The next `TICK`
     line, if the tick finished late, shows which step held it.
3. Compare the instances. All three gapping at the same time points to the
   box or the hub. One instance alone points to that instance's own tick.
