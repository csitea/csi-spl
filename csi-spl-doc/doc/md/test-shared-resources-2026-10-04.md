# Shared resources tests touch, 2026-10-04

Counted on tree `e52d6a63b08b3388b6fe50f19790af48ff2ceb5b`.
The paths cited below are the same bytes from that tree through
`e9e68c874` (`git diff --stat` on those paths was empty).
Scope is the test files under `csi-spl-api`, `csi-spl-wui`, `csi-spl-orc`,
`csi-spl-iac` and `csi-spl-cnf`, plus the workflows that run them.
Fixed `/tmp` paths are a separate lane and are not in this note.
Nothing here was executed as a suite. Every `n` is a source count on that
tree. The commands are in [Checks](#checks).

Test files in the count: **1287** (`.mjs` 416, `_test.go` 379, `.tst.sh` 275,
`.proof.mjs` 127, other `.sh` under a `tests/` directory 90).

Workflow 10 runs on the self-hosted runner label. Its comment at
`10_ci-quality.yml:161` says four runners share one home. Its jobs share
one localhost and one `/dev/shm`. The concurrency group is
`quality-gate-${{ github.ref }}` with `cancel-in-progress: false`
(`10_ci-quality.yml:57-59`), so one master gate runs at a time and its
jobs run together. A gate on another ref can overlap that one.

## Findings

Sorted by what two overlapping runs can break.

| # | resource | where | n | what two runs break | proposed fix |
|---|---|---|---|---|---|
| 1 | Chrome scratch on the shared `/dev/shm` tmpfs | any `puppeteer.launch` whose next 25 lines omit `--disable-dev-shm-usage`. Examples: `csi-spl-wui/tests/e2e/close-buttons.test.mjs:42`, `issues.test.mjs:33`. The CI job is `wui-e2e`, three shards (`10_ci-quality.yml:277`, `352`) | 210 launches without the flag in that window; 61 with it; 65 lines contain the flag; **0** lines contain the path `/dev/shm/` | the three shards start Chrome on one box. Chrome puts its shared-memory files on `/dev/shm` unless the flag is set. A full tmpfs fails the browser start. There is no fixed filename to collide on | one launch helper that always passes `--disable-dev-shm-usage`, the same flag the 61 launches already pass |
| 2 | TCP port taken by a probe, then released, then bound for real | `csi-spl-api/src/bash/tests/hub-gcs.tst.sh:35` (`free_port`, docker bind at `:61`); `csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh:20-27` (the harness workflows 10 and 11 call); `csi-spl-wui/tests/e2e/lib/server.mjs:14-20` then `:47`; also `channel-agent-add.tst.sh:52`, `channel-privacy-probe.tst.sh:56`, `sql-proxy-port.tst.sh:31`, `sec-headers.tst.sh:91` | 1 fake-gcs probe, 1 CI harness, 1 dev-server helper, 4 smaller probes | the probe socket is closed before the real server binds, so two jobs on one localhost can be handed the same port. `hub-gcs` then fails its docker bind (a false red). The harness checks that this job's pids are still alive (`wui-e2e-mock-serve.sh:38-40`), which closes the old failure where a stale server on `:4173` answered the probe (comment at `:17-19`). What remains is a false red. `server.mjs` runs only when `BASE_URL` is unset (`:42-46`); CI sets `BASE_URL` at `wui-e2e-mock-serve.sh:42` | retry the real bind when the address is in use, or keep the probe socket until the real server has bound |
| 3 | Go build cache on the shared home | `10_ci-quality.yml:87` and `:542` (`cache: false` on setup-go). `GOCACHE` is not set in that file. `20_hub-build-deploy.yml:92-97` records why: the self-hosted home persists, so the default cache is already warm | `cache: false` **2**; `GOCACHE` in workflow 10 **0**; tests that set `GOCACHE=` **2**, both to `"$T/gocache"`; `go clean -cache` **0** | concurrent `go test` and `go mod download` on the four runners share `$HOME/.cache/go-build` and `$HOME/go/pkg/mod`. Go locks that cache. The failure mode is a full disk or a rare cache race. The warmth is the workflow's stated reason for `cache: false` | point `GOCACHE` and `GOMODCACHE` at a per-runner directory (`RUNNER_TOOL_CACHE`), the same move the pnpm store already made, when the home should stop being the lock |
| 4 | Default listen port 8443 | `csi-spl-wui/tests/e2e/lib/serve-hosting-h2.mjs:22` (`argOf('--port', '8443')`), listen at `:63`. The product compose publishes the same default at `docker-compose.yml:151` (`SPOOL_HTTPS_PORT:-8443`) | 1 helper default. `*.proof.mjs` is not discovered by `run-e2e-tests.mjs` (`:16`, filter at `:58`) | two hand-run proofs, or a proof and a compose stack, fail the bind on `127.0.0.1:8443` | default the helper to port 0 and print the port it got |
| 5 | Pre-push green-cache file | `csi-spl-iac/src/bash/run/check-pre-push.func.sh:41`, directory at `:429`, default file at `:431` (`$HOME/.cache/csi-spl/pre-push.parts.green`), trim at `:199-200` | 1 default path | every push on the shared home appends to one file. The key is a hash of that part's git tree ids (`:167-189`), so a different tree does not reuse a green line. The trim writes a tail to a temp file and `mv`s it over the cache, which can drop another run's line. The next push runs that part again | take a lock around the trim, or use one cache file per worktree |
| 6 | Fleet tmux socket and fixed window names, hand run only | `csi-spl-orc/src/bash/features/spawn-agents/tests/live-terminal-proof.sh:32` (output dir `/var/tmp/${ORG_APP}-terminal-proof`), `:33` (socket `/tmp/tmux-$(id -u)/default`), `:41-42` (windows `TRM-1` and `TRM-2`), `:34` (reads `$HOME/.local/share/$ORG_APP/cloud/dev/m3-e2e/t1`) | 1 script. The suite glob is `test-*.sh` (`run-all-tests.sh:10`); this name does not match. A search for the filename finds only the file itself | two hand runs delete each other's `TRM-1` / `TRM-2` windows on the fleet tmux server and share the output directory. CI does not start this script | put the pid in the window names and in the output directory. The real socket is the point of the script; the names and the output dir are what collide |

## Checked, and isolated

These are the categories the question names. Each one was counted. A zero
here is the count the command printed, on this tree.

| category | n | where it is isolated |
|---|---|---|
| `t.Parallel()` in `*_test.go` | 0 | Go tests in one package run one at a time. Packages still run in parallel under `go test ./...`, which is why the Postgres harness gives each package its own database |
| `store.NewMemory(` / `auth.NewMemoryCredStore(` | 10 / 9 | a new in-memory store per call. No shared object across processes |
| `net.Listen` / `tls.Listen` on `127.0.0.1:0` | 6 | the test keeps the listener. The port is not released and then reused |
| `SPOOL_TEST_PG_DSN:-` (a default DSN) | 0 | 97 lines mention `SPOOL_TEST_PG_DSN`. The bash harness sets it. An unset variable leaves the Go tests on the memory store |
| Postgres server, database, role | per run | `hub-pg.tst.sh`: local mode uses `mktemp` and `listen_addresses=''` with `PGPORT` in `20000 + RANDOM % 20000` (`:37-41`); docker mode uses `--name spool-hub-pg-test-$$` and `-p 127.0.0.1::5432` (`:45-47`). Database names `spool_hub*` and role `spool_rt` (`:105`) live inside that server. `:93-98` records the old failure: one shared database let the store retention sweep purge the hub suite (CI 35436333578). The split per package is the fix |
| Port `55499` | 8 lines, 0 live servers | `msg-to-db.tst.sh:70` and `spl-db-health.tst.sh:67` pass that DSN to a stub `psql` (`msg-to-db.tst.sh:27-31`). `cloud-actions.tst.sh:98` checks a string rewrite. `sql-proxy-port.tst.sh:112` asserts an unset `SPL_PROXY_PORT` is a free port and is not 55499. The production default that used to be fixed is described in `spl-cloud-cnf.func.sh:380` |
| Docker published host port `127.0.0.1:<fixed>:` | 0 | ephemeral publish `-p 127.0.0.1::5432` is **10**. `--name` lines in tests are **11**, and **0** of them are a literal name (each expands a variable, and the Postgres / fake-gcs names include `$$`) |
| `docker network create` / `docker volume create` / `docker compose up` | 0 / 0 / 0 | `lde-stack.tst.sh:78` runs `docker compose -p lde-test ... config`. That renders. It does not create the `csi-spl-lde` project |
| Local-dev stack ports | cnf only | `csi-spl-cnf/csi-spl/lde.env.yaml`: project `csi-spl-lde` (`:23`), host ports 55432 (`:26`), 54443 (`:32`), 3000 (`:34`), 58080 (`:36`). No `*.tst.sh` starts that stack |
| pnpm store and pnpm binary dir | the home race is closed | `10_ci-quality.yml` sets `dest: ${{ runner.temp }}/setup-pnpm` at `:163`, `:217`, `:312` (3). The comment at `:161-162` names the old race on `~/setup-pnpm` (run 36138615567). `npm_config_store_dir=$RUNNER_TOOL_CACHE/pnpm-store` at `:169`, `:223`, `:318` (3). The store is content-addressed, one directory per runner |
| tmux server in the suites | private socket | spawn-agents `t_sandbox` sets `SPOOL_TMUX_SOCKET` under `mktemp` (`lib.inc.sh:47-49`) and the server is `tmux -S` that socket (`:76`). `test-agent-winch.sh:37` uses `tmux -L "winch-$$"`. The suite header says the run does not touch the box socket (`run-all-tests.sh:2-3`). The fleet socket appears as a default only in the hand script in row 6 |
| Live spool root `/var/spool-hub` opened by a test | 0 of the 32 scanned lines | 14 test lines contain the path. They are comments, a `grep -c` of the default, or a refusal when the temp dir is inside the live root. The call scan is below |
| `flock` in tests | 20 call sites, 0 fixed paths | every path is under that test's `$T`, `$D`, `$S`, `$SPOOL_ROOT` or `$BOX_SESSIONS_DIR`. One more line names `flock` in a tool list (`satellite-ansible.tst.sh:212`) and does not take a lock. **0** lines contain `/dev/shm/` |
| `~/.config/gcloud` written by a test | 0 | `adhoc-harvest-gcp-actions.tst.sh:79-80` asserts the shared config is refused. `gcp-list-secrets.tst.sh:54` asserts it is not created. A command-position scan printed 5 `gcloud` lines: 3 are a planted file the pin scanner reads (`gcloud-account-pinned.tst.sh:240-247`), 1 is a `grep -E` pattern (`spl-hub-route-latency.tst.sh:51`), 1 calls a `gcloud()` function defined in the same `bash -c` (`secrets-check-seed-all.tst.sh:45` and `:71`). None exec the real binary |
| `gh` as a command in a test | 0 real calls | the 2 command-position hits are a redact fixture and a comment |
| Terraform plugin cache used by the validate test | per pid | `tf-steps-render-and-validate.tst.sh:180` sets `TF_PLUGIN_CACHE_DIR` to `$HOME/.terraform.d/plugin-cache/csi/spl/test-$$`. The comment at `:177-179` records that the shared operator cache failed once in 3 validates during another apply (2026-09-17). The test does not use that shared directory. A sweep deletes `test-*` dirs whose `/proc/<pid>` is gone (`:186-189`) |
| Same-worktree `bin/spool` | one binary per checkout | `t_spool_bin` (`lib.inc.sh:85-90`) builds `csi-spl-api/src/go/spool-hub-api/bin/spool` when it is missing. Two tests in one worktree can build it at once. CI checks out one tree per job |

### Live spool root: how the 0 was read

56 functions whose name is at least 8 characters have `/var/spool-hub` in
the function body (production shell under `csi-spl-orc`, `csi-spl-iac`,
`csi-spl-api`, `csi-spl-cnf`). A test line that names one of those
functions, is not itself a definition, has no `SPOOL_ROOT=` in the
previous 6 lines, and sits in a file that does not contain the literal
`SPOOL_TEST=1`, came out at **32**.

Those 32 lines, read one by one:

| bucket | n | why the live root stays closed |
|---|---|---|
| not a call | 7 | a `grep` of the source, an `echo` of the name, a comment, a function redefined in the test, or a `case` arm |
| `directive_env_load` | 2 | `SPOOL_BOX_ENV` is the temp file, so the default path is not opened (`test-directive.sh:40`) |
| `spl_desk_box_default` | 1 | `SPOOL_DESK_BOX` is set, so the function returns before reading a file (`spl-desk-box.func.sh:25`) |
| `do_spl_standby_bench` via `in_orc` | 1 | the test sets `SPOOL_AGENT_USER`. The function reads `box.env` only when that variable is empty (`spl-standby-bench.func.sh:55`) |
| after `t_sandbox` | 21 | `t_sandbox` exports `SPOOL_ROOT` to a `mktemp` directory and `SPOOL_TEST=1` (`lib.inc.sh:48-54`). The later `env` inherits both, so `${SPOOL_ROOT:-/var/spool-hub}` is not taken. `spool_test_guard` (`spool-env.inc.sh:241-249`) refuses the live root when `SPOOL_TEST=1` |

`in_orc` in `csi-spl-orc/src/bash/tests/test-lib.inc.sh:39` is `env`
without `-i`. It sets `SPL_STATE_DIR` and does not set `SPOOL_TEST` or
`SPOOL_ROOT`. A snippet that calls a function with the live default,
and that does not pass its own root, follows the caller's environment.
The 32-line reading above found no such open. It is not a trace of
every snippet `in_orc` can eval. The hardening that matches the
spawn-agents harness is to export a private `SPOOL_ROOT` under `$T`
and `SPOOL_TEST=1` from `in_orc` itself. `SPOOL_TEST=1` alone does not
help a function that never calls the guard.

## Checks

Run from the repo root. `n` above is what these printed on
`e52d6a63b08b3388b6fe50f19790af48ff2ceb5b`.

Test-file set used for every test count: a file ending in `_test.go`,
`.tst.sh` or `.proof.mjs`, or a `.mjs` / `.js` / `.sh` / `.ts` file
under a `tests/` directory or under `csi-spl-wui/src/node/test/`.
`node_modules`, `dist`, `.nuxt` and `bin` are skipped. That walk
printed `TEST_FILES 1287`.

Launch flag (row 1). Lines containing `puppeteer.launch`: 271. Of those,
the next 25 lines contain `disable-dev-shm-usage` in 61 and do not in
210. Lines containing `disable-dev-shm-usage` anywhere in a test file:
65. Lines containing `/dev/shm/`: 0.

```text
python3 - <<'PY'
import os
from pathlib import Path
root = Path('.')
skip = {'.git','node_modules','dist','.nuxt','bin','vendor'}
def is_test(p, r):
    n = p.name
    if n.endswith(('_test.go','.tst.sh','.proof.mjs')): return True
    return (('/tests/' in '/'+r) or r.startswith('csi-spl-wui/src/node/test/')) and n.endswith(('.mjs','.js','.sh','.ts'))
files=[]
for dp, dns, fns in os.walk(root):
    dns[:] = [d for d in dns if d not in skip]
    for f in fns:
        p = Path(dp)/f
        r = str(p)
        if is_test(p, r): files.append(p)
occ=hit=miss=flag=shm=0
for p in files:
    lines = p.read_text(errors='replace').splitlines()
    flag += sum(1 for l in lines if 'disable-dev-shm-usage' in l)
    shm += sum(1 for l in lines if '/dev/shm/' in l)
    for i,l in enumerate(lines):
        if 'puppeteer.launch' not in l: continue
        occ += 1
        if 'disable-dev-shm-usage' in '\n'.join(lines[i:i+25]): hit += 1
        else: miss += 1
print(f'files {len(files)} launch_lines {occ} with_flag_25 {hit} without {miss} flag_lines {flag} shm_path {shm}')
PY
```

Row 2 anchors:

```text
grep -n 'free_port()' csi-spl-api/src/bash/tests/hub-gcs.tst.sh
grep -n 'bind(("127.0.0.1",0))' csi-spl-orc/src/bash/scripts/wui-e2e-mock-serve.sh
grep -n 'function freePort' csi-spl-wui/tests/e2e/lib/server.mjs
```

Row 3: `grep -n "argOf('--port', '8443')" csi-spl-wui/tests/e2e/lib/serve-hosting-h2.mjs`
and `grep -n 'SPOOL_HTTPS_PORT:-8443' docker-compose.yml`.

Row 4: `grep -n 'cache: false' .github/workflows/10_ci-quality.yml` (2) and
`grep -c GOCACHE .github/workflows/10_ci-quality.yml` (0). The reason is
`.github/workflows/20_hub-build-deploy.yml:92-97`.

Row 5: `grep -n 'pre-push.parts.green' csi-spl-iac/src/bash/run/check-pre-push.func.sh`.

Row 6: before this file existed, `grep -n 'live-terminal-proof' -r csi-spl-orc csi-spl-iac .github --include='*.sh' --include='*.yml'`
printed only `live-terminal-proof.sh`. `grep -n 'test-\*.sh' csi-spl-orc/src/bash/features/spawn-agents/tests/run-all-tests.sh`
shows the suite glob, which that name does not match.

Isolated counts, same test-file walk:

| check | result on this tree |
|---|---|
| `t.Parallel(` | 0 |
| `store.NewMemory(` | 10 |
| `auth.NewMemoryCredStore(` | 9 |
| `Listen` and `:0` on one line in `*_test.go` | 6 |
| `SPOOL_TEST_PG_DSN:-` | 0 |
| `-p 127.0.0.1::5432` | 10 |
| `-p 127.0.0.1:<digits>:` | 0 |
| `docker network create` / `docker volume create` | 0 / 0 |
| `go clean -cache` | 0 |
| `GOCACHE=` in test files | 2, both `$T/gocache` |
