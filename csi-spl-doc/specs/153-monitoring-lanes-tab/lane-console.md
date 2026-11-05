# 153 section 3.20: a lane's live console (SPL-4810)

Addendum to [spec.md](spec.md), placed by the dispatch holder as one lane
brief (task `dispatch-27162335`, plan msg `7e928b34`, GO msg `f85b9a18`), not
a panel version. Epic SPL-2403. Issue SPL-4810.

## 1. The owner's asks, verbatim

Owner HUM-10, t1 topic `27162335-08ea-4a9b-8a27-aad17a920eef`:

| msg | time (UTC) | text |
|---|---|---|
| `038fa412` | 2026-10-25 11:03:35 | "it should be possible for the end user to actually seen the console output of a lane , ON PER DEMAND click" |
| `8dd53bd9` | 2026-10-25 11:05:22 | "meaning getting the same output which the terminal user on the tmux window will see , but ONLY after he opens the lane , which will have the lane data in a pop-up modal dialog - the same way the issues are opened within th table , and theere at tend should bhe the console output button , wihch one clicking will get a life feed of the console , the same one which one would get via the terminal" |
| `3b2ba6f3` | 2026-10-25 11:05:41 | "and than the capability to save that logoutput to a file locally" |

## 2. What it does

- **The dialog.** On Monitoring -> Lanes, a row's agent (`lanes-open`)
  opens the lane in a modal dialog (`UiDialog`, as an issue opens from the
  Issues sheet): the lane's fields first, the **Console** button at the
  end. The table itself has no Console button. The dialog is loaded lazily
  (`defineAsyncComponent`), never in the first chunk.
- **The feed.** Console shows the lane's tmux screen plus 200 lines of
  scrollback as plain text, newest at the bottom. It refreshes every 2 s
  while the browser tab is visible; Pause stops it, closing the dialog stops
  the reads and the watch renewals, and the box stops capturing when the
  last demand runs out, within 60 s. Follow keeps the bottom in view; scrolling up turns it off. The status
  reads waiting (no capture yet), live (captured n s ago) or stale (the
  last capture is over 15 s old), and "n secrets masked on the box".
- **Save.** Writes exactly the shown lines to a local file
  `<agent>@<box>-<UTC yyyymmddThhmmssZ>.txt` (no box when the reader is not
  given it). Nothing is sent anywhere.

## 3. The path: box -> hub -> browser

1. **Watch.** Console sends `POST` (below) and repeats it every 20 s while
   the feed shows. The hub sets that lane's `demand_until = now + 60 s` in
   `lane_console` (rdb `0263_lane_console.sql`), in the BOX's workspace.
2. **Box.** The box file follower (`csi-spl-orc/src/bash/scripts/file-stream-follow.py`,
   spec 160) runs `features/spawn-agents/lib/lane_console.py` on every tick.
   Every 5 s it pulls the agents of its own box with a demand on (lane op
   `file_streams_console_demands`). For each one it finds the tmux window
   whose name is the agent id (an optional `<tag>: ` prefix allowed), runs
   `tmux capture-pane -p -J -S -200`, masks every line and pushes the text
   (lane op `file_streams_console_push`), at most once a tick, and an
   unchanged screen at most every 10 s. No demand: no tmux call, no push.
3. **Read.** The dialog `GET`s the last capture every 2 s.

The two lane ops ride the follower's existing push command (`spool
file-streams push --json -`) and session: the box and the workspace are the
session's, never the frame's. A push with no demand on is `409
not_demanded`; a screen over 128 KiB is `413 too_large`.

The tmux the follower calls (`FILE_STREAMS_CONSOLE_TMUX`, a JSON argv) is set
by `do_spl_file_stream_follow`: the box user's server (box.env
`SPOOL_BOX_USER`, else the spool root's owner), socket
`/tmp/tmux-<uid>/default`, through `sudo -n -u <box user>` when the follower
runs as another user.

## 4. Who may see it

| door | route | who |
|---|---|---|
| operator | `POST` / `GET /v1/operator/lane-console` | an admin of the operator workspace (`operatorActor`); never the service account |
| workspace | `POST` / `GET /v1/lanes/console` | the owner or an admin of the caller's workspace (3.6's gate) |

The request names `agent_id` and `agent_box` (query on `GET`, JSON body on
`POST`). Then the lane must be a live row of the SAME view that door's Lanes
tab reads (`fleetLanesView`, `workspaceLanesView`), or `404`: a reader opens
only a lane its Lanes tab shows. A member or a viewer gets `403`. A workspace
reader never learns an operator box: its view sends `agent_box ""` for
those lanes, and so does the console's answer.

## 5. Secrets

The capture is masked on the box before it leaves it: every line through
the follower's `mask_line()`, which is `spool_redact.redact()` (the box's one
redaction list) plus the PEM state across lines, from the first captured
line on. Then the lines a secret spans that the agent's TUI hard-wrapped
with real newlines (`capture-pane -J` joins only the rows tmux itself
wrapped) are masked whole as `<redacted:wrapped-secret>`: from each line,
up to 4 lines are joined at the wrap, and when the join shows a secret its
lines alone do not, every line the secret touches is masked. The join
drops the newline, so a word that starts the line after a token may be
masked with it: more, never less. Each line is cut to the follower's line
limit only after the mask, so a cut never leaves a token's prefix
unmasked. `spool_redact` also masks a `KEY=value` whose upper-case name
carries KEY, SECRET, TOKEN, PASS, PWD, CRED, AUTH, SIGN, SALT, PRIVATE,
COOKIE, SESSION or DSN, which an `env` or a `cat .env` in a pane shows.
The hub stores and serves only the masked text and the per-kind
count, never what was removed. Save writes the masked text the dialog shows.

## 6. Cost (db-f1-micro)

One row per watched lane, overwritten in place: no history. Writes happen
only while someone watches: at most one push every 2 s per watched lane,
plus one demand upsert every 20 s per open feed; reads are one `GET` every
2 s per open feed (the lane's resolution is cached 30 s per reader) and one
demand read every 5 s per box per hub. That pull runs on every box whether
anyone watches or not: per box and hub, one `spool file-streams push`
subprocess, one hub request and one indexed read every 5 s; the capture
itself runs only on a demand. A row whose demand ended an hour ago is
deleted by the next demand in that workspace; until then the last masked
screen stays readable to the same readers.

## 7. Cases

| case | what | test |
|---|---|---|
| C90 | operator admin watches; the box pulls, pushes; the admin reads it live | `internal/hub/lane_console_test.go` |
| C91 | a workspace owner and admin read an operator lane on their topic, box never named | same |
| C92 | a developer (403), the operator door for a workspace admin (403), a lane not on the reader's Lanes tab (404), the operator box named by a workspace reader (404) | same |
| C93 | a workspace's own lane (3.17) lives in that workspace; another box hears nothing and its push is 409; an oversized screen is 413 | same |
| C94 | a demand ends after 60 s: no demand pulled, a push is 409 | same |
| L1 | screen + 200 lines of scrollback; a token on scrollback line 150 and a PEM key arrive masked | `csi-spl-orc/src/bash/tests/spl-lane-console.tst.sh` |
| L2 | nobody watches: no tmux call, no push | same |
| L3 | a window named `<tag>: <id> title` is found | same |
| L4 | an unchanged screen is not re-sent before keep_s | same |
| L5 | a token hard-wrapped by the TUI (2 lines at col 14, 4 lines at 12 cols) arrives masked | same |
| L6 | a line over the line limit is masked before it is cut | same |
| W1 | the row opens a modal; Console only inside it; a click shows the feed; Save downloads the shown lines as .txt; both doors, 1440 and 390 | `csi-spl-wui/tests/e2e/monitoring-lane-console.test.mjs` |
| W2 | the feed body, the routes, the file name and text, the mock's doors, the lazy dialog | `csi-spl-wui/tests/unit/monitoring-lane-console.test.mjs` |

Rollout: a box serves the console once its follower and its desk's `spool`
binary carry the two lane ops; before that the dialog stays at "waiting".
