# The 7-min box link watcher (SPL-4816)

Owner HUM-10, topic 0956269e, 2026-11-04 11:45:50Z (msg 7e8d02b4): a problem
in the relay or the connection that lasts more than 7 minutes must be told to
the owner in that topic. The trigger: a push command ran on the box
09:43:56Z..10:45:14Z and exited 6 (`REFUSED: <sha> never reached this box (no
matching bundle in 60 min)`); nobody told the owner before the 60-min timeout.

The relay itself left this tree (SPL-1910). The watcher is name-neutral: the
relay's paths are box-local, in env or a file outside git.

## 1. What it does

`cd csi-spl-orc && ./run -a do_spl_box_link_watch` (dry run; `DRY_RUN=0`
sends) runs every minute from the box-crons manifest row `box-link-watch`
(`src/bash/scripts/box-link-watch-cron.sh`; core
`src/bash/scripts/box-link-watch.py`). It is read-only on the relay: it never
touches the relay, its queues or the box.

For each box the hub serves (a dir `<root>/<box>/` with `inbound/` and
`outbound/`) it tracks four conditions:

| | condition | read from | clears on |
|---|---|---|---|
| a | a queued or sent bundle/command with no receipt | hub log `queued ...` / `sent <name> hub -> ...` | `delivered <name> to`; a command also on its box `START`, its `exec: request <id> -> exit` line or `<results>/<id>/result.json` |
| b | a box apply or command refused or timed out | `box: deploy:` / `box: exec:` REFUSED or timed out lines; `exec: request <id> -> exit <n>` with REFUSED / timed out in `<results>/<id>/` or exit 124 | a later `box: deploy: APPLIED` (apply) or `-> exit 0` (command) |
| c | the box log not advancing, while a, b or d holds or a command runs on the box | the newest `inbound/*/*-log.box.*` and the hub's `received ...-log.box.` lines; quiet for more than 180 s, counted from the later of that and the oldest of a, b, d or a running command | the next box log, or nothing left in flight |
| d | the link or session down | no `<home>/run -a radiate` process, or the hub log closed the session after its last `radiating session` | the radiate back |

A command runs on the box from its `exec: request <id> START` line until its
`DONE` / `-> exit` line or `<results>/<id>/result.json`. It is no condition of
its own (a long command is no fault), but it is work in flight, so a box log
silent while it runs counts as c.

The hub logs read are the `*.out.log` files of the last 6 h in the log dir
that name `<root>/<box>/`: a relay test run logs into the same dir but names
its own temp queues, so it never counts. While an incident is open the read
reaches back to its start, so a stuck line older than 6 h still holds it open.
A log stamp marked `UTC` (or `GMT`, `Z`) is read as UTC whatever the cron's
`TZ`; any other zone token is read in the local zone.

A silent box log alone is no incident: the box is off at night (about 00Z
to 04-08Z on 2026-11-03 and 11-04), and with nothing in flight there is
nothing to tell anyone (c-002@sat, msg b7011f23). The hub's radiate keeps
running through the night and its log closed no session in the night of
2026-11-04/05 (n=1 night; its only close since 11-02 was 22:19Z on 11-04), so
d did not bring the quiet box log back that night.

When any condition is older than 7 min the box has ONE incident: one spool
message, kind `blocker`, task `dispatch-<topic8>`, listing every stuck
condition with since when and its evidence line (URLs and tokens redacted).
When none is left: one note, `LINK CLEARED on box <box> after N min`. The
state file (`$XDG_STATE_HOME/csi-spl/box-link-watch.json`) keeps what was
sent; a send that fails is retried next run. A lock keeps two runs apart.

## 2. Configure a box

`$XDG_CONFIG_HOME/csi-spl/box-link-watch.env` (default
`$HOME/.config/csi-spl/box-link-watch.env`), read as `KEY=VALUE` lines, never
sourced; env wins over it:

| key | holds |
|---|---|
| `BOX_LINK_WATCH_ROOT` | the hub's box dirs |
| `BOX_LINK_WATCH_LOG_DIR` | the hub's own logs |
| `BOX_LINK_WATCH_HOME` | the relay checkout whose `run -a radiate` must run |
| `BOX_LINK_WATCH_RESULTS` | the run-on-box results dir (optional) |
| `BOX_LINK_WATCH_LOG_GLOB` | the hub log names (optional, default `*.out.log`) |

No `BOX_LINK_WATCH_ROOT` -> nothing to watch, exit 0: the cron is a no-op on
every box without the file.

## 3. Who gets it

The topic that owns a box's work is `csi-spl-orc/cnf/box-link-watch/topics.tsv`
(`box<TAB>topic8`). The receiver is that topic's live seat: the newest live
lane-map row on the topic whose scope starts with `Seat`; with none, the
dispatch lease holder. A box with no row in that file goes to the dispatch
lease holder too, on task `box-link-watch-<box>`, and the run exits 1 so the
missing row shows in the cron log. The watcher never posts to the hub: the seat tells the
owner in the topic, within the 7 min.

Until the relay ships a box heartbeat line, "no box log for 7 min while
work is in flight" is the silence signal (owner pick [4], narrowed by c-002
msg b7011f23 for the night-off box); a heartbeat line arrives in the same box log, so it needs no
change here.

## 4. Test

`csi-spl-orc/src/bash/tests/box-link-watch.tst.sh`: a bundle 8 min with no
receipt -> one alert; the next run -> none; the receipt -> one "cleared";
6 min -> none; the command, box-log, link and refusal cases; the fallback;
dry run; a failed send retried; a test-run log ignored; the env file; a box
with no topic row -> the fallback; an incident older than the window is not
cleared; UTC stamps read under another `TZ`; a box log silent 4 h with nothing
in flight -> none, then a bundle unreceipted 8 min -> one alert naming both. Red
control: the second run with the state file gone sends a second alert.
