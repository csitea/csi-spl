# Laptop Box

A member's own **Debian laptop** can run fleet agents during her working
hours, so its hardware is used while she works. She runs one-liners only:
one to install, one per control. The agents run as their own OS user, never
as her: her account, and any Claude CLI of hers, are not touched or used.

Outside her hours the laptop takes no new lanes. At the end of her hours,
while lanes still run, she is asked whether to continue: **Continue** keeps
them 1 more hour; **Stop**, or no answer in 15 minutes, moves every lane to
the fleet box named at install (the move box), where its session resumes.

## 1. Before the install (the workspace admin)

1. **A join token** for the laptop: Workspace settings -> Agents -> Join
   tokens -> **New join token** (see [Connect an Agent](./connect-an-agent.md),
   section 9). Give it to her out of band; she types it when the install asks.
2. **The move box's ssh is reachable from her network.** The laptop pulls
   the fleet's Claude login from the move box and moves its lanes there over
   ssh. Check it from her network before the install; if it is not
   reachable, opening it (a firewall rule or IAP) is a separate decision of
   the workspace owner, and the laptop box does not work until it is made.
3. **Her values** for the install line: a box tag (`lap-a`, lower case),
   her hours, the workspace id, the move box's tag and its
   `<user>@<host>`.

## 2. Install (she runs it once, with sudo)

One line, in a terminal on her laptop:

```bash
sudo apt-get install -y git && sudo git clone https://github.com/csitea/csi-spl /opt/csi/csi-spl && cd /opt/csi/csi-spl/csi-spl-orc && sudo ./run -a do_spl_laptop_box_install --box-tag lap-a --hours "Mon-Fri 09:00-17:00" --tenant-id <workspace> --move-box <move box> --move-ssh <user>@<host> --dry-run 0
```

- Without `--dry-run 0` it only prints what it would do.
- It asks for the join token without showing it. The token never sits on a
  command line or in a file that stays.
- The clone path is fixed: the lanes resume on the move box at the same
  path.
- Optional: `--agent-max 4` (the most agents at once, default 4),
  `--laptop-ask wui|dsk` (how she is asked at the end of her hours: a form
  in the web UI, the default, or a desktop pop-up), with `wui` also
  `--laptop-ask-channel`, `--laptop-ask-from` and `--laptop-ask-hum HUM-<n>`.

What it does: the packages (git, gh, cron, tmux, curl, python3, jq, ...);
the agents' OS user (no sudo, a locked password); a current Claude Code and
the spool CLI for that user (`install.sh --cli claude --fleet`); the box
seated with the join token; her hours and the cap; her controls; a check
every 5 minutes; the login pull every 15 minutes; and the fleet services
that need no cloud key (the desk reconcile and the cross-box spawn
receiver).

Last it prints two public key lines **for the workspace admin**: the login
key and the move key (section 4).

## 3. Her controls

Each is one line, run as herself:

| line | what it does |
|---|---|
| `spl-laptop-box status` | her hours, the state (in use, stopped for today, off), the agents running here, an open question |
| `spl-laptop-box stop` | stop for today: the lanes move to the move box, back tomorrow in her hours |
| `spl-laptop-box off` | stop until she runs `start` (the lanes move too) |
| `spl-laptop-box start` | undo `stop` or `off` |
| `spl-laptop-box continue` | past her hours: keep the agents 1 more hour |
| `sudo spl-laptop-box github-token` | paste the fleet's GitHub push token once (not shown); the agents push with it |
| `sudo spl-laptop-box remove` | take it all off the laptop (refused while agents still run: `stop` first) |

The only secret placed on the laptop is that GitHub push token. Lanes that
need a cloud key are not placed there. She has root on her laptop, so she
can read the fleet login and the token stored for the agents' user: the
workspace owner accepted that.

## 4. On the move box (the workspace admin)

From the move box's checkout, in `csi-spl-orc`, with the two key lines the
install printed:

```bash
BOX_TAG=lap-a LAPTOP_PUBKEY="<the login key line>" DRY_RUN=0 ./run -a do_spl_laptop_box_login_grant
```

```bash
BOX_TAG=lap-a LAPTOP_GRANT_CMD=grant-move LAPTOP_PUBKEY="<the move key line>" DRY_RUN=0 ./run -a do_spl_laptop_box_login_grant
```

The login key can only read the fleet's Claude login (no shell). The move
key is a shell on the move box, so the lanes can resume there. To take both
back:

```bash
BOX_TAG=lap-a LAPTOP_GRANT_CMD=revoke DRY_RUN=0 ./run -a do_spl_laptop_box_login_grant
```

Removing the laptop also needs its seat revoked: Monitoring -> Boxes.

The design: spec 037, section "Laptop box"
(`csi-spl-doc/specs/037-spool-agent-install/spec.md`).
