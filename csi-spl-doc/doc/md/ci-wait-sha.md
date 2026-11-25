# Waiting for a commit's CI: `do_ci_wait_sha` (SPL-6502)

## 1. The rule

A lane waits for the CI runs of its commit with

```bash
cd csi-spl-orc && SHA=<sha> ./run -a do_ci_wait_sha
```

never with a bare `gh run watch <id>`, and never with a `gh run list` or
`gh run view` loop. If one run must be watched by hand:
`gh run watch <id> --interval 60`. The seed's integration step (7)
(`spawn-core.inc.sh`) names the action and bans `gh run watch`; the
`--interval 60` fallback is written here only, because every vendor's seed is
capped at 9500 bytes (`spawn-agents/tests/test-spawn-seed-size.sh`).

## 2. Why

Every agent on every box uses the same GitHub account, and the account has
one budget of 5000 REST calls an hour. When it is spent, every `gh` call on
every box fails until the hourly reset: CI proofs, `gh run list`, review
checks.

Measured on 2026-11-25 (spec 016, `GH_DEBUG=api`, n = 1 window of 62 min on
both boxes):

| what | REST calls |
|---|---|
| `gh run watch --interval 10` on a 28-job wf 10 run | 69 in 60 s (55 are job annotations) |
| the same at gh's default `--interval 3` | about 230 a minute, more as jobs finish |
| `do_ci_wait_sha` | 1 a minute (60 an hour) |

`gh run watch` re-reads the run, its workflow, its jobs and the annotations
of every completed job on every refresh. One lane's chain of three
default-interval watches took the account from about 15 to about 100 calls a
minute.

## 3. What it does

- One call per tick (default 60 s, at least 30 s):
  `GET repos/{owner}/{repo}/actions/runs?head_sha=<full sha>`. No jobs call,
  no annotations call.
- Only runs whose event is in `CI_WAIT_EVENTS` (default `push,workflow_run`)
  count. A scheduled or dispatched run that started while the commit was the
  trunk head carries the same head sha, and is not the lane's.
- Done when every run is completed on two ticks in a row with the same run
  ids, so a run that a finished one triggers is waited for too. It then
  prints `<run id> <workflow> <conclusion>` per run.
- Exit 0: every run green (success, skipped, neutral). 1: a red run, or a bad
  setting. 2: no run appeared within `CI_WAIT_NORUN_MIN` (default 10).
  4: not done within `CI_WAIT_TIMEOUT_MIN` (default 90).
- A failed call (rate limit, network) is a WARN; the next tick retries.

Test: `csi-spl-orc/src/bash/tests/ci-wait-sha.tst.sh` counts the calls of one
simulated hour (60 at the default interval).

## 4. Next (separate rows of SPL-6502)

A shared per-box CI status file read by every lane, a cache for the
`do_spl_done_claim_check` lookups, and the retire check of
`tmux-close-window.sh`. A second GitHub account or a GitHub App token is the
owner's decision.
