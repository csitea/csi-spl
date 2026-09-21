# CI gate reliability — what "the CICD has been failing for long" actually was

**Feature**: `016-spool-testability` · **Contract**: `contracts/test-layers.md`
**Lane**: CLE-3442 · **Measured**: 2026-09-21 ~17:20Z, `gh run list --limit 200 --status failure`
**Tree**: trunk `4de5d1a` (the classification) → `b4994ec` (the changes below)

## 1. The measurement

| workflow | red runs on 2026-09-21 |
|---|---|
| `10 ci: quality gate` | 31 |
| `30 ci-cd: spool WUI build + deploy` | 3 |
| `00 ops: spool hub deploy lag watch` | 8 |
| **total** | **42** |

Those 42 runs are **six causes**. Every red run in the table below is the same
defect seen again by the next push:

| # | window (UTC) | red runs | job(s) | the log line | class |
|---|---|---|---|---|---|
| C1 | 07:38–07:45 | 7 | `iac` | `FAIL: the domain literal appears outside csi-spl-cnf/ and csi-spl-doc/:` | real defect |
| C2 | 12:54–13:08 | 12 | `distribution-hygiene` + `iac` | `::error::hygiene: literal OS user / box / AD id -- 2 line(s)` → `./csi-spl-doc/specs/030-spool-wire-fastpath/spec.md:104` and `:105` | real defect |
| C3 | 12:58–13:04 | (inside C2) 5 + 3 on `30` | `wui: unit tests + typecheck` | `FAIL key present auth.native_error.__control_missing__: missing in en.json` | real defect |
| C4 | 13:16–13:20 | 7 | `iac` + `orc` | `FAIL: dev image: action '…/spool-hub:0.1.18' vs 030 '…/spool-hub:0.1.17'` and `FAIL: dev tfvars differ from a fresh render (run ENV=dev ./run -a do_tpl_gen)` | real defect |
| C5 | 13:23–13:26 | 4 | `wui: browser e2e (mock, generated)` | `FAIL 390x844 /login: scrollWidth=9999 innerWidth=1560` — **two facts, and the first one is deliberate**: `c04ac2f` ("plant overflow so wui-e2e must go red", 016 T021) added a workflow step appending `html,body{min-width:9999px!important}` to the generated CSS, reverted by `8b7902e`. The `9999` is that plant. `innerWidth=1560` on a check labelled 390x844 is a separate, real harness miss, guarded since `4153561`. | **intentional control** on trunk, over a latent harness miss |
| C6 | 12:54 | 1 (inside C2) | `hub` | `--- FAIL: TestV2HeldForV1OnlySession (5.05s)` … `delivery "queued" frame &{recv …}` | flake |
| C7 | 13:18 | 1 | `hub` | `FAIL - hub did not come up`, over a hub log ending in `"addr":"127.0.0.1:37604" … "hub listening"` | flake, mechanism unproven |
| C8 | 01:03–07:37 | 8 on `00` | `Does dev/prd serve this commit?` | `dev hub lagging served=af8c6db6 sha=cea65d28 n=3 … age=2177m grace=45m` | correct alarm, not a CI fault |

7 + 12 + 7 + 4 + 1 = 31 on the gate; C3 and C6 fall inside C2's runs; C8 is
the hourly watcher and is a different question.

**So the gate is not flaky. 26 of 31 red gate runs were a real defect sitting
on trunk, 4 were a control that was SUPPOSED to be red, and 1 was a flake**
(C6, the second flake, reddened a run C2 had already reddened). The owner's
experience is nonetheless exactly right: a red workflow on the repo page, over
and over, for most of a day.

**Verified rather than relayed** — C5 came from the e2e lane (GRK-3381) and is
the one row of this table not read off a log by this lane:

    git show c04ac2f:.github/workflows/10_ci-quality.yml \
      | grep -c 'CONTROL — plant a horizontal overflow\|min-width:9999px'   -> 2
    git show 25649ab:...  -> 2      (still planted at the last red run)
    git show 8b7902e:...  -> 0      (the revert)

## 2. Why six defects read as forty-two failures

Each defect was fixed by its own lane within 5 to 20 minutes. In that window
every OTHER lane pushed too, and each of those pushes ran the gate against a
trunk that already carried the defect. One line in one `spec.md` cost 12 red
runs across 2 jobs.

That amplification is not cosmetic. A gate that is red five times more often
than it has reasons to be is a gate people learn to scroll past — which is the
failure mode that lets a real red through.

It also means the useful count is **per job, not per run**. `31 red runs`
sounds like a broken pipeline; `iac 19, distribution-hygiene 12, wui 9, orc 7,
hub 2` names the four things that actually broke.

## 3. What changed

| # | change | commit |
|---|---|---|
| 1 | `do_check_dist_hygiene` — the `10 ci` Sweep step, extracted from the workflow with `yq` and run over a `git ls-files` export of the working tree, in about a second. C2 becomes a one-second local failure instead of 12 red runs. | `b5be577` |
| 2 | `TestV2HeldForV1OnlySession` waits for `welcome` before sending. C6's shape — `delivery "queued"` **with the recv frame present** — is only reachable if the send landed between the hello write and the hub registering the session. `ws.go` registers before it writes `welcome`, so that read is the barrier; every other raw-socket test in the package already takes it. | `d8578b3` |
| 3 | The hub binds with `net.Listen` before logging `hub listening`, and logs `ln.Addr()`. `ListenAndServe` binds inside the goroutine, so the old line announced a socket that might never have bound — which is why C7 could not be diagnosed. With the real address in the log, `hub-e2e.tst.sh` asks for port 0 and reads back what it got, and `hub-gcs.tst.sh` takes a port below `/proc/sys/net/ipv4/ip_local_port_range` and binds it first. Both previously drew from 20000–39999, which overlaps the ephemeral range 32768–60999. | `cdbb737` |
| 4 | `do_report_ci_gate` — failures per job over the last N runs, `CI_GATE_SIGNATURES=1` for the first failure line of each. Wired into `10 ci` as a `gate-health` job that runs only on failure and writes the table into the run summary, so the next red run carries its own history. | `b4994ec`, `(gate-health)` |

### Residual risk, per item

- **1**: predicts the `distribution-hygiene` job only. It does not predict
  `iac`, `wui` or `hub`; a lane still has to run the suite for the tree it
  touched. It reads the workflow, so it cannot drift from the gate — but it
  also inherits any blind spot the Sweep has.
- **2**: not reproduced locally. n=200 on an idle box (120 default, 80 at
  `GOMAXPROCS=1`), zero failures. Against a CI rate near 1 in 40 that is
  evidence of a low local rate, never proof of absence. The claim rests on the
  mechanism in `ws.go` and on the log line, not on a repro.
- **3**: it is **not claimed** that a port collision caused C7. It is one
  mechanism that fits the evidence, it is now gone, and the next occurrence
  will say whether the process was alive and what held the port.
- **4**: a report, not a gate. `continue-on-error: true`, so it can never turn
  a run red, and correspondingly it proves nothing — read it, do not trust it
  as a control.

## 4. The smallest rule that prevents the amplification

Not "do not push onto a red trunk": that serialises the fleet and punishes the
lanes that did nothing wrong. The defects were all catchable **in the lane that
wrote them, before the push**, in under a minute:

> **Before every push, run the cheap gate for the tree you touched.**
>
> | you touched | run | catches |
> |---|---|---|
> | anything at all | `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (~1 s) | C2 |
> | `csi-spl-cnf/**`, any tfvars, any image tag | `ENV=<env> ./run -a do_tpl_gen` then `git diff --exit-code` | C4 |
> | `csi-spl-wui/**` | `pnpm run typecheck` | C3 |
| `csi-spl-wui/**`, anything the browser renders | `BASE_URL=<generated bundle> pnpm run test:e2e` | the viewport-miss half of C5 — **typecheck does not drive Chrome** (GRK-3381) |
> | `csi-spl-api/**` | `bash csi-spl-api/src/bash/tests/run-all-tests.sh` | C6, C7 |

Each of C2, C3, C4 would have been a local failure in the lane that wrote it.

And one thing the fleet should do about deliberately-red trunk: **a control
that must turn trunk red is indistinguishable, in the run list, from a defect**
— C5 cost this lane an hour of classification before the owning lane named it.
Either keep the plant off trunk (dispatch it on a throwaway branch, which is
how `gate-health` below was proved), or say so in the commit subject of the
plant AND of the revert, which `c04ac2f` / `8b7902e` in fact do. The run list
does not show commit subjects, so the second form only helps a reader who
already suspects it.

## 5. Two things left for their owners

- **`wui: browser e2e` is in CI, `contracts/test-layers.md` §1 still says layer
  G is "**not in CI**" and §2 lists it as not run.** The row is stale; the
  e2e-harness lane owns that file's e2e rows.
- **One hygiene breach reddens two jobs.** `distribution-hygiene` fails, and so
  does `iac`, because `hygiene-owner-email-allow.tst.sh` re-runs the real-tree
  sweep as its first assertion. That is not wrong — it is a deliberate control
  — but it doubles the apparent failure count of every hygiene breach, and the
  per-job table in §2 reads 12 + 12 for one bad line. Worth knowing before
  reading those counts as two problems.

## 6. Seeing the next one fast

```
cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate
```

A job that appears in a handful of runs inside one narrow window is a defect
that sat on trunk. A job that appears once here and once next week, with the
same signature line and nothing else red around it, is a flake.
