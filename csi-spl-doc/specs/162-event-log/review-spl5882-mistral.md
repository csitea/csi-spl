# Review SPL-5882: spec 162 section 10, backend errors into the System log (mistral)

Reviewer: m-520@sat (mistral, cross-vendor, read-only; no code written). Reviewed
sha: `358a9cf4b76c33e6245bc4b3cbec6f2c0563707b` on branch
`review/c002-spl5882-backend-errors-event-log-spec`. All code citations below were
checked on `04ca1d897` (origin/master at review time) with
`git show 04ca1d897:<file> | sed -n <N>p`; every spec line cited was checked the
same way on `358a9cf4b`. Each check names the command and what it printed.

## Verdict

**PASS** on `358a9cf4b76c33e6245bc4b3cbec6f2c0563707b`. No defect (W) found. Notes
N1-N4 at the end.

## The sha, verified

- `git ls-remote origin 'review/c002-spl5882*'` printed
  `358a9cf4b76c33e6245bc4b3cbec6f2c0563707b\trefs/heads/review/c002-spl5882-backend-errors-event-log-spec`
  (matches the brief; the mistral review branch did not exist yet).
- `git log --oneline -3 358a9cf4b` printed head
  `358a9cf4b docs(spec-162, SPL-5882): section 10, backend errors into the System log`
  on `04ca1d897`; `git merge-base --is-ancestor 04ca1d897 358a9cf4b` exited 0.
- `git diff --stat 04ca1d897 358a9cf4b` printed
  `csi-spl-doc/specs/162-event-log/spec.md | 468 ++++...`, `1 file changed, 468 insertions(+)`.
- `git show 358a9cf4b:csi-spl-doc/specs/162-event-log/spec.md | wc -l` -> `862`;
  `sed -n '400p'` -> `## 10. Backend errors into the System log (v1.1-draft, SPL-5882)`;
  `sed -n '7,9p'` -> the `v1.1-draft (2026-11-18)` note. Section 10 = lines 400-862,
  the note = lines 7-9, as the brief says.

## Check 1: the owner's ask is fully covered

Spec 10.1 (lines 402-433) quotes all six owner msgs of t1 topic `bfd5af01`; I compared
them with the author brief's verbatim quotes: identical, except `e05d9c00` (spec line
412) where the second box name is replaced by `[main]` and the replacement is noted
inline. Coverage:

| ask | where the spec covers it |
|---|---|
| `0b7c9534` trap backend errors from STDERR/Cloud Run into the same EventLog | two sources: (a) in-process rows at the moment they happen (10.3 lines 486-511, 10.4.2 lines 540-582); (b) the box reader takes what dies with the process from Cloud Logging (10.4.3 lines 583-620, rules 10.4.4 lines 643-661) |
| `58c65b39` bug lanes scan entries, create issues, start work | 10.7 lines 746-774: `do_spl_evlog_groups` as the bug round plan's sixth source (line 755), one issue per group deduped by fingerprint, link both ways, reopen on regrowth |
| `f6b251db` / `d0e0085f` errorless, like google | 10.8 lines 775-791: measurable targets M1-M4, each read by a named command |
| `e05d9c00` hub owns panics/crashes; component on the sat box, portable to the other box | 10.4.3 lines 583-620: box component, cron row in `box-crons.manifest`, boxes/interval/envs from cnf `env.box.evlog_reader`, nothing pinned to a box; C40 (line 810) tests the move |
| `6ddfaa91` cron, hourly | 10.4.3 line 596: `env.box.evlog_reader.interval_min` = 60 |
| author brief: read from where the last run stopped, no window missed or read twice; per-env SA; write through the hub API; two boxes never double-write | 10.4.4 lines 621-642: cursor CAS (`gen` + `from` checked in one transaction, stale gen -> 409 `cursor_moved`, line 638); per-env project SA key with `--account` and throwaway `CLOUDSDK_CONFIG` via `do_gcp_pin_account` (lines 602-606); one `evlog` frame to the hub (lines 624-633) |

The dispatcher's plan (msg `a6609004`) is followed; the one difference is stated in
10.1 lines 415-421: no terraform log sink by default (the `_Default` bucket already
holds the lines), a terraform grant is option B of Q1 (line 843). Nothing in the
owner's ask is dropped.

## Check 2: every cited code file:line exists on 04ca1d897 and says what the spec claims

Sampled 30 citations (brief asks for at least 10). Command form for each:
`git show 04ca1d897:<file> | sed -n <N>p` (ranges: `sed -n '<A>,<B>p'`). All printed
what the spec claims:

| citation | printed |
|---|---|
| `hub/server.go:888` | `func (s *Server) middleware(next http.Handler) http.Handler {` |
| `hub/server.go:897` | `defer func() {` (the `recover()` at 898; panic before header -> `writeErrCause(sw, 500, "internal", ...)` at 899-901; `sw.status >= 500 \|\| rec != nil` -> `logServerError` at 902-904) |
| `hub/server.go:906-907` | the `http` access line: `request_id`, `method`, `path`, `host`, `status`, `dur` |
| `hub/server.go:913-916` | logServerError doc: "never the query string, a header, the body or a token (Constitution VII)" |
| `hub/server.go:917` | `func (s *Server) logServerError(r *http.Request, rid string, sw *statusWriter, rec any) {` |
| `hub/server.go:935` | `}` (end of logServerError; body 917-935 logs `route` = `r.Pattern`, `token`/`detail`/`site`, `err`, messages `handler panic` / `http 5xx`) |
| `hub/server.go:871` | `type statusWriter struct {` (fields `status`, `token, detail, site`, `err` at 871-879) |
| `hub/server.go:834` | `func noteCause(w http.ResponseWriter, token, detail string, err error) {` (sets `sw.site` via `runtime.Caller(2)`) |
| `hub/server.go:815` / `:824` | `func writeErr(...)` / `func writeErrCause(...)` (both call `noteCause` when status >= 500) |
| `hub/supervise.go:39` | `func supervise(ctx context.Context, log zerolog.Logger, name string, run func(context.Context), lo, hi time.Duration, now func() time.Time) int {` |
| `hub/supervise.go:52-53` | `log.Error().Str("loop", name).Str("panic", ...).Str("stack", stack).` / `.Msg(LoopPanicMsg)` |
| `hub/supervise.go:25` | `const LoopPanicMsg = "hub loop panicked; restarting"` |
| `hub/supervise.go:68` | `func runOnce(ctx context.Context, run func(context.Context)) (rec any, stack string) {` (the `recover()`, ends :76) |
| `cmd/spool/hub.go:142` | `srv.LogHubStarted(ctx) // spec 162 3.3: each start shows in the System log` |
| `cmd/spool/hub.go:144`, `:156`, `:355` | three `go hub.Supervise(ctx, log, "<loop>", ...)` lines |
| `internal/logging/logging.go:27`, `:31`, `:48` | `return newTo(cfg, os.Stderr)`; `func newTo(cfg *config.Config, w io.Writer) zerolog.Logger {`; `var severities = map[zerolog.Level][]byte{` (severityWriter at :62-79, JSON when deployed per the header comment at :3) |
| `csi-spl-cnf/csi-spl/all.env.yaml:401` | `log_bucket: _Default` |
| `store/log_events.go:32-54` | the kinds const block: `lease.*`, `hub.started`, workspace kinds; `grep -c "error\."` over lines 56-80 -> `0` (no error kind, as the spec claims); `LogEventKinds` at :57, pinned by `TestLogEventKinds` (`log_events_test.go:22`) |
| `hub/box_lease.go:144` / `:169-180` | `func (s *Server) logLeaseHandover(...)` / `func (s *Server) LogHubStarted(ctx context.Context) {` |
| `hub/log_events.go:49-53` | `routeLogEvents`: `GET /v1/operator/events` at :52, `POST /v1/operator/events/delete` at :53 (routes live, as claimed); `:182` `handleSystemEvents` |
| `hub/ws.go:183` | `case wire.TLease: // CLE-77911: the fleet-wide lease, compare-and-set` (dispatched to `onLease`, `box_lease.go:49-67`) |
| `csi-spl-iac/src/bash/run/gcp-003-configure-proj-sa-permissions.func.sh:34` | `local member="serviceAccount:${sa_email}" role="roles/owner"` |
| `csi-spl-iac/src/terraform/030-cloud-run-hub/03-runtime-sa.tf` | exists; `grep -in logging` over it -> no lines (the runtime SA has no logging read, as claimed) |
| `csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh:251` | `do_gcp_pin_account() {`; used by `spl-db-query.func.sh:31` |
| `store/log_events_postgres.go:46-47` | `pgSystemEventTrim = DELETE FROM system_events WHERE id <= (SELECT id FROM system_events ORDER BY id DESC OFFSET $1 LIMIT 1)`; `SystemEventsKeep = 10000` (`log_events.go:23`); the page select at :148-149 is `ORDER BY id DESC LIMIT $2` (newest-first by id, as claimed) |
| `csi-spl-rdb/.../0240_workspace_system_events.sql:41,55` | `kind ... CHECK (kind ~ '^[a-z]+(\.[a-z_]+)+$' ...)`; `message ... CHECK (length(message) <= 800)`; RLS only on `workspace_events` (:66-71), none on `system_events` (hub-wide, as claimed) |
| `internal/wire/wire.go:70` | `TLease = "lease"`; `internal/config/config.go:445-452` `OperatorTenant` (the operator-workspace concept the frame check uses) |

Counts, run myself:

- `git grep -n "Log.Error()" 04ca1d897 -- 'csi-spl-api/src/go/spool-hub-api/internal/hub/*.go' | grep -v _test | wc -l` -> `493` (also 493 via `git archive` + the spec's own `grep -n "Log.Error()" internal/hub/*.go | grep -v _test | wc -l`). Matches the spec's 493 (10.2 lines 453-455).
- `git grep -n "operator/events" 04ca1d897 -- csi-spl-wui/src | wc -l` -> `0` (the System scope is not built, as claimed, 10.2 lines 472-473).

Files the build rows name, all exist on 04ca1d897 (`git ls-tree` / `git grep -l`):
`csi-spl-orc/cnf/box-crons/box-crons.manifest`, `csi-spl-orc/src/bash/run/install-box-crons.func.sh`,
`csi-spl-orc/src/bash/scripts/cron-no-stack.sh`, `csi-spl-orc/src/bash/run/rdb-migration-next.func.sh`
(`do_rdb_migration_next`), `.github/workflows/20_hub-build-deploy.yml`,
`csi-spl-wui/src/pages/monitoring/events/index.vue`, `csi-spl-wui/src/utils/event-sheet.mjs`,
`csi-spl-api/.../internal/hub/openapi.json`, `csi-spl-api/.../cmd/spool/cli_verbs_test.go`,
cnf `hub.service_name` (`csi-spl-cnf/csi-spl/dev.env.yaml:261` -> `service_name: csi-spl-hub-dev`).
Doc claims: spec 169 T13c (`csi-spl-doc/specs/169-channel-workspace-move/spec.md:907`):
"dev read 2026-11-07: two sinks, `_Default` 30 days, the hub's `requests` and `stderr`
lines there; prd not read" — matches 10.2 line 460. The bug round plan's section 2 with
five sources: `csi-spl-doc/doc/md/bug-round-11-plan.md:11` ("same shape, same 5 sources")
and :32-34 (the source table); rulebook 3.1 (`rounds-rulebook.md:192-199`) is the plan
document requirements. Spec 162's own R2 (`spec.md:361`, box CLI rollout) is what T7's
"after" cites.

## Check 3: design soundness

- **Two boxes never double-write** (10.4.4 lines 635-642): the `put` is a
  compare-and-set in one transaction — `gen` = stored gen and `from` = stored
  `read_until`, then the cursor moves to `to` with `gen + 1` and the groups upsert;
  a stale gen answers 409 `cursor_moved` and writes nothing (line 638); the losing
  box prints `SKIP` and exits 0. C35/C40 (lines 803, 808) pin it, red control included.
  The spec's own note is correct: the fingerprint upsert alone would add both boxes'
  counts (line 641). Sound.
- **Upsert `id = DEFAULT` vs the keep-by-id trim** (10.5 lines 691-701): the trim is
  `DELETE ... WHERE id <= (id of the (SystemEventsKeep+1)th newest)` with
  `SystemEventsKeep = 10000` (verified above), so a firing group that gets a new id
  via `id = DEFAULT` is never trimmed while firing; a trimmed group that fires again
  reopens with `n = 1` and the bug lane finds its old issue by the fingerprint line.
  Sound, contingent on C34 (line 802): whether PostgreSQL 16
  takes `SET id = DEFAULT` on a `GENERATED ALWAYS` identity in `ON CONFLICT DO UPDATE`
  is checked on Postgres first, with a delete+re-insert fallback in the same
  transaction (lines 699-701). See N2.
- **Redaction before any row leaves a box** (10.4.4 line 626: "Raw lines never leave
  the box"; 10.6 lines 721-744: `evlog.Redact` applied on every text that reaches a row
  and on the `put` frame before it leaves the box, plus a never-read list — body,
  headers but `X-Cloud-Trace-Context`, query string, URL path). C29/C30/C38 (lines
  797-798, 806) test it with red controls. Sound.
- **`evlog` frame restricted to operator-workspace boxes** (10.4.4 lines 630-633:
  `x.tenant` = `operatorTenant`, else 403 `operator.workspaces`; `OperatorTenant`
  verified at `config.go:445-452`; C36 at line 804). Sound.

## Check 4: build rows T1-T9 (10.10 lines 812-838)

Each row is small, names only its files, has an `after` column and cases with a red
control; the order T1 -> T2 -> (T3, T4) -> (T6, T8, T5) -> T7 -> T9 is stated at lines
830-832. The migration is named, not written: `rdb/<next>_system_events_error_groups.sql`
with the number taken by `do_rdb_migration_next` at build time (line 675; the action
exists, verified above). Line 835: "No row runs terraform, writes IAM or changes GCP
under option A of Q1. Option B adds one row before T7 ... applied only on the owner's
go." Matches the brief's judge.

## Check 5: open questions Q1-Q4 (10.11 lines 839-846)

Each is a real owner decision with a proposed A and a B, answerable A/B from the
table alone: Q1 who reads Cloud Logging (A: the per-env project SA, `roles/owner`
holds the read — verified at gcp-003:34; B: a `roles/logging.viewer` SA via a
terraform step on the owner's go); Q2 whether a new dev error group after a deploy
holds the prd deploy; Q3 which groups get an issue; Q4 System log only vs also the
Mine log. Risks R4-R7 (lines 848-862) state what is unmeasured (R5 Cloud Run strings,
R6 today's 5xx/panic rates) and that T7 reads them on dev first, read-only.

## Check 6: repo rules

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` on the review tree (worktree at
  358a9cf4b) printed `INFO distribution-hygiene: clean over the tracked tree of
  /opt/csi/csi-spl-wt/m-520` (all sweeps `ok`; only the owner-approved cnf keys
  allowed). No literal host beyond the cnf: `spool-hub.ai` is `BASE_DOMAIN`
  (`csi-spl-cnf/csi-spl/all.env.yaml:12`) and appears only inside the verbatim owner
  quote at spec line 408. The sweep's OS-user/box ban list
  (`.github/workflows/10_ci-quality.yml:1811`, six banned literals) does not include
  `sat`, and `c-002@sat` already exists on master (`spec.md:372` on
  04ca1d897) — see N1.
- Every infra step is a named action: `do_spl_evlog_read`, `do_spl_evlog_groups`,
  `do_spl_evlog_link`, the cron row installed by `do_install_box_crons` under
  `cron-no-stack.sh`; terraform only under Q1 B on the owner's go (line 835).
- Service accounts only, per env: 10.4.3 lines 602-606 — per-env project SA key
  `$HOME/.gcp/.csi/key-csi-spl-<env>.json`, throwaway `CLOUDSDK_CONFIG`, `--account`
  on the call, through `do_gcp_pin_account` (verified at
  `gcp-account-pin.func.sh:251`); a box without the key exits 3 and sends nothing.

## Defects

None. No W1..: every judge above passes on the sha read.

## Notes

- N1 (spec line 412): the `e05d9c00` quote keeps the literal box name `sat` while the
  second box name is replaced by `[main]`. The enforced gate
  (`do_check_dist_hygiene`, run above) is green and `sat` is not on its ban list, and
  `c-002@sat` already exists on master at `spec.md:372`, so this is not a gate
  failure — but the quote is internally inconsistent about hygiene.
- N2 (spec lines 699-701): the upsert's `SET id = DEFAULT` on a `GENERATED ALWAYS`
  identity in `ON CONFLICT DO UPDATE` is a real PostgreSQL behaviour question; the
  spec defers it to C34 on Postgres with a delete+re-insert fallback, which is the
  honest way to carry it. Not a defect.
- N3 (spec lines 643-661, R5): the Cloud Run log strings the classify rules match
  (OOM, exit, probe, split panic dumps) are from documented behaviour, not read on
  this tree; T7's dry run on dev records the fixtures before the rules are fixed.
  Stated as a risk, not hidden.
- N4 (spec lines 415-421): the one stated difference from the dispatcher's plan
  (a6609004) — no terraform log sink by default, the `_Default` bucket already holds
  the hub's lines (cnf `hub.log_bucket: _Default`, verified at `all.env.yaml:401`);
  a terraform grant is Q1 option B. Stated, not silent.
