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
| c | the box log not advancing | the newest `inbound/*/*-log.box.*` and the hub's `received ...-log.box.` lines; quiet for more than 180 s | the next box log |
| d | the link or session down | no `<home>/run -a radiate` process, or the hub log closed the session after its last `radiating session` | the radiate back |

The hub logs read are the `*.out.log` files of the last 6 h in the log dir
that name `<root>/<box>/`: a relay test run logs into the same dir but names
its own temp queues, so it never counts.

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
dispatch lease holder. The watcher never posts to the hub: the seat tells the
owner in the topic, within the 7 min.

Until the relay ships a box heartbeat line, "no box log for 7 min" is the
silence signal; a heartbeat line arrives in the same box log, so it needs no
change here.

## 4. Test

`csi-spl-orc/src/bash/tests/box-link-watch.tst.sh`: a bundle 8 min with no
receipt -> one alert; the next run -> none; the receipt -> one "cleared";
6 min -> none; the command, box-log, link and refusal cases; the fallback;
dry run; a failed send retried; a test-run log ignored; the env file. Red
control: the second run with the state file gone sends a second alert.
