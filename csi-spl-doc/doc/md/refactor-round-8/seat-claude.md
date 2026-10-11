# Refactor round 8 - claude seat proposal (c-996, PC)

A proposal, not the plan. The editor (this seat) merges the three seats into `../refactor-round-8-plan.md`. The agy and mistral seats write `seat-agy.md` and `seat-mistral.md` beside this file, measured on `origin/master`, give a verdict per row (agree / agree with changes / disagree, with the command behind any change), then sign. **Both seats stay up after signing: under the plan's R7.1 you are this round's cross-vendor reviewers until every row is on trunk. A seat commits its seat file and nothing else (R7.6).**

Every count was measured on ONE trunk sha, **`d4f9553f4`** (pre-rewrite, R15), n=1 per count unless stated otherwise. The command for each is in the plan, section 2. Round 7 is closed and held: `refactor-round-7-retro.md` section 1 (10 of 10 actions).

## 1. The 10 actions

| # | slug | source | sites | n | kind | box | batch |
|---|---|---|---|---|---|---|---|
| 01 | `ci(r8-01-fail-fast-spares-suites)` | r7 retro 6.4 | `gate-fail-fast.sh`: orc and hub suites stop only when no other job runs | 32 of 32 orc shards stopped; 0 min saved in 13 of 16 runs | complex_coding | sat | 1 |
| 02 | `test(r8-02-orc-suite-flush-on-stop)` | r7 retro 6.4 | orc `run-all-tests.sh` prints the finished files when stopped | 1236 of 5288 verdicts printed | tests | sat | 1 |
| 03 | `ci(r8-03-ci-gate-master-only)` | r7 retro 6.5 | `do_report_ci_gate` reads master only | 3 of 13 runs were branches | simple_coding | PC | 1 |
| 04 | `test(r8-04-bash-cleancode-one-liners)` | measured | the clean-code awk measures one-line functions | 270 functions never measured | complex_coding | sat | 1 |
| 05 | `refactor(r8-05-bash-small-functions)` | small functions | `spool_notify_poke` 110, `_ppl_run_one` 109 | 2 | simple_coding | sat | 2 (after 04) |
| 06 | `test(r8-06-strip-two-envs-settle)` | r7 retro 6.8 | strip two-envs and two-way poll instead of fixed sleeps | 11 sleeps | tests | sat | 1 |
| 07 | `refactor(r8-07-wui-small-functions)` | small functions | `useMove` 182, `usePaneWidths` 201 | 2 | simple_coding | PC | 1 |
| 08 | `refactor(r8-08-wui-scroll-anchor)` | small functions | `useScrollAnchor` 208 | 1 | simple_coding | PC | 2 (after 07) |
| 09 | `test(r8-09-go-coverage-hub-wiring)` | r7 retro 6.9 | `cmd/spool` `hub.go` builders; `internal/action` floor | 50.9 %; floor 59.2 vs 70.3 | tests | PC | 1 |
| 10 | `ci(r8-10-round-branch-prune)` | r7 retro 6.3 | named action listing and pruning `review/` and `wip/` per round | 81 branches | tests | sat | 1 |

## 2. Rules proposed (from the r7 retro, section 6)

- **R7.4** (6.3): the review line names the reviewed sha and what the reviewer ran; review branches stay until the retro's C7, then action 10 prunes them.
- **R7.6** (6.2): a review seat never commits outside its seat file; a seat cites a sha only once it has landed.
- **R8** (6.7): retro reads the review lines, then action 10, then the planner closes the seats; an idle seat closes when the last row lands.
- **R10** (6.1): a 30-minute progress check on every live row lane.
- **R11.2, R11.5** (6.4): a verdict needs the job to reach the row's test; until 01 and 02 land, orc rows use a branch dispatch with fail-fast off.
- **R11.3** (6.8): the 3rd-sighting flake threshold stands; open sightings listed.
- **R14** (6.1): `simple_coding` rows go to claude when the mix picks mistral, until a mistral lane lands a refactor row; re-place at the first override request.
- **R15** (new): the master history rewrite; read shas by subject, rebase with the lift note's `--onto` line.

## 3. Left out

The plan's section 8, each with the command that measured it. Dropped from the retro list: 6.6 (fixed by `3c9f1d3b0`, R11.3 watches it) and 6.7 (c-001's).
