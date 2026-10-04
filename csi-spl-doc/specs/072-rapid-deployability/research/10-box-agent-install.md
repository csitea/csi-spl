# 072 research 10: box agent install (spec 037, `install.sh`)

Author: c-171. Tree: file reads on `origin/master` @ `c05a85c2`, 2026-10-04;
the timed walk ran on the public clone @ `c87a6779`. The install paths are
identical on both: `git diff --stat c87a6779 c05a85c2 -- csi-spl-orc/src/bash/features/spool-install csi-spl-orc/src/bash/run/spl-desk-pin.func.sh csi-spl-orc/src/bash/features/spawn-agents/scripts/spool-agent.sh`
-> empty. Docs only. Scope: P3 of spec 072 section 3, seating agents on a
fresh Linux box as a fresh user. Ranked by the section 2 rule: time, manual
steps, clarity of errors. `<fresh-user>`, `<hub-url>`, `<tenant>` and
`<repo-url>` are placeholders. Paths without a dir are under
`csi-spl-orc/src/bash/features/spool-install/`.

## 1. Today

### 1.1 The walk, measured (n = 1)

A throwaway `debian:13` container on this box. Root only installs the base
packages; then a new OS user `<fresh-user>` with an empty home runs the rest.
Every row below is a line of the walk's output.

| # | step | who | measured | check |
|---|---|---|---|---|
| 0 | the bare image lacks `git curl wget python3 tmux` (`perl tar flock setsid` are there) | - | 5 tools | `for b in git curl wget tar python3 perl flock setsid tmux; do command -v $b >/dev/null \|\| echo MISSING $b; done` |
| 1 | `apt-get install -y git curl ca-certificates python3 perl tmux util-linux` | **root** | **27 s** | apt rc 0 |
| 2 | `useradd -m <fresh-user>`; clone **into `~/csi/csi-spl`** (the layout `./run` needs) | user | **7 s**, 58 MB | `git clone <repo-url>`; `du -sh` |
| 3 | `install.sh --cli none --no-seat --dry-run` | user | < 1 s | prints the plan and writes nothing (FR-003 holds) |
| 4 | `install.sh --cli none --no-seat` | user | **73 s**, rc 0 | downloads Go `go1.27.1`, runs `go mod download`, builds `spool 1.1.3` |
| 5 | re-run of step 4 | user | **4 s**, rc 0 | nothing rewritten (FR-002 holds) |
| 6 | the Claude Code CLI (what `--cli claude` runs), timed alone in a second fresh container | user | **23 s**, 235 MB | `curl -fsSL https://claude.ai/install.sh \| bash; claude --version` -> `2.1.289` |
| 7 | the seat: `SPOOL_HUB_URL=<hub-url> install.sh --env self --tenant <tenant>` | user, then **the tenant admin** | not timed: it needs a human with the root key | section 1.3 |

**Fresh box to "installed, not seated": about 2 min 10 s** (27 + 7 + 73 + 23 s)
of machine time plus 1 root command, on this box's network. Disk in the
user's home: **about 1.3 GB**. Go is 282 MB (`du -sh ~/.local/share/spool-agent/tools/go`),
the module cache is **722 MB** (`du -sh ~/go`), the claude CLI 235 MB and the
clone 58 MB. Go and its cache (1 GB) exist only to build one binary.

### 1.2 What `install.sh` writes into a fresh home (step 4)

| what | where | source |
|---|---|---|
| `spool` binary + link | `~/.local/share/spool-agent/tools/bin/spool`, `~/.local/bin/spool` | `install.sh:287-313` |
| `spool-agent` shim + config | `~/.local/bin/spool-agent`, `~/.config/spool-agent/env` | `install.sh:316-347` |
| mirror hooks | `~/.claude/settings.json` (and a `.bak-spool-install`, even for a new file) | `install.sh:350-379` |
| 8 slash commands, 7 skills | `~/.claude/commands`, `~/.claude/skills` ("14 written") | `install.sh:384-443` |
| fleet standing orders, 124 lines | `~/.claude/CLAUDE.md` (5 fragments) | `steps/y4-claude-config.sh`, `install.sh:449` |
| fleet settings | `~/.claude/settings.json` | `assets/claude/settings/00-fleet.json` |
| `./run` completion | a line appended to `~/.bashrc` | `steps/y10-run-completion.sh`, `install.sh:446` |
| browser MCP links + configs | `~/.local/mcp-bot/*` | `steps/y1-mcp-bot.sh`, `install.sh:447` |
| graft skill link | `~/.claude/skills/graft` | `steps/y6-graft.sh`, `install.sh:450` |

Literal values rendered into that home, counted with
`grep -rhoE '/var/spool-hub|CLE-00|/opt/csi[^ "]*' ~/.claude | sort | uniq -c`:
`/var/spool-hub` 21, `CLE-00` 12, `/opt/csi/csi-web` 1.

### 1.3 The seat, read from the tree

The hub pins a box only with the tenant **root key** (037, "The seat").
Without `ROOT_KEY_JSON` the seat is PENDING: the installer prints one
`spool hub-pin` line for the tenant admin, exits 0, and a re-run picks the pin
up (`install.sh:461-467`). So a non-admin's time to a working agent is
bounded by a human round trip, not by the machine. 037 T005 (the join token)
is OPEN: `grep -n 'T005' csi-spl-doc/specs/037-spool-agent-install/tasks.md`
-> 32. The live seat proof is 037 T004: dev hub, 2026-09-25, n = 1.

## 2. Blockers

Ranked by the section 2 rule. A stranger hits B1 to B3 first.

1. **The installer rewrites the user's global Claude Code config with our
   fleet's standing orders, and turns off a safety prompt.** On a fresh home it
   writes 124 lines of `~/.claude/CLAUDE.md` ("push directly to trunk",
   "deploy both dev and prd", "spawn up to 40 agents", and our csi-web deploy
   line). It also merges `"skipDangerousModePermissionPrompt": true` into
   `~/.claude/settings.json`. This is on by default. Only the env var
   `SPOOL_INSTALL_CLAUDE_CONFIG=0` skips it, and the usage text never names it:
   `grep -c SPOOL_INSTALL_CLAUDE_CONFIG install.sh` -> 0. Sources:
   `assets/claude/settings/00-fleet.json:2`,
   `assets/claude/claude-md/10-push-and-deploy.md:7`, `install.sh:449`.
   From then on, every agent the user starts follows our orders, whether it is
   seated or not.
2. **An unreachable or wrong hub is reported as "seat PENDING", exit 0.**
   Measured: `SPOOL_HUB_URL=http://127.0.0.1:9 install.sh --env self --tenant t1`
   -> "seat PENDING ... Send your tenant admin this ONE line", rc 0. Any
   `hub-sync` failure, connection refused included, takes the not-pinned
   branch (`csi-spl-orc/src/bash/run/spl-desk-pin.func.sh:105-112`).
   `install.sh:456-467` keeps only the JSON line and drops the WARN that
   carries the hub's error. The user then asks an admin to pin a box on a hub
   they never reached.
3. **A seat needs the tenant root key or an admin's shell** (037 T005 OPEN;
   072 F8, G7). `grep -rliE 'join.?token' csi-spl-api/src/go --include=*.go | grep -vc _test` -> 0.
4. **It needs Go and a 722 MB module cache to build one binary** (072 F7, G6).
   See `install.sh:271-298`. `grep -c 'releases/download' install.sh` -> 0.
5. **The clone must sit at `<dir>/csi/csi-spl`.** Anywhere else, `./run` takes
   the wrong org, and the installer only warns. Measured with a clone at
   `~/csi-spl`: "WARN clone this repo as <dir>/csi/csi-spl ... ./run takes the
   org from the parent dir", and the run goes on (`install.sh:156-162`).
6. **The harness defaults come from our box, not the user's.** The skills
   get `SPOOL_ROOT=/var/spool-hub`, a root-owned path a fresh user cannot
   create, and the orchestrator `CLE-00`, a legacy id. Spec 061 ended legacy
   ids at 2026-10-03T20:59:59Z. See `install.sh:393`. `spool-agent.sh:63`
   defaults the tenant to `t1`.
7. **The env names are fixed** to `dev|prd|self` (072 F9, A17). With no
   `--env`, the installer picks `dev`, our hosted dev hub, and then
   `SPOOL_HUB_URL` must match that hub's cnf URL. See `install.sh:82` and
   `:121`, and `spawn-agents/scripts/spool-agent.sh:92` and `:117`.
8. **`~/.local/bin` is not on a fresh user's PATH** (Debian's `.profile` adds
   it only if the dir existed at login). The installer only warns
   (`install.sh:346`), so the next `spool-agent claude` fails with "command
   not found". Step y10 already edits `~/.bashrc`, so this is a gap, not a
   policy.
9. **No fresh-box test.** `tests/test-install.sh` is hermetic: the vendor
   installers, the network, the build and the seat are all stubbed (037,
   Components). Nothing runs the real install on a clean image, which is why
   nobody saw B2 and B8.
   `grep -lE 'debian:|ubuntu:' .github/workflows/*.yml | xargs -r grep -l spool-install | wc -l` -> 0.

## 3. Actions

Each action is one lane. Ids continue spec 072 section 6; A18 and up are new.
Effort: XS < 0.5 day, S <= 1 day, M 2-5 days, L > 1 week.

| # | action | changes | effort | done when (a test can check it) |
|---|---|---|---|---|
| **A18** | Make the fleet config opt-in: steps y1 (mcp-bot), y4 (CLAUDE.md + fleet settings), y7 and y10 run only with `--fleet`, which our boxes pass from `do_spl_box_deploy`. Without it, the installer writes nothing outside `~/.local`, `~/.config/spool-agent` and the mirror hooks. `skipDangerousModePermissionPrompt` is never in a default | B1, G6 | S | on a fresh home, `install.sh --cli none --no-seat` -> `test ! -e ~/.claude/CLAUDE.md && ! grep -q skipDangerous ~/.claude/settings.json`; with `--fleet` the output is today's |
| **A19** | Make an unreachable hub an error: `do_spl_desk_pin` separates "not pinned" (the hub answered) from "cannot reach, bad TLS, 404" (it did not). The installer checks `<hub-url>/v1/health` before it mints a key, and exits 5 naming the URL and the error | B2 | XS-S | `SPOOL_HUB_URL=http://127.0.0.1:9 install.sh --env self --tenant t1` -> rc 5, stderr names `127.0.0.1:9`; a reachable hub without the pin still gives PENDING rc 0 |
| **A4** (072) | A prebuilt `spool` per release, sha256 checked; Go only as a `--build` fallback | B4 | S-M | on a box with no Go: under **30 s** of machine time, no `~/go`, `~/.local/share/spool-agent` < 60 MB |
| **A5** (072) | Join token (037 T005): an admin mints it in the WUI, `install.sh --join <token>` seats the box | B3 | M-L | a non-admin seats a box with only the WUI token in < 1 min; a used token is refused with the fix |
| **A20** | One pasted line: a `bootstrap.sh` from the repo's raw URL or a release that clones to the right layout (to `~/.local/share/spool-agent/src` once A21 lands) and runs `install.sh` with the same args | B5, F3 | S | `curl -fsSL <url>/bootstrap.sh \| bash -s -- --cli claude --no-seat` on a fresh home -> rc 0 and `spool-agent` on PATH |
| **A21** | No layout dependency: the installer and the shim pass `ORG`/`APP` to `./run` explicitly, so any clone path works | B5, 072 A8 | S | a clone at `~/anything/x` gives no WARN and `do_spl_desk_pin` resolves; the orc suite stays green |
| **A22** | Defaults the user owns: for a non-fleet install `SPOOL_ROOT` defaults to `${XDG_STATE_HOME:-~/.local/state}/spool`, the orchestrator to the spec 061 role `orchestrator`, and there is no `t1` tenant default (the saved config or `--tenant` instead) | B6 | XS-S | after a default install, `grep -rhoE '/var/spool-hub\|CLE-00' ~/.claude` -> nothing |
| **A23** (with 072 A17) | The env follows the hub, not a name: with `SPOOL_HUB_URL` set and no `--env`, the installer and `spool-agent` use `self`; `dev` and `prd` only when named. Plus 072 A17's cnf-declared env names | B7 | S | `SPOOL_HUB_URL=<hub-url> install.sh --tenant x --dry-run` -> the plan says `self` |
| **A24** | Fix PATH the way y10 does: add one marked `~/.local/bin` PATH line to `~/.bashrc` or `~/.zshrc` when it is missing (`--no-rc` skips this), then print `exec $SHELL -l` | B8 | XS | on a fresh home after install, `bash -lc 'command -v spool-agent'` -> a path |
| **A25** | A fresh-box CI job: as a new user on `debian:13` and `ubuntu:24.04` containers plus a `macos-latest` job, run `install.sh --cli none --no-seat`; assert the rc, the A18 files, the re-run's "already current" and A19's control; post the seconds | B9 | S | the job runs on `ubuntu-latest` and goes red when any assertion fails; control: revert A19 on a throwaway branch -> red |

### 3.1 Order

**A18 and A19 come first.** Each takes under a day, and they are the two
problems a stranger meets in the first session: one silently changes their
Claude Code, the other sends them to an admin for nothing. Then A25 (it
guards everything after it), then A4 (removes the 1 GB of Go), then A20 and
A21 (one pasted line). A5 comes last: it is the largest and needs the owner's
go on T005.

### 3.2 Target after A4 and A18 to A24

| measure | today (n = 1) | target |
|---|---|---|
| machine time, fresh box to installed (claude CLI included) | about 130 s | < 60 s |
| root commands | 1 (base packages) | 1, printed whole by the installer |
| user commands | clone + install + PATH edit + a `.tmux.conf` line | 1 pasted line |
| disk in the home | about 1.3 GB | < 300 MB (the claude CLI is 235 MB of it) |
| seat for a non-admin | an admin round trip | a WUI token, < 1 min |
| a wrong hub URL | PENDING, rc 0 | rc 5 naming the URL |

## 4. Questions for the owner

1. **Should `install.sh` write the fleet's standing orders and
   `skipDangerousModePermissionPrompt` into a user's global Claude Code config
   by default?** Recommended: **no**. Make it opt-in with `--fleet` (A18). Our
   boxes keep today's behaviour through `do_spl_box_deploy`; an open-source
   user gets only what seats an agent.
2. **A go for the join token (037 T005)?** Recommended: **yes**, after
   A18/A19 and A4. It is the only step a non-admin cannot do alone (A5).
3. **Which env applies when none is given?** Recommended: **`self` whenever
   `SPOOL_HUB_URL` is set**, and `dev` or `prd` only by name. A stranger's hub
   is never our dev hub (A23).
4. **Is macOS a supported box?** The installer says so (`install.sh:7`), but
   it is not measured here (n = 0), and `flock` and `setsid` are not stock on
   macOS. Recommended: **yes**, proven by the A25 `macos-latest` job before the
   README claims it.
