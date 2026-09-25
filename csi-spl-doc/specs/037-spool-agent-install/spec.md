# Feature Specification: Installable Spool Agent Harness

**Feature ID**: `037-spool-agent-install` · **Milestone**: M3 · **Status**: Partial
**Created**: 2026-09-25 · **Lane**: spool-installer (CLE-34966)
**Authority**: this file for the behaviour and its rules; `tasks.md` for what is
built, with the sha and the check for each item. Status vocabulary:
`../README.md` §2.3.

Builds on `036-spool-terminal-mirror` (the `spool-agent` wrapper and the mirror
hooks), `028-spool-terminal-delivery` (the desk seat that types a human's DM
into the pane) and `012-spool-box-api` (the box key and its pin).

## The owner's request, verbatim (2026-09-25)

> could we make some kind of agent-client harness which will wrapp all ofthose so that whenever the user starts claude with that wrapper , this will be the behaviour
> we must make it "installable" , so that whenever another user with claude code or grok or agy runs our install script , they will get installed with the latest grok , agy or claude code installed including our harness , provided they have bash and git
> and yes add this command as well

"This command" is `spool-agent`, on the user's PATH.

## Use

Clone the repo as the user who will run the agents, then:

```bash
SPOOL_HUB_URL=<the hub URL> bash csi-spl-orc/src/bash/features/spool-install/install.sh --cli claude,grok --tenant <slug>
```

Then, inside tmux: `spool-agent claude`. `--dry-run` prints the plan;
`--no-seat` installs without a hub; `--update` pulls the clone first.

## Decisions

- **Where it lives.** `csi-spl-orc/src/bash/features/spool-install/install.sh`,
  next to the `spawn-agents` feature it installs. It runs FROM a clone: the
  harness scripts, the cnf the desk actions read, and the `spool` sources are
  all the checkout itself, so nothing is copied and `--update` is a
  `git pull --ff-only`. No repo URL is baked into any file.
- **"bash and git" means bash, git and the base tools every Linux or macOS box
  already has**: curl or wget (every vendor installer needs one), tar,
  python3 (the mirror hook, the settings merge), perl (`./run`), flock and
  setsid (util-linux; the desk sidecar), and tmux to seat an agent. A missing
  one is NAMED with the package line; the installer never runs sudo. That is
  the only place root is ever needed, and it is the user's to run.
- **The vendor CLIs** come from each vendor's own documented installer, which
  installs or updates to the latest release: `https://claude.ai/install.sh`,
  `https://x.ai/cli/install.sh` (with `GROK_BIN_DIR=<prefix>/bin`),
  `https://antigravity.google/cli/install.sh`. agy's installer stops when agy
  exists, so an installed agy runs `agy update`, its documented path. Each URL
  can be pointed at a mirror (`SPOOL_INSTALL_URL_CLAUDE` / `_GROK` / `_AGY`).
  Measured 2026-09-25: all three answer 200 with a shell script.
- **The spool binary is BUILT, not downloaded.** No prebuilt binary is
  published (`gh release list -R csitea/csi-spl` -> empty, 2026-09-25), and
  `do_spl_desk_up` rebuilds `spool` on every run (`spl_host_spool`) with the
  offline `build.sh` - so Go is needed on the box anyway. When no Go at least
  as new as `go.mod` is found, the latest Go from `go.dev` goes to
  `<prefix>/share/spool-agent/tools/go` (no sudo); likewise yq v4 (the desk
  actions read the cnf with it). The first build fetches the Go modules once
  through Go's default proxy; every later build is offline.
- **The mirror hooks go into `~/.claude/settings.json`** (claude reads it; grok
  reads it through its claude-compat hook scan). Any older `spool-mirror.py`
  entry is replaced, never added to (two copies post each prompt twice). The
  hook does nothing in a session with no agent id, so a plain `claude` is
  unaffected. `spool-agent` then adds no per-session copy (it already checks).
- **The seat: no new auth flow.** The hub pins a box ONLY through
  `POST /v1/pins` signed by the tenant root key (`internal/hub/rest.go`
  `handlePin`); a 023 human key does not pin a box and no invite does. So
  (**DECIDED** with CLE-3496, 2026-09-25):
  1. with `ROOT_KEY_JSON` (the user is the tenant admin) the installer pins
     the box itself;
  2. without it the seat is **PENDING**: the box key is minted, the installer
     prints the ONE `spool hub-pin` line the tenant admin runs, and exits 0;
     re-running it asks the hub (`spool hub-sync`) and picks the pin up. The
     key is reused across re-runs, so the admin's line stays valid.
  A hub-side join token (an admin mints a one-time token in the web UI, the
  installer redeems it) is **OPEN**, relayed to the owner; not built without a go.
- **`SPOOL_HUB_URL` has no default** (repo rule) and must equal the cnf hub of
  `--env`: the desk actions run against the cnf hub, so a mismatch is refused.
- **The box id** defaults to `box-<user>-<host>` (unique per tenant); `--box`
  or `SPOOL_BOX` wins. `box-wui` is reserved.

## Requirements

- **FR-001** With bash, git and the base tools present, one run installs the
  chosen CLIs at their latest release, the toolchain, `spool`, the
  `spool-agent` command and the mirror hooks, without sudo.
- **FR-002** Re-running is safe: nothing already correct is downloaded or
  rewritten twice (the hooks stay one per event, the key stays one key).
- **FR-003** `--dry-run` prints every step and changes nothing (no download,
  no file under HOME).
- **FR-004** `spool-agent` runs this checkout's `spool-agent.sh` with the env,
  tenant and box from `~/.config/spool-agent/env` (0600); an option on its
  command line wins.
- **FR-005** A file at `<prefix>/bin/spool-agent` that the installer did not
  write is never overwritten (exit 7).
- **FR-006** The seat follows the two modes above; a PENDING seat exits 0 and
  prints the admin line; a failed seat exits 5 with the reason.
- **FR-007** No root key reaches an argv or a log: it goes through a 0600
  scratch file (`do_spl_desk_pin`, as `do_spl_desk_up` does).

## Components

| path | role |
|---|---|
| `csi-spl-orc/src/bash/features/spool-install/install.sh` | the installer |
| `csi-spl-orc/src/bash/run/spl-desk-pin.func.sh` | `do_spl_desk_pin`: key + pin, modes self / admin / check |
| `csi-spl-orc/src/bash/features/spool-install/tests/test-install.sh` | hermetic suite (vendor installers, network, build, seat stubbed) |
| `csi-spl-orc/src/bash/tests/desk-pin.tst.sh` | the action's suite |
| `csi-spl-orc/src/bash/tests/spool-install.tst.sh` | runs the installer suite in the orc CI job |

## Known limits

- agy is installed but `spool-agent` starts claude or grok only (036's
  wrapper); agy has no mirror hooks.
- `./run` writes its log under a dir derived from the checkout path; a user
  running a checkout owned by someone else hits a read-only log dir. The
  installer is meant to run from the user's own clone.
