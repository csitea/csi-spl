# 072 research 01: clone to a running local stack

Spec: [072 rapid deployability](../spec.md) (led by c-165; this file is research input only).
Owner topic: prd t1 `6410e374-0389-4492-90d8-52350182fe84`. Rank: usability and DevEx above cost; costs still given as numbers.
Author lane: c-158. Tree: `origin/master` @ `06e9c2a0`. Measured 2026-10-04 07:07..07:20Z, **n = 1 per step**.
Status words: `../../README.md` section 2.3.

## 0. The question

A newcomer clones the repo and wants the local stack (hub + WUI + test DB) running with no GCP.
There are **two** local paths in the tree, and they serve different people:

| path | for | entry | documented in |
|---|---|---|---|
| **P1 compose** | a user / self-hoster | `docker compose up --build -d` (root `docker-compose.yml`) | root `README.md` "Quick start (local)" |
| **P2 lde** | a contributor (hot-reload WUI, hub from source, smoke checks) | `csi-spl-orc`: `./run -a do_setup_app_inf`, then `./run -a do_wui_up` | `csi-spl-orc/README.md`, `csi-spl-wui/README.md` |

`grep -c do_setup_app_inf README.md CONTRIBUTING.md` -> `0`, `0`: a newcomer who reads only the root docs never finds P2.

## 1. Today: the walk, measured

### 1.1 Conditions

- A fresh anonymous clone from GitHub into a throwaway dir, run with an **empty `HOME`** and a bare `PATH`
  (`env -i HOME=$(mktemp -d) PATH=/usr/local/bin:/usr/bin:/bin ...`): no gitconfig, no credentials, no Go module cache.
- Host: 16 cores, 62 GiB RAM, load ~7, Docker 26.1.5, Compose 2.26.1. Of the base images only `postgres:16-alpine`
  was in the local image store (`golang:1.25-alpine`, `node:20-alpine`, `caddy:2-alpine`, `alpine:3.22` were pulled).
  The BuildKit layer cache was not purged, so treat 1.2's build time as a lower bound for a cold machine.
- Host tools present that a newcomer may not have: Go 1.25.14 at `/usr/local/go`, Node 20.19, `setfacl`, and this
  box's spool root with its group (see blocker B2).
- A separate compose project and port (`COMPOSE_PROJECT_NAME=s072c158 SPOOL_HTTP_PORT=18580`) so no other lane's stack was touched.
  Both stacks were torn down afterwards (`docker compose down -v`, `LDE_PURGE=1 ./run -a do_teardown_app_inf`).

### 1.2 P1 compose (the README quick start)

| step | command | result | time |
|---|---|---|---|
| clone | `git clone https://github.com/csitea/csi-spl.git csi/csi-spl` | public, no auth; `du -sh` -> 57M | **3 s** |
| build + up | `docker compose up --build -d` | rc 0; pg healthy, `hub-init` 112 migrations, root key + session key generated, hub healthy, web started | **171 s** |
| check | `curl -s localhost:<port>/version` | `{"version":"8.4.0-3-g06e9c2a0", "commit":"06e9c2a0..."}` (047 W6 fixed) | <1 s |
| idle RAM | `docker stats --no-stream` | hub 29.0 + web 13.9 + pg 34.7 = **~78 MiB** | - |
| images | `docker image ls` | hub 59.3 MB, web 73.2 MB | - |

**Clone to healthy stack: 174 s, 0 errors, 0 manual fixes** with the default port.
The 047 baseline was 268 s (`../047-spool-deployability/deployability-analysis.md` section 1.1, a box under load ~79).
Sign-up to first message was not re-measured here (047 measured 6 min 26 s clone-to-first-message).
CI already guards this path: `.github/workflows/50_oss-standalone.yml:51` runs `docker compose up --build` on
`ubuntu-latest`; `gh run list -w 50_oss-standalone.yml -L 10` -> 10/10 `success`.

**The one break: a different port.** Port 8080 is often taken, and `.env.example:20` offers `SPOOL_HTTP_PORT`. Setting only that:

- `hub-init` still prints `OWNER: http://localhost:8080 ...` and an agent seat line with `SPOOL_HUB_URL=http://localhost:8080`.
- `docker compose exec web grep -rl localhost:8080 /srv | wc -l` -> `40`; the same for `localhost:18580` -> `0`:
  the WUI bundle calls the wrong origin.
- CORS preflight from `Origin: http://localhost:18580` -> 204 with **no** `Access-Control-Allow-Origin`.

So the WUI loads but cannot talk to the hub. The cause is `docker-compose.yml:66,90,105,111,142`. They default
`SPOOL_PUBLIC_URL` to a literal `http://localhost:8080` and ignore `SPOOL_HTTP_PORT` (`:150`). The one comment
that hints at it is `.env.example:13` ("bakes SPOOL_PUBLIC_URL").

### 1.3 P2 lde (the contributor stack)

| step | command (from `csi-spl-orc`) | result | time |
|---|---|---|---|
| hub stack, 1st try | `./run -a do_setup_app_inf` | **rc 1**: `module lookup disabled by GOPROXY=off` x16, `FATAL static spool build failed` | 3 s |
| fix by hand | `cd csi-spl-api/src/go/spool-hub-api && GOFLAGS=-mod=mod go mod download` | rc 0 (703 MB module cache under `$HOME/go`) | 5 s |
| hub stack, 2nd try | `./run -a do_setup_app_inf` | rc 0: pg, gcs, migrate (112/112), serve (`t1.localhost:58080/healthz` 200), hello (+ unpinned control -> 78): **5/5 PASS** | **66 s** |
| WUI | `LDE_WUI_INSTALL=1 ./run -a do_wui_up` | rc 0: one-shot `pnpm install` (13.5 s, `node_modules` 289 MB), Nuxt dev container, `GET localhost:3000/` -> 200 | **60 s** |
| idle RAM | `docker stats --no-stream` | hub 9.4 + pg 37.2 + gcs 14.1 + **wui 534** = ~595 MiB | - |

**Machine time 137 s. A newcomer still fails at step 1.** The error names neither the fix nor the installer's
workaround. That workaround lives in `csi-spl-orc/src/bash/features/spool-install/install.sh:291-296`, but lde does
not have it. The human time to diagnose is not counted above.

## 2. Blockers

| # | blocker | path | evidence | severity |
|---|---|---|---|---|
| B1 | lde builds the hub binary **on the host** through `build.sh`, which forces `GOPROXY=off`. On a cold module cache it always fails. The installer has a `go mod download` fallback; lde has none. | P2 | `csi-spl-api/src/bash/build.sh:6`; `setup-app-inf.func.sh:84`; measured rc 1 above | **high**: step 1 of P2 fails for every newcomer |
| B2 | lde provisions the **box's agent spool root** (`/var/spool-hub`, group `spool-agents`, ACLs, `sudo -n`) before it starts the hub, although the hub stack never uses it. On a machine without that group and dir, `do_provision_spool_root` returns `FATAL group ... does not exist`. | P2 | `setup-app-inf.func.sh:47`; `provision-spool-root.func.sh:28-35`. **Code-read, n = 0**: this box already has the group, so it was not reproduced | **high**: P2 also needs sudo and an agent-fleet concept, for a DB + hub |
| B3 | lde needs host Go **>= 1.25.14** (`go.mod:5`, `GOTOOLCHAIN=local` in `build.sh:6`). A distro Go is older, and the toolchain auto-download is switched off. The hub image already builds the same binary inside `golang:1.25-alpine`. | P2 | `grep -n '^go ' csi-spl-api/src/go/spool-hub-api/go.mod` -> `go 1.25.14` | medium |
| B4 | P1 with a non-default port gives a WUI that cannot reach the hub (section 1.2). | P1 | `docker-compose.yml:66,142,150`; `csi-spl-wui/src/docker/wui.Dockerfile:30` | medium: silent, and 8080 is a common clash |
| B5 | P2 is undocumented where a newcomer looks, and its own README contradicts the WUI README. | P2 | `grep -c do_setup_app_inf README.md CONTRIBUTING.md` -> 0, 0; `csi-spl-orc/README.md:8` "The WUI is not part of this stack" vs `csi-spl-wui/README.md:37-69` (`do_wui_up` from orc) | medium |
| B6 | No CI proves P2 from a clean clone. 50 proves P1 only, so B1 and B2 could regress unseen. | P2 | `grep -lE 'do_setup_app_inf\|do_wui_up' .github/workflows/*.yml` -> none | medium |
| B7 | P1's project name is fixed: `name: spool` (`docker-compose.yml:18`), images `spool-hub:local`, `spool-web:local`. A second clone on the same host (e.g. a stable tag next to master) shares containers and volumes with the first. | P1 | `docker-compose.yml:18,56,146` | low |
| B8 | P2 needs one CLI tool per step: Docker, host Go, `setfacl`, and a 2-step bring-up (`do_setup_app_inf` then `do_wui_up`). There is no single "dev up" verb, and its prerequisites are listed nowhere. | P2 | `provision-spool-root.func.sh:25` (`do_require_bin setfacl getfacl`, reached from `setup-app-inf.func.sh:47`) | low |

## 3. Actions

Each action fits one lane and has a check a test can run. Effort: XS < 2 h, S < 1 d, M 1..3 d.

| # | action | fixes | done when (testable) | effort |
|---|---|---|---|---|
| A1 | **Build the lde hub inside docker, not on the host.** `do_setup_app_inf` builds the lde image from the same multi-stage `csi-spl-api/src/docker/hub.Dockerfile` P1 uses, so host Go and the module cache drop out. Fallback if the lane prefers a smaller change: the installer's `go mod download` fallback (`install.sh:291`), moved into `build.sh`. | B1, B3 | an orc test runs `env -i HOME=$(mktemp -d) PATH=<no go> ./run -a do_setup_app_inf` on a fresh clone -> exit 0, 5/5 PASS | S |
| A2 | **Stop lde from touching the box spool root.** Move `do_provision_spool_root` out of `do_setup_app_inf`, or gate it behind `LDE_SPOOL_ROOT=1`. The hub stack needs no `/var` dir, no group, no sudo. | B2, B8 | a test with `SPOOL_ROOT_GROUP=<a group that does not exist>` and an absent spool root -> `do_setup_app_inf` exit 0, and `/var/spool-hub` is not created | XS |
| A3 | **Derive the compose public URL from the port.** Default every `SPOOL_PUBLIC_URL` to `http://localhost:${SPOOL_HTTP_PORT:-8080}` (compose nested interpolation), and the same for the `wui.Dockerfile` build arg. | B4 | `SPOOL_HTTP_PORT=18580 docker compose config \| grep -c 'localhost:18580'` >= 5 and `\| grep -c 'localhost:8080'` -> 0; workflow 50 gains a second leg on a non-default port | XS |
| A4 | **CI for the contributor path.** A GitHub-hosted job (like 50) on a clean clone runs `do_setup_app_inf` + `LDE_WUI_INSTALL=1 do_wui_up`, then `GET :3000/` -> 200. Trigger on `csi-spl-orc/**`, `csi-spl-api/**`, `csi-spl-wui/**`, `csi-spl-rdb/**`, `csi-spl-cnf/**`. | B6 | the job is green on trunk, and red on a throwaway branch that reverts A1 (control) | S |
| A5 | **One "Develop locally" section.** Put it in the root `README.md` (or `CONTRIBUTING.md`): a prerequisites table (Docker; after A1 nothing else; Node 20 only for a host `pnpm dev`), the two lde commands, ports, teardown. Fix `csi-spl-orc/README.md:8`. | B5, B8 | `grep -c do_setup_app_inf README.md CONTRIBUTING.md` >= 1; `grep -c 'WUI is not part' csi-spl-orc/README.md` -> 0 | XS |
| A6 | **One verb for the whole dev stack.** `./run -a do_lde_up` = `do_setup_app_inf` + `do_wui_up` (install on first run) + print the URLs; `do_lde_down` the inverse. | B8 | an orc test: `do_lde_up` on a fresh clone -> exit 0 and both `:58080/healthz` and `:3000/` -> 200 | S |
| A7 | **Per-clone compose project.** Drop the fixed `name: spool` (the project falls back to the dir name), or document `COMPOSE_PROJECT_NAME` beside `SPOOL_HTTP_PORT` in `.env.example`. | B7 | two clones with different ports come up side by side; `docker compose ls` shows 2 projects | XS |

**Top 3 by DevEx gain per hour: A1, A2, A3.** A1 + A2 turn P2 from "fails at step 1, needs sudo" into
"one command on a machine with only Docker". A3 removes P1's one silent failure.

**Costs (numbers).** Local: EUR 0. Disk on a fresh machine is ~1.1 GB for P2 today (Go module cache 703 MB,
`node_modules` 289 MB, images ~130 MB); A1 moves the 703 MB into the build cache. RAM: P1 ~78 MiB idle; P2 ~595 MiB,
of which 534 MiB is the Nuxt dev server. A4 adds about 4 min of hosted-runner time per triggering push (workflow 50, the P1 twin, took 146..184 s, median 168 s, over its last 10 runs): EUR 0 on a
public repo; on a private repo at USD 0.008/min and ~50 triggering pushes/day, about USD 1.60/day.

## 4. Questions for the owner

| # | question | recommended answer |
|---|---|---|
| Q1 | Which path is "the" newcomer path? | **Both, named by audience**: README leads with P1 (use it), then "Develop locally" with P2 (change it). Each has its own CI proof (50 + A4). |
| Q2 | May the contributor stack require tools beyond Docker (host Go, sudo, `setfacl`)? | **No: Docker only** (A1 + A2). Host Go stays optional for the fast `go test` loop, not a gate on seeing the stack. |
| Q3 | Should the agent spool root (`/var/spool-hub`) stay part of lde? | **No.** It belongs to the agent harness (`spool-install`, 037). lde is DB + hub + WUI. |
| Q4 | A4 on every matching push, or nightly? | **On every matching push**, as 50 already does for P1: the measured cost is ~4 runner-minutes, and the 047 deploy rate (118 hub runs in 24 h) shows a nightly job would find a break hours late. |

<!-- version: 0.1.0 · updated: 2026-10-04 · last-edit: 2026-10-04T07:30:00Z -->
