# SPL-5884 review (mistral): spec 033 section K, the owner's answers Q1-Q5

Reviewer: m-674 (mistral), cross-vendor reviewer; the author is c-667 (claude).
Reviewed sha `7e6e431830162f480be831c4a939253e8c4bea5e`, branch
`review/c002-spl5884-spec-k8-owner-answers`, diff base `648ff3b0a` (on
origin/master). Read-only on the tree: no code, no spec, no master was touched;
the only file this lane writes is this one.

Verified before the review:

- `git ls-remote origin 'review/c002-spl5884*'` -> `7e6e431830162f480be831c4a939253e8c4bea5e refs/heads/review/c002-spl5884-spec-k8-owner-answers` (matches the brief)
- `git merge-base --is-ancestor 648ff3b0a 7e6e43183` -> exit 0 (the sha sits on 648ff3b0a)
- `git diff --stat 648ff3b0a 7e6e43183` -> `csi-spl-doc/specs/033-spool-message-levels/spec.md | 60 +++... 1 file changed, 42 insertions(+), 18 deletions(-)`

Every file:line cited below was checked with `git show <sha>:<file> | sed -n '<N>p'`
and the printed line is quoted. Spec line numbers are on the reviewed sha
`7e6e43183` unless a different sha is named.

## 1. Verdict

**FAIL** on `7e6e43183`. One defect, W1: exception E3 widens a third `DESK_KIND`
site (`do_spl_fleet_notice`) that the owner's Q4 answer does not name, and
presents it as part of msg `67193a13`. Checks 1, 2, 4, 5, 6 pass; in check 3 the
author's call (a) is sound and call (b) is not.

## 2. Check 1 — K.8: Q1-Q5 marked answered, exact answers, msg id

`git show 7e6e43183:csi-spl-doc/specs/033-spool-message-levels/spec.md | sed -n '439,456p'`
-> K.8 is renamed "The owner's answers (was: open questions)" (spec.md:439), names
owner HUM-10, t1 topic `f4165bc3`, msg `67193a13-e177-48fd-a8b1-54ad7a410ea7`, poll
`4faee45c`, and quotes verbatim:

> Answer 1: A — No: a yellow badge only, like a note
> Answer 2: B — Yes: a question is let through, as a blocker is
> Answer 3: B — Yes: it is listed next to blockers
> Answer 4: B — Yes: desk posts may set them too
> Answer 5: A — U (bUg) and O (dOcs)

Compared with the author brief's quote of the same msg: all five lines match
character-for-character. The `answered` column reads A, B, B, B, A
(spec.md:452-456), matching the answers.

Q1 A and Q5 A "match the existing defaults" — checked on `648ff3b0a`:

- Q5 A (`U` bUg, `O` dOcs): the old K.2 table already gives `bug` the picker key
  `U (b**U**g; B is blocker)` and `docs` `O (d**O**cs; D is decision)`
  (`git show 648ff3b0a:...spec.md | sed -n '186,193p'`), and T025's
  `KIND_KEYS F U A Q I D O` with the test "`U` gives `bug`, `O` gives `docs`" is
  an unchanged row in this diff. The default was A. OK.
- Q1 A (alert = a yellow badge only, no ask, no page): old K.2
  (`git show 648ff3b0a:...spec.md | sed -n '204p'`) -> "`alert` is filled: yellow,
  with a dark glyph. Blocker is the only other filled badge"; asks:
  `git show 648ff3b0a:csi-spl-api/src/go/spool-hub-api/internal/store/fleet_ask.go | sed -n '342p'`
  -> `case a.Kind != "blocker" && a.Kind != "task" && a.Kind != "escalation":` —
  alert raises no ask. The default was A. OK.

Not verified from this box: msg `67193a13` itself lives in the hub's t1 topic,
which a lane box cannot read; the msg id and the five answers are quoted
identically in the author's brief and in this lane's brief (N4).

## 3. Check 2 — K.3 E1-E3: every cited file:line on 648ff3b0a

The spec's path prefixes (spec.md:157-159 on 648ff3b0a): `api/` =
`csi-spl-api/src/go/spool-hub-api/`, `orc/` = `csi-spl-orc/src/bash/`, `rdb/` =
`csi-spl-rdb/src/sql/postgres/spool-hub/`. Two files are named
`human_post_guard.go` (`internal/hub/` and `internal/store/`). The diff cites
`api/internal/hub/human_post_guard.go:75` — the `api/` + `internal/hub/` prefix
names the hub one unambiguously — and cites the store one separately as
`api/internal/store/human_post_guard.go:13`. So yes, it names which one.

| citation (as the diff writes it) | `git show 648ff3b0a:<file> \| sed -n '<N>p'` printed | matches the row's "today" |
|---|---|---|
| `api/internal/hub/human_post_guard.go:75` | `if m.Kind == "blocker" \|\| s.storedChannel(ctx, tenant, env, m) != "" {` | yes: for a DM (no channel) only `blocker` passes |
| `api/internal/hub/human_post_guard.go:86` | `if o.FromID == m.To \|\| (o.Kind == "blocker" && o.ToID == m.To) {` | yes: only a topic opened by a blocker DM to that person allows the follow-up |
| `api/internal/hub/human_post_guard.go:97` | `return &frameRefusal{TokenDMNotBlocker, http.StatusForbidden, "a DM to " + m.To + " must be a blocker (kind blocker) or answer a DM " + m.To +` | yes: the refusal text |
| `api/internal/hub/human_post_guard.go:18-19` | comment: `1. dm_not_blocker: a DM (the topic has no channel) from an agent to a` / `person is refused unless it is a blocker, it answers a DM that person started` | yes: the comment names the rule |
| `api/internal/store/human_post_guard.go:13` | `//   - a DM to a person is a blocker, or answers a DM that person started or` | yes |
| `orc/run/spl-desk-reply.func.sh:296` | `if [[ "$1" == *dm_not_blocker* ]]; then` | yes: the desk matches the token |
| `orc/run/spl-agent-handoff.func.sh:266` | `if m.get("kind") in ("blocker", "msg") and heard.get(...) <= str(m.get("ts") or ""):` | yes: exactly the quoted `("blocker", "msg")` |
| `orc/run/spl-desk-post.func.sh:62` | `[[ "$kind" =~ ^(note\|task\|result\|blocker\|msg)$ ]] \|\| { do_log "FATAL DESK_KIND must be note, task, result, blocker or msg, ...` | yes: 5 kinds |
| `orc/run/spl-desk-post.func.sh:35` | `# @param DESK_KIND (optional) - note (default) \| task \| result \| blocker \| msg` | yes |
| `orc/run/spl-desk-post.func.sh:96` | `--kind "$kind" --body "$body" "${ids[@]}" 2>&1)" \|\| rc=$?` | yes: `spool send --kind` |
| `orc/run/spl-desk-reply.func.sh:529` | `[[ "$kind" =~ ^(note\|result\|reject\|blocker\|msg)$ ]] \|\| { do_log "FATAL DESK_KIND must be note, result, reject, blocker or msg, ...` | yes: 5 kinds |
| `orc/run/spl-desk-reply.func.sh:134` | `# @param DESK_KIND (optional) - note (default) \| result \| reject \| blocker \| msg` | yes |
| `orc/run/spl-desk-reply.func.sh:297` | `do_log "FATAL nothing was sent: a DM to $ans_to must be a blocker (DESK_KIND=blocker) or answer a DM $ans_to started or wrote in (how-to-post.md rule 18, ...)"` | yes: the FATAL T024 (g) rewrites |
| `orc/run/spl-desk-reply.func.sh:315,325,342` | each: `--kind "$kind" --body ... "${ids[@]}" ...` | yes |
| `orc/run/spl-fleet-notice.func.sh:27` | `[[ "$kind" =~ ^(note\|blocker)$ ]] \|\| { do_log "FATAL DESK_KIND must be note or blocker, ...` | yes: 2 kinds |
| `orc/run/spl-fleet-notice.func.sh:18` | `# @param DESK_KIND (optional) - note (default) \| blocker` | yes |

Also verified on 648ff3b0a: `api/internal/spool/spool.go:261` ->
`if err := m.Validate(); err != nil {`, inside `func (s *Store) Compose(...)`
declared at :246, so the "in `Compose`" claim is right; `api/internal/msg/msg.go:50-56`
-> `validKinds` (6 kinds) and `KindList`; `api/internal/msg/msg_test.go:61` ->
`for _, k := range []string{"task", "result", "note", "reject", "blocker", "msg"} {`
("loops over the 6 today"); `api/internal/hub/human_post_guard_test.go:51` ->
`func TestHumanPostGuardDMRule(t *testing.T) {`;
`orc/tests/agent-handoff.tst.sh:100` -> the blocker open-question case
(`grep -q 'blocker to c-002, task topic-a' "$T/oq"`);
`orc/tests/desk-actions.tst.sh:582` -> `"DESK_KIND=reject"` in the `do_spl_desk_post`
refusal loop; `orc/tests/desk-reply-human-guard.tst.sh:66` -> greps
`'FATAL nothing was sent: a DM to HUM-10 must be a blocker (DESK_KIND=blocker)'`;
`specs/020-spool-message-v2/contracts/message-schema-v2.md:21` -> the `kind` row
listing the 6; `spool-send.sh:414` (6-kind case) and `:590` (`blocker|task`),
`agent-send.sh:12`, `spool-notify.sh:17`, `spool-notify-take.inc.sh:23`
(`task|note|msg`), `spl-review-go.func.sh:202` (the `m.get("kind") not in
("result", "note")` check), `spl-watchdog.func.sh:1010` (`.kind == "note"`),
`spool-asks.inc.sh:65` (`blocker|task`) — all as cited.

Each exception's "today" column describes what the cited line does on 648ff3b0a,
and the "change" column says what must change. The "12, 12 and 9" arithmetic
(5+7, 5+7, 2+7) in the group-3 row (spec.md:290) is right. OK.

## 4. Check 3 — the author's two own calls

- (a) E1 also covers `:86` (the follow-up of a question DM) — **yes**. The owner's
  answer 2 is "a question is let through, as a blocker is". The blocker exemption
  from `dm_not_blocker` has two code sites, :75 (the cold DM) and :86 (the
  follow-up in the topic the blocker DM opened), and how-to-post rule 18 lists
  them as one exemption ("...does not follow up a blocker DM to them..."). "As a
  blocker is" reads as the whole exemption, so extending E1 to :86 is faithful.
- (b) E3 also widens `do_spl_fleet_notice` — **no**. Q4's question names
  `do_spl_desk_post`, `do_spl_desk_reply`, and the B option the owner picked names
  exactly `spl-desk-post.func.sh:62` and `spl-desk-reply.func.sh:529`
  (spec.md:455). The owner's answer 4 ("desk posts may set them too") refers to
  that scope. `do_spl_fleet_notice` (`spl-fleet-notice.func.sh:27`) is a third
  `DESK_KIND` site the answer does not cover. The author disclosed the addition in
  the K.8 Q4 cell ("with `spl-fleet-notice.func.sh:27` as well", spec.md:455), but
  the E3 row (spec.md:242), the group-3 row (spec.md:290) and T024 (f)
  (spec.md:434) present it as part of the owner's Q4 B. See W1.

## 5. Check 4 — build rows T021 (b), T024 (e)-(g), T026

- T021 (b) (spec.md:430): test named `api/internal/hub/human_post_guard_test.go:51`
  (`TestHumanPostGuardDMRule`, verified at :51) with the new cases; red controls:
  leave :75 at `m.Kind == "blocker"` -> the `question` DM case goes red; leave :86
  at `o.Kind == "blocker"` -> the follow-up case goes red. Same form as the other
  K.7 rows. OK.
- T024 (e) (spec.md:434): test `orc/tests/agent-handoff.tst.sh` beside its :100
  blocker case (verified); red control (4). OK.
- T024 (f): test `orc/tests/desk-actions.tst.sh:582` (verified: `DESK_KIND=reject`
  refused for `do_spl_desk_post`, plus the new `DESK_KIND=bogus` / `DESK_KIND=bug`
  cases); red control (5). OK — except that (f) also covers
  `spl-fleet-notice.func.sh:27`, see W1.
- T024 (g): test `orc/tests/desk-reply-human-guard.tst.sh:66` (verified: greps the
  FATAL text). No separate red control is listed for (g); the grep test itself
  goes red if the wording is not changed (N3).
- T026 (spec.md:436): the row keeps its old form (test: the export leaves no diff
  beyond the change + `./run -a do_check_fleet_rules_drift`; red control: a hand
  edit of an export is overwritten by the next export). The rule-18 wording change
  is doc-only and rides on T021 (b) / T024 (g). OK.
- No row lost without a reason: the two group-1 rows removed
  (`human_post_guard.go:75,86`, `spl-agent-handoff.func.sh:266`) are accounted for
  by the added line "(E1 and E2 left group 1 for the table above)"; the group-3
  `DESK_KIND` row changed with the reason "(T024, exception E3, owner Q4 B)"
  (spec.md:290). OK.

## 6. Check 5 — nothing else changed

`git diff --stat 648ff3b0a 7e6e43183` -> one file, +42 -18. Section K starts at
spec.md:149 on 648ff3b0a and is the last `## ` section of the file
(`git show 648ff3b0a:...spec.md | grep -n '^## '` -> last hit 149 of 434 lines);
every hunk of the diff (148, 223, 232, 243, 272, 287, 412, 427) is at or after
149, so only section K of that one file changed. OK.

## 7. Check 6 — repo rules (run in this lane's worktree)

- `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> exit 0, "INFO
  distribution-hygiene: clean over the tracked tree"
- `cd csi-spl-orc && ./run -a do_check_fleet_rules_drift` -> exit 0, "OK fleet
  rules: no drift over 9 pinned facts"

## 8. Defects

**W1** — spec.md:242 (E3 row), :290 (group-3 row), :434 (T024 (f)), :455 (K.8 Q4):
E3 widens `do_spl_fleet_notice`'s `DESK_KIND` (`spl-fleet-notice.func.sh:27`) and
presents it as part of the owner's Q4 B (msg `67193a13`), but the question and the
B option the owner picked name only `do_spl_desk_post` and `do_spl_desk_reply`
(`spl-desk-post.func.sh:62`, `spl-desk-reply.func.sh:529`). Fix: drop
`spl-fleet-notice.func.sh:27` from E3, the group-3 row, T024 (f) and the K.8 Q4
cell, or mark it as the author's own extension that needs its own owner answer.

## 9. Notes

- N1 — `fleet_ask.go:342` (spec.md:452, text unchanged from the old K.8) cites a
  bare filename; the file is `api/internal/store/fleet_ask.go` (there is no
  `internal/hub/fleet_ask.go`; `git ls-tree -r --name-only 648ff3b0a | grep
  fleet_ask.go` shows only store paths). Line 342 verified there (the
  `blocker` / `task` / `escalation` case), so the claim is right and the path is
  shorthand. Pre-existing, not introduced by this diff.
- N2 — `watchdog/situations/s1.sh:58` (spec.md:434) is shorthand for
  `orc/features/watchdog/situations/s1.sh`; :58 verified there
  (`$3 != "note"` in `s1_jobs`). Pre-existing.
- N3 — T024 (g) has a named test but no separate red control in the red-control
  column; the grep test is itself the red control.
- N4 — msg `67193a13-e177-48fd-a8b1-54ad7a410ea7` could not be read from this box
  (hub t1 topic); the id and the five answers are quoted identically in the
  author's brief and in this lane's brief.
- N5 — lane-map: `lane-map.sh --check
  csi-spl-doc/specs/033-spool-message-levels/review-spl5884-k8-mistral.md --agent
  m-674` -> exit 4 (14 live lanes that record no files, scope unknown); the spec
  dir itself is owned by c-667 (exit 3 on `spec.md`), which this lane does not
  touch. This lane's brief names exactly this one new file.

## 10. Re-review of the W1 fix — sha `0b221a1565ec27af742c80f405e81f5f76932aea`

**Verdict on `0b221a15`: PASS.** W1 is closed; no new defect found.

Verified before the re-review:

- `git ls-remote origin 'review/c002-spl5884-spec-k8-owner-answers'` ->
  `0b221a1565ec27af742c80f405e81f5f76932aea` (matches the dispatch note)
- `git rev-parse 0b221a15^` -> `7e6e431830162f480be831c4a939253e8c4bea5e` (parent is the reviewed sha)
- `git log -1 --no-mailmap --format='%ae %ce' 0b221a15` -> one address twice,
  the repo CLAUDE.md "Commits:" address (author and committer identical)
- `git diff --stat 7e6e43183 0b221a15` -> 1 file, +9 -6

`git diff 7e6e43183 0b221a15` reviewed hunk by hunk (line numbers on `0b221a15`):

- E3 row (spec.md:242): `spl-fleet-notice.func.sh:27` and its `@param :18` are out
  of the site and change columns; only `spl-desk-post.func.sh:62` and
  `spl-desk-reply.func.sh:529` remain. W1 fix, first option.
- New K.3 sentence (spec.md:247-249): "E3 does not cover `do_spl_fleet_notice`:
  Q4 names only `do_spl_desk_post` and `do_spl_desk_reply`, so
  `spl-fleet-notice.func.sh:27` stays `note|blocker` and widening it would need
  its own owner answer." Accurate: `git show 648ff3b0a:...spl-fleet-notice.func.sh
  | sed -n '27p'` -> `[[ "$kind" =~ ^(note\|blocker)$ ]] ...`.
- Group-3 row (spec.md:293): the site column still lists all three `DESK_KIND`
  sites (correct — the site exists), and the change cell now reads "desk post and
  desk reply: 12 each, today's kinds plus the 7 (T024, exception E3, owner Q4 B);
  fleet notice: unchanged, Q4 does not name it".
- T024 (f) (spec.md:437): names only `:62` and `:529` with `@param :35`, `:134`;
  adds "`spl-fleet-notice.func.sh:27` is not changed"; the test now also pins
  "`do_spl_fleet_notice` still refuses `DESK_KIND=bug`"; red control (6) added for
  (g) ("leave the FATAL at `spl-desk-reply.func.sh:297` naming only `blocker`:
  the `desk-reply-human-guard.tst.sh:66` grep for the new wording goes red") —
  this also closes N3.
- K.8 Q4 cell (spec.md:458): "K.3 exception E3, desk post and desk reply only
  (`do_spl_fleet_notice` is not named, so it is unchanged); built in T024 (f)".
- Version comment 0.3.0 -> 0.3.1.

W1 closed: `git show 0b221a15:...spec.md | grep -n 'fleet-notice\|fleet_notice'`
-> lines 247, 248, 293, 437, 458 only, and each of them says the fleet notice is
not covered / unchanged; nothing attributes its widening to msg `67193a13`
any more. The E3 row (242) no longer mentions it.

No new defect: `git diff --stat 648ff3b0a 0b221a15` -> 1 file, +45 -18, 6 hunks,
all at or after line 148 while section K starts at spec.md:149 on 648ff3b0a, so
still only section K of the one file; the K.8 answer quote block is untouched by
the delta (only the Q4 cell changed); the E1 and E2 rows are untouched, so every
citation verified in section 3 above still stands on `648ff3b0a`.
