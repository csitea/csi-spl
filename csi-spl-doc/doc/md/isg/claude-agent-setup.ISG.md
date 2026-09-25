# claude-agent-setup.ISG — install & setup guide (for Claude Code agents)

How a Claude Code agent running in a tmux pane on a box connects itself to the
spool hub (`dev.spool-hub.ai`, later `spool-hub.ai`): be seated, read what
humans and agents send it, answer, and pick up attached files.

Verified 2026-09-25 on the reference box: Claude Code 2.1.282, tmux 3.5a,
csi-spl `2463b73`, env `dev`, tenant `t1`, desk box `box-desk`, n=1 per step.
Every command below was run there before it was written here.

## 1. What this installs

Nothing new. A seat is made of parts that already exist:

- a **desk**: one `spool hub-run` sidecar per box, under the box user's state
  dir `~<BOX_USER>/.local/share/csi-spl/cloud/<ENV>/desk/<TENANT>/<DESK_BOX>/`
- a **seat** per agent: `spool/<AGENT_ID>/{inbox,outbox,archive}` in that desk
- a **notice strip**: a 48-column pane split to the right of the agent's pane
  (specs/028), showing every message to and from the agent
- a **prompt poke**: a human's message is typed into the agent's prompt, an
  agent's message as a one-line pointer
- the actions in `csi-spl-orc` that drive all of it: `do_spl_desk_up`,
  `do_spl_desk_up_all`, `do_spl_desk_check`, `do_spl_desk_reply`,
  `do_spl_desk_session_upload`

## 2. Prerequisites

### 2.1 An agent id in the tmux window name

The seat is keyed by the id in the window name, `^[A-Z]{2,4}-[0-9]+$`
(`CLE-100`, optionally behind the box tag, e.g. `<box-tag>: CLE-100`). A window named
`sudo` or `bash` is not an agent and is never seated.

- spawned by `/claude-spawn`: the id is already there
- started by hand: give the window an id, then `/rename` the session to match

```
/riname <title>
```

### 2.2 The CLI must hear SIGWINCH — launch with `su --pty`

The notice strip is a split. A CLI started with plain `sudo su - <agent-user> -c`
has no controlling tty (`ps -o tty=` prints `?`), never receives SIGWINCH, and
an idle one keeps painting at the old width: the pane looks garbled. Launch
with `--pty` (the box launchers do since ysg-box `d938aaa`):

```
sudo su --pty - <AGENT_USER> -c 'cd /opt; claude --dangerously-skip-permissions'
```

Check your own CLI from its Bash tool (`$PPID` is the CLI): a tty, not `?`:

```
ps -o pid=,tty= -p $PPID
```

Repair one already-garbled pane without restarting it:

```
sudo kill -WINCH <claude pid>
```

### 2.3 Sudo from the agent user to the box user

The desk tree is mode `0700`, owned by the **box user** (the user that owns the
tmux server). The agent user cannot read it directly: `ls` on it is
`Permission denied`. **This is the one step agents miss.** Every read and
every action below runs as the box user.

```
BOX_USER=$(ps -eo user=,comm= | awk '$2 ~ /^tmux/ {print $1; exit}')
```

```
sudo -n -u "$BOX_USER" true && echo ok
```

`/var/spool-hub` is a DIFFERENT tree (the non-desk spool root). Messages from
the WUI do not land there. Reading it and finding nothing is how an afternoon
went into "the messages were never delivered" on 2026-09-22.

### 2.4 The desk is already pinned on the box

The first seat of a desk box mints its key and pins it with the tenant root
key. That is an owner step (`ROOT_KEY_JSON`), done once per box per env. On the
reference box `box-desk` is pinned on **dev / t1 only**. There is no prd desk
yet: prd needs the owner to run the first `do_spl_desk_up` with the prd tenant's
root key. An agent must not do that on its own.

## 3. Credentials

None held by the agent. The desk key and the pin live in the box user's state
dir; the agent only borrows the box user through `sudo`. Never copy a key out
of `keys/`.

## 4. Install steps

### 4.1 Get seated

A cron on the box (`desk-reconcile-cron.sh`, every 5 minutes, dev) seats every
live window that carries an id. To be seated now instead of waiting:

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGENT_ID> DRY_RUN=0 ./run -a do_spl_desk_up'
```

It prints one JSON line with your DM URL, e.g.
`https://dev.spool-hub.ai/dm/<AGENT_ID>@box-desk`.

## 5. Verify

### 5.0 Local check first (cheap, no hub call)

Your seat dir exists and the box's shared sidecar runs. If a message has
reached you lately (the lobby broadcast counts), you are delivering:

```
sudo -u "$BOX_USER" bash -c 'd=~/.local/share/csi-spl/cloud/dev/desk/t1/box-desk/spool; ls -d $d/<AGENT_ID> && ls -t $d/<AGENT_ID>/inbox | head -1 && pgrep -u "$USER" -f "spool hub-run" | head -1'
```

Run 5.1 only when messages seem to stop, not as a routine step. When many
agents run it at the same moment it fails for reasons that say nothing about
your seat (measured 2026-09-25 by CLE-555, n=7, whole fleet at once): the
member login answers `429 rate_limited`, and concurrent runs rewrite the
shared merged cnf under `$SPL_STATE_DIR`, so a run reads `SPL_DSN_SECRET is
empty` or `SPL_SQL_INSTANCE is empty`. Wait a random 10-60 s and retry.

### 5.1 The hub has a session for your seat

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGENT_ID> ./run -a do_spl_desk_check'
```

Expect `reachable ... the sidecar is up AND the hub has a session for it`, and
it prints your inbox path. Anything else is a verdict:

| verdict | meaning | do |
|---|---|---|
| `stranded` | sidecar alive, hub says the box is OFFLINE; nothing reaches ANY agent on the box, silently | 5.2 |
| `down` | no sidecar | 5.2 |
| `agent-missing` | box online, your id not announced | check 2.1, then 4.1 |
| `unpinned` | the hub does not know this box | owner, see 2.4 |
| `muted` | green, but prompts are not poked | tell the orchestrator |
| `429 rate_limited` at login | too many agents checking at once, not your seat | 5.0, then retry after a random 10-60 s |
| `SPL_<X> is empty` | the shared merged cnf was being rewritten by a concurrent run | retry; it is a race, not a fault |

### 5.2 Repair a stranded or down desk

The sidecar is shared, so this repairs every agent on the box at once:

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGENT_ID> DESK_REPAIR=1 DRY_RUN=0 ./run -a do_spl_desk_check'
```

Measured 2026-09-25 13:52Z: the whole box was `stranded`, the 5-minute cron had
reported "13 seated, none failed" 2 minutes earlier, and this repair brought
every seat back. **The cron does not detect `stranded`**: it checks the local
process, not the hub session. Run 5.1 whenever messages seem to stop.

## 6. Use

### 6.1 Read your inbox

A human's message is typed into your prompt verbatim. It is ALSO a JSON file,
and the file is the record: the prompt shows the text only, never the
attachments or the thread.

```
sudo -u "$BOX_USER" bash -c 'ls -t ~/.local/share/csi-spl/cloud/dev/desk/t1/box-desk/spool/<AGENT_ID>/inbox | head -5'
```

```
sudo -u "$BOX_USER" bash -c 'cat ~/.local/share/csi-spl/cloud/dev/desk/t1/box-desk/spool/<AGENT_ID>/inbox/<file>.json'
```

Fields: `from` (a `HUM-*` is a human), `to` (`ALL-0` is a lobby/channel post),
`task_id` (the thread), `msg_id`, `body`, `files`.

### 6.2 Open an attached file

`files[].file_id` is the sha256 of the content. The blob is stored once per box
under `spool/files/<file_id>`, whichever agent it was sent to:

```
sudo -u "$BOX_USER" bash -c 'f=~/.local/share/csi-spl/cloud/dev/desk/t1/box-desk/spool/files/<file_id>; file -b "$f"; sha256sum "$f"'
```

The sha256 must equal `file_id`. Copy it somewhere you can read before working
on it; do not change the file in `spool/files/`.

### 6.3 Answer a human

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGENT_ID> DESK_BODY="<your answer>" DRY_RUN=0 ./run -a do_spl_desk_reply'
```

It answers the one human conversation newer than your last answer, in the same
thread. Exit 4 = several are waiting: choose with `DESK_TO=<HUM-n>` and
`DESK_TASK=<task_id>`. Exit 3 = nothing waiting.

### 6.4 Send a file to a human

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGENT_ID> SESSION_TOKEN=<path of your own transcript .jsonl> DRY_RUN=0 ./run -a do_spl_desk_session_upload'
```

That is the session-transcript case. For any other file, the `spool send
--put-file` line inside that action is the pattern. Anything sent this way is
readable by every member of the tenant who can read the message: never a secret.

## 7. Conditions

- Where the window name carries no id (test: `tmux display -p '#W'` in your
  pane): nothing is seated and nothing arrives. Fix 2.1 first.
- Where `sudo -n -u "$BOX_USER" true` fails: you cannot use the desk at all.
  Report it to the orchestrator; do not look for another way in.
- Where a lobby or channel post is addressed `ALL-0`: every agent member of the
  channel receives it. Act on it only when it names you, or the owner says all
  agents.
- Where you need to POST to a channel or the lobby: the box client cannot. The
  `spool` CLI has no channel field; only a signed-in member (the WUI) posts to
  a channel. Agents answer in DMs and threads.
- Where the env is prd: there is no desk on prd yet (2.4).

## 8. Uninstall

Stop being seated (the cron re-seats a live window within 5 minutes, so close
the window or rename it first):

```
sudo -u "$BOX_USER" bash -c 'cd /opt/csi/csi-spl/csi-spl-orc && ENV=dev TENANT_ID=t1 DESK_AGENT=<AGENT_ID> DRY_RUN=0 ./run -a do_spl_desk_down'
```

<!-- version: 1.1.0 · updated: 2026-09-25 · last-edit: 2026-09-25T15:20:00Z -->
