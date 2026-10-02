# How-to: give the satellite real work

The box PC (desk box `box-desk`) leads the fleet; the satellite (desk box
`sat`, `ssh satellite` over IAP) stands by with its own trio. This page is the
measured recipe for passing messages between the two machines and for running
an execution agent on the satellite. Measured 2026-10-02 (CLE-77954).

"On the satellite" = from the PC, as the box user:

    ssh satellite 'sudo -iu <BOX_USER> bash -lc "<command>"'

`S=/opt/csi/csi-spl/csi-spl-orc/src/bash/features/spawn-agents/scripts` on
both machines.

## 1. Passing messages PC <-> satellite

| leg | path | works | measured |
|---|---|---|---|
| PC -> sat | `ssh satellite` + `spool-send.sh` ON the satellite | yes | task to ack in 10 s (n=1) |
| PC -> sat | hub relay (`spool-send.sh --to <ID>@sat` on the PC) | only when the SENDER is seated on the PC's desk | refused exit 13 for an unseated lane agent (n=1) |
| sat -> PC | hub relay (`spool-send.sh --to <ID>@box-desk` on the satellite) | yes, sender seated | file in the PC inbox 6 s after the send (n=1) |
| sat -> PC | `ssh` back to the PC | no: the satellite has no route to the PC | - |

### 1.1 PC -> satellite, from an agent that is NOT seated on the hub

Give yourself a mailbox on the satellite once (a lane agent of the PC has none
there):

    ssh satellite 'sudo -iu <BOX_USER> bash -lc "mkdir -p /var/spool-hub/<YOUR-ID>/{inbox,outbox,archive}"'

Send the task (the body file is piped over ssh: `scp` from the PC cannot read
a file in another user's private temp dir):

    cat body.md | ssh satellite 'cat > /tmp/<YOUR-ID>-body.md; sudo -iu <BOX_USER> bash -lc "SPOOL_ROOT=/var/spool-hub bash $S/spool-send.sh --from <YOUR-ID> --to CLE-001 --kind task --no-ask --body-file /tmp/<YOUR-ID>-body.md"'

Tell the receiver to answer `--to <YOUR-ID>` (your satellite mailbox), then
read the answer:

    ssh satellite 'sudo -iu <BOX_USER> bash -lc "SPOOL_ROOT=/var/spool-hub ~/.local/bin/spool recv --as <YOUR-ID> --ack"'

### 1.2 PC -> satellite, from a seated agent (the trio)

    SPOOL_ROOT=/var/spool-hub bash $S/spool-send.sh --from CLE-001 --to CLE-001@sat --kind note --body "<text>"

The PC's desk sidecar hands it to the hub, the satellite's sidecar writes it
into the inbox there and rings the pane (`delivery: sent`, `poke: remote`).

### 1.3 Satellite -> PC

On the satellite, from a seated agent (the trio):

    SPOOL_ROOT=/var/spool-hub bash $S/spool-send.sh --from CLE-001 --to CLE-001@box-desk --kind note --no-ask --body "<text>"

Trap: the file that lands on the PC reads `"from":"CLE-001"` with no box, so
CLE-001@box-desk sees a message from itself. Name the sending box in the body
until the envelope carries it.

## 2. Starting an execution agent on the satellite

The satellite's `/var/spool-hub/box.env` sets `SPOOL_AGENT_USER=ai-usr` and the
id range `100000-199999`, so `auto` ids never collide with the PC's. Copy the
brief over, then spawn (dry run first):

    cat brief.md | ssh satellite 'sudo install -o <BOX_USER> -g <BOX_USER> -m 644 /dev/stdin /var/tmp/<brief>.md'
    ssh satellite 'sudo -iu <BOX_USER> bash -lc "cd /opt/csi/csi-spl && SPAWN_DRY_RUN=1 bash $S/spawn-claude.sh CLE-100001 /opt/csi/csi-spl /var/tmp/<brief>.md <slug>"'
    ssh satellite 'sudo -iu <BOX_USER> bash -lc "cd /opt/csi/csi-spl && bash $S/spawn-window.sh claude auto /opt/csi/csi-spl /var/tmp/<brief>.md <slug>"'

It prints `<ID> <pane>`. Watch it:

    ssh satellite 'ps -o user=,etime=,args= -C claude | cut -c1-100; uptime; sudo -iu <BOX_USER> tmux capture-pane -p -t <pane> | tail -20'

The agent runs as ai-usr in the box user's tmux session `main`, in its own
worktree `/opt/csi/csi-spl-wt/<ID>`. The satellite's desk crons live in the
box user's crontab (`crontab -l` as the box user; `debian`, root and ai-usr
have none).
