# Bug-fix round 42 - plan (1 row)

Epic: SPL-2402  
Spec: csi-spl-doc/specs/157-dispatch-automation  
Issue: SPL-6331 (this plan, the round's discussion issue, priority 2).  
Discussion: t1 `548ab29d-0750-4214-888a-1e7490890453` ("Bug round 42", opened by c-002@sat 18:41Z). Round 41 ([bug-round-41-plan.md](bug-round-41-plan.md)) served both rows (b41-01 `366bc7dca`, b41-02 `358178682`).  
Round focus: the sources of rounds 40 and 41 (prd error and WARNING logs, prd alert incidents, open bug issues, CI runs of every workflow, R7 notes of the lanes landed since W), read since W. The one row comes from the prd WARNING log read past round 41's 401 bursts (its section 7 input), then widened to every severity.  
Round size: owner order 2026-11-18 (HUM-10, rulebook 5.1 to 5.4): 1 to 3 rows, aim at 2. One candidate met the bar (section 3); rulebook 5.2: "1 row is a round".  
Consensus: **no owner go, no question to the owner** (rulebook 1.4).  
Rules: [rounds-rulebook.md](rounds-rulebook.md), linked here, not copied.  
Model: [bug-round-41-plan.md](bug-round-41-plan.md).

**Status: v0.2, signed: m-812 PASS on v0.2 `5b4fc34bd` (v0.1 `719255dea` FAIL, W1 and N1..N4 folded); holder GO on `5b4fc34bd`, landed `88df38239`.** **Closed**: the one row landed and is served on dev and prd, b42-01 `c41b7080e` (SPL-6340), accepted (section 8).

Editor: **c-776@sat** (claude, `specs_and_docs`).  
Panel: placed by the holder (rulebook 3.2).

**One sha:** every count below is measured on **`bd41a3890`** (`origin/master` at this seat's fetch, 2026-11-23T18:44Z), on sat, 18:44Z..18:58Z on 2026-11-23, unless a line says otherwise. n=1 per command unless stated.  
**Window** (rulebook 5.3): `W=$(git log origin/master -1 --format=%cI -E --grep='^docs\(b41-plan')` read at 18:44Z -> `Window: W=2026-11-23T14:07:42+01:00` (commit `129d64862`, the b41 v1.0).

---

## 1. How to read this

- Since W, `origin/master` took 34 commits (`git log origin/master --since="$W" --oneline | wc -l` -> 34): the b41 rows, rounds r92 to r94, SPL-6300/6301 (costs), SPL-6316/6319/6324 (contacts), SPL-5985 (spl-run-path), SPL-6318 (spec 071 doc).
- `<box2>` is the fleet's box that is not sat, and `<ws>` one customer workspace, as in rounds 21 to 41: the public repo names neither.
- **Paths** are repo-relative; `<api>` is `csi-spl-api/src/go/spool-hub-api`. Line numbers are as of `bd41a3890`.
- In the commands of the tables, `\|` is the markdown escape of `|` inside a table cell: type a plain `|`.
- The red control is a script printed in section 4. It extracts the named sha's tree with `git archive` into a `mktemp -d` dir and changes nothing in the checkout.
- The prd reads are read-only (`do_gcp_tail_logs`, `do_gcp_list_alert_incidents`, `do_spl_db_query` SELECTs).

---

## 2. Where rows could come from (measured since W)

| source | command | count (n) | result |
|---|---|---|---|
| **1. prd error log** | `cd csi-spl-iac && ENV=prd SEVERITY=ERROR FRESHNESS=6h LINES=1000 FORMAT=json ./run -a do_gcp_tail_logs` (18:45Z; 6 h covers W) | 19 entries, 13:08Z..18:42Z: 18 Cloud SQL statement errors as the hub's runtime user (`column "id" does not exist`, `uuid ~~ unknown`, `relation "topics" does not exist`, ...), 1 Cloud Run 503 on `/v1/pins?probe=1` (16:03:06Z) | **0 rows.** The 18 SQL errors are hand-written reads with wrong column names, the shape round 41 traced to seats' `do_spl_db_query` (this seat's own first `messages` read adds one more, after this read). The 503 is one line at a hub roll (source 6's `db.schema_head` line is 2 s later); no repeat, no incident. |
| **2. prd alert incidents** | `ENV=prd SINCE=6h ./run -a do_gcp_list_alert_incidents` (csi-spl-iac, 18:47Z) | 9 policies, 0 incidents in 12:47Z..18:47Z | **0 rows.** |
| **3. Open issues labelled bug, t1** | `cd csi-spl-orc && ENV=prd SQL="select number, status, priority, assignee, left(title,110), created_at::date from issues where tenant_id='t1' and 'bug' = any(labels) and status in ('eval','todo','wip','blocked','onhold') and deleted_at is null and archived_at is null order by created_at desc" ./run -a do_spl_db_query` (18:48Z) | 7 issues; 1 new since W: SPL-6330 (`wip`, the cloud costs page of a routed workspace, lane c-764@sat) | **0 rows.** Each is its lane's or the holder's. |
| **4. CI, wf 10 per job** | `cd csi-spl-iac && CI_GATE_RUNS=100 CI_GATE_SIGNATURES=1 ./run -a do_report_ci_gate` (18:45Z..18:55Z) | 100 runs, 2026-11-22T15:54Z..2026-11-23T18:43Z: 76 success, 16 cancelled, 8 failure; every job's p90 under 75 % of its timeout (highest: hermetic 1/4, 59 %); 5 of the failures since W, every job green again by run 45225454706 (`ef80e6a01`, 17:14Z) | **0 rows**, section 3.2: two fixed by their lanes, the others first sightings. |
| **5. CI, every other workflow on master** | `gh run list --branch master --status failure --limit 60` (18:49Z; the list reaches back to 2026-11-19T19:17Z) | 0 failed runs of any workflow but wf 10 since W | **0 rows.** |
| **6. prd WARNING log** | `ENV=prd FRESHNESS=6h LINES=3000 FORMAT=json FILTER='severity=WARNING AND resource.type="cloud_run_revision" AND NOT httpRequest.status=401' ./run -a do_gcp_tail_logs` (18:50Z; the 401 bursts left out, as round 41 section 7 asked: the cap is NOT reached, the full 6 h is read) | 846 entries, 12:45Z..18:44Z: 479 `ws hello refused`, 218 `upload token refused`, 67 `roster over a workspace agent cap: agent not seated`, 43 `export.pdf` 403/404, 8 `release-notes/<sha>` 404, 5 `view/netvisor/forecast` 404, 3 `PUT /v1/me/hours/minutes` 400, scanner probes (`/.env`, `wp-admin`, ...), 2 `gcal: grant revoked`, 3 `gcal` cycle cancels, 2 `github: request refused`, 1 `db.schema_head`, 1 `deploy.reconcile_filled` | **Row b42-01** (section 3.1): the `deploy.reconcile_filled` line reads `"component":"hubhub","env":"prdprd","version":"3.4.8v3.5.0"`, the github line `"message":"Not Foundgithub: request refused"`. The rest: section 3.3. |
| **6b. every severity, joined keys** (new, from 6) | `ENV=prd FRESHNESS=7d LINES=2000 SEVERITY=DEFAULT FORMAT=json FILTER='resource.type="cloud_run_revision" AND jsonPayload.component=~"^hub.+"' ./run -a do_gcp_tail_logs` (18:52Z) | the 2000 cap in 2.3 days (2026-11-21T11:03Z..2026-11-23T18:51Z): 1482 `hubauth` `auth.login_ok` and 174 more `hubauth`; 56 `hubmail`; 51 `hubinvitemailinvitemail`; 88 `hubwui` + 44 `hubhub` `deploy.recorded` (66 of them `"env":"prddev"`); 69 `hubgithub`; 34 `hubrepo-edit-worker`; 2 `hubhub` `deploy.reconcile_*` | **Row b42-01.** |
| **7. R7 notes of lanes landed since W** | the reviewers' PASS messages in the sat spool (`c-002`, `c-003` inbox and archive, files newer than W, bodies with `PASS` and an `N<n>`/`W<n>`), `/var/spool-hub/reports/g-*.md` on sat, and prd `messages` from g-184, g-215, g-274 (`<box2>`) | 14 PASS lines with notes: g-724 N2 (`run.sh:797` labels a bad line count "is not version"), g-267 N1/N2 (SPL-6323: a stated rule; a stray `**` in `costs-allocation.md:8`), g-306 N2 (spec 181 B12, a live lane), g-754 N1 (spec 181 B2, a live lane), and scope notes from g-693, g-696, g-740, g-162, g-197, g-184, g-215, g-274, g-655, g-757, g-675 | **0 rows**, section 3.3. |
| **8. Owner, member and lane reports** | prd `messages` from `HUM-%` in t1 since W (47 rows: 28 `[spool-probe]` lines of HUM-51, 19 of HUM-10) | 1 report: HUM-10 18:04Z in `f08c0c58` (the loop of a discussion in another workspace's channel "does not work") | **0 rows**: the holder answered at 18:05Z and 18:09Z (the loop fired at 18:01:51Z and the seat acted; it posted nothing because the prompt said so). The other HUM-10 posts are asks in their own topics. |
| **9. Round 41's first inputs** | round 41 section 7, re-run | 7 items | **0 rows**: section 3.4. |

---

## 3. The candidates, read

### 3.1 b42-01: the hub's log lines carry a key twice, and Cloud Logging joins the two values

- **What happens.** The serving hub's logger puts three keys in every line: `hubLogger` (`<api>/cmd/spool/hub.go:159-163`) is `With().Str("component", "hub").Str("env", hc.Env).Str("version", version)`. zerolog appends a context field each time it is given, never replacing one, so a line that names `component`, `env` or `version` again holds the key twice:
  - part loggers built on it: `auth` (`<api>/internal/auth/handler.go:264`), `payments` (`hub.go:631`), `invitemail` (`hub.go:686`, and again at `<api>/internal/invitemail/invitemail.go:151`: three `component` keys), `mail` (`<api>/internal/mail/config.go:130`, `preflight.go:30`), `github` and `repo-edit-worker` (`<api>/cmd/spool/hub_repo_edit.go:56,61`), `repo-sync` (`hub_repo_sync.go:34`), `embed_relink` (`<api>/internal/hub/embed_relink.go:239`);
  - lines whose data is named `env`, `component` or `version`: a deploy record (`<api>/internal/hub/operator_deploys.go:118,122`) and the deploy reconcile (`:250,265,303`), the hr rates (`hr_payroll.go:127,155,275`), netvisor (`netvisor.go:336,427`), the evlog put (`evlog_frame.go:90`), the dev-login refusal (`<api>/internal/auth/dev_login.go:60`), the mail preflight skip (`<api>/internal/mail/preflight.go:43`);
  - and the github refusal (`<api>/internal/github/client.go:175`) names GitHub's text `message`, zerolog's own key for `Msg`.
- **What it costs.** Cloud Logging joins a repeated key's values into one string. Measured in prd (sources 6 and 6b): the 2000 newest lines with a joined `component` span only 2.3 days; a `deploy.recorded` of a dev deploy reads `"env":"prddev"` (the deploy's env is lost in the prd hub's), a reconcile reads `"version":"3.4.8v3.5.0"`, a sign-in reads `"component":"hubauth"`, and the github refusals read `"message":"Not Foundgithub: request refused"` (35 in 2.3 days), so a `jsonPayload.message="github: request refused"` filter (the form `csi-spl-iac/src/bash/run/gcp-hub-instance-health.func.sh:49` and the spec 149 review use for their own lines) finds none of them. The evlog reader (`<api>/internal/evlog/classify.go:164`) reads the same `message`. The same class was fixed once, in the evlog line, which names its group's text `group_message` because "zerolog's own message key collides with the group's "message" field" (`<api>/internal/evlog/classify_test.go:102-114`).
- **Why it is a bug.** A structured log whose fields cannot be read as written: the deploy's own env and version, the part of the hub, the GitHub message. `logging.go` already guards one key the same way: `severityWriter` keeps `severity` once ("the line never carries the key twice", `<api>/internal/logging/logging.go:56-62`). No reader depends on the joined values: `git grep -n 'jsonPayload\.\(env\|version\|component\)'` -> 0 lines on `bd41a3890`; the log alert metric (`csi-spl-iac/src/terraform/070-gcp-monitoring/05-policies.tf:121`) reads `jsonPayload.level` and `jsonPayload.message = "http 5xx"` (the hub's `logServerError` line, written with `Msg`, no second `message` key; the fix keeps it), and no `env`, `version` or `component`.
- **Red control** (`rc01-b42.sh`, section 4.1): on `bd41a3890` -> `rc01 part-logger: repeated=[component]`, `rc01 deploy-record: repeated=[env component version]`, `rc01 github-refusal: repeated=[message]`, `--- FAIL`, exit 1. **Control** in the same run: a line of unique keys -> `repeated=[]`.
- **Fix scope.** Every line the serving hub writes carries each key once. One place makes most of it true: the base logger names its facts under keys no other hub line writes (e.g. `hub_env`, `hub_version`, and the process tag under a key of its own, or none: `service: spool` and the Cloud Run service already name it), in `hubLogger` (`hub.go:159-163`). Then each part logger's `component` and each line's own `env` / `component` / `version` stand alone, and none of the call sites above changes. Two lines still repeat a key after that and change: `invitemail.go:151` sets the `component` its caller (`hub.go:686`) already set (keep one of the two), and `github/client.go:175` names GitHub's text `github_message` (as evlog's `group_message`). Tests: a Go test in `cmd/spool` (the case of `rc01-b42.sh` made real, red before the fix) that writes lines through `hubLogger` as the sites do and fails on any repeated key, and a case in `internal/github/client_test.go` that the refusal line keeps `message` = `github: request refused`. No store, migration, WUI or cnf change. Docs: no doc names these log keys (`git grep -nE '"component": ?"hub"' bd41a3890 -- 'csi-spl-doc/*.md'` -> 3 lines, all `csi-spl-doc/specs/143-reporting-section/spec.md:317,358,359`: deploy-record API payload examples, not hub log lines; v0.1 printed 0, true only for a top-level pathspec, panel N2); the commit carries `Docs: none (<why>)` unless the lane finds one. The lane picks the key names; the tests pin "each key once" and the github `message`.

### 3.2 CI reds since W, read

| run | job | first red line | why not a row |
|---|---|---|---|
| 45217594068, 45220059471, 45223415636 (16:32Z..17:03Z) | orc hermetic 4/4 (+ fail-fast stops) | `an orc check skipped in CI` (`SKIP: the binary half: no SPL_RUN_PATH_TEST_BIN`) | fixed by its lane: `ef80e6a01` fix(ci, SPL-5985); green since run 45225454706. |
| 45220059471 (16:45Z, schedule) | orc hermetic 2/4 | `The job has exceeded the maximum execution time of 30m0s` | 1st sighting; the job's p90 is 56 % of its timeout (source 4). Carried (2.11.3). |
| 45208818805 (15:45Z, schedule) | hub gofmt/vet/test | `--- FAIL: TestContactsSyncLogsNoValues: C12: the log holds the contact value "555"` | fixed by its lane: `1797577cb` fix(api, SPL-6324), R7 g-757 PASS. |
| 45197570926 (14:45Z, schedule) | iac tfvars parity | `FAIL: download iframe: ... no documents list on the "Invoices" page, or it never stopped loading` (`csi-spl-iac/src/bash/tests/gcp-billing-invoices.tst.sh:409`) | 1st sighting in the 100 runs (the two older tfvars reds, 11-22 19:39Z and 19:44Z, are round 41's fixed parity reds); no change to the test since 2026-11-17 (`git log origin/master --since=2026-11-22 -- csi-spl-iac/src/bash/tests/gcp-billing-invoices.tst.sh` -> 0). Carried. |
| 45124937982 (06:33Z, before W) | wui e2e 2/8 | `monitoring-costs.test.mjs` | the hr-tab flake round 41 carried; still 1 sighting. |

### 3.3 The other candidates, read

| candidate | read | why not a row |
|---|---|---|
| `roster over a workspace agent cap: agent not seated`, 67 in 6 h | `FILTER='jsonPayload.message="roster over a workspace agent cap: agent not seated"'` over 72 h -> 727 entries, every one `tenant=<ws> box=sat agent=g-003`, `grok agent cap reached for workspace <ws>: max 0 live`, one per 5 min, from 2026-11-20T18:51Z (the read's start) on. That workspace's desk spool root on sat holds a real `g-003` dir (empty inbox, outbox, archive; made 2026-11-02 09:50); its other ids are c-001..c-003. | **Not a row**: the hub refuses as designed and seats the rest of the roster (`<api>/internal/hub/ws.go:596-617`, SPL-5642). The cause is a box leftover, not code: handed to the holder (section 6). |
| `GET /v1/release-notes/<sha>` 404, 8 in 6 h | referer the csitea workspace, no `scope=` on the URL; the shas are spool release commits (`e75c771c0` = tag `v3.4.9-c4`, ...) | **Not a row**: by design, "the in-message link previews keep the workspace's own read" (`d489d787b`, SPL-6274); the dialog reads with `scope=platform`. A preview of a spool release in a customer workspace shows no card: handed to the holder as a design question (section 6). |
| `GET /v1/view/netvisor/forecast` 404, 5 | referers a customer workspace and the root site | **Not a row**: the WUI asks once whether the reader may see Finance, and the 404 of every workspace but the Netvisor one is the answer (`csi-spl-wui/src/utils/reporting-finance.mjs:191-198`, `<api>/internal/hub/netvisor.go:20-45`). |
| `PUT /v1/me/hours/minutes` 400, 3 | one phone client, csitea, 16:02Z, 16:07Z, 16:12Z (the recorder's 5-min flush); a 400 drops the batch (`csi-spl-wui/src/utils/hours-recorder.mjs:120-121`) | **Carried**: the 400's code is not in the log, and its causes (`<api>/internal/hub/hours_me.go:527-547`, `day_cap`, `bad_hours`) cannot be told apart from it. 1 client, 15 min. |
| `export.pdf` 403/404, 43 | `Go-http-client`, topic `98b6dd72` (a topic of another workspace) | **Not a row**: the seat's PDF export of that topic (source 8), the holder's and the seat's. |
| `db.schema_head` `ahead`, 1 (16:03:08Z) | hub 3.5.0 started with bundled `0312`, applied `0313` | **Not a row**: one line at a roll (SPL-6301's `0313` landed with `d291fb26b`); no repeat. |
| g-724 N2: `run.sh:797` (4 copies, one blob) says "`<bin>` is not version 0.1.0" when the version is right and the line count is wrong | read on `bd41a3890` | **Not a row**: a DEBUG note's wording on a path that falls back to the right values; SPL-5985's lane can take it. |
| g-267 N2: a stray `**` in `costs-allocation.md:8` | - | **Not a row**: a doc typo in SPL-6301's spec. |
| g-306 N2, g-754 N1 | spec 181 B12 and B2 | **Owned** by their live lanes (R3). |
| g-162 N2 (SPL-6308 R7, a30866cd): `csi-spl-wui/i18n/i18n-lang-review-exempt.json:2` `_doc` names only `Lang-review: a-NNN <msg id>`, while the gate's refusal line (`csi-spl-iac/src/bash/run/check-pre-push-lang-review.func.sh:151`) asks for `Lang-review: gct <run id>` first | re-measured on `70f05ea48` (origin/master, 20:4xZ): `git grep -n 'Lang-review' 70f05ea48 -- csi-spl-wui/i18n/i18n-lang-review-exempt.json` -> 1 line (`:2`); `git grep -c 'an agy review still counts' 70f05ea48 -- csi-spl-iac/src/bash/run/check-pre-push-lang-review.func.sh` -> 1 (line 151 still takes the `a-NNN` form, as `:27` and [pre-push-gate.md](pre-push-gate.md) say) | **Not a row**: no wrong behaviour. A commit that follows the `_doc` still passes the gate; the `_doc` is incomplete (it omits the gct form, the one the language rule now asks for), not false. A one-line doc string in a WUI data file: carried to a docs or refactor round (section 7), as [refactor-round-93-plan.md](refactor-round-93-plan.md) section 6 also left it. (v0.1 counted it under "no defect named": panel W1.) |
| the other R7 notes of source 7: g-693, g-696, g-740, g-162 N1, g-197, g-184, g-215, g-274, g-655, g-757, g-675 | each read | scope notes and confirmations; none names a defect. |

### 3.4 Round 41's first inputs, re-read

| candidate | command | result | why not a row |
|---|---|---|---|
| The pre-push e2e selector's composed testids | `git log origin/master --since="$W" --format=%h -- csi-spl-iac/src/bash/run/check-pre-push-e2e.func.sh` -> 0 | unchanged | **Not a row**, as rounds 37 to 41: a gate-design input with the holder. |
| The `monitoring-costs` hr-tab flake | source 4 | still 1 sighting (06:33Z) | **Carried** (2.11.3). |
| SPL-6277 N2 (one sha, two release tags) | `git ls-remote --tags origin 'v*' \| grep -v '\^{}' \| awk '{print $1}' \| sort \| uniq -d \| wc -l` | 0 | **Carried**: no instance. |
| SPL-6174's link to the relay hash `3e2c61b1` | `git log origin/master --since="$W" --format='%h %s' \| grep -ciE 'SPL-6174\|relay hash'` -> 0 | no writer named | **Carried.** |
| b34-01 N2 and SPL-6212 N2 | rounds 38 to 41 | test-shaped | **Carried** to a test or refactor round. |
| r87-01 N2 (coverage floor tolerance) | no tier=full report past a floor's tolerance since W (source 7) | - | **Carried.** |
| The prd WARNING log read past its 3000 cap | source 6 with `NOT httpRequest.status=401` | 846 entries, the whole 6 h | **Done**: it gave row 01. |

---

## 4. Red control, as run

### 4.1 `rc01-b42.sh` (b42-01), sha256 first 12 hex `0a7153be5c2d`, 2857 B

Run from any checkout: `bash rc01-b42.sh bd41a3890`, 23 s on sat with a warm Go cache.

```bash
#!/usr/bin/env bash
# rc01-b42.sh <sha>: b42-01 red control. On <sha>'s tree, every JSON line the
# serving hub's logger (cmd/spool hubLogger) writes must carry each key once.
# Four lines as the hub's own sites write them: a part logger
# (auth/handler.go:264), a deploy record (operator_deploys.go:122), the
# github refusal (github/client.go:175); control: a line of unique keys.
# Cloud Logging joins a repeated key's values ("hubauth", "prddev"). The
# Go test below is dropped into that tree's cmd/spool; it reads nothing
# outside the tree.
set -uo pipefail
sha="${1:?usage: rc01-b42.sh <sha>}"
repo="$(git rev-parse --show-toplevel)" || exit 2
full="$(git -C "$repo" rev-parse --verify "$sha^{commit}")" || exit 2
tmp="$(mktemp -d)"; trap 'chmod -R u+w "$tmp"; rm -rf "$tmp"' EXIT
git -C "$repo" archive "$full" csi-spl-api csi-spl-rdb | tar -x -C "$tmp"
d="$tmp/csi-spl-api/src/go/spool-hub-api"
cat >"$d/cmd/spool/b42_rc01_test.go" <<'GO'
package main

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
)

// dupKeys lists the top-level keys line holds more than once.
func dupKeys(t *testing.T, line string) []string {
	dec := json.NewDecoder(strings.NewReader(line))
	if tok, err := dec.Token(); err != nil || tok != json.Delim('{') {
		t.Fatalf("not a JSON object: %q", line)
	}
	seen, dup := map[string]bool{}, []string{}
	for dec.More() {
		k, _ := dec.Token()
		var v json.RawMessage
		if err := dec.Decode(&v); err != nil {
			t.Fatalf("decode %q: %v", line, err)
		}
		if seen[k.(string)] {
			dup = append(dup, k.(string))
		}
		seen[k.(string)] = true
	}
	return dup
}

func TestB42HubLogKeysOnce(t *testing.T) {
	base, _ := hubLogger(&config.Hub{Env: "prd", LogLevel: "info", LogFormat: "json"})
	var buf bytes.Buffer
	l := base.Output(&buf)
	cases := []struct {
		name string
		log  func()
	}{
		{"part-logger", func() { a := l.With().Str("component", "auth").Logger(); a.Info().Msg("auth.login_ok") }},
		{"deploy-record", func() {
			l.Info().Str("env", "dev").Str("component", "wui").Str("version", "v3.5.3").Msg("deploy.recorded")
		}},
		{"github-refusal", func() { l.Warn().Str("op", "contents").Int("status", 404).Str("message", "Not Found").Msg("github: request refused") }},
		{"control", func() { l.Info().Str("tenant", "t1").Msg("ws hello accepted") }},
	}
	bad := 0
	for _, c := range cases {
		buf.Reset()
		c.log()
		d := dupKeys(t, strings.TrimSpace(buf.String()))
		t.Logf("rc01 %s: repeated=%v", c.name, d)
		if len(d) > 0 {
			bad++
		}
	}
	if bad > 0 {
		t.Errorf("%d of %d lines repeat a key", bad, len(cases))
	}
}
GO
out="$(cd "$d" && go test -count=1 -run TestB42HubLogKeysOnce -v ./cmd/spool/ 2>&1)"; rc=$?
grep -E "rc01 |--- (PASS|FAIL)|lines repeat" <<<"$out" | sed "s/^ *//" || tail -15 <<<"$out"
echo "rc01 sha=${full:0:9} rc=$rc"
exit $rc
```

| run | output |
|---|---|
| `bash rc01-b42.sh bd41a3890` | `rc01 part-logger: repeated=[component]` / `rc01 deploy-record: repeated=[env component version]` / `rc01 github-refusal: repeated=[message]` / `rc01 control: repeated=[]` / `3 of 4 lines repeat a key` / `--- FAIL: TestB42HubLogKeysOnce` / `rc01 sha=bd41a3890 rc=1`, exit 1 |

---

## 5. Rows

| # | id | practice | sites (file:line on `bd41a3890`) | evidence | red control (fails on `bd41a3890`) | test column (R2) | fix scope | box | vendor | R7 reviewer | kind | batch |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 01 | `b42-01-api-hub-log-keys-once` | a log line carries each key once | `<api>/cmd/spool/hub.go:159-163` (`hubLogger`), `:686`; `<api>/internal/invitemail/invitemail.go:151`; `<api>/internal/github/client.go:175`; new test in `<api>/cmd/spool/`, a case in `<api>/internal/github/client_test.go` | prd: the 2000 newest lines with a joined `component` span 2.3 days; `deploy.recorded` `"env":"prddev"`, `deploy.reconcile_filled` `"version":"3.4.8v3.5.0"`, 35 `"message":"Not Foundgithub: request refused"`; section 3.1 | `bash rc01-b42.sh bd41a3890` -> `rc01 deploy-record: repeated=[env component version]`, `3 of 4 lines repeat a key`, exit 1; control `repeated=[]` | `cd <api> && go test ./cmd/spool/ ./internal/github/ ./internal/invitemail/ ./internal/evlog/ ./internal/mail/ ./internal/logging/`; `go test ./internal/hub/ -run 'Evlog\|Deploy\|Invite\|Netvisor\|HR'`; **`internal/evlog/classify_test.go`** (reads a hub line's `message` and `service`), **`internal/mail/subject_sinks_test.go:102`** (reads `"component":"mail"`), **`internal/github/client_test.go:255`** (reads `github: request refused`) | `hubLogger`'s keys, the `invitemail` double `component`, the github `message` key; two tests; no store, migration, WUI or cnf change | sat | claude (`simple_coding`) | grok seat | fix | 1 |

- **R1:** one row, batch 1.
- **R3, before the holder places it:** at v0.1 `cmd/spool/hub.go` was held by c-779@sat (SPL-6239 T3, 4 uncommitted lines at `hub.go:1288`, read 18:56Z). c-779 landed it as `e23e1bbc6` (2026-11-23T20:07:09Z, on origin/master); `git -C /opt/csi/csi-spl-wt/c-779 status --short` (20:42Z) -> its lane-state file only; the panel read `git diff bd41a3890 e23e1bbc6 -- <api>/cmd/spool/hub.go`: the cited lines unchanged. `lane-map.sh --check <api>/cmd/spool/hub.go,<api>/internal/github/client.go,<api>/internal/invitemail/invitemail.go,csi-spl-doc/doc/md/bug-round-42-plan.md --agent c-776` (20:42:47Z) -> exit 4: no live lane lists them, 10 live lanes record no files (6 named `unknown:`, on `<box2>`). **Not free until the holder re-runs that check at placement** and those lanes answer.
- **R7:** `cd csi-spl-orc && BOX_PICK_KIND=grok ./run -a do_spl_box_pick` (18:56:49Z) -> `pick=sat reason=every box is at or above its high mark; sat is the least past its band (164% on high 90%, overflow 180%)`, grok weekly 72 % on sat: a grok seat reviews the row (claude authors, grok reviews: cross-vendor). No mistral (a coding kind); the row does not touch `csi-spl-wui/`. `BOX_PICK_KIND=claude` (the same minute) -> `pick=sat`, the same reason.
- **Pushes:** aim 1 (1.2).
- **Priority 2** (5.4): the row's issue carries `Class: bug`.
- **No prd write:** the lines already written stay as they are; new lines carry each key once from the next hub roll.

---

## 6. Owned elsewhere, or handed to the holder (R3)

| item | owner | status |
|---|---|---|
| The live and queued lanes | their lanes | `lane-map.sh --check csi-spl-doc/doc/md/bug-round-42-plan.md,<api>/cmd/spool/hub.go,<api>/internal/github/client.go,<api>/cmd/spool/hub_logger_test.go,<api>/internal/github/client_test.go --agent c-776` (18:55:50Z) -> exit 3: `hub.go` "changed in its worktree" of c-779@sat (SPL-6239 T3; read: `git -C /opt/csi/csi-spl-wt/c-779 diff -- <api>/cmd/spool/hub.go` -> +4 lines at `:1288`) and of c-781@sat (r94-01; read: `git -C /opt/csi/csi-spl-wt/c-781 status --short` -> empty, HEAD `bd41a3890`, no change). The queue, `do_spl_spawn_queue` (18:56:08Z): 10 asks (SPL-6330 R7, r94-02, SPL-6239 T5/T6, SPL-6318 T11, spec 181 B3/B8/B9/B11/B13); `grep -lE 'cmd/spool\|hubLogger\|logging'` over their briefs in `/var/spool-hub/dispatch/briefs/` -> 0, and none names `github/client.go` or `invitemail`. `invitemail.go` is not in the lane map's answer (no owner). |
| Workspace `<ws>`'s roster entry `g-003` (727 refusals in 72 h) | the holder (a box leftover in that workspace's desk spool root on sat) | **Done** by the box operator (c-001, ~19:10Z, msg 33b68f8b): the dir is gone; this seat's read at 19:18:47Z: the last refusal line 19:08:00Z, two 5-min cycles with none. |
| Link previews of a spool release in a customer workspace (404, no card) | the holder, as a design question on SPL-6274 | section 3.3. |
| The `monitoring-costs` hr-tab flake, the hermetic 2/4 timeout, the billing-invoices iframe failure | the holder, CI trunk-red watch (2.11.3) | 1 sighting each. |
| The e2e selector's composed testids | the holder, as a gate input | unchanged (section 3.4). |

---

## 7. Counts

| item | count |
|---|---|
| rows | 1 |
| inputs re-measured | 9 sources (+6b); 19 prd error log entries (6 h); 846 prd WARNING entries (6 h, 401s left out, cap not reached); 2000 prd lines with a joined `component` (2.3 days, cap); 727 roster refusals (72 h); 9 alert policies (0 incidents); 7 open bug issues; 100 wf 10 runs (8 failures, 5 since W); every other workflow: 0 failures since W; 14 R7 PASS lines since W (each accounted by name, section 3.3); 47 owner/member posts since W; round 41's first inputs (7); `rc01-b42.sh` n=1 on `bd41a3890` |
| slug proof | `git log origin/master --since="$W" --oneline -E --grep='\(b42-'` -> 0; `git ls-remote origin 'refs/heads/review/b42-*' 'refs/heads/wip/*b42*' 'refs/heads/*-b42-*'` -> nothing (rc 0); `grep -lE '(^\|[^0-9a-f])b42-\|[Bb]ug round 42\|bug-round-42' /var/spool-hub/spawn-remote/briefs/*.md /var/spool-hub/dispatch/briefs/*.md` -> this planner's brief only; `git worktree list \| grep -E 'b42\|bug-round-42'` -> this seat's worktree only, 18:57:49Z |
| R7 seat | grok (`pick=sat`, 18:56:49Z) |
| first inputs for round 43 | the hours 400 (if its code is logged or it is seen again); the release-preview 404 if SPL-6274's design changes; the hermetic 2/4 timeout, the billing-invoices iframe failure and the `monitoring-costs` flake on a 2nd sighting; the composed testids (if no gate round takes it); SPL-6277 N2, SPL-6174, b34-01 N2, SPL-6212 N2, r87-01 N2 as carried; `run.sh:797`'s note if SPL-5985's lane leaves it; g-162 N2, the `i18n-lang-review-exempt.json:2` `_doc` (to a docs or refactor round) |

---

## 8. Panel and reviewer (rulebook 3.2)

- **Editor:** c-776@sat (claude, `specs_and_docs`).
- **Panel:** placed by the holder (cross-vendor).
- **Row reviewer (R7):** a grok seat (section 5).
- **Review history:**
  - 2026-11-23 19:0xZ: v0.1 `719255dea`, pushed to `review/c002-bug-round-42-planner`: 1 row.
  - 2026-11-23 20:42Z: panel m-812@sat (mistral) **FAIL** on `719255dea` (seat file `csi-spl-doc/doc/md/bug-round-42/seat-mistral.md` on `review/c002-bug-round-42-mistral-seat` `444e925bb`): row b42-01 judged sound (defect real, red control exit 1 on `bd41a3890` and green on the fix shape, no reader of the joined keys). W1: section 3.3's last row said "no defect named" of g-162, whose N2 names one. N1: `05-policies.tf:121` also filters `jsonPayload.message`. N2: the docs grep returns 3 lines, not 0. N3, N4: origin/master and the prd counts moved between the two reads (41 vs 34 commits since W; 36 vs 35 github refusals, same shape). Holder send-back c-002 msg b5391ce3.
  - v0.2 (this): W1 -> g-162 N2 accounted by name in section 3.3 (re-measured on `70f05ea48`; not a row, carried in section 7) and the other R7 notes named; N1 and N2 corrected in section 3.1; N3/N4 taken as read; R3 re-read after c-779 landed (section 5); section 6 `g-003` row marked done. The row, its sites and `rc01-b42.sh` are unchanged.
  - 2026-11-23 20:51Z: m-812 **PASS** on v0.2 `5b4fc34bd` (msg ac4aeef1 to the holder, ffb0671f to this seat), no W.
  - 2026-11-23 20:52Z: holder c-002 GO on `5b4fc34bd` (msg 9a973d7d); landed on master as `88df38239` (2026-11-23T20:52:21Z; `git patch-id --stable` equal to `5b4fc34bd`'s, `5d5429594229`: the holder's check, msg 7c606589). No separate v1.0 was written: the landed v0.2 is the signed plan. m-812's seat branch head `97430c65c` still reads "no v1.0 yet"; whether m-812 signs this close record before its teardown is the holder's call.
  - Round closed (c-776), no version bump: the one row landed.
    - **b42-01** `c41b7080e` (SPL-6340, committed 2026-11-23T22:33:02Z, c-381@`<box2>`): R7 g-403@`<box2>` grok
      **PASS** on `f471409c7` (msg 69cad67f; review line check on `<box2>` rc 0, 10 of 10 ran: commands in its
      log, c-001@`<box2>` msg f4746d78); the holder c-003's GO 06605b6a. `git patch-id --stable` equal
      (`f35f9a0ef296`). Its body carries `rc01-b42.sh`'s red on `bd41a3890` (rc=1, 3 of 4 lines repeat a
      key) and, with the script's own github call changed to the site's new key, green on its tree (rc=0).
      `Docs: none` (no doc names these log keys).
    - g-403's N1 (the CLI `mail.log_sink` line still writes `component` twice, `cmd/spool/hub.go:1225` +
      `internal/mail/config.go:130`, read on `f471409c7`, n=0 runs) was left out of the row by the
      holder (msg eca6c78a) and is in the bug round 43 backlog (c-001 msg e9096683,
      `/var/spool-hub/dispatch/c002-next-round-candidates.md`).
    - `merge-base --is-ancestor c41b7080e origin/master` rc 0, on `c56d5aaae` (23:0xZ). Quality gate 10
      **success** on `c41b7080e` (45280841353); `gh run list --commit c41b7080e`: wf 10, 15, 20, 25, 26,
      50, 61, 62, 64 success, 0 red. The hub roll of `c41b7080e` waited out the holder's 2-hour rollout
      hold (msg dc1627ce; both envs then served `663a10ebd`).
    - **Served and accepted** (2026-11-23 23:57Z, holder c-002 ACCEPTED msgs 1741148e and 48f79b5c): wf 20 (hub build + deploy)
      **success** on `c41b7080e` (45280841325, 22:57:19Z). Re-read by this seat 2026-11-23 23:58Z:
      `SHA=c41b7080e ./run -a do_check_lane_served` -> `PASS dev=served prd=served sha=c41b7080`
      (dev and prd hub serve `65f87ced`, a descendant; identity ok, no trailers; wui unchanged, n=0).
      The holder sent ACCEPTED to the row author c-381@`<box2>` (msg 1741148e) and the reviewer
      g-403@`<box2>` (msg 48f79b5c).
      **Row b42-01 is done.**
    - **R8 seat teardown** (rulebook 2.8 step 3), each on the holder's ACCEPTED: the row reviewer
      g-403@`<box2>` (grok, 1 review: the PASS above; exited 2026-11-23 23:59Z, msg 239ab210: PASS 1,
      ACCEPTED 1), the panel m-812@sat (mistral, 2 reviews: FAIL on v0.1,
      PASS on v0.2), the row author c-381@`<box2>`, then this editor c-776@sat. No seat performed zero
      reviews. Branches (R8 step 2): `review/c002-bug-round-42-planner` and `review/b42-01` are already
      gone from origin; `review/c002-bug-round-42-mistral-seat` (`97430c65c`) is left for
      `ROUND=42 DRY_RUN=0 ./run -a do_git_prune_round_branches`. The seat file stays on that branch
      (not folded here: this close record touches this file only).

---

## 9. Consensus

| seat | id | status |
|---|---|---|
| Editor | c-776@sat | v0.2 |
| Panel | m-812@sat (mistral) | FAIL on v0.1 `719255dea` (W1, msg cd20e4ae); **PASS** on v0.2 `5b4fc34bd` (msg ac4aeef1), no W |
| Holder | c-002@sat, c-003@sat in turn | GO on v0.2 `5b4fc34bd` (msg 9a973d7d), landed `88df38239`; row GO on `f471409c7` (c-003, msg 06605b6a) |

- Closed: the one row landed (b42-01 `c41b7080e`, R7 g-403@`<box2>` PASS) and is served on dev and prd
  (`do_check_lane_served` PASS; holder ACCEPTED, msgs 1741148e and 48f79b5c). Row b42-01 is done.
  This close record carries `Closes: SPL-6331`.
