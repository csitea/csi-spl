# Bug-fix round 44 - plan (2 rows)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6359 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `efebede5-b84b-4992-94cb-e2bbbe27857f` ("Bug round 44", opened by c-003@sat 08:49Z). Round 43 ([bug-round-43-plan.md](bug-round-43-plan.md)) served its one row (b43-01 `c581dc43d`, SPL-6350) and is closed (`387370a79`).  
Round focus: the sources of rounds 40 to 43 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W, owner posts), round 43's first inputs, and the holder's candidate list (`c002-next-round-candidates.md`, the bug sections).  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. Two candidates met the bar (section 3).  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-43-plan.md](bug-round-43-plan.md).

**Status: v0.1, signed: m-718 (mistral) PASS on v0.1 `dafdceeb2`, W none; holder GO (c-002@sat, msg 02175a35) on `dafdceeb2`, landed `acb1ca5d8`.** **Closed**: both rows landed, b44-01 `14b6055c2` (SPL-6369) and b44-02 `158664186` (SPL-6388), b44-02 served on dev and prd (section 8).

Editor: **c-032@sat** (claude, `specs_and_docs`).  
Panel: placed by the holder (rulebook 3.2).

**One sha:** every count below is measured on **`387370a79`** (`origin/master` at this seat's fetch, 2026-11-24T08:57Z: round 43's close record), on sat, 08:57Z..09:09Z on 2026-11-24, unless a line says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b43-plan')` read at 08:57:40Z -> `Window: W=2026-11-24T10:56:35+02:00` (commit `387370a79`, the last b43 plan commit). The sources are read since round 43's own W (`2026-11-24T02:03:55+02:00`, `c23d5019c`), as the brief asks; round 43 read them up to 06:2xZ, so the new part is 06:2xZ..09:0xZ.

---

## 1. How to read this

- Since round 43's W, `origin/master` took 29 commits (`git log origin/master --since=2026-11-24T02:03:55+02:00 --oneline | wc -l` -> 29); since round 43's reads (`c4000b25b`): b43's plan, row and close, refactor round 95 (plan, r95-01, r95-02, close), SPL-6341 (spec 181 B13, 4 commits), the nuxt osv-scanner ignore renewal, SPL-5006 W3.
- `<box2>` is the fleet's box that is not sat, `<ws>` one customer workspace and `<box3>` one of its boxes, as in rounds 21 to 43: the public repo names none of them.
- **Paths** are repo-relative; `<api>` is `csi-spl-api/src/go/spool-hub-api`. Line numbers are as of `387370a79`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red controls are scripts printed in section 4. Each copies the named sha's files out with `git show` or `git archive` into a `mktemp -d` dir, changes that copy only, and changes nothing in the checkout.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs). This seat's own reads added 2 statement errors to the prd log after source 1 was read (a `;` refused by the action before it ran, then `relation "topics" does not exist` at 08:59Z): the shape of source 1's SQL lines.
- A correction to round 43's close record (`387370a79`, written by this seat): its `git ls-remote origin` read is dated "09:0xZ"; it ran at 08:5xZ. Not re-committed there (that commit was one file, one record).

---

## 2. Where rows could come from (measured since W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (08:57:55Z) | 21 entries, 03:08Z..08:56Z: 17 Cloud SQL statement errors as the hub's runtime user (`column ... does not exist` x11 for `created_at`, `id`, `p.id`, `sender`, `from_agent`, `key`, `source`, `parent_id`; `uuid ~~ unknown` x5; `invalid input syntax for type uuid: "281449e1"` x1); the 4 Cloud Run lines of the 03:55Z hub roll round 43 read | **0 rows.** The SQL lines are hand-written reads with wrong column names or a short id, the shape rounds 41 to 43 traced to seats' `do_spl_db_query`. The roll burst: round 43 section 2 source 1; no repeat. |
| **2. prd alert incidents** | `cd csi-spl-iac && ENV=prd SINCE=6h ./run -a do_gcp_list_alert_incidents` (08:58Z) | 9 policies, 0 incidents in 02:58:01Z..08:58:01Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | round 43's `do_spl_db_query` SELECT on `issues` (`'bug' = any(labels)`, open statuses) (08:58:08Z) | 7 issues: round 43's 6 (SPL-5911, 5254, 5104, 4994, 4934, 4849) and SPL-6356 (wip, 08:17Z, the phone Back fix) | **0 rows.** SPL-6356 is the live lane c-680@`<box2>` (R3); each other is its lane's or the holder's. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (08:57Z..09:0xZ, background) | 100 runs, 2026-11-23T07:45Z..2026-11-24T08:45Z: 81 success, 10 cancelled, 7 failure, 2 running; every job's p90 under 75 % of its timeout (highest: hermetic 1/4, 59 %); the newest failure is run 45328560134 (04:45Z), round 43's row; every job last green in 45355019786 (`c581dc43`, 08:18Z) | **0 rows.** No failure after round 43's read. The 7: section 3.3. |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 60` (09:00Z), filtered to `createdAt` after round 43's W | 1 failed run, 45328560134, and it is wf 10 (source 4) | **0 rows.** |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=6h LINES=3000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (08:58:32Z; cap not reached, the full 6 h read) | 654 entries: 390 `upload token refused` (`unknown_token`), 237 `ws hello refused` (`unpinned_box`, `<ws>`, `<box3>`), 6 `github: request refused` (404), 6 `export.pdf` 403 (2 topics x 3, box CLI, 07:14Z), 3 `release-notes/<sha>` 404 (browser), 1 `view/issues/SPL-5232` 404, 1 `view/netvisor/forecast` 404, 1 `gcal: grant revoked`, 1 `db.schema_head`, scanner probes and single 404s | **0 rows**, section 3.4. |
| **7. R7 notes of lanes landed since round 43's read** | the reviewers' and authors' messages in the sat spool (`c-001`, `c-002`, `c-003` dirs, files newer than 06:20Z, bodies with `PASS`/`FAIL` and an `N<n>`/`W<n>`) | g-658 PASS r95-01 (N1..N3), g-663 PASS r95-02 (N1), m-969 PASS r95 plan v0.1 and v1.0 (N1..N3), g-675 PASS b43-01 (N1, N2), g-666 PASS SPL-5006 W3 (no note); 0 W | **0 rows**: every note is a wording, a sha of a comment-only change or a box-local read. |
| **8. Owner and member posts** | `ENV=prd SQL="select from_id, count(*), ... from messages where tenant_id='t1' and from_id like 'HUM-%' and accepted_at > '2026-11-24T00:03:55Z' group by 1" ./run -a do_spl_db_query` (09:01Z) | 0 rows | **0 rows.** |
| **9. Round 43's first inputs** | round 43 section 7, re-run | 8 items | **0 rows**: section 3.5. |
| **10. The holder's candidate list** | `/var/spool-hub/dispatch/c002-next-round-candidates.md` (131 lines, read 09:00Z), its bug-shaped items; each cited site's fix commits since 2026-11-17 (`git log origin/master --since=2026-11-17 -- <site>`) | 2 items re-measured as live and row-shaped, the rest accounted in section 3.6 | **Rows b44-01 and b44-02.** |

---

## 3. The candidates, read

### 3.1 b44-01: the review-go owner-go scan holds a brief whose only `apply` is a prohibition ("no terraform apply")

- **What happens.** `do_spl_review_go`'s rule [4] (`_spl_review_go_owner_go`, `csi-spl-orc/src/bash/run/spl-review-go.func.sh:707-740`, called at `:764`) refuses rc 4 when the author brief's instruction text names an owner-go keyword (`apply`, ...) and has no `Owner-go:` line. The instruction text (`_spl_review_go_instr`, `:636-675`) drops narrative and prohibition sections (SPL-5670, SPL-5915) and a negated `apply`, but the negation regex (`:672`) knows only `<aux> not apply`, `don't`/`won't`/`cannot`/... and `never apply`. A prohibition written the briefs' usual way, inside a Do or Steps list, is a keyword: "No GCP mutation, no prd write, no terraform apply." (spec 181 B7's brief, line 32, under `## Do`) and "Run NO terraform plan or apply" (an R7 reviewer brief, under a numbered step).
- **Candidate list's reading, corrected.** The item (c-001@sat 00:1xZ, n=2) names line 41 of the B7 brief; on `387370a79` line 41 sits under `## Never` and is already dropped (SPL-5915). The keyword the scan keeps is line 32's (`_spl_review_go_instr` on that brief, `grep -n -i apply` -> line 32 only).
- **Measured.** Over the dispatch briefs of sat that hold the word (`grep -lis '\bapply\b'` -> 600 of 6771 readable): rule [4] holds 521 of them on `387370a79` with no `Owner-go:` found (this run's spool is empty, so a brief with an `Owner-go:` line also counts as held); with the fix shape of section 4.1 (the negation also takes `no` + up to 3 words + `apply`), 504; the **17 freed** were each read at their `apply`: every one a prohibition (`no terraform apply` in 7 spec 181 row briefs, `no apply`, `No terraform plan or apply`, `no box apply`, `run no terraform and no apply`, `No tier change and no terraform apply`). 0 of the 504 still held was read (n=17 read, not the 504).
- **Harm.** Each such brief's PASS waits for the holder's hand GO (a grep of the brief, then a manual GO). `grep -c "owner-go keyword 'apply'" /var/csi/csi-spl/review-go/cron.out` -> 39 (the whole log, sat, not split by cause); today's two (r95-02's msg 4fa121d5, SPL-5006 W3's 2bc520ca) are not this defect: r95-02's brief uses `apply` as a noun ("repo-variable apply tail", section 3.6) and W3's says "plan then apply" (a real apply step).
- **Red control** (`rc01-b44.sh`, section 4.1): on `387370a79`, two fixture briefs whose only `apply` is a prohibition (`## Do` "no terraform apply"; `## Steps` "Run NO terraform plan or apply") -> rc 1 each (want 0), the true positive (`## Do` "Then apply the migration to prd.") -> rc 1; `rc01 exit 1`. **Control**: `fix-shape` -> rc 0, 0, 1; `rc01 exit 0`.
- **Fix scope.** `csi-spl-orc/src/bash/run/spl-review-go.func.sh` (`_spl_review_go_instr`'s negation at `:672`, its comment `:624-625`, the `@description` at `:58`) and `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (a new case 29 after case 28 at `:1128`: the two prohibitions above -> GO; controls that still hold rc 4: "then apply", "apply the migration to prd", "do not skip, apply step 053" if the lane's form reaches it). The fix shape is the shape, not the fix: the lane picks the form (a bounded `no ... apply` is one), and proves on the 600 briefs that it frees only prohibitions (the 17 read above, or its own count, each read). Docs: `csi-spl-doc/specs/157-dispatch-automation/spec.md:259` names the negated forms (`does not apply`, `never apply`): the same commit adds the new one.

### 3.2 b44-02: the CLI invite with the log transport writes `component` twice on `mail.log_sink`

- **What happens.** `inviteMailOpts.send` (`<api>/cmd/spool/hub.go:1216-1230`) builds its logger with `component=cli` (`:1226`) and hands that logger to `mc.Sender(log)` (`:1227`). With `Transport: log`, `mail.Config.Sender` returns `Log{Logger: log.With().Str("component", "mail").Logger()}` (`<api>/internal/mail/config.go:129-130`), so the `mail.log_sink` line (`<api>/internal/mail/mail.go:338-339`) carries `component` twice: zerolog appends a repeated key, and Cloud Logging joins the values (the b42-01 rule, `<api>/cmd/spool/hub.go:155-163`, test `TestHubLogKeysOnce`, `<api>/cmd/spool/hub_log_keys_test.go:45`).
- **Seen.** b42-01's R7 g-403@`<box2>` N1 (on `f471409c7`, read only, n=0 runs), confirmed by its author c-381 (6953b051), left out of b42-01 by the holder (eca6c78a) and carried to round 43 (c-003@sat 41640875), which did not account it. Re-measured here on `387370a79`: the three site lines are unchanged (`grep -c` 1 each, section 4.2), and the test of section 4.2 prints the line `{"level":"info","component":"cli","component":"mail","template":"invite",...,"message":"mail.log_sink"}`.
- **Only the CLI path.** Every other `Sender(log)` caller hands it a logger with no `component`: the hub's `operatorMailer` (`hub.go:688-700`, `Sender(log)` with the base logger, `component=invitemail` only on `Deps.Log`), `baseOptions`' marketing and vendor-key mailers (`hub.go:368-378` pass the base `log`), `enableNativeSignIn` (`:618`), `wirePayments` (`:645`, `Sender(log)`, not its `plog`) and `inviteMailer` (`:677`), each called with the base hub logger (`hub.go:309-374`). The hub test (`TestHubLogKeysOnce`'s `invite-mailer` case) covers the hub path, not `send`.
- **Harm.** Low: the CLI's own log line, and the log transport is a non-SMTP sink. One key per line is the rule b42-01 set; this is the one path it missed.
- **Red control** (`rc02-b44.sh`, section 4.2): on `387370a79`, a grep proves the three site shapes (`cli logger 1, Sender(log) in send 1, mail sink component 1`), then a test in the extracted copy builds the sender as `send`'s two lines do and checks the `mail.log_sink` line with `repeatedKeys` -> `rc02 mail.log_sink repeated=[component]`, `rc02 exit 1`. **Control**: `fix-shape` (Sender gets the logger without `component=cli`) -> `ok`, `rc02 exit 0`. The test copies the two lines' shape: `send` itself needs a `*store.Postgres`. The lane's test calls the code it changes (e.g. the logger pair built in one named helper that `send` calls), not a copy.
- **Fix scope.** `<api>/cmd/spool/hub.go` (`send`, `:1216-1230`: hand `mc.Sender` a logger without `component=cli`, keep `component=cli` on `Deps.Log`; or name that pair in a helper) and a test in `<api>/cmd/spool/` (a case in `hub_log_keys_test.go`, or its own file) that fails on `387370a79`. Not `<api>/internal/mail/config.go`: the hub's mail lines keep `component=mail`. `Docs: none` unless the lane finds a doc that names this line (`grep -rn 'mail.log_sink' csi-spl-doc` -> spec 006 and 021 task proofs only, which quote hub lines).
- **Placement: after B11.** `hub.go` is changed in c-918@sat's live worktree (spec 181 B11, SPL-6345, hunks at `:448` and `:1382`, not the row's lines): R3 holds the row until B11 lands (section 5).

### 3.3 CI reds in the 100 runs, read

| run | job | first red line | why not a row |
|---|---|---|---|
| 45328560134 (04:45Z, `c5fa1ded`) | hub gofmt/vet/test | `--- FAIL: TestKeyDeskOnListensWithIdentity` | **Served**: b43-01 `c581dc43d`. |
| 45244623103, 45197570926 (11-23 19:02Z, 14:45Z) | iac tfvars parity | `FAIL: download iframe ... "Invoices" page` | Fixed before round 43 (`c6e04cff2`, SPL-6333), round 43 section 3.2. |
| 45223415636, 45220059471, 45217594068 (11-23 16:32Z..17:03Z) | orc hermetic 4/4 | `an orc check skipped in CI` | Fixed (`ef80e6a01`, SPL-5985), round 42 section 3.2. |
| 45220059471 (11-23 16:45Z) | orc hermetic 2/4 | `exceeded the maximum execution time of 30m0s` | Still 1 sighting in 100 runs; p90 56 % of its timeout. Carried (2.11.3). |
| 45208818805 (11-23 15:45Z) | hub gofmt/vet/test | `TestContactsSyncLogsNoValues` | Fixed (`1797577cb`, SPL-6324), round 42 section 3.2. |

The `monitoring-costs` e2e flake (round 43: run 45124937982, 11-23 06:33Z) is out of these 100 runs: 0 sightings now.

### 3.4 The prd WARNING lines, read

| candidate | read | why not a row |
|---|---|---|
| `upload token refused`, 390 in 6 h (round 43: 379) | `reason=unknown_token` | **Not a row**, round 43 section 3.3: one box keeps a token no hub process minted; which box is the holder's box question (round 43 section 6), unanswered in the files this seat read. |
| `ws hello refused`, 237 in 6 h (round 43: 450) | `unpinned_box`, `<ws>`, `<box3>` | **Not a row**: refused as designed (round 43 section 3.3). |
| `export.pdf` 403, 6 (2 topics x 3, box CLI, 07:14Z) | the shape rounds 41 and 42 read (a seat exporting another workspace's topic) | **Not a row**: as round 42 section 3.3. Three 403s per topic in the same second; whether the CLI retries a 403 was not read. |
| `release-notes/<sha>` 404, 3 (browser) | `c058d292c` = tag `v3.5.6-c4`, `743f68e90` = `v3.0.8-c4`, `9de071fa0` = `v3.0.9-c4` (`git ls-remote --tags origin`), referers a customer workspace and the csitea workspace | **Not a row**: round 42 section 3.3 (SPL-6274's design: a link preview reads the workspace's own notes). Carried. |
| `view/issues/SPL-5232` 404, 1 | SPL-5232 is `done` and archived (`do_spl_db_query`, 08:59Z) | **Not a row**: an archived issue's view. |
| `view/netvisor/forecast` 404, 1 | round 42 section 3.3 | **Not a row**: the Finance probe's answer. |
| `github: request refused` 404, 6; `db.schema_head` 1; `gcal: grant revoked` 1 | as round 43 | **Not a row.** |

### 3.5 Round 43's first inputs, re-read

| candidate | result | why not a row |
|---|---|---|
| The `unknown_token` box | source 6: 390, one shape | **Carried** with the holder (box question). |
| The hub dir mode (`.hub` 0775 less the umask when `writeAtomic` makes it first; `keydesk.go:172` says "0700 dir") | `git grep -n '0700 dir' origin/master -- <api>/internal/keydesk/keydesk.go` -> 1 line | **Not a row**: no exposure (round 43 section 3.1); a hardening or comment input for a refactor round. Carried. |
| The hermetic 2/4 timeout, the `monitoring-costs` flake | 1 and 0 sightings in 100 runs | **Carried** (2.11.3). |
| The composed testids | `git log origin/master --since=2026-11-24T02:03:55+02:00 -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh \| wc -l` -> 0 | **Not a row**: a gate-design input with the holder. |
| SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`, g-162 N2 | not re-measured here (round 43 section 3.4 read them on `c4000b25b`) | **Carried.** |

### 3.6 The holder's candidate list, read

Each item's cited site was checked for a fix commit since 2026-11-17 (`git log --since=2026-11-17 origin/master -- <site>`, 09:02Z). "Served" names the commit.

| item (list section) | result |
|---|---|
| review-go rule [4] false HOLD on a prohibition (00:1xZ) | **Row b44-01** (section 3.1; the line it cites corrected). |
| CLI `mail.log_sink` `component` twice (22:3xZ, b42-01 N1) | **Row b44-02** (section 3.2). |
| review-go GO retried to a retired author (11-19 08:0xZ); false "found locally only" (11-20 07:3xZ) | **Served**: b20-01 `2f634fbd4` ("holds a send to a retired author once instead of retrying every minute"), b27-01 `656ab3389` ("a landed sha says on origin/master"). |
| placer `After:` reads the wrong box's key (11-21 01:1xZ); review notice bare `Author:` (11-21 01:2xZ); notice names only `review/` (11-21 02:1xZ); panel seat UI swap (11-20 06:2xZ); ci row first (11-20 22:1xZ) | **Served**: b30-03 `6f2a343bb`, b31-01 `8b7828a6b`, b32-02 `1fadfb77b`, b29-02 `ae4898ae1`, b30-01 `9b680e7b5`. |
| `ws-docs-head.mjs` synthetic clicks (11-21 01:2xZ) | **Served**: `48c96fc2b` (SPL-6115). |
| topic loop hourly cap race (11-20 22:1xZ) | **Not a row now**: `topic_loop_fire.go` changed since (`4c5633d84`, `9a1d7b3e2`); the race is unproven on `387370a79` (no control run). A 3rd round candidate, with a two-fires test first. |
| store tests need a fresh DB (11-23 21:4xZ) | **Not a row**: CI green on every hub-pg run (source 4); a reused-DB test-hygiene input for a test round. |
| false SILENT gap (11-23 23:4xZ), the per-seat report rewritten (11-23 22:5xZ) | **Not a row**: cause unchecked in the list, n=1 each; no re-measure here. Carried. |
| lease vendor order reverts (11-21), kept weekly quota (11-20), `unanswered-sweep.tst.sh` user-dependent (11-20) | **Not a row**: n=1 each, "not re-measured" in the list; not re-measured here. Carried. |
| `spl-customer-box-role-check` ban-list limits N1..N4 (11-21) | **Not a row**: a ban list cannot prove absence (its header says so); a hardening input. Carried. |
| r95-02's noun `apply` (this round, source 7 and section 3.1) | **Not a row**: a keyword used as a noun ("repo-variable apply tail") holds rc 4; a different defect from b44-01's, n=1, and the scan cannot tell a noun from a verb without a rule the panel has not seen. Carried as a 4th candidate (rulebook 5.1: the first row of a later round, if it repeats). |
| the rest (refactor-, perf-, docs- or i18n-shaped: the e2e selector, the entry-chunk headroom, `ro.json` topic word, the gct rule's scope, SPL-6174's link, AltGr pick) | **Not bug rows**: their kinds are named in the list. |

---

## 4. Red controls, as run

### 4.1 `rc01-b44.sh` (b44-01), sha256 first 12 hex `7c49d340d326`, 2174 B

Run from any checkout: `bash rc01-b44.sh 387370a79` (exit 1), then `bash rc01-b44.sh 387370a79 fix-shape` (exit 0). Under 1 s.

```bash
#!/usr/bin/env bash
# rc01-b44.sh <sha> [fix-shape]: b44-01 red control. On <sha>'s tree, the
# review-go owner-go scan (_spl_review_go_owner_go, rule [4]) must pass a
# brief whose only `apply` is a prohibition in a Do step ("no terraform
# apply", spec 181 B7 brief line 32) and must still hold a brief that
# says to apply. The action file is copied out of <sha> with git show into a
# mktemp dir; nothing in the checkout changes. fix-shape also adds a "no ...
# apply" form to the copy's negation regex (the shape, not the fix).
set -uo pipefail
sha="${1:?usage: rc01-b44.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
git -C "$repo" show "$sha:csi-spl-orc/src/bash/run/spl-review-go.func.sh" >"$tmp/rg.sh" || exit 2
if [ "${2:-}" = fix-shape ]; then
  python3 - "$tmp/rg.sh" <<'PY' || exit 2
import sys
p = sys.argv[1]; s = open(p).read()
old = "|never)\\s+apply\\b\""
new = "|never|no(?:\\s+[\\w-]+){0,3})\\s+apply\\b\""
assert s.count(old) == 1, "fix-shape: neg regex not found once"
open(p, "w").write(s.replace(old, new))
PY
  echo "rc01 fix-shape: 'no [w [w [w]]] apply' is negated"
fi
printf '%s\n' '# Lane brief' '## Do' '3. Gates for the trees you touch. No GCP mutation, no prd write, no terraform apply.' >"$tmp/neg.md"
printf '%s\n' '# Lane brief' '## Steps' '5. Hygiene. Run NO terraform plan or apply, nothing against dev, prd or GCP.' >"$tmp/neg2.md"
printf '%s\n' '# Lane brief' '## Do' '3. Then apply the migration to prd.' >"$tmp/pos.md"
rc=0
SPOOL_ROOT="$tmp" SPL_STATE_DIR="$tmp" bash -c 'source "$1"; _spl_review_go_owner_go "$2" c-000' _ "$tmp/rg.sh" "$tmp/neg.md"; n=$?
SPOOL_ROOT="$tmp" SPL_STATE_DIR="$tmp" bash -c 'source "$1"; _spl_review_go_owner_go "$2" c-000' _ "$tmp/rg.sh" "$tmp/neg2.md"; n2=$?
SPOOL_ROOT="$tmp" SPL_STATE_DIR="$tmp" bash -c 'source "$1"; _spl_review_go_owner_go "$2" c-000' _ "$tmp/rg.sh" "$tmp/pos.md" >/dev/null; p=$?
echo "rc01 'no terraform apply' -> rc $n (want 0); 'NO terraform plan or apply' -> rc $n2 (want 0); 'then apply' -> rc $p (want 1)"
[ "$n" = 0 ] || rc=1
[ "$n2" = 0 ] || rc=1
[ "$p" = 1 ] || rc=1
echo "rc01 exit $rc"
exit "$rc"
```

Output on `387370a79` (sat, 09:07Z):

| run | output |
|---|---|
| `bash rc01-b44.sh 387370a79` | `the author brief names owner-go keyword 'apply' and has no Owner-go: line` (x2) / `rc01 'no terraform apply' -> rc 1 (want 0); 'NO terraform plan or apply' -> rc 1 (want 0); 'then apply' -> rc 1 (want 1)` / `rc01 exit 1` |
| `bash rc01-b44.sh 387370a79 fix-shape` | `rc01 fix-shape: 'no [w [w [w]]] apply' is negated` / `rc01 'no terraform apply' -> rc 0 (want 0); 'NO terraform plan or apply' -> rc 0 (want 0); 'then apply' -> rc 1 (want 1)` / `rc01 exit 0` |

### 4.2 `rc02-b44.sh` (b44-02), sha256 first 12 hex `c9edfd3e4e79`, 2552 B

Run from any checkout: `bash rc02-b44.sh 387370a79` (exit 1), then `bash rc02-b44.sh 387370a79 fix-shape` (exit 0). About 1 s with a warm Go cache.

```bash
#!/usr/bin/env bash
# rc02-b44.sh <sha> [fix-shape]: b44-02 red control. On <sha>'s tree, the
# CLI invite-mail path (cmd/spool/hub.go inviteMailOpts.send) builds its
# logger with component=cli and hands it to mail.Config.Sender, whose log
# sink adds component=mail (internal/mail/config.go): the mail.log_sink line
# must carry each key once (the b42-01 rule, repeatedKeys). The tree is
# extracted with git archive into a mktemp dir; a test is added there only.
# The test builds the sender the way send's two lines do (a copy of their
# shape: send itself needs a Postgres store), after a grep proves the two
# sites still hold those shapes. fix-shape hands Sender the logger without
# component=cli (the shape, not the fix).
set -uo pipefail
sha="${1:?usage: rc02-b44.sh <sha> [fix-shape]}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
a=$(grep -c 'With().Str("component", "cli").Logger()' "$d/cmd/spool/hub.go")
b=$(grep -c 'Store: st, Sender: mc.Sender(log)' "$d/cmd/spool/hub.go")
c=$(grep -c 'Log{Logger: log.With().Str("component", "mail").Logger()}' "$d/internal/mail/config.go")
echo "rc02 sites: cli logger $a, Sender(log) in send $b, mail sink component $c"
[ "$a$b$c" = 111 ] || { echo "rc02 sites moved: re-read them"; exit 2; }
from='log := base.With().Str("component", "cli").Logger()'
sender='s := (&mail.Config{Transport: mail.TransportLog}).Sender(log)'
[ "${2:-}" = fix-shape ] && sender='s := (&mail.Config{Transport: mail.TransportLog}).Sender(base)' && echo "rc02 fix-shape: Sender gets the logger without component=cli"
cat >"$d/cmd/spool/rc02_b44_test.go" <<GO
package main

import (
	"bytes"
	"context"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

func TestRC02CLIInviteLogKeysOnce(t *testing.T) {
	var buf bytes.Buffer
	base := zerolog.New(&buf)
	$from
	_ = log
	$sender
	if err := s.Send(context.Background(), mail.Message{Template: "invite", To: "a@example.com"}); err != nil {
		t.Fatal(err)
	}
	line := strings.TrimSpace(buf.String())
	if r := repeatedKeys(t, line); len(r) > 0 {
		t.Fatalf("rc02 mail.log_sink repeated=%v line=%s", r, line)
	}
}
GO
cd "$d" && go test -count=1 -run '^TestRC02CLIInviteLogKeysOnce$' ./cmd/spool/ 2>&1 | tail -4
rc=${PIPESTATUS[0]}
echo "rc02 exit $rc"
exit "$rc"
```

Output on `387370a79` (sat, 09:05Z):

| run | output |
|---|---|
| `bash rc02-b44.sh 387370a79` | `rc02 sites: cli logger 1, Sender(log) in send 1, mail sink component 1` / `rc02_b44_test.go:25: rc02 mail.log_sink repeated=[component] line={"level":"info","component":"cli","component":"mail","template":"invite","locale":"","to":"08168cd80dfd","message_id":"","message":"mail.log_sink"}` / `FAIL` / `rc02 exit 1` |
| `bash rc02-b44.sh 387370a79 fix-shape` | `rc02 fix-shape: Sender gets the logger without component=cli` / `ok github.com/csitea/csi-spl/spool-hub-api/cmd/spool 0.085s` / `rc02 exit 0` |

---

## 5. Rows

| # | id | practice | sites (file:line on `387370a79`) | evidence | red control (fails on `387370a79`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b44-01-orc-review-go-no-apply-negated` | a prohibition is not an instruction | `csi-spl-orc/src/bash/run/spl-review-go.func.sh:672` (the negation), `:624-625` and `:58` (its words); `csi-spl-orc/src/bash/tests/spl-review-go.tst.sh` (new case 29 after `:1128`); `csi-spl-doc/specs/157-dispatch-automation/spec.md:259` | 17 of 600 briefs held only by a prohibition (section 3.1); spec 181 B3, B7, B9, B11, B12, B13 briefs among them | `bash rc01-b44.sh 387370a79` -> `rc01 exit 1`; control `fix-shape` -> `rc01 exit 0` | **`bash csi-spl-orc/src/bash/tests/spl-review-go.tst.sh`** (every case, 24 to 28 included); `bash rc01-b44.sh <fix sha>` -> exit 0 unchanged (its regex patch then finds nothing: the lane runs it without `fix-shape`); the 600-brief count re-run, the freed ones read | section 3.1: the negation only; no other keyword, no section rule | where the holder places it (`do_spl_box_pick` held at 09:04Z, both kinds) | claude | the claude waiver seat (1a7c70da) | `simple_coding` | 1 |
| 02 | `b44-02-api-cli-invite-log-component-once` | a log line carries each key once | `<api>/cmd/spool/hub.go:1216-1230` (`:1226`, `:1227`); read only: `<api>/internal/mail/config.go:129-130`, `<api>/internal/mail/mail.go:338-339`; a test in `<api>/cmd/spool/` | b42-01 R7 g-403 N1, confirmed c-381; the line of section 4.2 | `bash rc02-b44.sh 387370a79` -> `rc02 exit 1`; control `fix-shape` -> `rc02 exit 0` | `go test -count=1 -run 'TestHubLogKeysOnce\|<the new test>' ./cmd/spool/`; `go test -count=1 ./internal/mail/`; the new test red on `387370a79` (its body shows it) | section 3.2: `send` only; `internal/mail` unchanged | as row 01 | claude | the claude waiver seat (1a7c70da) | `simple_coding` | 2 (after B11, R3) |

- **R1:** the two rows share no file. Row 01 is batch 1. Row 02 is batch 2 only because of R3 (B11 holds `hub.go`), not because of row 01; R16's 30 minutes count from B11's landing.
- **R3** (09:03:47Z): `lane-map.sh --check csi-spl-orc/src/bash/run/spl-review-go.func.sh,csi-spl-orc/src/bash/tests/spl-review-go.tst.sh,<api>/cmd/spool/hub.go,<api>/internal/mail/config.go,<api>/cmd/spool/hub_log_keys_test.go,csi-spl-doc/doc/md/bug-round-44-plan.md --agent c-032` -> exit 3: `hub.go owned by c-918@sat c-918-c002-s181-b11-signin-relay (changed in its worktree; no files recorded)`; `git -C <c-918 worktree> diff origin/master -- <api>/cmd/spool/hub.go` -> hunks at `:448` and `:1382` only. No other path of either row is listed by a live lane. The queue, `./run -a do_spl_spawn_queue` (09:03:50Z): 6 rows, all `feature` (another workspace's release, specs 186, 153, 187, 149), none on these files. The brief's other live lanes (r96 planner and panel, B9 follow-up, SPL-5006 W3, SPL-5070, the back-button fix, the A2UI evaluation, the seats of other workspaces) list none of these paths. This seat's check of the two plan files at 08:5xZ gave exit 4 with 10 `unknown:` lanes (seats and rotations): **not free until the holder re-runs `--check` at placement** (an `unknown:` answer is not free).
- **R7:** `cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (09:04:35Z) -> `pick=hold reason=no box with a sample is below its overflow mark (200% of its high): queue the lane, spawn nothing`; `BOX_PICK_KIND=claude` the same minute -> the same. Grok is not picked, so per the brief the R7 seat is the claude waiver seat (1a7c70da). If the holder finds a grok seat free at placement, a grok seat is the cross-vendor first choice. No mistral (coding kinds); neither row touches `csi-spl-wui/`.
- **Pushes:** aim 1 each (1.2).
- **Priority 2** (5.4): each row's issue carries `Class: bug`.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| `<api>/cmd/spool/hub.go` | c-918@sat (spec 181 B11, SPL-6345) | live; row 02 waits for its landing. |
| SPL-6356, the phone Back fix | c-680@`<box2>` | live. |
| The `unknown_token` box | the holder, as a box question | carried from round 43. |
| `<ws>`'s unpinned box `<box3>` | the holder, for that workspace's owner | refused as designed. |
| r95-02's noun `apply` held rc 4; this planner's own brief held rc 4 on its line 29 ("SPL-5006 W3 c-978@sat (step 053 apply next)", another lane's state, not a step), the holder's note 294da317 | the holder | a 4th candidate (section 3.6), 2 sightings now. |
| The hermetic 2/4 timeout | the holder, CI trunk-red watch (2.11.3) | 1 sighting. |

---

## 7. Counts

| item | count |
|---|---|
| rows | 2 |
| inputs re-measured | 10 sources; 21 prd error entries (6 h); 654 prd WARNING entries (6 h, 401s left out, cap not reached); 9 alert policies (0 incidents); 7 open bug issues; 100 wf 10 runs (7 failures, 0 after round 43's read); every other workflow: 0 failures since round 43's W; 5 R7 verdicts with notes since 06:20Z; 0 owner posts; round 43's first inputs (8); the holder's list (bug items, section 3.6); `rc01-b44.sh` and `rc02-b44.sh` n=1 each way on `387370a79`; 600 briefs through rule [4] twice |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b44-'` -> 0; `git ls-remote origin 'refs/heads/review/b44-*' 'refs/heads/wip/*b44*' 'refs/heads/*-b44-*' 'refs/heads/*bug-round-44*'` -> nothing (rc 0); `grep -lE '(^\|[^0-9a-f])b44-\|[Bb]ug round 44\|bug-round-44' /var/spool-hub/spawn-remote/briefs/*.md /var/spool-hub/dispatch/briefs/*.md` -> this planner's brief only (sat's briefs only); `git worktree list \| grep -E 'b44\|bug-round-44'` -> this seat's worktree only, 08:57:40Z |
| R7 seat | the claude waiver seat (1a7c70da): `pick=hold` for grok and claude, 09:04Z |
| first inputs for round 45 | the non-instruction `apply` that rule [4] holds (r95-02's noun; this planner's brief line 29, a status of another lane): 2 sightings; the topic loop cap race (with a two-fires test); the store tests' fresh-DB need; the `unknown_token` box; the hub dir mode; the hermetic 2/4 timeout; the composed testids; SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2, `run.sh:797`, g-162 N2 as carried |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-032@sat (claude, `specs_and_docs`).
- **Panel:** placed by the holder (cross-vendor).
- **Row reviewer (R7):** the claude waiver seat, or a grok seat if one is free at placement (section 5).
- **Review history:**
  - 2026-11-24 09:13Z: v0.1 `dafdceeb2`, pushed to `review/c003-bug-round-44-planner`: 2 rows.
  - 2026-11-24 09:42Z: panel m-718@`<box2>` (mistral) **PASS** on `dafdceeb2`, W none (msg 90be0228 to this seat, 47a03093 to the holder; seat file on `review/c003-bug-round-44-mistral-seat` `95cb86fe3`). It re-ran both red controls (exit 1 on `387370a79`, exit 0 with `fix-shape`, `then apply` still rc 1), read every cited line on `387370a79` (all match) and the two script hashes (match). Notes: N1 its `<box2>` recount of rule [4]: 321 briefs with `apply`, 293 held, 7 freed by the fix shape, all 7 prohibitions (this plan's sat count: 600, 521, 17); N2 lane-map exit 4, c-918@sat among the `unknown:` lanes, matching R3 for b44-02; N3 go1.26.10, nothing installed; N4 `origin/master` moved docs-only after `387370a79`, no row file; N5 the slug grep clean on its box. None changes a row.
  - Review line checked: `do_spl_review_line_check` rc 0 on `<box2>` (c-001, msg 641cc7c0, 2 of 2 named commands in the log). `do_spl_review_go` also held rc 4 on `apply` in this planner's brief (line 29, another lane's status): a false positive by the holder's reading (msg 294da317), the 4th candidate of section 3.6.
  - GO: c-002@sat (dispatch holder), msgs 02175a35 and 5881d45a, on `dafdceeb2`; rebased onto `817be0fa2` (the plan file unchanged, `git patch-id --stable` `2f28a5bb71df` on both) and landed as `acb1ca5d8` (`git-fetch-fresh.sh --landed` rc 0).
  - Round closed (c-025@`<box2>`, round 45's editor, for c-032, round 44's editor), no version bump: both rows landed and are served. Read on `origin/master` `64123998a`, 2026-11-24T19:18Z..19:25Z, n=1 per command.
    - **b44-01** `14b6055c2` (SPL-6369, committed 2026-11-24T11:11:13Z, author c-049): R7 g-750@`<box2>` grok
      **PASS** on `8088c0c41` (its spool result to c-001, 10:52:31Z, the only message of task `dispatch-bug-r44` the
      hub tail shows on `<box2>`; the holder's GO is in the sat spool, not read from this box). `git patch-id --stable`
      equal on the reviewed and the landed commit (`34886e037c43`); the trees differ (`f6b2bc835e0f`, `8cb9a680fec0`):
      a rebase onto a newer master. Its body carries `rc01-b44.sh` red on `387370a79` (rc01 exit 1) and green on its
      tree (rc01 exit 0), and case 29 of `spl-review-go.tst.sh` red on `387370a79`'s action, green on its own. Docs in
      the same commit: `csi-spl-doc/specs/157-dispatch-automation/spec.md` (`git diff --stat 14b6055c2^ 14b6055c2` ->
      3 files, 33 insertions, 5 deletions).
    - g-750's notes N1 (its box's brief count: 258 with `apply`, 7 freed, all prohibitions), N2 (an unpunctuated
      "if no errors apply" is stripped; none of the freed briefs has that form) and N3 (31 still-held briefs lost a
      prohibition span and stay held on another keyword) change nothing in the row. N2 is an input for round 45.
    - R5 (tooling): `git merge-base --is-ancestor 14b6055c2 origin/master` rc 0; the box checkouts of `<box2>`
      (the main checkout and the desk checkout, both at `64123998a`) hold it, rc 0. R11: wf 10 on its own sha was
      cancelled (45381942039, superseded); the first completed wf 10 run whose head contains it, 45382520931
      (`7e31ade12`, 11:15:33Z), **success**. `gh run list --commit 14b6055c2`: wf 15, 25, 26, 32, 40, 64, 67 and 21
      success, wf 12 skipped, 0 red.
    - **b44-02** `158664186` (SPL-6388, committed 2026-11-24T17:28:16Z, author c-148): R7 a-166 agy **PASS** on
      `99019024f` (the line in the commit body; the holder's ACCEPTED, c-002@sat 17:56Z, is as the planner brief
      says, not read from this box). `git patch-id --stable` equal on the reviewed and the landed commit
      (`0730c44ba08e`). Its body carries `rc02-b44.sh` red on `387370a79` (`repeated=[component]`, rc02 exit 1) and
      green with `fix-shape`, and the new `TestCLIInviteMailLogKeysOnce` red on the planted old shape, green on its
      tree. `Docs: none` (no doc names that CLI line); 2 files, 58 insertions, 2 deletions.
    - a-166's notes N1 (`rc02-b44.sh` on the fix sha exits 2: its site grep finds `Sender(log)` 0 times once fixed,
      as expected) and N2 (the test builds `zerolog.New`, safe because `logging.New` sets no `component`) change
      nothing in the row.
    - R5 (hub change): `SHA=158664186 ENV=dev ./run -a do_check_deploy_lag` and `ENV=prd` (19:18:43Z) -> hub
      served `c7be3c19`, WUI served `6beb21c8`, "the env serves this commit or a later one", both envs. R11: wf 10 on
      its own sha was cancelled (45449522171); the first completed wf 10 run whose head contains it, 45451195664
      (`c7be3c19c`, 17:40:40Z), **success**. `gh run list --commit 158664186`: wf 15, 20 (hub build + deploy), 25,
      26, 50, 61, 62, 64 success, wf 12 skipped, 0 red.
    - **R8 seat teardown** (rulebook 2.8 step 3), each on the holder's ACCEPTED: the row authors c-049 and c-148, the
      row reviewers g-750@`<box2>` (grok, 1 review: b44-01) and a-166 (agy, 1 review: b44-02), the panel
      m-718@`<box2>` (mistral, 1 review: the PASS on v0.1), the editor c-032@sat. No seat performed zero reviews.
      Branches (R8 step 2, `git ls-remote origin` at 19:2xZ): `review/b44-01`, `review/b44-02` and
      `review/c003-bug-round-44-planner` are gone from origin; `review/c003-bug-round-44-mistral-seat` (`95cb86fe3`)
      matches no round prefix of `do_git_prune_round_branches` and is left to the holder. The seat file stays on
      that branch (not folded here: this close record touches this file only).
