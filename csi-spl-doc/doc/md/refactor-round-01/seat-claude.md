# Refactor round 01 — panel seat claude (c-650@<box>)

Issue: SPL-6520 (epic SPL-2402, Issue-Role: shared). Spec: csi-spl-doc/specs/011-spool-project-refactor.
Brief: `/var/spool-hub/dispatch/briefs/c002-refactor-round-100-claude-panel-seat.md`
(placement slug keeps "100"; the round is r01 per rulebook 5.3 and holder ruling `83dd3a25`).

Review target: `csi-spl-doc/doc/md/refactor-round-01-plan.md` on branch
`review/c002-refactor-round-01-planner` at v0.1
**`78277dc10e5bb7f6037b7e469f35ae616f24fc0f`** (relayed by the planner a-649, msg `b389015d`).

- `git ls-remote origin refs/heads/review/c002-refactor-round-01-planner` ->
  `78277dc10e5bb7f6037b7e469f35ae616f24fc0f` (head == the v0.1 sha named by the planner).
- `git show 78277dc10 --stat` -> one file, `refactor-round-01-plan.md` +798, parent
  `991ce5bc5`, author and committer the repo-canonical address; AI-trailer grep -> 0.
- Plan file sha256 (`git show 78277dc10:<plan>`): `96f20c03134272162aff51e7caa8951f1e8685f296c5273a1d0b393053e7f69d`.
- Plan base `fe1f82671`; origin/master at review time `991ce5bc5`.
- Every file:line cited below was checked with `git show <sha>:<file> | sed -n <N>p`.
  Plan line numbers (`plan:N`) are lines of the plan at `78277dc10`.
- Control runs: full `git archive fe1f82671 csi-spl-orc csi-spl-iac` trees in this seat's
  scratch dir (base, head1, head2, rc1, rc2, gc1, gc2, m1a, m1b, m2a, m2b, m2c), heads
  rebuilt by script from the plan's verbatim blocks (`plan:215-227`, `234-299`, `378-401`,
  `406-416`, `423-448`, `455-476`), `SPOOL_TEST=1`, `SPOOL_BOX_TAG`/`SPOOL_AGENT_ID` unset,
  stdin `/dev/null`, n=1 each. Nothing committed or pushed from them.

**Verdict: PASS on v0.1 `78277dc10e5bb7f6037b7e469f35ae616f24fc0f`. No W defects.**

## 1. Slug r01 unused since W

`W=2026-11-25T14:48:03+02:00` (`plan:82`), re-read:
`git log origin/master -1 --format='%H %cI %s' -E --grep='^docs\(r99-plan'` ->
`7a8ebd3ccb673042ee643381875f22eec38aab63 2026-11-25T14:48:03+02:00 docs(r99-plan, SPL-6469): refactor round 99 closed: ...`.

- `git log origin/master --since="$W" --oneline -E --grep='\(r01-' | wc -l` -> `0`.
- `git ls-remote origin | grep -E 'r01-[0-9]{2}|refactor-round-01'` ->
  `78277dc10e5bb7f6037b7e469f35ae616f24fc0f refs/heads/review/c002-refactor-round-01-planner`
  only (the planner's branch; this seat's branch did not exist yet). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'r01-[0-9]{2}|refactor-round-01'` -> empty
  (rc 1). The two briefs of this round keep the "100" slug:
  `ls ... | grep refactor-round-100` -> `c002-refactor-round-100-claude-panel-seat.md`,
  `hand-<box>-c002-refactor-round-100-planner.md` (expected).

## 2. Sites exist on the base and on origin/master

All row sites read on `fe1f82671` match the plan text:
`spl-hub-request-minutes.func.sh:35-39` (the 5-line block, `plan:149-153`), `:49`
(`spl_hub_request_minutes_check_args() {`), `:55` (`}`); `spl-hub-run-metrics.func.sh:13`
(`spl_hub_request_minutes_check_args "$since" "$minutes" 1 1 || return 1`), `:17-21` (same
5 lines); `spl-hub-request-minutes.tst.sh:97` (`echo`), `:98` (`ALL PASS` line);
`spl-hub-agent-kinds.func.sh:69-83` and `spl-hub-runner-cpu.func.sh:54-68` (comment + reporter,
the 400 / 401|403 / 404 / `*` branches as quoted in `plan:320-322`);
`hub-agent-kinds.tst.sh:78` and `hub-runner-cpu.tst.sh:69` (the `PASS: all` line).

Drift: `git diff --name-only fe1f82671 origin/master -- <the 7 row files> | wc -l` -> `0`
(origin/master `991ce5bc5`).

Side citations also checked: `spl-hub-box-band.func.sh:110-123` (no `404)` branch, the
`*)` says `box $1 band was not read or changed`), `spl-hub-load-test.tst.sh:75` (stub of
`do_spl_hub_run_metrics`), `canary-hub-deploy.tst.sh:185` (comment),
`spl-review-go.tst.sh:1078,1096,1103,1109` (fixture prose), and the section 7 sites
(`spl-hub-agent-kinds.func.sh:30-32,40-42`, `spl-hub-runner-cpu.func.sh:29-31,39-41`,
`spl-msg-dedup.func.sh:46`, `spl-msg-wipe.func.sh:36`, `gcp-get-alert-incident.func.sh:71`,
`gcp-list-alert-incidents.func.sh:89`, `dispatch-inbound-pg.tst.sh:141`,
`check-disk-headroom-install-cron.func.sh:36,56`, `spl-wui-perf-report.func.sh:69-75`): each
line reads as the plan says.

## 3. Red controls (and guard / mutation controls)

The rebuilt heads reproduce the plan's sha256 prefixes byte for byte (`sha256sum | cut -c1-12`):
head1 `d614c9dd9f63` / `adf9375567fa` / `fc7d9b8407d5`, head2 `52d20bac44d7` /
`74a3db121695` / `918e59626f4d` / `d7f616c6c177` (= `plan:200-202`, `365-368`). Line
counts 137 / 74 / 165 and 92 / 64 / 106 / 93 (= the plan's).

Red-control test files read, sha256:
- rc1 `spl-hub-request-minutes.tst.sh` `fc7d9b8407d55490a655952a8aa712cc04785691caea3f575b3556a5ffc884be`
- rc2a `hub-agent-kinds.tst.sh` `918e59626f4d3c0fbf5bd04d901735cccde88cc4f4041c308e482437c88b2cd5`
- rc2b `hub-runner-cpu.tst.sh` `d7f616c6c177b7e5e143188ada397003030ef9aeb739fd5ea81a3b6f5cf2cea8`

Runs (rc / pass / fail lines, counted as the plan counts, `^ *(ok|pass)` / `^ *(not ok|fail)`):

| tree | suite | rc / pass / fail | last line | = plan |
|---|---|---|---|---|
| base | spl-hub-request-minutes | 0 / 54 / 0 | `ALL PASS` | yes |
| rc1 | spl-hub-request-minutes | 1 / 56 / 6 | `6 FAILED` | yes |
| head1 | spl-hub-request-minutes | 0 / 62 / 0 | `ALL PASS` | yes |
| gc1 | spl-hub-request-minutes | 1 / 61 / 1 | `1 FAILED` | yes |
| m1a | spl-hub-request-minutes | 1 / 61 / 1 | `1 FAILED` (`5. minutes wire ... .. 2026-10-15T07:16:00Z`) | yes |
| m1b | spl-hub-request-minutes | 1 / 61 / 1 | `1 FAILED` (`5. metrics wire ... .. 2026-10-15T07:16:00Z`) | yes |
| base / head1 | spl-hub-load-test | 0 / 50 / 0 | `ALL PASS (spl-hub-load-test)` | yes |
| base | hub-agent-kinds | 0 / 17 / 0 | `PASS: all hub-agent-kinds.tst.sh assertions` | yes |
| rc2 | hub-agent-kinds | 1 / 18 / 6 | `FAIL: 5 assertion(s) in hub-agent-kinds.tst.sh` | yes |
| head2 | hub-agent-kinds | 0 / 24 / 0 | `PASS: all ...` | yes |
| m2a | hub-agent-kinds | 1 / 22 / 2 | `FAIL: 1 assertion(s) ...` (`6. kinds 500: ... runner CPU cap was ...`) | yes |
| m2c (this seat's own: 401/403 text changed in the helper) | hub-agent-kinds | 1 / 20 / 4 | `FAIL: 3 assertion(s) ...` (`5. 403`, `6. err 401`, `6. kinds one copy`) | n/a |
| base | hub-runner-cpu | 0 / 14 / 0 | `PASS: all hub-runner-cpu.tst.sh assertions` | yes |
| rc2 | hub-runner-cpu | 1 / 16 / 2 | `FAIL: 1 assertion(s) in hub-runner-cpu.tst.sh` | yes |
| head2 | hub-runner-cpu | 0 / 18 / 0 | `PASS: all ...` | yes |
| gc2 | hub-runner-cpu | 1 / 16 / 2 | `FAIL: 1 assertion(s) ...` (`6. lazy cpu: rc=127 ... line 62: _spl_hub_fleet_load_error: command not found`) | yes |
| m2b | hub-runner-cpu | 1 / 16 / 2 | `FAIL: 1 assertion(s) ...` (`6. cpu 500: ... agent kinds were ...`) | yes |

Reasons: rc1 fails on `spl_hub_request_minutes_prep: command not found` (3 direct checks),
the two one-copy greps (`fm one copy: own=[18: ... FATAL env.hub.service_name ...]`), and the
standalone check (`spl-hub-run-metrics.func.sh: line 13: spl_hub_request_minutes_check_args:
command not found`); rc2a on `_spl_hub_fleet_load_error: command not found` (4) + `kinds one
copy`; rc2b on `cpu one copy: own=[63: 400) ...]`. Each is the reason the plan gives
(`plan:524-545`), none an environment reason. The 2 wiring checks of rc1 and the 2
end-to-end 404/500 checks of rc2 pass on base, as the plan says: they pin the behaviour.

Live state: none. The wiring checks put stub `gcloud`/`curl` first on `PATH` and override
`do_spl_cloud_cnf`, `do_gcp_pin_account`, `do_gcp_require_live_account`; the standalone
checks fail before any pin (row 01, missing `service_name`) or stub `spl_hub_operator_call`
with `SPL_HUB_URL=https://hub.invalid` (row 02). `mktemp` only.

## 4. Equivalence

- **Row 01.** The helper runs the same 5 statements in the same order (`yq` read,
  non-empty check with the same FATAL text, `do_gcp_pin_account "$SPL_CNF"`,
  `do_gcp_require_live_account "$GCP_ACCOUNT"`, the same `date -u -d` with `$1`/`$2` =
  `$since`/`$minutes`), each `|| return 1` as before; both callers keep their
  `local svc until` (`spl-hub-request-minutes.func.sh:34`, `spl-hub-run-metrics.func.sh:16`)
  and copy the two globals into them. Same output, exit codes, paths and defaults. The only
  new state is two unexported process globals (N3). The wiring checks catch a changed
  `since`/`minutes` (m1a, m1b) and a changed service name; the direct checks catch a lost
  FATAL text or a pin/live reordering.
- **Row 02.** On every non-200 status the helper logs the same text and returns 1, as each
  `case` branch did (`return 1` after `do_log`); on 200 the OK line is unchanged. The one
  difference is that the unused `detail` `jq` call no longer runs on 200: its output was
  discarded and its stderr sent to `/dev/null`, and `run.sh` sets no `errexit`
  (`git show fe1f82671:csi-spl-orc/src/bash/run/run.sh | grep -nE '^\s*set -[a-z]*e'` -> empty),
  so nothing a caller sees changes. The subject text of the `*)` branch is passed per caller;
  m2a / m2b prove a swap is caught; m2c proves a changed 401/403 text is caught (403 end to end
  is already covered: `hub-agent-kinds.tst.sh:75`, `hub-runner-cpu.tst.sh:66`).
- Under `./run` both guards are no-ops: the lazy index stubs every function of a file with
  only function definitions (`run.sh:885-889`), so `declare -F` finds the stub; the guards
  matter only when a `.func.sh` is sourced by hand (gc1, gc2).

## 5. Row form (R2, R1, vendor)

Rows 01 and 02 (`plan:572-573`): each has a red control that fails on the parent and passes on
the head (section 3), a test list, vendor claude, kind `simple_coding`, batch 1; no mistral row.
R7 (`plan:677-688`): an agy seat per row, claude waiver backup only under ruling `dc84300a`,
never mistral. R1: row 01 files {request-minutes.func, run-metrics.func,
request-minutes.tst} and row 02 files {agent-kinds.func, runner-cpu.func, hub-agent-kinds.tst,
hub-runner-cpu.tst} are disjoint.

## 6. R3

`lane-map.sh --check <the 7 row paths> --agent c-650` at 2026-11-25T16:37:48Z -> **exit 4**:
`WARN no live lane lists <the 7 paths>, but 20 live lane(s) record no files`. The 20
`unknown:` lanes, all on the other box: c-029, c-041, c-086, c-146, c-187, c-398, c-407, c-416, c-474,
c-476, c-529, c-535, c-561, c-569, c-571, c-728, c-927, c-936, c-957, c-965. No lane owns a
row path (no exit 3). Cross-check: every `refs/remotes/origin/*` branch committed in the
last 24 h (63 of them): `git diff --name-only $(git merge-base origin/master <b>) <b> -- <the 7 paths>`
-> 0 hits; `git log origin/master --since='24 hours ago' -- <the 7 paths> | wc -l` -> 0.
The planner's live and queued lanes (`plan:615-633`) name none of the 7 paths; I did not
re-read the spawn queue.

## 7. Inputs accounted for, one refactor per row

`/var/spool-hub/dispatch/c002-next-round-candidates.md`: 140 lines, mtime 2026-11-24 22:12
(= `plan:127-129`), no `for refactor round 01/100` block. Refactor-shaped items re-checked
on origin/master: `spl-unanswered-sweep.func.sh` `send_to_peers_on` -> 0 hits (served by
r97-01 `2924c633f`); `spl-lane-mix.func.sh` "final word | waits for an agy review |
needs_agy_review" -> 0 hits (served); `spl-desk-reply.sh:9,19` list the new kinds (served).
One item the plan does not name by itself (N6). The r99 section 7 items are each in the
plan's section 7 (`plan:770-779`) or served by the rows. No row changes an exit code, a
message, a path or a default (section 4).

## 8. Hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over
the tracked tree of /opt/csi/csi-spl-wt/c-650`, rc 0.

Also run: `shellcheck -S warning -x` on head1's 3 and head2's 4 files -> rc 0 each;
`func-name-unique.tst.sh` on head1, head2 -> `ALL PASS`. NOT RUN by this seat: the rest of
the shared column of `plan:500-508`; `bash-cleancode.tst.sh` gave rc 3 on base and head1
alike with the same 3 `CONTROL: the walk does not list csi-spl-{utl,api,wui}/...` fails,
an environment reason (my tree held only orc and iac), so it shows no difference but proves
nothing about the cap.

## W (defects)

None.

## N (notes)

- **N1** (`plan:616-617`): the lane map now reads 20 `unknown:` lanes, not 22 (c-426 and c-566
  gone, 16:15Z -> 16:37Z). Live state; the holder re-reads at placement anyway.
- **N2** (`plan:55` vs `plan:334`, `770`): the box-band exclusion cites `:119-121` in the
  header and `:110-123` in 1.4 and 7. Both are true (the branches, and the whole reporter);
  one range in v1.0 would read cleaner.
- **N3** (`plan:304-305`): row 01 leaves `SPL_HUB_REQ_SVC` / `SPL_HUB_REQ_UNTIL` set in the
  `./run` process (not exported). The plan documents them; no caller reads them. Fine, noted
  so R7 does not flag it as new behaviour.
- **N4** (`plan:328-333`, `413-414`): row 02 hosts the shared helper in an action file
  (`spl-hub-agent-kinds.func.sh`), so `spl-hub-runner-cpu.func.sh` now depends on a sibling
  action file. That follows the r99 pattern and the one-copy + lazy-load checks hold it; if the
  agent-kinds action is ever retired the helper must move first.
- **N5** (`plan:479-481`): the "avoiding the unused `detail` jq call on 200" is the only
  path change in row 02; it is unobservable (section 4). Say so in the row's commit body so
  R7 does not read it as a behaviour change.
- **N6** (`plan:126-134`): the candidates line `i18n-lang-review-exempt.json:2` (BUG/REFACTOR-
  shaped, "`_doc` still says Lang-review a-NNN") is not named by itself; on origin/master the
  `_doc` still says `Lang-review: a-NNN <msg id>`, and the gate header still lists that form
  (`check-pre-push-lang-review.func.sh:27`) beside `gct` (`:17`). Not a bash refactor and maybe
  not a defect at all; v1.0 could name it in section 7's lumped row.
