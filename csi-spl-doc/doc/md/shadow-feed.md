# The shadow feed and the shadow seat

A shadow seat is a second leader in training: it reads what the orchestrator
and the dispatcher read, decides what it would have done, and posts nothing.
The shadow feed is the one thing it reads.

Owner, t1 #spool-hub-ops topic ee1e58d5, 2026-10-11 (msg f802ab00): "READ-ONLY
access to a mirror of c-001/c-002/c-003's spool traffic (inbox, outbox,
archive), refreshed every few minutes, with no write access to any spool dir
and no desk seat ... Keep one safety: drop file attachments from the mirror."
The data rule allows a Grok seat to see that traffic (owner msg 26117740).

## 1. What the feed is

`cd csi-spl-orc && ./run -a do_spl_shadow_feed` makes one pass:

| from | to |
|---|---|
| `$SPOOL_ROOT/<agent>/{inbox,outbox,archive}/*.json` and `*.md` | `$SHADOW_FEED_DIR/<box>/<agent>/<same sub>/<same name>` |

- `SHADOW_FEED_AGENTS` defaults to `c-001 c-002 c-003`; `SHADOW_FEED_DIR` to
  `/var/spool-shadow`, which must lie outside the spool root (refused
  otherwise).
- A JSON message keeps every field except its attachments: `files` becomes
  `[]` and `files_dropped` says how many refs were cut. The file a ref points
  to is never read or copied. A legacy `.md` message is copied as is.
- Every mirror file is mode 0444 with the source's mtime; every dir 0755. A
  message acked out of an inbox leaves the mirror's inbox too.
- Handoff notes, heartbeats and any other file next to the mailboxes are not
  copied.
- `$SHADOW_FEED_DIR/LAST_RUN` holds the time and counts of the last pass. A
  seat that finds it older than 15 minutes says so in its notes.
- Each `<box>=<ssh host>[:<spool root>]` in `SHADOW_FEED_REMOTES` is pulled
  first with one `rsync` over ssh into a private stage (0700), then mirrored
  into `$SHADOW_FEED_DIR/<box>/` the same way. A failed pull is a WARN that
  names rsync's own error (a timed-out ssh, a `Permission denied` on the far
  spool) and keeps that box's last mirror.

Measured on the satellite box, 2026-10-11 (11 535 messages of three agents):
the first pass 3.6 s, a pass with nothing new 1.1 s; 12 attachment refs
dropped.

Test: `csi-spl-orc/src/bash/tests/spl-shadow-feed.tst.sh` (the attachment
drop is red without the drop; a plain message and a legacy `.md` are the
controls that arrive intact).

## 2. Set it up on a box

### 2.1 Create the feed dir, owned by the box owner user

```bash
sudo install -d -o "$USER" -m 0755 /var/spool-shadow
```

Run it as the box owner user (`<DEV_USER>`), not as the agent user the seat
runs as: the seat must not own the feed, or it could write it.

### 2.2 One pass by hand

```bash
cd csi-spl-orc && ./run -a do_spl_shadow_feed
```

### 2.3 The cron, every 5 minutes, from the main checkout

```bash
cd csi-spl-orc && DRY_RUN=0 SHADOW_FEED_REMOTES="<box>=<ssh host>" ./run -a do_spl_shadow_feed_install_cron
```

Leave `SHADOW_FEED_REMOTES` out on a box that cannot reach the other one.

### 2.4 When the ssh login cannot read the far spool

The spool root is readable by its owner and the spool group only. An ssh login
that is in neither (a cloud image's default user) gets `Permission denied` on
the far side. If that login has sudo there, read the far spool as the spool
owner (`<DEV_USER>`) by adding this to the commands in 2.2 and 2.3:

```bash
cd csi-spl-orc && DRY_RUN=0 SHADOW_FEED_REMOTES="<box>=<ssh host>" SHADOW_FEED_REMOTE_RSYNC="sudo -n -u <DEV_USER> rsync" ./run -a do_spl_shadow_feed_install_cron
```
`SHADOW_FEED_CRON_ACTION=remove` takes the line out again.

## 3. The shadow seat

### 3.1 What keeps it read-only

- It reads `$SHADOW_FEED_DIR` only, never `$SPOOL_ROOT/c-00*/`; its brief says
  so and its notes cite feed paths only.
- The feed is owned by another user: its files are 0444 and its dirs 0755, so
  the seat cannot change them.
- It holds no desk seat and sends nothing to the owner, a desk or a lane. Its
  one message is the final report to the orchestrator.
- The agent user is in the spool group, so the OS alone does not keep it out
  of the spool: the brief and the orchestrator's review of its notes do.

### 3.2 The brief

A brief for the seat, as the orchestrator hands it to the launcher (fill in
`<feed dir>`, `<notes file>` and `<orchestrator>`):

> You are the shadow leader. For at least 10 hours, every 10 to 15 minutes,
> read the new files under `<feed dir>` (newest first: `ls -t`), and
> `<feed dir>/LAST_RUN`. Read nothing under the spool root. Post nothing,
> route nothing, spawn nothing, edit no repository file. Once an hour append
> to `<notes file>`: what you would have done with the hour's messages, and
> where you differ from what the orchestrator and the dispatcher did, citing
> the feed paths. At the end, append a gap list: what the runbooks
> `csi-spl-doc/doc/md/runbook-dispatcher.md` and
> `runbook-orchestrator.md` (on master once they land) do not tell you that
> you needed. Then send `<orchestrator>` one message naming the notes file,
> and stop.
