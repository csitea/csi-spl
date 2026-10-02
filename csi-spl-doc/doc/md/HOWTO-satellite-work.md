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
| PC -> sat | hub relay (`spool-send.sh --to <ID>@sat` on the PC) | yes, for any agent in the PC's `registry.tsv` (since 90a78b17) | before: refused exit 13 for an unseated lane agent (n=1); after: see 1.4 |
| sat -> PC | hub relay (`spool-send.sh --to <ID>@box-desk` on the satellite) | yes, for any agent in the satellite's `registry.tsv` (since 90a78b17) | file in the PC inbox 6 s after the send (n=1); after: see 1.4 |
| sat -> PC | `ssh` back to the PC | no: the satellite has no route to the PC | - |

### 1.1 PC -> satellite by hand (superseded by 1.4, kept for a box whose sidecar is down)

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

Since 90a78b17 the file that lands on the PC reads `"from":"CLE-001@sat"`
(before, it read `"from":"CLE-001"` and CLE-001@box-desk saw a message from
itself).

### 1.4 Any lane agent, either way (since 90a78b17)

The box is the trust unit, not the seat. `spool-send.sh --to <ID>@<box>`
from any agent with a row in its machine's `registry.tsv` crosses the hub:

- `scripts/spool-fleet-relay.sh` sends a lane that is not seated on the desk
  under a seated id of that desk (`SPOOL_FLEET_PROXY` in `box.env`, else the
  lease's `LEASE_ORCH`, else the first seated id). An id that is neither
  seated nor in `registry.tsv` is still refused, exit 13.
- Every relayed body opens with `from_agent: <ID>@<box>`. The receiving
  sidecar (`internal/spool` `WithFromAgent`) accepts the claim only for the
  box whose pin signed the envelope, writes it as `from` and drops the line.
  A sidecar older than 90a78b17 shows the line in the body instead.
- The reply goes back with `--to <ID>@<box>` and lands in that machine's
  `/var/spool-hub/<ID>/inbox` and rings the pane.
- Trap: the reader must be 90a78b17 or newer too. An older `spool recv` counts
  an `<ID>@<box>` from as "malformed message file(s) left" and shows nothing.
  Rebuild with `bash csi-spl-api/src/bash/build.sh <the spool on PATH>` (done
  2026-10-02 on both machines, for the box user and the agent user).
- Trap: `--task` must be a UUID across machines. The prd hub stores `task_id`
  as `uuid`, so `--task sat-relay-gaps` is refused `internal (message not
  stored)`; a same-machine send accepts any string.

Measured 2026-10-02, n=1 each way:

| leg | msg_id | from in the receiver's inbox file |
|---|---|---|
| PC lane CLE-77963 -> CLE-100000@sat | `87020a44` | `CLE-77963@box-desk` |
| sat lane CLE-100000 (registry row, not seated on the sat desk, sent under the proxy CLE-001) -> CLE-77963@box-desk | `8b3eaa99`, rang the PC pane | `CLE-100000@sat` |

## 2. Starting an execution agent on the satellite

The satellite's `/var/spool-hub/box.env` sets `SPOOL_AGENT_USER=<AGENT_USER>` and the
id range `100000-199999`, so `auto` ids never collide with the PC's. Copy the
brief over, then spawn (dry run first):

    cat brief.md | ssh satellite 'sudo install -o <BOX_USER> -g <BOX_USER> -m 644 /dev/stdin /var/tmp/<brief>.md'
    ssh satellite 'sudo -iu <BOX_USER> bash -lc "cd /opt/csi/csi-spl && SPAWN_DRY_RUN=1 bash $S/spawn-claude.sh CLE-100001 /opt/csi/csi-spl /var/tmp/<brief>.md <slug>"'
    ssh satellite 'sudo -iu <BOX_USER> bash -lc "cd /opt/csi/csi-spl && bash $S/spawn-window.sh claude auto /opt/csi/csi-spl /var/tmp/<brief>.md <slug>"'

It prints `<ID> <pane>`. Watch it:

    ssh satellite 'ps -o user=,etime=,args= -C claude | cut -c1-100; uptime; sudo -iu <BOX_USER> tmux capture-pane -p -t <pane> | tail -20'

The agent runs as `<AGENT_USER>` in the box user's tmux session `main`, in its own
worktree `/opt/csi/csi-spl-wt/<ID>`. The satellite's desk crons live in the
box user's crontab (`crontab -l` as the box user; the login user, root and
`<AGENT_USER>` have none).

### 2.1 First real work, measured (CLE-100000@sat, 2026-10-02)

One execution agent on the satellite ran the four csi-spl suites on trunk
`08f6ef57`, sequentially, 06:19..06:29Z: **0 code red**, only box gaps.

| suite | verdict | passed/failed | wall s |
|---|---|---|---|
| iac `run-all-tests.sh` | FAIL, box gap only (no terraform for the box user) | 64/3 test files | 93 |
| api `run-all-tests.sh` | PASS (hub-pg, hub-gcs skipped: images not cached) | 80/0 | 319 |
| wui install + typecheck + unit | PASS (pnpm not on the box user's PATH, worked around) | 218/0 files | 34 + 105 + 87 |
| `do_check_dist_hygiene` | PASS | clean | 2 |

Load during the api suite: `load average: 5.65` on `nproc 4` (idle before:
0.23). The PC at the same time: `load average: 54.15` on `nproc 16`, 33 agent
processes (n=1 sample each).

## 3. Split proposal: what stays on the PC, what moves to the satellite

Classified from the live lane map at 06:21Z: n=36 scoped lane agents on the
PC, 0 on the satellite (besides the trio and CLE-100000).

| class | where | why | lanes at 06:21Z |
|---|---|---|---|
| orchestrator role + master dispatcher (lease holder) | PC | owner decision "a": the PC leads the fleet lease | trio |
| fleet / lease / rotation / desk / tmux code | PC | the code acts on the PC's own panes, desks and crons; its live proofs need them | 8 |
| WUI lanes with a live Chrome proof (perf, e2e, look) | PC, until the satellite has a browser | the satellite has no Chrome / puppeteer cache | 8 |
| anything that needs the owner's screen, browser or local-only creds | PC | only the PC has them | - |
| clean-code / refactor rounds | **satellite** | CPU-heavy suites, no live state | 3 |
| hub / api / store / CI-infra / iac-action lanes | **satellite** | `go test`, bash suites and builds are the CPU; the per-env SA keys and the gh login are present on the satellite | 11 |
| spec / doc / analysis lanes | **satellite** | light CPU, but each one is an agent process the PC no longer carries | 6 |
| test / measure runs (suite baselines, perf harness without Chrome, DB audits) | **satellite** | the first lane class proven there (2.1) | 1 (CLE-100000) |

Next class to move: **the clean-code / refactor rounds** (3 live now), then
the hub / api lanes. Capacity: the satellite has 4 cores; one suite run took it
to load 5.65, so 2..3 heavy lanes at once is the ceiling until the machine type
grows.

## 4. Harness gaps for multi-box

Every manual step taken in sections 1..2. Input for the next lanes.

| # | gap | done by hand | harness piece that removes it | size |
|---|---|---|---|---|
| 1 | **fixed 90a78b17** (1.4). PC -> sat hub relay refuses a sender not seated on the PC's desk (exit 13); lane agents are never seated | ssh + `spool-send.sh` on the satellite | the PC's sidecar relays for any agent in the local `registry.tsv` (the box is the trust unit), or seat lane agents at spawn | M |
| 2 | **fixed 90a78b17** (1.4). A satellite agent cannot reply to a PC lane agent (same seat rule, other way) | gave the PC agent a mailbox on the satellite, read it over ssh | same as 1; until then `spool-send.sh --to <ID>@box-desk` falls back to a satellite-local mailbox | M |
| 3 | **fixed 90a78b17** (1.3, 1.4). Relayed envelope drops the box: lands as `"from":"CLE-001"`, so CLE-001@box-desk reads a message from itself | named the box in the body | the relay writes `from` as `<ID>@<box>` (or a `from_box` field) | S |
| 4 | every satellite command is `ssh satellite 'sudo -iu <BOX_USER> bash -lc "..."'`, three quoting levels, IAP NumPy warning on stderr | typed it per call | one named action `do_satellite_run CMD=...` (stdin passed through, IAP noise filtered) | S |
| 5 | files to the satellite: `scp` cannot read a lane agent's private temp dir | piped over ssh into `install` | `do_satellite_run` takes stdin, or `do_satellite_put SRC= DST=` | S |
| 6 | spawning on the satellite from the PC: copy brief + `spawn-window.sh` over ssh | 2 ssh calls | `spawn-window.sh --box sat` (or a `task` to the satellite's orchestrator that spawns) | M |
| 7 | `spawn-core.inc.sh` seed text has a backquoted `add` inside a double-quoted string: bash runs it (`line 165: add: command not found`) and every seed prompt reads "ON THE , THEN COMMIT" | none | quote it as `'git add'` | S |
| 8 | the seed prompt on the satellite names the orchestrator "CLE-00" | none (brief named the reply target) | resolve `SPOOL_ORCHESTRATOR_ID` from the fleet lease, not a local default | S |
| 9 | the seed prompt orders commit + push + CI watch for a measure-only lane | the brief overrode it | a measure-only seed variant (no INTEGRATION block) | S |
| 10 | **fixed 4e456627**. No terraform for the box user on the satellite (3 iac reds) | none | add the pinned terraform to the replica manifest (057) for the box user | S |
| 11 | no tpl-gen clone + venv in satellite worktrees (a control render skipped) | none | spawn links the main checkout's tpl-gen into the worktree | S |
| 12 | **fixed 4e456627**. `postgres:16-alpine` and `fake-gcs-server` not cached: hub-pg / hub-gcs skip | none | replica manifest pre-pulls the images the suites use | S |
| 13 | **fixed 4e456627**. pnpm not on the box user's PATH | agent ran it via corepack with a copied cache | replica manifest installs pnpm for the box user | S |
| 14 | **fixed 4e456627**. No browser on the satellite: WUI live proofs cannot move | none | install Chrome + the puppeteer cache on the satellite | M |
| 15 | both machines share one GitHub login: the 5000/h API quota is shared, hit 403 at 06:21Z and 06:23Z | waited | a per-box token (GitHub App installation token per machine) | M |
| 16 | 4 cores on the satellite: 2..3 heavy lanes at once | none | a larger machine type (terraform, 057) once the move is proven | M |

### 4.1 Gaps 10, 12, 13, 14 closed (CLE-100003, 2026-10-02)

Every one is box-playbook code now, so a recreate gets it back with the rest:

| # | what is on the satellite | installed by | verify row |
|---|---|---|---|
| 10 | terraform (cnf `terraform_version`, 1.9.8) in `/usr/local/bin` | role 09: `LINT_TOOLS_SYSTEM=1 ./run -a do_install_lint_tools` copies terraform too | `terraform`, and terraform on the box user's login PATH |
| 12 | `postgres:16-alpine`, `fsouza/fake-gcs-server:1.52.2` cached | role 09: `./run -a do_pull_test_images` (tags read from the hub-pg / hub-gcs tests) | `img-postgres`, `img-fake-gcs` |
| 13 | pnpm (the WUI's `packageManager`, 9.15.4) for the box user and the agent, each with a warm pnpm store | role 09: corepack + a `pnpm install` of the WUI lockfile in a throwaway dir | `pnpm`, and pnpm on the box user's login PATH |
| 14 | Google Chrome at `/usr/bin/google-chrome` | role 02: Google's `.deb` | `google-chrome`, and on the box user's login PATH |

The WUI e2e files load `puppeteer-core` and launch `CHROME_PATH` or
`/usr/bin/google-chrome`. `puppeteer-core` never downloads a browser, so there
is no puppeteer cache to seed (`grep -rn "cache/puppeteer" csi-spl-wui/tests` -> 0).

`./run -a do_satellite_verify` from the PC at `5c4d57dc` (contains
`4e456627`), measured by CLE-001@box-desk at 08:4xZ: **`SATELLITE-VERIFY fails=0`**. The new rows:
`pnpm box=9.15.4 satellite=9.15.4`, `terraform 1.9.8/1.9.8`,
`google-chrome box=153.0.8010 satellite=154.0.8037`, `img-postgres` and
`img-fake-gcs` present on both machines.
