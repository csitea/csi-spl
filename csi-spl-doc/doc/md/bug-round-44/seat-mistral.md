# Bug round 44 — panel seat mistral (m-718@<box2>)

Issue: SPL-6359 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/spawn-remote/briefs/befdd0ff-c110-461e-9d89-b6b92ce05fd7.md`.
Review target: `csi-spl-doc/doc/md/bug-round-44-plan.md` on branch
`review/c003-bug-round-44-planner`, at the plan version sha
`dafdceeb26bb14b59c489405928d6f3c3f8b99a3` (v0.1), named by the brief (planner
c-032@sat). `git ls-remote origin refs/heads/review/c003-bug-round-44-planner`
-> exactly that sha, still the branch head at my check (2026-11-24T09:2xZ). The
branch is one docs commit on `ab87b6d8f`:
`git rev-list --count origin/master..dafdceeb` -> `1`,
`git show dafdceeb --stat` -> `csi-spl-doc/doc/md/bug-round-44-plan.md | 302 +++...`,
1 file changed, 302 insertions — the "+302" the brief names. `origin/master` at
my fetch is `ab87b6d8f`; since the plan's measurement sha `387370a79` it took 3
docs-only commits (`git log --oneline 387370a79..origin/master` ->
`09a147c24`, `ab87b6d8f`, `309175d3b`; `git diff --stat 387370a79..origin/master`
-> only `csi-spl-doc/specs/186-.../spec.md`, `csi-spl-doc/specs/191-.../spec.md`,
`csi-spl-doc/specs/README.md`) — no row file moved. I reviewed the plan at
`dafdceeb` and verified every cited file:line on `387370a79`, the sha the plan
names; both shas named here.

**Verdict: PASS, 2 rows, on `dafdceeb26bb14b59c489405928d6f3c3f8b99a3` (v0.1).**

## Check 1 — slug b44 unused since the plan's W

W = `2026-11-24T10:56:35+02:00` (the plan's window, commit `387370a79`).

- `git log origin/master --since="2026-11-24T10:56:35+02:00" --oneline -E --grep='\(b44-' | wc -l`
  -> `0`.
- `git ls-remote origin | grep -E 'refs/(heads|tags)/[^ ]*(b44-[0-9]{2}|bug-round-44)'`
  -> exactly one ref: `dafdceeb26bb14b59c489405928d6f3c3f8b99a3 refs/heads/review/c003-bug-round-44-planner`
  (the planner's, expected; this seat's review branch did not exist yet at this
  check). Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b44-[0-9]{2}|bug-round-44'` ->
  no match (rc 1); the dir is readable here (3226 entries, 3225 readable; the one
  unreadable file is `reflection-2026-11-14.md`). A content grep
  `grep -lE '(^|[^0-9a-f])b44-[0-9]{2}|[Bb]ug round 44|bug-round-44' /var/spool-hub/spawn-remote/briefs/*.md /var/spool-hub/dispatch/briefs/*.md`
  -> exactly one file: this seat's brief `befdd0ff-c110-461e-9d89-b6b92ce05fd7.md`.
  The planner's brief is sat-only and is not readable on this box (NOT RUN there;
  the plan's own sat-side grep named only the planner's brief).
- `git worktree list | grep -E 'b44|bug-round-44'` -> only
  `/opt/csi/csi-spl-wt/m-718  ab87b6d8f [m-718-c003-bug-round-44-mistral-panel-seat]`.

## Check 2 — both defects are real on `387370a79` (every cited file:line printed)

Each line read with `git show 387370a79:<file> | sed -n <N>p`:

b44-01 (`csi-spl-orc/src/bash/run/spl-review-go.func.sh`):

- `:58` -> `# @description       fenced block or a negated ` + "`does not apply`" + `, SPL-5670;` — matches.
- `:624-625` -> `# fenced blocks and ` + "`>`" + ` quote lines, and without a negated ` + "`apply`" / `# (` + "`does not apply`" + `, ` + "`never apply`" + `). Backticked spans stay: ...` — matches.
- `:636` -> `_spl_review_go_instr() {` — matches.
- `:672` -> `neg = r"(?i)\b(?:(?:does|do|did|will|would|should|shall|may|might|can|could|must)\s+not|doesn't|don't|didn't|won't|cannot|can't|never)\s+apply\b"`
  — the negation knows only `<aux> not`, the contractions and `never` + `apply`; no `no ... apply` form. Matches the plan's claim.
- `:707` -> `_spl_review_go_owner_go() {`; `:764` -> `  why="$(_spl_review_go_owner_go "$abrief" "$holder")" ||` — rule [4] and its call site. Match.
- `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh:1128` -> `# --- 28. an owner-go keyword in a prohibition section (SPL-5915) ---...` — case 28 sits there, so a new case 29 goes after it. Match.
- `csi-spl-doc/specs/157-dispatch-automation/spec.md:259` -> the owner-go scan bullet naming the negated forms "(`does not apply`, `never apply`)". Match.

b44-02 (`csi-spl-api/src/go/spool-hub-api`):

- `cmd/spool/hub.go:1216` -> `func (o inviteMailOpts) send(ctx context.Context, st *store.Postgres, tenant, email string) (invitemail.Result, error) {`;
  `:1226` -> `log := logging.New(&config.Config{LogLevel: "info", LogFormat: "json"}).With().Str("component", "cli").Logger()`;
  `:1227` -> `return invitemail.Send(ctx, invitemail.Deps{Store: st, Sender: mc.Sender(log), Delivers: mc.Delivers(), Log: log,`;
  `:1230` -> `}`. The `component=cli` logger handed to `mc.Sender(log)` — matches.
- `cmd/spool/hub.go:155-163` -> the b42-01 repeated-key rule comment ("zerolog appends a repeated key and Cloud Logging joins the values ... SPL-6340") above `func hubLogger(...)` at `:163`. Match.
- The other `Sender(log)` callers with the base logger: `:309` (enableNativeSignIn call), `:368`/`:378` (marketing/invoice mailers), `:618` (`Sender: mc.Sender(log)` in EnableNative), `:645` (`Mail: pmc.Sender(log)`), `:677` (`sender := pmc.Sender(log)`). Match.
- `internal/mail/config.go:129-130` -> `case TransportLog:` / `return Log{Logger: log.With().Str("component", "mail").Logger()}`. Match.
- `internal/mail/mail.go:338-339` -> the `mail.log_sink` line (`...Str("message_id", msg.MessageID).Msg("mail.log_sink")`). Match.
- `cmd/spool/hub_log_keys_test.go:45` -> `func TestHubLogKeysOnce(t *testing.T) {`. Match.

Re-count of the "17 of 600" on this box (<box2>; sat's 6771 briefs are not readable
here): `grep -lis '\bapply\b' /var/spool-hub/dispatch/briefs/*.md | wc -l` ->
`321` briefs hold the word; running `_spl_review_go_owner_go` from
`387370a79`'s file over each with an empty `SPOOL_ROOT` (so an `Owner-go:` line
also counts as held, as the plan did) -> `293` held rc 1; with the section 4.1
fix-shape applied to the copy -> `7` freed. All 7 freed briefs read at their
`apply` line (n=7 >= 3), every one a prohibition:

- `20261007-c001-c7b6e8db-wildcard-cert-spec.md:3` — "Doc only: no terraform apply, no gcloud mutation."
- `c002-070-alert-severity-agy-reviewer.md:1` — title "(agy, review only, no edits, no apply)".
- `c002-inc1022-failover-standby-guard.md:24` — under `## Rules`: "prd is READ-ONLY for you: no restart, no apply, no DB write."
- `c002-inc1022-prove-db-tier.md:9` — "No tier change and no terraform apply in this lane."
- `c002-inc1022-slow-view-queries.md:24` and `c002-inc1022-view-time-limit.md:24` — same "no apply" Rules line.
- `c002-s166-b7-fixed-clocks.md:15` — under `## Do`: "NEVER run terraform or the role against a box (no apply; ...)" — exactly the b44-01 shape.

## Check 3 — red controls, extracted, hashed, run

Both scripts extracted from the plan's sections 4.1 / 4.2 fenced blocks:

- `sha256sum rc01-b44.sh` -> `7c49d340d3266b4d4bea86e61d0ebbed31f3a41ba67b886a202c875edb607fce` (2174 B) — first 12 hex `7c49d340d326`, matches the plan.
- `sha256sum rc02-b44.sh` -> `c9edfd3e4e79d0e1747db544ea7f4ccfe63801485e8ab08db277135042878486` (2552 B) — first 12 hex `c9edfd3e4e79`, matches the plan.

Runs from the worktree on `387370a79` (2026-11-24T09:2xZ..09:3xZ):

- `bash rc01-b44.sh 387370a79` -> `the author brief names owner-go keyword 'apply' and has no Owner-go: line` (x2) / `rc01 'no terraform apply' -> rc 1 (want 0); 'NO terraform plan or apply' -> rc 1 (want 0); 'then apply' -> rc 1 (want 1)` / `rc01 exit 1`, **EXIT=1**.
- `bash rc01-b44.sh 387370a79 fix-shape` -> `rc01 fix-shape: 'no [w [w [w]]] apply' is negated` / `rc01 'no terraform apply' -> rc 0 (want 0); 'NO terraform plan or apply' -> rc 0 (want 0); 'then apply' -> rc 1 (want 1)` / `rc01 exit 0`, **EXIT=0** — the true positive ("Then apply the migration to prd.") stays held rc 1 under the fix shape.
- `bash rc02-b44.sh 387370a79` (go1.26.10 at `/usr/local/go/bin/go`) -> `rc02 sites: cli logger 1, Sender(log) in send 1, mail sink component 1` / `rc02_b44_test.go:25: rc02 mail.log_sink repeated=[component] line={"level":"info","component":"cli","component":"mail","template":"invite","locale":"","to":"08168cd80dfd","message_id":"","message":"mail.log_sink"}` / `FAIL` / `rc02 exit 1`, **EXIT=1**.
- `bash rc02-b44.sh 387370a79 fix-shape` -> `rc02 fix-shape: Sender gets the logger without component=cli` / `ok github.com/csitea/csi-spl/spool-hub-api/cmd/spool 0.041s` / `rc02 exit 0`, **EXIT=0**.

Live state: neither script touches the hub, prd, GitHub, the spool or the
checkout. rc01 copies one file out with `git show` into a `mktemp -d` dir and
sources that copy with `SPOOL_ROOT`/`SPL_STATE_DIR` pointed into the same tmp
dir; rc02 `git archive`s the sha into a `mktemp -d` dir, adds its test file
there only, and runs `go test` in that copy; both `trap rm -rf` the tmp dir.

## Check 4 — the rows

- **b44-01: keep.** Fix scope is narrow and matches the code I read: the
  negation at `spl-review-go.func.sh:672`, its comment `:624-625`, the
  `@description` `:58`, a new test case 29 after `:1128`, and
  `spec.md:259` — no other keyword, no section rule. The red control proves the
  defect (rc01 exit 1 on `387370a79`) and turns green on the fix shape (exit 0)
  while the true positive stays held (rc 1 in both runs, check 3). Gates named:
  `bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` every case, rc01 re-run
  on the fix sha, the 600-brief count re-run with the freed ones each read.
  Batch 1.
- **b44-02: keep.** Fix scope is `send` only (`hub.go:1216-1230`), with
  `internal/mail` unchanged — matches the sites I read (`:1226-1227` vs
  `config.go:129-130`). Red control rc02 exit 1 on `387370a79` with the exact
  repeated-key line, fix-shape exit 0. Gates named: `go test -run 'TestHubLogKeysOnce|<new>' ./cmd/spool/`,
  `go test ./internal/mail/`, the new test red on `387370a79`. Batch 2 after B11
  (R3) — consistent with my lane-map read (check 6): `c-918@sat` is live and
  records no files, so `hub.go` is not free.
- Neither row should be cut or split: 2 rows, within the owner's 1..3 order, each
  with reproduced evidence and a reproduced red control that turns green on the
  fix shape.

## Check 5 — inputs accounted for

- Round 43's plan on origin/master (`csi-spl-doc/doc/md/bug-round-43-plan.md`,
  section 7 "first inputs for round 44", 8 items) — all 8 re-read in the b44
  plan's section 3.5: the `unknown_token` box, the hub dir mode, the hermetic
  2/4 timeout + `monitoring-costs` flake, the composed testids, and the carried
  group (SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`,
  g-162 N2). Every one accounted.
- The plan's "Served" shas spot-checked with `git merge-base --is-ancestor <sha> origin/master`:
  `2f634fbd4`, `656ab3389`, `6f2a343bb`, `8b7828a6b`, `1fadfb77b`, `ae4898ae1`,
  `9b680e7b5`, `48c96fc2b`, `c581dc43d`, `c6e04cff2`, `ef80e6a01`, `1797577cb`,
  `4c5633d84`, `9a1d7b3e2` — all on origin/master.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md` (sections "next BUG
  round" and "Bug-shaped"): **NOT RUN** — the file is sat-only and absent on this
  box (`find /var/spool-hub -name 'c002-next-round-candidates*'` -> nothing;
  `ls /var/spool-hub/dispatch/c002-next-round-candidates.md` -> No such file).
  No bug-shaped input I could read on this box is left unserved and unaccounted.

## Check 6 — R3 lane map

`bash /opt/csi/csi-spl-desk-cron/csi-spl-orc/src/bash/features/spawn-agents/scripts/lane-map.sh --check csi-spl-doc/doc/md/bug-round-44-plan.md,csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-api/src/go/spool-hub-api/internal/hub/hub.go,csi-spl-api/src/go/spool-hub-api/internal/mail/config.go --agent m-718`
-> **exit 4**: `unknown: a-025@sat a-025-c002-refactor-round-96-planner`,
`c-032@sat c-032-c003-bug-round-44-planner`, `c-918@sat c-918-c002-s181-b11-signin-relay`,
`c-980@sat c-980-c002-spl5070-nuxt4-migration-r2` — all four record no files, so
their scope is unknown, not free (ask first). `c-918@sat` among them matches the
plan's R3: `hub.go` sits in its live B11 worktree, so row 02 waits for B11.

## Check 7 — distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` ->
`ok - literal OS user / box / AD id`, `ok - personal home directory`,
`allowed - owner mail address or domain: 6 line(s) = the owner-approved gcp_account_owner_email key in csi-spl-cnf`,
`ok - owner mail address or domain`, `ok - hidden workspace or private literal (SPL-1874)`,
`ok - retired relay estate (SPL-1910)`, `ok - no tracked .vibe/ dir`,
`INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-718`,
**exit 0**.

## Defects

None. **W: none.**

## Notes

- N1: the plan's sat-side counts (600 of 6771 briefs, 39 `cron.out` lines, the
  candidates file, the planner's brief) are not re-runnable on this box; my
  <box2>-side recount is 321 briefs with `apply`, 293 held, 7 freed by the fix
  shape, all 7 read as prohibitions (check 2). `/var/csi/csi-spl/review-go/cron.out`
  on this box holds 1 `owner-go keyword 'apply'` line.
- N2: lane-map answers exit 4, not 3: the four live lanes record no files, so
  their scope is `unknown:`, not free — consistent with the plan's R3 note that
  an `unknown:` answer is not free until the holder re-runs `--check` at placement.
- N3: rc02 ran with go1.26.10 (`/usr/local/go/bin/go`), warm cache, about 1 s per
  run; no tool was missing, nothing installed.
- N4: the plan was measured on `387370a79`; `origin/master` has 3 docs-only
  commits on top (specs 186/191 + specs README), no row file moved
  (`git diff --stat 387370a79..origin/master` -> 3 files, all under
  `csi-spl-doc/specs/`).
- N5: the plan's own slug-proof grep on sat named only the planner's brief; on
  this box only this seat's brief matches the b44 slug (check 1).

The verdict stands: **PASS, 2 rows, on `dafdceeb26bb14b59c489405928d6f3c3f8b99a3` (v0.1).**
