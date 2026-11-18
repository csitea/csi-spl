# Spec review SPL-5884 — mistral verdict on `94e046bb`

- Reviewer: m-534, placement `c002-spl5884-spec-mistral-reviewer`, issue SPL-5884, epic SPL-2403.
- Reviewed sha: `94e046bbfcb17e6088048e23db957984d5c16800`, branch
  `review/c002-spl5884-message-kinds-seven-spec`, base `405fe0885`.
  `git fetch origin review/c002-spl5884-message-kinds-seven-spec` then
  `git rev-parse FETCH_HEAD` printed `94e046bbfcb17e6088048e23db957984d5c16800`;
  `git log --oneline -3 FETCH_HEAD` printed `94e046bbf docs(spec-033, SPL-5884): ...`
  on `405fe0885`; `git diff --stat 405fe0885 FETCH_HEAD` printed
  `csi-spl-doc/specs/033-spool-message-levels/spec.md | 271 ++++... 1 file changed, 269 insertions(+), 2 deletions(-)`.
- Section under review: "Message kinds: seven more (SPL-5884)", K.1-K.8.
  `git show 94e046bb:csi-spl-doc/specs/033-spool-message-levels/spec.md | wc -l`
  -> 416; `grep -n '^## Message kinds: seven more\|version: 0.2.0'` -> header at
  line 149, version comment at line 416. So the section is lines 149-416
  (the brief said 149-415 per the author; line 416 is the version comment).
- Every code cite below was checked at `405fe0885` (the sha the spec itself
  names) with `git show 405fe0885:<file> | sed -n '<N>p'`; the printed line is
  quoted. origin/master has since moved to `b36b2057`; `git diff --stat
  405fe0885 origin/master` over the cited api/wui/rdb dirs prints no file, so
  the cites hold on current master too (only orc blog/box-state files moved).

## Verdict: FAIL (fixable — W1 is substantive, W2-W3 are cite cosmetics)

Checks 1, 3, 4, 5, 6, 7, 8 pass. Check 2 (the routing rule) fails: K.3's
"every site that branches on a kind" table misses one site that lists `note`
by name, where a new kind would NOT behave as a note (W1).

## Check 1 — the owner's ask is covered: PASS

The 7 kinds (feature, bug, alert, question, idea, decision, docs — the owner's
poll answer `F,B,AL,Q,I,D,DOC`, quoted in the author brief and in spec K.1) are
all in the same kind menu, each with icon, dark + light colour tokens, a picker
key, a search token and a one-line meaning (spec K.2 table, lines 178-186).

- Keys: `git show 405fe0885:csi-spl-wui/src/utils/kind-picker-keys.ts | sed -n '13,20p'`
  printed `KIND_KEYS = { msg: 'M', note: 'N', task: 'T', blocker: 'B', result: 'R', reject: 'J' }`.
  The spec's new letters F U A Q I D O share none of M N T B R J; all 13 are
  unique. Keys act only while the picker is open:
  `git show 405fe0885:csi-spl-wui/src/components/KindPicker.vue | sed -n '107p'`
  printed `const picked = keysOn.value ? kindForKey(e, MSG_KINDS) : ''`.
- Order: `git show 405fe0885:csi-spl-wui/src/utils/msg-kind.mjs | sed -n '9p'`
  printed `export const MSG_KINDS = ['msg', 'note', 'task', 'blocker', 'result', 'reject']`
  (today's six; the spec's 13-list is the T025 target).
- Search: `git show 405fe0885:csi-spl-wui/src/utils/search.mjs | sed -n '60p'`
  printed the `is:` suggestion list with the six kinds plus relay/root/online/offline/revoked.
- Old colours/frame rule: `git show 405fe0885:csi-spl-wui/src/assets/css/main.css | sed -n '566,573p'`
  printed the six `.kind-*` rules and `.kind--icon:not(.kind-blocker) { border-color: transparent; }`
  — frame only on blocker, as K.2 claims.

## Check 2 — routing rule "all 7 behave as a note": FAIL (W1)

Every site K.3 cites was verified at `405fe0885` (each `git show ... | sed -n '<N>p'`):

- `api/internal/store/fleet_ask.go:342` -> `case a.Kind != "blocker" && a.Kind != "task" && a.Kind != "escalation":`
- `api/internal/store/flow.go:204` -> `case m.Kind == "blocker":`
- `api/internal/store/blocker_issue.go:281,338,383,432` -> `kind = 'blocker'`, `m.kind = 'blocker' OR EXISTS (...)`, `m.Kind != "blocker"`, `m.Kind == "blocker"`
- `api/internal/hub/blocker_issue.go:76,427,431` -> `blockerKind = "blocker"`, `if cs[i].To == blockerKind && cs[i].From != blockerKind && msg.ValidKind(cs[i].From) {`, `return "note"`
- `api/internal/hub/human_post_guard.go:75,86` -> `if m.Kind == "blocker" || ...`, `o.Kind == "blocker" && o.ToID == m.To`
- `api/internal/action/action.go:148` -> `case in.Kind != "result":`
- `api/internal/hub/dispatch.go:138` -> `if m.Kind != "task" && m.Kind != "note" {`
- `api/internal/hubclient/hubclient.go:1069` -> `if e.FromBox == wuiBox && m.Kind != "task" && m.Kind != "note" {`
- `api/internal/hub/message_kind.go:58` -> `if !msg.ValidKind(body.Kind) {`
- `orc/features/spawn-agents/lib/spool-asks.inc.sh:65` -> `case "$kind" in blocker|task) ;; *) return 0 ;; esac`
- `orc/features/spawn-agents/scripts/spool-send.sh:590` -> `case "$KIND" in blocker|task) _af="$KIND" ;; esac`
- `orc/run/spl-orch-inbox.func.sh:48,54,86` -> the three jq `select`s on `blocker`/`task`
- `orc/run/spl-agent-handoff.func.sh:266` -> `if m.get("kind") in ("blocker", "msg") ...`
- `orc/features/spawn-agents/scripts/kill-your-self-report.sh:193,196` -> `if [ "$kind" = reject ] ...`
- `orc/run/spl-done-claim-check.func.sh:271` -> `grep -lZE '"kind": *"result"'`; `orc/run/spl-topic-archive-suggest.func.sh:316` -> `m.get("kind") == "result"`; `orc/run/spl-agent-restart.func.sh:767` -> `if [[ "$kind" == blocker ]] ...`
- `orc/run/spl-desk-reply.func.sh:552` -> `[[ "$kind" == blocker ]] && return 0`; `:529` -> DESK_KIND 5 kinds
- the two named sites: `orc/features/spawn-agents/lib/spool-notify-take.inc.sh:23` -> `case "$kind" in task|note|msg) ;; *) return 0 ;; esac`; `orc/run/spl-review-go.func.sh:202` -> `m.get("kind") not in ("result", "note")`
- allow-lists: `api/internal/msg/msg.go:50-56` -> `var validKinds = map[string]bool{ "task": true, ... "msg": true, }` + `const KindList = "task|result|note|reject|blocker|msg"`; `msg.go:199` -> `if !validKinds[m.Kind] {`; `msg.go:385` -> `if !validKinds[s.Kind] {`; `api/cmd/spool/main.go:498` -> `kind := fs.String("kind", "", msg.KindList)`; `orc/.../spool-send.sh:414` -> `case "$KIND" in task|result|note|reject|blocker|msg) ;; *) ... exit 2 ;; esac` (usage `:12`, `:66`), `agent-send.sh:12`, `spool-notify.sh:17`; `orc/run/spl-desk-post.func.sh:62` (5 kinds), `spl-fleet-notice.func.sh:27` (note|blocker); `git grep -n "SPOOL_KINDS\|SPOOL_NOTE_KINDS" 405fe0885 -- csi-spl-orc/src/bash` printed nothing — correct, T024 adds them.

My own sweep (`git grep -nE '\.kind ==|\.kind !=|kind" ==|kind" !=|case "$kind"|kind in \(|Kind == "|Kind != "|ValidKind|validKinds|KindList' 405fe0885 -- csi-spl-orc/src/bash csi-spl-api/src/go/spool-hub-api/internal csi-spl-api/src/go/spool-hub-api/cmd`, tests excluded) found message-kind sites K.3's table does not list:

- **W1 — `orc/run/spl-watchdog.func.sh:1010`** (`spl_wd_job_after`): `git show 405fe0885:.../spl-watchdog.func.sh | sed -n '1010p'`
  printed `[[ "$(jq -r --arg me "$1" '.kind == "note" or ((.from // "") | sub("@.*"; "")) == $me' "$f" 2>/dev/null)" == true ]] || return 0`.
  This site lists `note` by name (K.3's group 2, spec lines 252-258) but is not
  in that table, and T024 (spec line 401) does not patch it. There a new kind
  from another agent is NOT a note: the jq is false, the function returns 0
  ("a job arrived"), so the watchdog treats e.g. a peer's `question` like a
  task and wakes the agent — exactly the escalation the routing rule forbids.
- Note-like sites missed from the table (they test a named kind and a new kind
  falls to the default, so no change is needed, but K.3's "every site" claim at
  spec line 231 should name them): `spool-send.sh:231` (`.kind == "task"`),
  `spl-watchdog.func.sh:996` (`.kind == "result"`), `spl-lane-rotate.func.sh:963`
  (`.kind == "result"`), `spl-rotate-lib.func.sh:1844` (`.kind == "result"`),
  `spl-wd-orch-outcome.func.sh:119` (`.kind == task`),
  `spl-agent-restart.func.sh:768` (`elif [[ "$kind" == result ]]`, same branch
  as the cited :767), `spl-peer-poll.func.sh:317` (rewrites `.kind = "note"` on
  a DEAD delivery — a new kind is overwritten to note there anyway).
- API side is complete: the sweep over `internal/` + `cmd/` found no further
  message-kind branch (the other `Kind` hits are agent-id, token, flow-line,
  payroll and attachment kinds, not message kinds).

## Check 3 — old-client claim (K.4.3): PASS, gate design sound

- `git show 405fe0885:api/internal/hubclient/hubclient.go | sed -n '1063p'` ->
  `return e.Inner()`; `.../internal/wire/wire.go | sed -n '1056p'` ->
  `if err := m.Validate(); err != nil {`; `.../internal/hubclient/commit.go | sed -n '36p'`
  -> `m, err := e.Inner()`; `.../internal/hub/ws.go | sed -n '657,659p'` ->
  `m, err := env.Inner()` / `x.fail(ctx, "", "bad_json", http.StatusBadRequest, ...)`.
  So an old box refuses a new-kind frame at recv and never commits it — the
  K.4.3 chain is real. `.../internal/hubclient/flush.go | sed -n '340p'` ->
  `// reject moves a pending envelope that will never be accepted to rejected/,`
  (the spec honestly marks the rejected/-vs-pending trace as not done).
- The gate fits the existing mechanism: `git show 405fe0885:api/internal/hub/ws.go | sed -n '82,94p'`
  printed `func (x *session) accepts(v int) bool { ... }` (hello `msg_versions`);
  `git grep -n "x.features" 405fe0885 -- api/internal/hub` ->
  `backfill.go:232: func (x *session) has(f string) bool { return slices.Contains(x.features, f) }`,
  used as `x.has(wire.FeatureCommit)` (commit.go:28) etc.
  `git show 405fe0885:api/internal/wire/wire.go | sed -n '115,135p'` printed
  `FeatureBackfill`/`FeatureFallback`/`FeatureCommit`/`FeatureLiveAck` consts.
  `git grep -n "kinds13\|FeatureKinds13\|acceptsKind" 405fe0885 -- csi-spl-api/...`
  printed nothing — correct, T023 adds them. The four `accepts` sites are
  exactly as cited: `hub/commit.go:65`, `hub/backfill.go:209`, `hub/fallback.go:88`,
  `hub/message_move_notice.go:97` (each `x.accepts(wire.InnerVersion(...))`).
  So `session.acceptsKind(k)` next to `accepts`, checked at those four sites,
  keeps an unreadable-kind frame queued exactly like a v:2 frame for a v:1 box.
  Sound.
- Old WUI (K.4.1): `git show 405fe0885:csi-spl-wui/src/components/KindGlyph.vue | sed -n '29p'`
  and `KindBadge.vue | sed -n '81p'` -> label falls back to the kind's word when
  the locale has no key; `msg-kind.mjs | sed -n '21,23p'` ->
  `return KIND_ICONS[String(kind || '')] || ''`. An old WUI shows the word, no
  glyph, no colour; nothing breaks. Shift+K still opens the picker:
  `KindKeyHost.vue` `isShiftK` (ev.shiftKey && key K). The spec itself marks
  this "read from the code, not tested in a browser" — honest.
- WUI-set kinds never reach a box as new kinds: `git show 405fe0885:csi-spl-rdb/.../0060_message_kind_changes.sql | sed -n '5,11p'`
  printed the comment "The envelope keeps the kind it was sent with" — matches K.4.3's last paragraph.

## Check 4 — migration: PASS

- Named, not written, forward-only: spec K.5 (lines 334-345) says so; no
  migration file in the diff (`git diff --stat 405fe0885 94e046bb` -> only spec.md).
- Both CHECKs: `git show 405fe0885:csi-spl-rdb/.../0058_message_kinds.sql | sed -n '12p'`
  -> `CHECK (kind IN ('task', 'result', 'note', 'reject', 'blocker', 'msg'))` on
  `messages_kind_check`; `0060_message_kind_changes.sql | sed -n '33,36p'` ->
  `kind_from text NOT NULL,` (no CHECK) and `kind_to ... CONSTRAINT message_kind_changes_kind_to_check CHECK (kind_to IN (...))`.
  So widening `messages.kind` and `kind_to` (leaving `kind_from` free) is exactly right.
- Next free number: `git ls-tree -r --name-only 405fe0885 csi-spl-rdb/src/sql/postgres/spool-hub | sort | tail -1`
  -> `0294_hours_prices.sql` (head = 0294 as the spec says, line 336);
  `git ls-remote origin 'refs/rdb-claims/*' | awk '{print $2}' | sort | tail -1`
  -> `refs/rdb-claims/0294`. Next free = 0295, claimed at build time by
  `do_rdb_migration_next` as the spec says. (I did not claim it.)

## Check 5 — i18n: PASS

- `git ls-tree 405fe0885 csi-spl-wui/i18n/locales/ --name-only | wc -l` -> 19,
  and the names are exactly the 19 the K.6 table lists (en + bg el es et fi he
  lt lv mk nl pl ro ru sk sr sv tr uk).
- `git show 405fe0885:csi-spl-wui/i18n/locales/en.json | sed -n '694,701p'`
  printed the six `feed.kind.*` entries under `"kind": {`.
- agy review before the WUI ships: spec K.6 line 356 ("agy has the final word",
  `/agy-spawn`, `LANE_MIX_KIND=i18n`, "The WUI does not deploy before it") —
  matches the fleet language rule. The es/fi `idea` keep-english note and the
  never-raise-the-baseline rule are consistent with developer guide 2.7.2/2.7.3.

## Check 6 — build rows T020-T027: PASS (one wrong path cite, W2)

Rows are dependency-ordered hub (T020-T023 + one deploy) -> CLI/orc (T024) ->
WUI (T025) -> help/docs (T026) -> live proof (T027); each row names its test and
its red control (spec lines 397-403). Help docs go through their Qto docs, not
by hand: `git show 405fe0885:csi-spl-doc/doc/help/how-to-post.md | sed -n '3p'`
-> "Generated from qto doc `0d291303-2b30-4b23-8541-cd2ff5863387`";
`git show 405fe0885:csi-spl-doc/doc/help/message-actions-and-formatting.md | sed -n '3p'`
-> "Generated from qto doc `bf244c37-39b0-40c1-9567-b8ec5fd94913`" — both ids as
T026 names them. Its "kinds table lists 4 of the 6" claim:
`git show 405fe0885:.../message-actions-and-formatting.md | sed -n '131,141p'`
printed section 3.5 with rows note/task/result/reject only — verified.
`git show 405fe0885:csi-spl-doc/specs/020-spool-message-v2/contracts/message-schema-v2.md | sed -n '21p'`
printed the `kind` row with the six kinds — the T026 schema target, line 21 as cited.
Test files named exist: `git ls-tree 405fe0885 csi-spl-wui/tests/unit/calendar-phone-tokens.test.mjs`,
`tests/unit/msg-kind.test.mjs`, `tests/unit/kind-picker-keys.test.mjs`,
`tests/e2e/kind-picker-keys.test.mjs`, `csi-spl-wui/src/utils/uiIcons.ts`,
`csi-spl-wui/i18n/i18n-keep-english.json` — all printed by `git ls-tree`.
`do_spl_spool_refresh` exists: `git grep -ln do_spl_spool_refresh 405fe0885 -- csi-spl-orc/src/bash/run`
-> `spl-spool-refresh.func.sh` (also spl-box-update, spl-skills-refresh).

## Check 7 — open questions Q1-Q5: PASS

Spec lines 407-413: each of Q1-Q5 is a real owner decision with a proposed
default (column A) and an alternative (column B), each answerable A or B
without reading the rest of the spec, and each cites the code site it touches
(e.g. Q1 -> `fleet_ask.go:342`, Q2 -> `human_post_guard.go:75`, Q3 ->
`spl-agent-handoff.func.sh:266`, Q4 -> `spl-desk-post.func.sh:62` /
`spl-desk-reply.func.sh:529`, Q5 -> the picker letters). All five cites verified
above.

## Check 8 — repo rules: PASS

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` (run in the worktree
  checked out at 94e046bb, so the spec file is in the scanned tree) ->
  `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-534`, exit 0.
- `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift` ->
  `OK fleet rules: no drift over 9 pinned facts in /opt/csi/csi-spl-wt/m-534`, exit 0.
- No literal host/domain, box name, OS user or personal name in the section
  (the hygiene gate covers the tracked tree; the spec names only repo paths,
  agent ids and msg ids).

## Defects

- **W1** (spec lines 231, 252-258, 401): K.3's group-2 table and T024 miss
  `orc/run/spl-watchdog.func.sh:1010` (`spl_wd_job_after`,
  `.kind == "note" or from == me`). A new kind from another agent is treated
  there as a job (the watchdog wakes the agent), not as a note — the routing
  rule "all 7 behave as a note" is false at this site unless T024 adds the 7
  (or `SPOOL_NOTE_KINDS`) there too. Fix: one row in the K.3 group-2 table and
  one clause in T024(d).
- **W2** (spec line 402): T025 cites `types/spool.ts:1` for `MsgKind`. Under the
  spec's own root convention (`wui/` = `csi-spl-wui/`),
  `git show 405fe0885:csi-spl-wui/types/spool.ts` -> `fatal: path ... does not exist in '405fe0885'`.
  The real path is `csi-spl-wui/src/types/spool.ts:1`:
  `git grep -n MsgKind 405fe0885 -- csi-spl-wui` ->
  `src/types/spool.ts:1: export type MsgKind = 'task' | 'result' | 'note' | 'reject' | 'blocker' | 'msg'`.
  Line 1 matches; the path needs `src/`.
- **W3** (cosmetic): the brief says the section is lines 149-415; at 94e046bb it
  is 149-416 (line 416 is the `<!-- version: 0.2.0 ... -->` comment).

## Notes

- N1: the `is:` enum at `api/internal/search/grammar.go:181-182` already holds 7
  values (the 6 kinds plus `relay`, agent-to-agent mail that search leaves out
  unless asked — `match.go:101` special-cases it, `match.go:104` is the generic
  `m.Kind == t.Enum` the spec cites). Adding the 7 new kinds makes 14 enum
  values; T022's test should count 14, not 7.
- N2: K.2's dark colours match the calendar palette hexes in
  `variables.css:420-446` exactly for 6 of 7 kinds (feature `#8c9eff`=blueberry,
  bug `#ff8a5c`=tangerine, alert `#ffd54f`=banana, question `#c770e0`=grape,
  idea `#f2a29c`=flamingo, docs `#a0a0a0`=graphite); `decision` `#2dd4bf` is not
  a cal-palette value. Of the light values, 4 coincide with cal light hexes
  (`#3f51b5`, `#f6bf26`, `#8e24aa`, `#616161`); the rest are new darker tokens.
  "Repeat hues / darker variants" is accurate prose; the `--color-kind-*`
  tokens themselves are new variables in the `:root` blocks at
  `variables.css:391-398` (verified pattern).
- N3: topic `f4165bc3-ff18-4781-8a81-e555ad21ba31` is not readable from this
  box: `SPOOL_ROOT=/var/spool-hub spool tail --task f4165bc3-...` ->
  "no messages visible to this box in the local spool". K.1's owner quotes were
  checked against the author brief's verbatim quotes (msg `3ca36ae0`,
  `890eadfb`) and match; the spec itself flags `ddc6f29a` as not checked.
- N4: `lane-map.sh --check csi-spl-doc/specs/033-spool-message-levels/review-spl5884-mistral.md --agent m-534`
  exits 4 (14 live lanes record no files, including the author c-847). My
  brief names this exact file as the one deliverable, so I proceeded; flagging
  per the exit-4 rule.
- N5: `api/internal/msg/msg_test.go:61` loops over the 6 kinds today
  (`for _, k := range []string{"task", "result", "note", "reject", "blocker", "msg"}`);
  T021's "loops over all 13" is a change to that test, correctly scoped.
- N6: the WUI has no message-kind branch sites beyond the picker/badge CSS and
  `msg-kind.mjs` (sweep over `csi-spl-wui/src`); `AgentSplitKinds.vue` is the
  task-kind domain, unrelated.

<!-- review by m-534, 2026-11-18, on 94e046bbfcb17e6088048e23db957984d5c16800 -->
