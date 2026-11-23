# Bug round 42 — panel seat mistral (m-812@sat)

Issue: SPL-6331 (epic SPL-2402). Spec: csi-spl-doc/specs/157-dispatch-automation.
Brief: `/var/spool-hub/dispatch/briefs/c002-bug-round-42-mistral-panel-seat.md`.
Review target: `csi-spl-doc/doc/md/bug-round-42-plan.md` on branch
`review/c002-bug-round-42-planner`, at the plan version sha
`719255deac1572ae904cc355a2cfb421934b0e63` (v0.1), named by the brief (planner
c-776@sat). `git ls-remote origin refs/heads/review/c002-bug-round-42-planner`
-> exactly that sha, still the branch head at my check (2026-11-23T20:1xZ).
`git show 719255de --stat` -> one commit, one file, `bug-round-42-plan.md | 256
+++...`, 1 file changed, 256 insertions. The plan's measurement sha is
`bd41a3890` (`git rev-parse --verify bd41a3890^{commit}` ->
`bd41a38908ef5fe10ec24eae5986092999532ef1`). `origin/master` at my fetch was
`e23e1bbc6` (moved past `bd41a3890`: SPL-6239 row T3 landed); per the brief I
reviewed only the planner-named shas (plan `719255de`, measured `bd41a3890`)
and name the sha I read. All checks ran on sat between 2026-11-23T20:0xZ and
20:33Z, n=1 per command unless stated. `<api>` is
`csi-spl-api/src/go/spool-hub-api`; `<box2>` is the fleet's box that is not
sat, as in rounds 21 to 41.

**Verdict: FAIL on `719255deac1572ae904cc355a2cfb421934b0e63` (v0.1), 1 row. One W
(W1, the plan's section 3.3 claim "no defect named"), four N.** The row b42-01
itself is sound (checks 2, 3, 5, 7 all reproduce); the W is in the plan's input
accounting, not in the row.

## Check 1 — slug b42 unused since the plan's `Window: W=`

- `git log -1 --format='%H %cI %s' 129d64862` ->
  `129d64862cd13d6750df927105acc1d43fbb5788 2026-11-23T14:07:42+01:00 docs(b41-plan, SPL-6305): bug round 41 plan v1.0 signed, ...`
  — matches the plan's `Window: W=2026-11-23T14:07:42+01:00` (`129d64862`).
- `W="2026-11-23T14:07:42+01:00"; git log origin/master --since="$W" --oneline -E --grep='\(b42-' | wc -l`
  -> `0`.
- `git ls-remote origin | grep -E 'b42-[0-9]{2}|bug-round-42'` ->
  `719255deac1572ae904cc355a2cfb421934b0e63\trefs/heads/review/c002-bug-round-42-planner`
  only — the planner's branch, expected; this seat's review branch did not exist
  yet at this check. Nothing else.
- `ls /var/spool-hub/dispatch/briefs | grep -E 'b42-[0-9]{2}|bug-round-42'` ->
  `c002-bug-round-42-mistral-panel-seat.md` (this brief) and
  `c002-bug-round-42-planner.md` (the planner's) — both expected.
- `git worktree list | grep -E 'b42|bug-round-42'` -> `/opt/csi/csi-spl-wt/c-776`
  (planner, at `719255dea`) and `/opt/csi/csi-spl-wt/m-812` (this seat) only.
- Note: `git log origin/master --since="$W" --oneline | wc -l` -> `41` now (the
  plan said 34 at 18:44Z; the head moved to `e23e1bbc6` since).

## Check 2 — the defect is real on `bd41a3890` (every cited file:line printed)

Each line read with `git show bd41a3890:<file> | sed -n <N>p`:

- `cmd/spool/hub.go:159` -> `func hubLogger(hc *config.Hub) (zerolog.Logger, *hub.EvlogHook) {`
  `:160` -> `h := hub.NewEvlogHook()`
  `:161` -> `return logging.New(&config.Config{LogLevel: hc.LogLevel, LogFormat: hc.LogFormat}).`
  `:162` -> `With().Str("component", "hub").Str("env", hc.Env).Str("version", version).Logger().Hook(h), h`
  `:163` -> `}` — matches the plan's `hubLogger` description.
- `cmd/spool/hub.go:686` -> `ilog := log.With().Str("component", "invitemail").Logger()` — matches.
- `internal/invitemail/invitemail.go:151` ->
  `log := d.Log.With().Str("component", "invitemail").Str("tenant", tenant).Str("to", res.To).Logger()`
  — matches (the second `component` on top of `hub.go:686`).
- `internal/github/client.go:175` ->
  `c.log.Warn().Str("op", op).Int("status", resp.StatusCode).Str("message", ae.Message).Msg("github: request refused")`
  — matches (`message` collides with zerolog's own `Msg` key).
- `internal/logging/logging.go:56-62` -> the `severityWriter` comment: "...that
  one wins, and the line never carries the key twice..." — matches.
- `internal/evlog/classify_test.go:102-114` -> the comment "zerolog's own message
  key collides with the group's \"message\" field ... a \"group_message\" field
  wins when the line has one" and `TestClassifyHubUnwrittenLine` counting
  `strings.Count(buf.String(), `"message":`)` — matches.
- Reader claim: `git grep -n 'jsonPayload\.\(env\|version\|component\)' bd41a3890 | wc -l`
  -> `0` — matches "no reader depends on the joined values".
- Also verified: `internal/evlog/classify.go:164` ->
  `m, _ := e.JSONPayload["message"].(string)`; `csi-spl-iac/src/bash/run/gcp-hub-instance-health.func.sh:49`
  -> `filter+=" AND (logName=... OR jsonPayload.message=\"ws hello accepted\")"`;
  `internal/mail/subject_sinks_test.go:102` ->
  `if !strings.Contains(buf.String(), `"component":"mail"`) {`;
  `internal/github/client_test.go:255` ->
  `if !strings.Contains(log.String(), "github: request refused") || ...`.

## Check 3 — red control `rc01-b42.sh`

- Extracted the section 4.1 bash block from `719255de` -> 2857 B;
  `sha256sum` -> `0a7153be5c2db0cb1b82b3aaa691c85101df709c0a49dacb493c81e12519201d`,
  first 12 hex `0a7153be5c2d` — matches the plan's claim.
- `bash rc01-b42.sh bd41a3890` (24.2 s, warm Go cache) ->
  `rc01 part-logger: repeated=[component]` /
  `rc01 deploy-record: repeated=[env component version]` /
  `rc01 github-refusal: repeated=[message]` /
  `rc01 control: repeated=[]` /
  `3 of 4 lines repeat a key` /
  `--- FAIL: TestB42HubLogKeysOnce` /
  `rc01 sha=bd41a3890 rc=1`, exit 1 — identical to the plan's run table.
- Live state: read the script — it only `git archive`s the sha into a
  `mktemp -d` dir, writes one `b42_rc01_test.go` there, runs `go test` in that
  dir, and the EXIT trap `rm -rf`s it. No hub, prd, GitHub, Cloud Logging or
  spool writes; nothing outside the temp dir is touched.

## Check 4 — prd evidence, re-read read-only

`cd csi-spl-iac && ENV=prd FRESHNESS=7d LINES=2000 FORMAT=json FILTER='resource.type="cloud_run_revision" AND jsonPayload.component=~"^hub.+"' ./run -a do_gcp_tail_logs`
-> exit 0 (read-only tail; no prd write), 2000 entries spanning
2026-11-21T12:21:16Z..2026-11-23T20:21:15Z (2.3 days, the cap) — the plan's
"2000 cap in 2.3 days" holds. Joined values present in the read:
`"component": "hubauth"` 1650, `"hubhub"` 48, `"hubinvitemailinvitemail"` 51,
`"hubwui"` 85, `"hubgithub"` 72, `"hubmail"` 58, `"hubrepo-edit-worker"` 36;
`"env": "prddev"` 66, `"env": "prdprd"` 67; `"version": "3.4.8v3.5.0"` 3;
`"message": "Not Foundgithub: request refused"` 36 (the plan read 35 at 18:52Z;
my window is ~1.5 h later). Counts differ from the plan's by the same shift
(e.g. hubauth 1650 vs 1482+174); same shape. No member name, workspace content
or connection detail is written here.

## Check 5 — the row

- Fix scope narrow: one base-logger key rename (`hub.go:159-163`), the
  `invitemail` double `component` (`invitemail.go:151` vs `hub.go:686`), the
  github `message` -> `github_message` (`client.go:175`), two tests, no store,
  migration, WUI or cnf change. Verified the shape turns the control green: in
  a scratch copy of `bd41a3890` (`git archive` into `mktemp -d`) I renamed
  `hubLogger`'s keys to `hub_component`/`hub_env`/`hub_version`, dropped
  `invitemail.go:151`'s `component`, and changed `client.go:175` to
  `github_message`; the rc01 test (github case as the fixed site writes it)
  -> `rc01 part-logger: repeated=[]` / `deploy-record: repeated=[]` /
  `github-refusal: repeated=[]` / `control: repeated=[]` /
  `--- PASS: TestB42HubLogKeysOnce`, exit 0.
- Readers still pass on that fixed tree:
  `go test -count=1 ./cmd/spool/ ./internal/github/ ./internal/invitemail/ ./internal/evlog/ ./internal/mail/ ./internal/logging/`
  -> all `ok`, exit 0; `go test -count=1 ./internal/hub/ -run 'Evlog|Deploy|Invite|Netvisor|HR'`
  -> `ok`, exit 0.
- No behaviour change beyond the defect: `git grep -n 'jsonPayload\.\(env\|version\|component\)' bd41a3890`
  -> 0 readers; the alert policy `csi-spl-iac/src/terraform/070-gcp-monitoring/05-policies.tf:121`
  filters on `jsonPayload.level` and `jsonPayload.message = "http 5xx"` (a
  non-doubled key on the `logServerError` line) — unaffected;
  `gcp-hub-instance-health.func.sh:49`'s `jsonPayload.message="ws hello accepted"`
  reads zerolog's own `Msg` key on that line — unaffected.
- **Keep the row** (not cut, not split): 1 row, batch 1, claude `simple_coding`,
  grok R7, sat — consistent with rulebook 3.1/5.

## Check 6 — inputs accounted for

- Round 41's plan section 7 (`bug-round-41-plan.md` on origin/master, `## 7.
  Counts`, "first inputs for round 42") lists 7 items; the b42 plan's section
  3.4 re-reads all 7 (composed testids, `monitoring-costs` flake, SPL-6277 N2,
  SPL-6174 relay hash, b34-01 N2 + SPL-6212 N2, r87-01 N2, the WARNING-past-cap
  read -> "Done: it gave row 01"). All accounted.
- `/var/spool-hub/dispatch/c002-next-round-candidates.md` (readable, 115 lines,
  mtime 2026-11-23 15:44): the only bug-shaped entry after W
  (2026-11-23T13:07:42Z) is the 2026-11-23 14:2xZ item "SPL-6308 R7 N2
  (g-162@<box2> a30866cd): `i18n-lang-review-exempt.json:2` `_doc` still says
  'Lang-review a-NNN' ... One doc line", classified "BUG/REFACTOR-shaped". The
  plan's source 7 (plan line 45) lists g-162 among the 14 PASS lines read since
  W, but section 3.3's last row (plan line 87) says "the other R7 notes (source
  7) | each read | scope notes and confirmations; no defect named." — g-162's
  N2 does name a defect. See W1. All earlier (pre-W) "next BUG round" entries in
  the file were round 40/41 inputs or ruled "no lane now" by c-001; none is a
  since-W input.

## Check 7 — R3 lane map

- `bash .../lane-map.sh --check csi-spl-doc/doc/md/bug-round-42-plan.md,<api>/cmd/spool/hub.go,<api>/internal/invitemail/invitemail.go,<api>/internal/github/client.go --agent m-812`
  -> exit 3: `csi-spl-doc/doc/md/bug-round-42-plan.md owned by c-776@sat
  c-776-c002-bug-round-42-planner (changed in its worktree; no files recorded)`
  — the plan file itself, its editor; expected, this seat does not touch it.
- `hub.go` alone -> exit 4 (only `unknown:` `<box2>` rotate lanes with no files
  recorded; none names `hub.go`). The planner's claim (plan line 208) "hub.go
  held by c-779@sat ... row 01 is placed after c-779 lands" is **stale**:
  SPL-6239 T3 landed on origin/master as `e23e1bbc6` (the current origin/master
  HEAD; `git log origin/master --oneline -E --grep='SPL-6239 row T3'` ->
  `e23e1bbc6 feat(hubclient): the box_sample frame handler ... (SPL-6239 row T3)`),
  c-779's worktree is clean at `e23e1bbc6` (`git -C /opt/csi/csi-spl-wt/c-779
  status --short` -> only an untracked `.lane-state-c-779.md`; HEAD `e23e1bbc6`),
  and `git diff bd41a3890 e23e1bbc6 -- <api>/cmd/spool/hub.go` touches only
  `:636-640` (`wirePayments` `Sessions`) and `:1288+` (`boxClient`
  `BoxSampleMin`) — not the cited `:159-163`/`:686`. The hold is resolved.
- Queued rows: `do_spl_spawn_queue` -> `c002-spl6239-t6-hub-refresh-route`
  HELD behind T5, `c002-spl6318-t11-htop-df-collector` HELD behind T10. Their
  briefs scope T5/T6 to `internal/hub/**` (T6 brief: "in `internal/hub`") and
  T11 to `internal/hubclient/**`; none touches `cmd/spool/hub.go`,
  `internal/invitemail/invitemail.go` or `internal/github/client.go`.

## Check 8 — distribution hygiene

`cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `ok - owner mail address
or domain`, `ok - hidden workspace or private literal (SPL-1874)`, `ok -
retired relay estate (SPL-1910)`, `ok - no tracked .vibe/ dir`, `INFO
distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-812`,
exit 0.

## W

- **W1 (plan line 87, section 3.3 last row): "the other R7 notes (source 7) |
  each read | scope notes and confirmations; no defect named." is false for
  g-162.** Source 7 (plan line 45) lists g-162 among the 14 PASS lines read
  since W; g-162's N2 (SPL-6308 R7, a30866cd) names a defect — a stale `_doc`
  line in `i18n-lang-review-exempt.json:2` — and the holder's candidates file
  (2026-11-23 14:2xZ, after W) classifies it "BUG/REFACTOR-shaped ... One doc
  line". The plan neither serves that input nor accounts for it by name; it
  misclassifies it as a scope note. Does not touch row b42-01.

## N

- **N1 (plan line 60):** "the log alert policy reads `jsonPayload.level` only
  (`05-policies.tf:121`)" — line 121 also filters
  `jsonPayload.message = \"http 5xx\"`. Substance holds: no reader of the joined
  `env`/`version`/`component`, and the `message` filter targets a non-doubled
  key.
- **N2 (plan line 62):** "no doc names these keys
  (`git grep -nE '\"component\": ?\"hub\"' -- 'csi-spl-doc/*.md'` -> 0 lines)" —
  as written the grep returns 3 lines on `bd41a3890`
  (`csi-spl-doc/specs/143-reporting-section/spec.md:317,358,359`), all
  deploy-record API payload examples, not log-key docs; with a `:(glob)`
  pathspec (top level only) it is 0. Substance holds; the command as printed
  does not print 0.
- **N3:** `origin/master` moved past the plan's measurement sha between the
  plan's read (18:44Z, 34 commits since W) and mine (41 commits, head
  `e23e1bbc6`). Per the brief I reviewed the planner-named shas; the hub.go
  diff since `bd41a3890` does not touch the cited lines.
- **N4:** my prd read (20:2xZ) counts differ slightly from the plan's (18:52Z)
  — same shape, window ~1.5 h later (36 vs 35 github refusals; hubauth 1650 vs
  1656); the 2000-cap-in-2.3-days holds.

---

The verdict stands: **FAIL, 1 row, on `719255deac1572ae904cc355a2cfb421934b0e63`
(v0.1). One W (W1), four N.** Row b42-01 itself: keep.

---

# Re-review of v0.2 — `5b4fc34bd73597937cd5123c3c96bbe7c12eec38`

Holder ask (c-002@sat, msg 20cb84e7, task `dispatch-bug-r42`, 2026-11-23T22:4xZ):
re-review the plan's next head. `git ls-remote origin
refs/heads/review/c002-bug-round-42-planner` ->
`5b4fc34bd73597937cd5123c3c96bbe7c12eec38`, a fast-forward of `719255dea`;
`git log 719255dea..5b4fc34b` -> one commit;
`git show 5b4fc34b --stat` -> `bug-round-42-plan.md | 25 ++++...`, 1 file
changed, 14 insertions(+), 11 deletions(-) — the plan file only.
`git diff 719255dea 5b4fc34b -- <plan>` read whole (86 lines): status line,
section 3.1's "why it is a bug" and "fix scope" sentences (N1/N2 folds),
section 3.3's rows (the g-162 N2 row added, the "other R7 notes" row reworded),
the R3 line, section 6's `g-003` row, the counts row, section 7's first-inputs
row, section 8's review history, the consensus table. The row table (section 5)
and the red control (section 4) are unchanged context.

**Verdict: PASS on `5b4fc34bd73597937cd5123c3c96bbe7c12eec38` (v0.2), 1 row. No
open W.**

## W1 answer — judged, holds

The planner's answer: section 3.3 names g-162 N2 as its own row, re-measured on
`70f05ea48`; not a b42 row because the gate still accepts the `a-NNN` form, so
the `_doc` is incomplete, not false; carried to a docs/refactor round
(section 7). Verified on `70f05ea48` (and still on `origin/master` at my
fetch):

- `git grep -n 'Lang-review' 70f05ea48 -- csi-spl-wui/i18n/i18n-lang-review-exempt.json`
  -> 1 line, `:2`: the `_doc` names `'Lang-review: a-NNN <msg id>'`.
- `git grep -c 'an agy review still counts' 70f05ea48 -- csi-spl-iac/src/bash/run/check-pre-push-lang-review.func.sh`
  -> `1` (line 151).
- `git show 70f05ea48:csi-spl-iac/src/bash/run/check-pre-push-lang-review.func.sh | sed -n '66p'`
  -> `_PPR_LINE_RX='^Lang-review:[[:space:]]+(a-[0-9]{3}(@[A-Za-z0-9._-]+)?[[:space:]]+[0-9a-f]{8}|c-...waiver...)'`
  — the `a-NNN` agy form is still an accepted pass line.
- `git show 70f05ea48:.../check-pre-push-lang-review.func.sh | sed -n '151p'`
  -> the FAIL text: "...with no 'Lang-review: gct <run id>' line ... (an agy
  review still counts: 'Lang-review: a-NNN <msg id>')".
- Same two greps on `origin/master` -> `1` and `1`.

So a commit that follows the `_doc`'s `a-NNN` form still passes the gate: the
`_doc` omits the gct form the language rule now asks for, but it is not false,
and no wrong behaviour follows. "Not a row, carried to a docs/refactor round"
is the right call, and the plan now accounts for g-162 N2 by name (section 3.3)
and in section 7's first inputs for round 43. W1 is resolved.

## N1/N2 folds — verified

- N1: the v0.2 "why it is a bug" line now reads the alert metric
  (`05-policies.tf:121`) as `jsonPayload.level` and
  `jsonPayload.message = "http 5xx"` (the hub's `logServerError` line, written
  with `Msg`, no second `message` key; the fix keeps it), and no
  `env`/`version`/`component`. Verified: `git show bd41a3890:<api>/internal/hub/server.go | sed -n '987p'`
  -> `ev.Msg("http 5xx")` (with the `:985-986` comment that the metric filter
  reads the literal). Accurate.
- N2: the v0.2 "fix scope" line now prints the docs grep as 3 lines, all
  `csi-spl-doc/specs/143-reporting-section/spec.md:317,358,359` (deploy-record
  API payload examples, not hub log lines), and notes v0.1's 0 was true only for
  a top-level pathspec. Matches my N2 measurement exactly.

## Rest of the seat, re-checked on v0.2

- The row (section 5), its sites and `rc01-b42.sh` (section 4) are unchanged in
  the diff; checks 2, 3, 5 above still stand (same `bd41a3890` citations, same
  red-control run).
- R3: the v0.2 line records c-779's landing as `e23e1bbc6` on origin/master and
  a `lane-map.sh --check` exit 4 with no live lane listing the row files —
  matching my check 7 (I read the same: exit 3 names only the planner's plan
  file; `hub.go` alone exit 4; `git -C /opt/csi/csi-spl-wt/c-779 status --short`
  -> lane-state file only, HEAD `e23e1bbc6`; `git diff bd41a3890 e23e1bbc6 --
  <api>/cmd/spool/hub.go` touches `:636-640` and `:1288+`, not `:159-163`/`:686`).
- Check 1 still holds: `git log origin/master --since="$W" --oneline -E --grep='\(b42-' | wc -l`
  -> `0` (the v0.2 commit lives on the review branch, not master).
- Check 8 re-run on this tree with the seat file updated:
  `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> clean, exit 0.

The verdict stands: **PASS, 1 row, on `5b4fc34bd73597937cd5123c3c96bbe7c12eec38`
(v0.2). No W.** Row b42-01: keep.

---

## State at the 2026-11-23T21:15Z rotation

- The plan landed on `origin/master` as `88df38239`
  (`git log origin/master --oneline -1` -> `88df38239 docs(b42-plan, SPL-6331):
  bug round 42 plan v0.2 ...`); `git show 5b4fc34b | git patch-id --stable` and
  `git show 88df38239 | git patch-id --stable` both ->
  `5d542959422956482eb534df421a8a41eb64ef44`, so the landed patch is exactly
  the head I signed PASS on. Holder note c-002 msg d12c5fa1.
- The editor's v1.0 confirmation in the round record (plan section 8) has not
  landed yet at this rotation: `git ls-remote origin
  refs/heads/review/c002-bug-round-42-planner` -> still `5b4fc34bd...`;
  `origin/master` head is `88df38239`. When it lands, this seat signs that sha
  here (next commit on `review/c002-bug-round-42-mistral-seat`) and reports
  again on task `dispatch-bug-r42`.
- This seat branch is fully pushed at `6f5023b2d` (two commits:
  `444e925bb` v0.1 FAIL verdict, `6f5023b2d` v0.2 PASS signing); master is
  untouched by this seat. Waiting for the ACCEPTED on `dispatch-bug-r42` before
  any /exit-clean.
