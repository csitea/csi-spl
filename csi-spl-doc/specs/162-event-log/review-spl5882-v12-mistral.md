# Review SPL-5882: spec 162 section 10 v1.2, the owner's poll answers folded in (mistral)

Reviewer: m-566@sat (mistral, cross-vendor, read-only; no code written). Reviewed
sha: `fd25054cbef4fb4e0545f44c7a33d239cb81a266` on branch
`review/c002-spl5882-spec-v12`, diff base `bc559b2f6` (verified on origin/master).
Every spec line cited below was checked with
`git show fd25054cb:csi-spl-doc/specs/162-event-log/spec.md | sed -n <N>p`; every
code citation was checked on `bc559b2f6` with
`git show bc559b2f6:<file> | sed -n <N>p`. Each check names the command and what
it printed.

## Verdict

**PASS** on `fd25054cbef4fb4e0545f44c7a33d239cb81a266`. No defect (W) found.
Notes N1-N4 at the end.

## The sha, verified

- `git ls-remote origin 'review/c002-spl5882*'` printed
  `fd25054cbef4fb4e0545f44c7a33d239cb81a266\trefs/heads/review/c002-spl5882-spec-v12`
  (matches the brief) and
  `9b114f15e9a0d6034cb44de889119266090f8575\trefs/heads/review/c002-spl5882-spec-mistral-review`
  (the earlier v1.1 verdict); `review/c002-spl5882-v12-mistral-review` did not
  exist yet.
- `git log --oneline bc559b2f6..fd25054cb` printed one commit:
  `fd25054cb docs(spec-162, SPL-5882): section 10 v1.2, the owner's answers to poll 00d28227`.
- `git merge-base --is-ancestor bc559b2f6 origin/master` exited 0 (the base is on
  origin/master).
- `git diff --stat bc559b2f6 fd25054cb` printed
  `csi-spl-doc/specs/162-event-log/spec.md | 220 +++...`, `1 file changed, 173 insertions(+), 47 deletions(-)`.

## Check 1: each answer Q1-Q4 is folded in faithfully and completely

- Spec line 422 (10.1) quotes msg `4dda13ce`'s answer text verbatim; it matches
  the brief's quote word for word ("Answer 1: B — A new read-only service
  account, granted by a terraform step on your go, plus one more key per env /
  Answer 2: A — The step turns red and says so; prd still deploys / Answer 3: A
  — Every error group / Answer 4: B — Also in the Mine log of the person whose
  request failed").
- 10.11 (lines 950-960): line 953 prints `No question is open.`; the table maps
  Q1 B -> "10.4.3 the identity; row T7a; C45-C47" (line 957), Q2 A -> "10.8 M3;
  row T9" (958), Q3 A -> "10.7, 10.8" (959), Q4 B -> "10.4.2 the person and the
  Mine copy; 10.5 `human_id`; 10.6; C43, C44" (960) — the author's map, exactly.
- Each answer's substance is present at the named place, checked line by line:
  - Q1 B: 10.4.3 lines 669-683 — new SA `<cnf env.gcp.evlog_reader_sa_id>@...`
    with one role `roles/logging.viewer`, made by terraform step
    `071-gcp-evlog-reader-sa` (row T7a, line 933), key
    `$HOME/.gcp/.csi/key-csi-spl-<env>-evlog-reader.json` minted out of band by
    `do_gcp_evlog_reader_key`, one per env per reader box.
  - Q2 A: line 877 (M3) prints "It never holds prd (Q2 A): its own job, which no
    prd job `needs`"; T9 row (line 936) prints "one job, no prd job `needs` it".
  - Q3 A: 10.8 prints "Q3 A: every error group gets an issue (10.7), whatever
    its count or env"; 10.7 files one issue per new group.
  - Q4 B: 10.4.2 lines 619-645 (the person and the Mine copy), 10.5 line 759
    (`human_id text ... CHECK ^(HUM-[0-9]+)?$`), 10.6 (Mine display), cases
    C43/C44.
- No answer is bent or dropped; 10.11 has no open question left.

## Check 2: Q1 B against the repo rules (CLAUDE.md)

- Step number free: `git ls-tree --name-only origin/master csi-spl-iac/src/terraform/ | sort`
  printed `... 060-gcp-vm-satellite 061-gcp-vm-wine-box 070-gcp-monitoring
  120-github-general-secrets ...`; `... | grep -c '^071'` -> `0`.
  `git grep -in 'logging.viewer\|evlog' origin/master -- csi-spl-iac/src/terraform/ | wc -l`
  -> `0` (no existing reader SA or grant).
- Action name free: `git grep -c 'do_gcp_evlog_reader_key' origin/master | wc -l`
  -> `0`; `git grep -c '071-gcp-evlog-reader-sa' origin/master | wc -l` -> `0`;
  `git grep -c 'evlog_reader_sa_id' origin/master -- csi-spl-cnf | wc -l` -> `0`.
- Named action / terraform step only, on the owner's go, dev first: T7a row
  (line 933) prints "**apply only on the owner's go, dev first, then prd** (dev
  leads prd); the key minted on each reader box only on the owner's go too (a
  key is a GCP change)"; the closing paragraph of 10.10 prints "Only T7a changes
  GCP ... each on the owner's go ... The lane plans and runs the tests; the apply
  and the mint are sent to the owner as the exact commands and wait for the go."
- No key in git, terraform state or a log: C46 (line 933's cases) pins that step
  `071-gcp-evlog-reader-sa` declares one `google_service_account` and one
  `google_project_iam_member` with role `roles/logging.viewer`, and **no**
  `google_service_account_key` (red control: a planted key resource fails it);
  C47 pins the key written only to
  `$HOME/.gcp/.<org>/key-csi-spl-<env>-evlog-reader.json`, mode 600, never to
  stdout or a log. The one billing-SA exception (step `002-gcp-billing-sa`, repo
  CLAUDE.md) is not extended: the step declares no key resource at all. See N1.
- `--account` on every gcloud call: 10.4.3 lines 678-683 print "its
  `client_email` in a throwaway `CLOUDSDK_CONFIG`, `--account` on the call. No
  owner account, no write to the shared gcloud config"; C39/C45/C47 pin it.
  Verified on bc559b2f6: `gcp-account-pin.func.sh:251` prints
  `do_gcp_pin_account() {`; `:106-111` shows `do_gcp_sa_key_file` honours
  `GCP_SA_KEY_FILE`.
- No fallback to the project SA or the owner account: lines 680-683 print
  "**no fallback to the per-env project service account**: a box without the
  reader key exits 3 with one line naming the missing key and sends nothing
  (C39, C45)"; C45's red control is a reader that falls back to the default key
  and calls gcloud as the project SA.

## Check 3: Q4 B, and whether R8 is a real risk or a defect

- Person id from the session cookie with no store read on the error path:
  10.4.2 lines 619-624 — new `auth.Handler.HumanFromCookie(r) string`: "the
  signature and expiry check of `SessionFromRequest` without the revocation
  read, so the error path never reads the store". Verified on bc559b2f6:
  `auth/handler.go:1614-1631` shows `SessionFromRequest` does `openToken(...)`
  (signature + expiry) and then `h.revoked.dead(...)` (the store read); dropping
  the latter leaves no store read. C44 tests it with a store whose every call
  fails.
- One Mine row per (person, fingerprint) per flush, capped: 10.4.2 lines 632-645
  — one row per (person, fingerprint) touched since the last flush, ` (x<n>)`
  when hit more than once, cap at most 1000 pairs (line 641), at most 20 Mine
  rows per person per flush (lines 642-643), the 500-row trim kept. C43's red
  control: a flush writing one row per sighting writes 100.
- No personal data in a row that leaves its workspace: 10.6 — the Mine row is
  visible only to that person; `human_id` reaches only operator admins (System)
  and that person (Mine); a message shows a person only as `HUM-<n>`, an agent
  as `<agent>`.
- R8 (line 977): two Mine rows per failed request (the WUI's `source: 'api'`
  and the hub's `source: 'hub'`) is a **real behaviour**, and the spec documents
  it as deliberate: joining them needs a request id the WUI journal does not
  record today, and a Mine row lost in a database outage stays lost while the
  group count survives through reader rule 1. Judgement: a real, acknowledged
  limitation, not a defect — the two rows carry different information (what the
  page saw vs the hub's cause), and C43/C44 pin the hub side.

## Check 4: cited code file:lines exist on bc559b2f6 and say what the spec claims

Sampled 20 citations (brief asks for at least 8, including
`do_gh_secret_put_gcp_key` and `auth.Handler`). Command form:
`git show bc559b2f6:<file> | sed -n '<N>p'` (ranges `'<A>,<B>p'`). All printed
what the spec claims:

| citation | printed |
|---|---|
| `auth/handler.go:1614-1631` | `func (h *Handler) SessionFromRequest(...)`: cookie, `openToken` (signature+expiry), then `h.revoked.dead(...)` (store read) |
| `hub/events.go:93-100` | `eventsHuman` reads the person via `s.o.Auth.SessionFromRequest(r)` |
| `hub/server.go:888-911` | `middleware`: `defer` with `recover()`, `sw.status >= 500 \|\| rec != nil` -> `logServerError`, access line at 906-907, comment at 913-916 "never the query string, a header, the body or a token (Constitution VII)" |
| `hub/server.go:897` | `defer func() { rec := recover(); ... writeErrCause(sw, 500, "internal", ...) ... }` |
| `hub/server.go:917-935` | `func (s *Server) logServerError(...)`: `route := r.Pattern`, `token`/`detail`/`site`, `err`, messages `handler panic` / `http 5xx` |
| `hub/server.go:871-879` | `type statusWriter struct { ... token, detail, site string; err error }` |
| `hub/server.go:834` / `:815` / `:824` | `func noteCause(...)`, `func writeErr(...)`, `func writeErrCause(...)` (both call `noteCause` when status >= 500) |
| `hub/supervise.go:25` / `:39-64` / `:68-76` | `const LoopPanicMsg = "hub loop panicked; restarting"`; `supervise` logs `loop`/`panic`/`stack` with `.Msg(LoopPanicMsg)` at 52-53; `runOnce` has the `recover()` + `debug.Stack()` |
| `cmd/spool/hub.go:142` / `:144-149` / `:156-159` / `:355` | `srv.LogHubStarted(ctx)`; the `go hub.Supervise(ctx, log, "<loop>", ...)` lines |
| `internal/logging/logging.go:31-42` / `:48-79` | `newTo`: JSON to the writer when deployed; `severities` map puts `{"severity":"ERROR",` on error lines (severityWriter) |
| `csi-spl-cnf/csi-spl/all.env.yaml:401` | `log_bucket: _Default` |
| `store/log_events.go:32-54` | the kinds const block: `lease.*`, `hub.started`, workspace kinds; no `error.*` kind (as the spec claims); `LogEventKinds` at :57, pinned by `TestLogEventKinds` (`log_events_test.go:20`) |
| `hub/box_lease.go:49-67` / `:144` / `:169-180` | `onLease` (msg_id pairing, tenant from the session); `logLeaseHandover`; `LogHubStarted` writes `hub.started` |
| `hub/log_events.go:49-53` / `:182-203` | routes live: `GET /v1/operator/events` at :52, `POST /v1/operator/events/delete` at :53; `handleSystemEvents` with `operatorActor` |
| `hub/ws.go:183` | `case wire.TLease: // CLE-77911: the fleet-wide lease, compare-and-set` |
| `csi-spl-iac/.../gcp-003-configure-proj-sa-permissions.func.sh:34` | `local member="serviceAccount:${sa_email}" role="roles/owner"` |
| `csi-spl-iac/src/terraform/030-cloud-run-hub/03-runtime-sa.tf` | exists; `grep -in logging` over it -> 0 lines (no logging read, as claimed) |
| `csi-spl-orc/lib/bash/funcs/gcp-account-pin.func.sh:106-111` / `:251` | `do_gcp_sa_key_file` honours `GCP_SA_KEY_FILE`; `do_gcp_pin_account() {` |
| `csi-spl-iac/.../gcp-sa-key-rotate.func.sh` | exists (the per-env key rotation the spec cites for R9) |
| `csi-spl-iac/.../gh-secret-put-gcp-key.func.sh:37` / `:64` | line 37: `[[ "$email" == "$PROJ_ID@$PROJ_ID.iam.gserviceaccount.com" ]] ||` (today only the project SA's key is accepted — the spec's claim); line 64: `gh_secret_put_gcp_key_name() { printf 'GCP_KEY_%s\n' ... }` (name `GCP_KEY_<PROJECT>`) |
| `rdb/0045_human_events.sql:22-38` | `human_id ... NOT NULL REFERENCES humans`, `kind ... CHECK (kind IN ('error'))`, `source <= 80`, `origin <= 120`, `code <= 120`, `message <= 800` |
| `store/human_events.go:18` | `const HumanEventsKeep = 500` |
| `rdb/0240_workspace_system_events.sql:41` / `:44` | `kind ... CHECK (kind ~ '^[a-z]+(\.[a-z_]+)+$' ...)`; `message ... CHECK (length(message) <= 800)` |
| `wui/composables/errorJournal.mjs:340-391` | the journal's status derivation and `source: redactText(input.source, 80)` (the WUI's failed-API-call row) |

Counts, run myself on bc559b2f6:

- `git grep -n "Log.Error()" bc559b2f6 -- 'csi-spl-api/src/go/spool-hub-api/internal/hub/*.go' | grep -v _test | wc -l`
  -> `493` (matches the spec's 493).
- `git grep -n "operator/events" bc559b2f6 -- csi-spl-wui/src | wc -l` -> `0`
  (the System scope is not built, as claimed).

Files the build rows name, all exist on bc559b2f6 (`git ls-tree` / `git grep`):
`csi-spl-orc/cnf/box-crons/box-crons.manifest`,
`csi-spl-orc/src/bash/scripts/cron-no-stack.sh`,
`csi-spl-orc/src/bash/run/install-box-crons.func.sh`,
`csi-spl-orc/src/bash/run/rdb-migration-next.func.sh`,
`.github/workflows/20_hub-build-deploy.yml`,
`csi-spl-doc/doc/md/rounds-rulebook.md:192` (`### 3.1 Plan document requirements`),
`csi-spl-doc/doc/md/bug-round-11-plan.md:11` ("same shape, same 5 sources") with
its source table at :32-34, `internal/config/config.go:445-452`
(`OperatorTenant`), `internal/wire/wire.go:70` (`TLease = "lease"`).
Doc claims: spec 169 row T13c exists on origin/master
(`csi-spl-doc/specs/169-channel-workspace-move/spec.md`, the `hub.log_bucket`
retention row) — matches 10.2.

## Check 5: build rows T7a / T9, and sections 1-9 unchanged

- T7a is small and ordered before T7: the 10.10 table lists row T7a at line 933,
  row T7 at line 935; T7a is one SA + one role + one key action + one cnf key,
  with cases C46, C47 and red C46 ("a planted `google_service_account_key`
  resource fails it"). The order paragraph after the table prints "T7a shares no
  file with T1-T6 and runs beside them; it must be applied before T7 starts."
- T9's `GCP_SA_KEY_KIND=evlog-reader` change is named: 10.8 lines 884-888 (the CI
  secret `GCP_KEY_CSI_SPL_DEV_EVLOG_READER` put by `do_gh_secret_put_gcp_key`;
  "row T9 adds `GCP_SA_KEY_KIND=evlog-reader`, which expects the reader SA's
  email instead and appends `_EVLOG_READER` to the name") and the T9 row at
  line 936. Verified the action today accepts only the project SA key
  (`gh-secret-put-gcp-key.func.sh:37`) and derives `GCP_KEY_<PROJECT>` (:64), so
  the change is needed and is named.
- Sections 1-9 unchanged: `git diff bc559b2f6 fd25054cb -- csi-spl-doc/specs/162-event-log/spec.md | grep '^-' | grep -v '^---'`
  lists only the `## 10. ...` header line (old line 400, v1.1-draft -> v1.2-draft)
  and section-10 lines; the only hunk before section 10 is the version preamble
  `@@ -8,6 +8,14 @@`, which adds the v1.2-draft note (new lines 11-17) and removes
  nothing. No hunk modifies a line of sections 1-9.

## Check 6: repo rules on the head

- A throwaway worktree at the head (`git worktree add --detach /tmp/m566-head fd25054cb`,
  removed after): `cd /tmp/m566-head/csi-spl-iac && ./run -a do_check_dist_hygiene`
  printed `INFO distribution-hygiene: clean over the tracked tree of /tmp/m566-head`
  — every sweep `ok`, the only `allowed` lines being the owner-approved cnf keys
  (gcp_account_owner_email, box_owner_user / box_agent_user).
- Added lines of the diff grep'd for box names, OS users, home dirs, personal
  names and literal hosts:
  `git diff bc559b2f6 fd25054cb -- <spec> | grep '^+' | grep -inE '\b(<box1>|<box2>)\b|spool-hub\.ai|@csitea|/home/|iam\.gserviceaccount'`
  (the two box-name literals of the pattern I ran are written `<box1>|<box2>`
  here so this file itself stays green under the hygiene gate)
  -> one line: the SA email template
  `` `<cnf env.gcp.evlog_reader_sa_id>@csi-spl-<env>.iam.gserviceaccount.com` ``
  (a placeholder with `<env>`, not a literal host). `spool-hub.ai` appears only
  in the unchanged verbatim owner quote (a context line; it is `BASE_DOMAIN`,
  `all.env.yaml:12`). See N2 for the `sat` literal in that quote.

## Defects

None. No W1..: every judge above passes on the sha read.

## Notes

- N1 (10.4.3 / T7a line 933): the spec enforces "no key in git, terraform state
  or a log" through C46 (no `google_service_account_key` resource; red control
  plants one) and C47 (key only to `$HOME/.gcp/.<org>/...`, mode 600, never
  stdout or a log), but never states in words that the one billing-SA exception
  (step `002-gcp-billing-sa`, repo CLAUDE.md) does not extend to the reader key.
  The tests cover it; one sentence would make it explicit.
- N2 (10.1 line 420): the `e05d9c00` quote keeps the literal box name `sat`
  while the second box name is replaced by `[main]` — carried unchanged from
  v1.1 (m-520's N1). The gate is green and `sat` is not on its ban list, but the
  quote is internally inconsistent about hygiene. The new v1.2 text avoids the
  literal ("the satellite box", line 663).
- N3 (10.8 line 877, M3): the post-deploy step's "wait 10 min" is a fixed wait
  in a CI job, not a test nap (developer guide 2.12.6 governs tests); the build
  lane may replace it with a bounded poll on the reader cursor. Not a defect.
- N4 (10.11 R5 line 965, R6 line 970): the Cloud Run log strings the classify
  rules match and today's 5xx/panic rates are unmeasured on this tree; T7's
  read-only dry run on dev records the fixtures before the rules are fixed.
  Stated as risks, not hidden.
