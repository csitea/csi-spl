# 065: the release notes table, one row per commit, lay and technical

Status: **owner answering** (section 10): Q1..Q3, Q5, Q7, Q9..Q13 yes, Q8
and Q14 no, Q6 backfill by at least three agents (option to be confirmed);
Q4 explained, answer open (section 11). Build lanes: section
12. Spec only; no code, workflow, gate or `CLAUDE.md` was touched.
Draft 2026-10-03, c-053; answers folded in 2026-10-03, c-067.
Related: [047 deployability](../047-spool-deployability/) (W10, the weekly
stable release, workflow `55_release-stable.yml`), the version mint
`do_release_version` (`csi-spl-orc/src/bash/run/release-version.func.sh`),
the pre-push gate ([pre-push-gate.md](../../doc/md/pre-push-gate.md)).

## 1. What the owner asked (t1 topic `a9df2f55`, verbatim)

> "Create proper release notes table , where each agent must properly exlain
> first il lay non tecnical germs what their commit does , how and why and
> than have the same questions in technical terms,"

**Reading.** A release-notes TABLE with one row per commit. The agent that
makes the commit writes its row: first WHAT / HOW / WHY in plain words a
non-engineer understands, then the same three questions in technical terms.

## 2. What exists today (measured 2026-10-03 on `origin/master`)

Every claim cites the command that produced it.

| # | fact | command -> result |
|---|---|---|
| 1 | No CHANGELOG or release-notes file in the tree; the only "release" files are the mint and the weekly stable cut | `git ls-files \| grep -iE 'changelog\|release'` -> 6 paths: `55_release-stable.yml`, `release-version.func.sh`, `release-stable.func.sh`, `spl-release-version.func.sh`, two `.tst.sh` |
| 2 | Every hub (20) and WUI (30) deploy mints a `v<X.Y.Z>` tag; 629 exist, newest v7.4.1 | `git ls-remote --tags origin 'v*' \| wc -l` -> 629 |
| 3 | ~105 v-tags a day (one per deploy) | `git for-each-ref 'refs/tags/v*' --format='%(creatordate:short)'`, 2026-09-28..10-02 -> 106, 55, 118, 154, 154 |
| 4 | ~240 commits a day land on trunk | `git log origin/master --since='7 days ago' --oneline \| wc -l` -> 1697 (n = 7 days, 103..336 a day) |
| 5 | So a version carries ~2 commits on average | rows 3 and 4 |
| 6 | Agent vs human commits cannot be told apart from the metadata: one author address on every commit | `git log -200 --no-mailmap --format=%ae \| sort \| uniq -c` -> 200, one address. The owner commits through agents, so treat every commit as an agent commit |
| 7 | Subjects already follow a conventional prefix | `git log origin/master --since='7 days ago' --format=%s \| grep -ciE '^(fix\|feat\|perf\|refactor\|test\|docs?\|chore)(\(\|:)'` -> 1618 / 1697 (95 %) |
| 8 | Fewer than half the commits have a body at all | loop over `git log -200 --format=%b`, non-empty -> 95 / 200 |
| 9 | Trailers are rare and ad hoc (`Tests:` 9, `Test:` 4, `Proof:` 4, ...) | `git log -200 --format=%B \| grep -oE '^[A-Z][A-Za-z-]+: ' \| sort \| uniq -c` |
| 10 | Trunk is linear: no merge commits | `git log origin/master --since='7 days ago' --merges --oneline \| wc -l` -> 0 |
| 11 | Reverts are rare | same range, `grep -ci revert` on the subjects -> 5 / 1697 |
| 12 | ~10 % of commits touch only `.md` | loop over `git show --name-only` of the 7-day range, no non-`.md` path -> 167 / 1697 |
| 13 | A weekly stable release exists with GENERATED notes: commits by kind (feat/fix/perf/other) + migrations + upgrade steps, published as a GitHub release | `gh release list -L 3` -> `stable-2026-09-29 (v2.2.0) Latest`; the notes logic is `release-stable.func.sh` lines 15..18 |
| 14 | The WUI shows the version in the footer / logo dialog (`appVersion`) and in `build.json`; no page lists versions or what they contain | `grep -rln appVersion csi-spl-wui --include=*.vue` -> `app.vue`, `LogoDialog.vue`, `MobileStatusStrip.vue`, `ChannelSidebar.vue`, `DebugPanel.vue`; workflow 30 step "Stamp build.json" |
| 15 | The hub DB has 104 forward-only migrations; a new table is a normal change | `ls csi-spl-rdb/src/sql/postgres/spool-hub/ \| wc -l` -> 104 (newest `0104_flow_events.sql`) |

**What this means.** The owner today learns what a version contains only
from commit subjects such as `perf(wui): ...`, written for engineers, and
less than half the commits explain anything beyond the subject. The weekly
GitHub release groups those same subjects. Nothing is in plain words, and
nothing is in the WUI.

## 3. Decision 1: where the table lives

The facts that decide it: ~240 commits a day from many lanes pushing at the
same time (row 4); the owner reads in the WUI (row 14); shipped files obey
the distribution-hygiene sweep (no personal names, no box tags); a commit
is immutable once pushed.

| option | how | for | against |
|---|---|---|---|
| A. One shared file in the repo (`RELEASE-NOTES.md` / `.json`) | every commit appends a row | readable in git, ships with the source | ~240 appends a day to ONE file from parallel lanes = a rebase conflict on nearly every push; the row cannot carry its own sha (the sha does not exist until the commit is made) |
| B. One file per commit in the repo (`csi-spl-doc/release-notes/<id>.md`) | the agent adds a small file with the commit | no conflicts | ~1700 files a week; the file still cannot name its own sha; the sweep has to read every one |
| C. Commit trailers, rendered into a DB table + WUI page | the six answers ride in the commit message as trailers; at deploy the hub ingests the new commits into a `release_note` table; the WUI shows it | no conflicts at all; the row and the change are the same object, so they cannot drift apart; works in a self-hosted clone too (`git log` shows it) | a pushed message cannot be edited (fix: `git notes`, see 6.1); commit messages are not covered by the distribution-hygiene sweep today, so the ingest must run the same filter before a row is shown |
| D. Git notes only | agents attach a note after the push | editable | notes are not fetched or pushed by default, are easy to lose, and cost every lane a second push per commit |

**Recommendation: C.** The commit message is the only place a row can be
written by the agent that made the change, in the same step, without
touching a shared file. The table the owner reads is a projection of it.
Git notes (D) are only the correction path for a row already on trunk.

## 4. Decision 2: the row shape

### 4.1 What the agent writes (trailers, last paragraph of the message)

```text
fix(wui): the unread badge stays after a channel is read

<optional technical body, as today>

Lay-What: The red "unread" dot now disappears once you have read a channel.
Lay-How: The app now tells the server you read it, the moment you open it.
Lay-Why: You saw a dot for messages you had already read, so it was useless.
Tech-What: WUI marks the channel read on open; the hub clears unread_count.
Tech-How: ChannelView calls POST /v1/channels/{id}/read on mount; the store resets the counter in one UPDATE.
Tech-Why: The read call was only sent on scroll-to-bottom, so short channels never sent it.
```

Rules for the agent:

1. Six trailers, each ONE line (a trailer cannot wrap), at most ~200 chars.
2. The `Lay-*` lines use no code names, file names, ids, acronyms or jargon:
   a reader who never saw the code understands them.
3. The `Tech-*` lines name the module, the mechanism and the root cause.
4. No personal names, box tags, hostnames or customer names (the same bans
   as the shipped tree): a row is shown in the WUI.

### 4.2 The table (hub DB, one row per commit)

| column | from |
|---|---|
| `sha` | the commit (primary key) |
| `version` | the first `v<X.Y.Z>` tag that contains the commit (filled by the deploy that minted it) |
| `committed_at` | commit date, ISO 8601 UTC |
| `kind` | the subject prefix (`fix`, `feat`, `perf`, ...) |
| `area` | the subject scope `(wui)`, else the top-level dir touched (`csi-spl-api`, ...) |
| `subject` | the subject line |
| `lay_what`, `lay_how`, `lay_why` | the `Lay-*` trailers |
| `tech_what`, `tech_how`, `tech_why` | the `Tech-*` trailers |
| `state` | `ok` / `missing` (written before 065, or bypassed the rule) / `skip` (5.2) / `revert` |
| `link` | the commit URL, built from cnf (no literal host) |

The WUI page groups rows by `version`, newest first, with the lay columns
visible and the technical three behind an expander on each row.

## 5. Decision 3: enforcement

### 5.1 Where a missing row fails

| place | effect | recommendation |
|---|---|---|
| pre-push gate (local, every lane) | refuses the push when a commit in the pushed range lacks the six trailers or one is empty | **yes**: caught in the lane, before trunk, in under a second; a new lint part `release-note` |
| CI (workflow 10, quality) | a red job on the sha | **yes, as the backstop** for a push that bypassed the hook (`SPL_PREPUSH_OVERRIDE=1`) |
| the mint step (20 / 30) | would stop a deploy | **no**: a missing note never blocks a deploy; the row is ingested with `state=missing` and the WUI shows it in amber, so the gap is visible instead of fatal |

Roll-out: one week as a WARNING (the gate prints, does not refuse), then a
refusal. That week measures compliance (n = commits with all six trailers /
all commits) before the switch.

### 5.2 Special commits

| case | measured | rule |
|---|---|---|
| merge commits | 0 in 7 days (row 10) | none needed; one that appears is skipped |
| reverts | 5 in 7 days (row 11) | `git revert` output plus one `Lay-Why:` trailer; the row is `state=revert` and links the reverted row |
| doc-only (`.md` only) | 167 / 1697 (row 12) | still required, but `Lay-What` + `Lay-Why` suffice (the "how" of a doc change is "edited the text") |
| test-only, CI-only, lint baseline bumps | not measured separately | `Release-Note: skip` plus one `Lay-Why:` line; shown collapsed as `state=skip` |

## 6. Decision 4: backfill

| option | cost | value |
|---|---|---|
| none: from now on only | zero | old versions are absent from the page |
| since the last stable (`stable-2026-09-29`), subject only | one ingest run | the page is not empty on day one; rows read `state=missing` |
| last N versions, written by an agent from the diffs | ~2 commits a version; N = 100 versions = ~200 rows of agent work | the recent past in plain words; risk: a row written later by someone who did not make the change |
| everything | ~1700 commits a week of history | not worth it |

**Recommendation: from now on, plus the ingest since the last stable with
subject only** (`state=missing`).

### 6.1 Corrections

A row on trunk is wrong or missing: the agent adds a `git notes
--ref=release-notes` note carrying the same trailers and pushes
`refs/notes/release-notes`. The ingest prefers the note over the message.
No history is rewritten.

## 7. Decision 5: how the owner reads it

| option | for | against |
|---|---|---|
| a. WUI page `/releases`, grouped by version, lay columns first | the place the owner already is; filterable by area and kind | a new page + one hub endpoint |
| b. the version in the footer / logo dialog links to that version's rows | one click from "what am I running" to "what is in it" | needs (a) |
| c. a channel post per deploy | pushed to the owner | ~105 deploys a day (row 3): noise |
| d. one daily digest post (lay what only, per area) | a summary without opening a page | one more scheduled job |
| e. the weekly stable GitHub release gains the lay column | self-hosters get plain notes too | a GitHub page, not the WUI |

**Recommendation: a + b + e now; d only if the owner wants a push; never c.**
Sections 7.1..7.3 then fix (a) and (b) as the owner set them.

### 7.1 Entry point: the version pop-up at the bottom (owner, t1 `4a31aa83`, 03:32Z and 03:33Z)

> "There should be a modal dialog presenting all of the versions and the
> commit hashes , both on desktop and mobile so that when A User clicks on
> the c.version of the role he/she should be able to see those notes per
> commit and eac time an agent informs for a commit released into prd or dev
> he should also post the link to that release note"

> "All of this this should be accessible from the version pop-up in the
> bottom"

What exists today (cite):

| surface | file | today |
|---|---|---|
| desktop | `csi-spl-wui/src/components/ChannelSidebar.vue` lines 632..670 (`data-test="app-version-wrap"`, card `app-version-card`) | the footer version; hover/click opens a small card with the commit sha, a copy button and a "newer build, reload" line |
| phone | `csi-spl-wui/src/components/MobileStatusStrip.vue` lines 36..64 (`status-strip-version`, card `status-strip-version-card`) | the same card in the bottom status strip |
| dialog shell | `csi-spl-wui/src/components/UiDialog.vue` (sizes `sm..xl`, `card`) | the shared modal every dialog uses |

`grep -n 'release' csi-spl-wui/src/components/ChannelSidebar.vue csi-spl-wui/src/components/MobileStatusStrip.vue` -> nothing: neither card links to any notes today.

The change (this replaces a stand-alone `/releases` page as the main
reading path):

1. Both version cards gain one button, **"Release notes"**. It opens ONE
   modal, `ReleaseNotesDialog`, built on `UiDialog` (`xl` on desktop,
   full screen on a phone: the same component, so both surfaces show the
   same thing).
2. The modal lists **every version**, newest first. The running version is
   open and marked "you are here"; a newer one that is live but not yet
   loaded is marked as in the card today. Each version row shows its
   commit hashes (short sha + subject + kind + area).
3. A click on a commit hash opens that commit's note in the modal: the lay
   What / How / Why first, the technical three below, plus the full sha, a
   copy button and the link to the commit. `state=missing` rows say so
   plainly ("no note: committed before notes were required").
4. A filter box (version, sha prefix, area, words) and paging of versions
   (about 105 a day, row 3): the modal loads the latest 50 versions and
   fetches older ones on scroll, from one hub endpoint
   `GET /v1/release-notes?before=<version>&limit=50` and
   `GET /v1/release-notes/<sha>`.
5. "c.version" in the owner's text is read as the version shown in that
   pop-up; the modal is reachable by EVERY signed-in user, not only admins
   (Q11).

### 7.2 A stable link per note

Every note has one link, built from the WUI host in cnf (no literal host):

```text
https://<<run-time>>.csitea.net/releases/<sha>
```

- `<sha>` may be the full sha or a 7+ char prefix; `/releases/v<X.Y.Z>` opens
  that version's list.
- The route loads the app and opens `ReleaseNotesDialog` on that note, so
  the link and the footer button show the same modal, not two pages.
- The link exists the moment the commit is on trunk: the row is ingested on
  deploy, and until then the modal shows the trailers read straight from
  the commit with "not deployed yet".
- The dev WUI and the prd WUI each serve the link; a post names the one the
  commit was released to.

### 7.3 The link in every "released to dev / prd" post

Rule: an agent post that says a commit reached dev or prd carries that
commit's note link (7.2), one per sha.

| where it is enforced | how | recommendation |
|---|---|---|
| the lane seed prompt (`csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh`, the closing-steps text) | the report template asks for `sha + note link` per released commit | **yes**: it is where every lane learns its report shape |
| a helper that prints the line | `./run -a do_release_note_link SHA=<sha> ENV=<env>` prints `<sha> v<X.Y.Z> <link>`, so nobody hand-builds the URL | **yes** |
| the dispatcher | before relaying a lane's result to the owner, a check flags a post that says released/deployed with a sha but no `/releases/` link, and asks the lane to add it | **yes, as a warning** (`do_spl_dispatch_check` today checks the dispatchers, not post content: `grep -c release csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh` -> 0) |
| the hub refusing the post | would block a message | **no**: a missing link must not lose a report |

The deploy workflows (20 / 30) could also post the links themselves; that
is offered as Q14, not recommended now (it is a channel post per deploy,
the noise 7 row c rules out).

## 8. Build order (after the owner answers)

Superseded by the lane table in section 12; kept as the original order.

1. The trailer rule as one help page in `csi-spl-doc/doc/help/` (the 4.1
   example), pointed to from the agent seed prompt.
2. The pre-push lint part `release-note` (warning mode) + its test.
3. Migration `0105_release_note.sql` (next free number at build time), the
   hub ingest at deploy time, and the hygiene filter on ingest.
4. `ReleaseNotesDialog` from both version cards (desktop + phone), the
   `/releases/<sha>` route, the two hub read endpoints, e2e on both widths.
5. `do_release_note_link` + the seed-prompt report line + the dispatcher
   warning (7.3).
6. After a week of warnings: the refusal, and the CI backstop job.
7. The workflow 55 notes gain the lay column.

## 9. Owner questions

1. **Q1** Store the six answers as commit trailers and show them from a hub
   DB table in the WUI (option C)? yes / no (no = pick A, B or D)
2. **Q2** The six fields Lay-What/How/Why + Tech-What/How/Why, one line
   each, as in 4.1? yes / no
3. **Q3** Refuse a push without the note in the pre-push gate, with CI as
   the backstop, and never block a deploy for it? yes / no
4. **Q4** One week as a warning before refusing? yes / no
5. **Q5** Doc-only commits need only Lay-What and Lay-Why; test/CI-only
   commits may say `Release-Note: skip`? yes / no
6. **Q6** Backfill, pick one: none / since the last stable, subject only
   (recommended) / last 100 versions written by an agent
7. **Q7** The notes open in ONE modal from the version pop-up at the
   bottom (desktop footer and phone strip), listing every version with its
   commit hashes, and a click on a hash shows that commit's note (7.1)?
   yes / no
8. **Q8** A daily digest post in a channel as well? yes / no (per-deploy
   posts are not offered: ~105 a day)
9. **Q9** Add the lay column to the weekly stable GitHub release notes?
   yes / no
10. **Q10** The note link is `<wui host>/releases/<sha>` (or
    `/releases/v<X.Y.Z>`), opening the same modal? yes / no
11. **Q11** Every signed-in user can open the notes, not only admins?
    yes / no
12. **Q12** Every "released to dev/prd" post must carry the note link per
    sha, taught in the lane seed prompt with a helper that prints it?
    yes / no
13. **Q13** The dispatcher warns (does not block) on a released post without
    the link? yes / no
14. **Q14** Should the deploy workflows also post the links themselves?
    yes / no (recommended: no, ~105 deploys a day)

## 10. Owner answers (t1 topic `4a31aa83`, 2026-10-03 from ~04:30Z)

Verbatim as relayed by the orchestrator (dictated text, kept as received).
Relayed by the orchestrator (c-001) and, for Q11, by the c-002 desk; rows in
the order they arrived.

| Q | owner, verbatim | reading |
|---|---|---|
| Q8 | "#8, no." | no daily digest post. Option 7 d is dropped; per-deploy posts (7 c) were never offered |
| Q9 | "#9, yes." | the weekly stable GitHub release (workflow 55) gains the lay column |
| Q10 | "On number 10 yes." | the note link is `<wui host>/releases/<sha>` (and `/releases/v<X.Y.Z>`), opening the same modal (7.2) |
| Q12 | "#12, yes." | every "released to dev/prd" post carries the note link per sha; the seed prompt teaches it and `do_release_note_link` prints it (7.3) |
| Q13 | "#13, yes." | the dispatcher WARNS on a released post without the link and never blocks it (7.3) |
| Q1 | "On one, yes." | option C: six trailers in the commit message, shown from a hub DB table in the WUI (section 3) |
| Q2 | "Onto yes" | read as "On two, yes" (dictated): the six fields Lay-What/How/Why + Tech-What/How/Why, one line each (4.1) |
| Q3 | "#3, yes." | the pre-push gate refuses a commit without the note, CI is the backstop, and a deploy is never blocked by it (5.1) |
| Q11 | "On number 11 yes." | every signed-in user can open the notes, not only admins (7.1 item 5); relayed by c-002, reached its desk ~04:39Z |
| Q4 | "On the 4th explain" | not an answer yet: the owner asked for Q4 to be explained. The five-line explanation (recommendation: yes, one week of warnings) was posted to the owner ~04:47Z. Open |
| Q7 | "On number 7 yes." | ONE modal from the bottom version pop-up, desktop footer and phone strip, every version with its hashes, a click on a hash shows the note (7.1) |
| Q14 | "#14, no." | the deploy workflows do not post the links themselves |
| Q6 | "Well, dedicate at least three agents to backfill. The backfill doesn't have as great a quality as the commits after this change." | backfill YES, written by at least three agents in parallel; backfilled notes may be of lower quality than new ones. Of the three options only "last 100 versions written by an agent" needs agents, so it is taken: **to be confirmed by the orchestrator**. Backfilled rows get `state=backfill` (a reading, not asked) so the WUI can show they were written after the fact |
| Q5 | "On 5, number yes." | yes: doc-only commits need only Lay-What and Lay-Why; test/CI-only commits may say `Release-Note: skip` plus one `Lay-Why:` (5.2) |

## 11. Still open

Verbatim from section 9:

- **Q4** One week as a warning before refusing? yes / no (explanation
  requested and posted ~04:47Z; answer pending)
- **Q6 scope** (orchestrator to confirm): "last 100 versions written by an
  agent", read from "dedicate at least three agents to backfill".

## 12. Build lanes

Small lanes, one task each, disjoint files. "After" names the lane whose
contract it needs on trunk first; a lane gated on an open question waits for
it. Paths checked on `origin/master` 2026-10-03: `ls
csi-spl-rdb/src/sql/postgres/spool-hub/ | tail -1` -> `0105_agent_lifecycle.sql`,
so the migration is `0106` or the next free number at build time (the 0105
in section 8 is taken).

| lane | task | files (only these) | test | after / gated on |
|---|---|---|---|---|
| L1 | the trailer rule as one help page (4.1 example, 5.2 special commits) | `csi-spl-doc/doc/help/release-notes.md` (new) | `./run -a do_check_dist_hygiene`; `./run -a do_check_pre_push_lint` (md links) | none |
| L2 | pre-push part `release-note`, WARNING mode: checks the six trailers (or the 5.2 forms) on every commit in the pushed range | `csi-spl-iac/src/bash/run/check-release-note.func.sh` (new), the one part line in `csi-spl-iac/src/bash/run/check-pre-push.func.sh`, `csi-spl-iac/src/bash/tests/check-release-note.tst.sh` (new) | the new `.tst.sh`: full note passes, missing / empty trailer warns, doc-only and `Release-Note: skip` pass; `check-pre-push.tst.sh` stays green | L1 (the rule it checks) |
| L3 | migration + store for `release_note` (4.2 columns, `state`) | `csi-spl-rdb/src/sql/postgres/spool-hub/0106_release_note.sql` (new), `csi-spl-api/src/go/spool-hub-api/internal/store/release_note*.go` (new) | store test on POSTGRES: `PRE_PUSH_TIER=full ./run -a do_check_pre_push` | none |
| L4 | hub endpoints: ingest (trailers + hygiene filter, `state` incl. `backfill`), `GET /v1/release-notes?before=&limit=50`, `GET /v1/release-notes/<sha>` | `csi-spl-api/src/go/spool-hub-api/internal/hub/release_notes*.go` (new) and its route line | Go tests incl. the hygiene filter dropping a banned name; `bash csi-spl-api/src/bash/tests/run-all-tests.sh` | L3; every signed-in user may read (Q11 yes) |
| L5 | deploy-time ingest: the deploy parses the new commits' trailers and calls the L4 ingest with the minted version | `csi-spl-orc/src/bash/run/release-note-ingest.func.sh` (new), one step in `.github/workflows/20_hub-build-deploy.yml`, `csi-spl-orc/src/bash/tests/release-note-ingest.tst.sh` (new) | the `.tst.sh` (trailer parse, `state` ok / missing / skip / revert); `do_check_pre_push_lint` (actionlint) | L4 |
| L6 | `ReleaseNotesDialog` from both version cards + the `/releases/<ref>` route (Q7 yes); `state=backfill` rows say "written after the fact" | `csi-spl-wui/src/components/ReleaseNotesDialog.vue` (new), `ChannelSidebar.vue` and `MobileStatusStrip.vue` (button only), `csi-spl-wui/src/pages/releases/[ref].vue` (new), `csi-spl-wui/tests/e2e/release-notes.spec.ts` (new) | `pnpm run typecheck`; e2e on desktop AND phone width against a generated bundle | L4 contract (may mock it) |
| L7 | `do_release_note_link SHA= ENV=` prints `<sha> v<X.Y.Z> <link>`, host from cnf | `csi-spl-orc/src/bash/run/release-note-link.func.sh` (new), `csi-spl-orc/src/bash/tests/release-note-link.tst.sh` (new) | the `.tst.sh` (no literal host; unknown sha fails) | none |
| L8 | seed prompt: the report asks for `sha + note link` per released commit | `csi-spl-orc/src/bash/features/spawn-agents/scripts/spawn-core.inc.sh` (closing-steps text only) | the spawn-core / seed tests that cover that text; `do_check_dist_hygiene` | L7 |
| L9 | dispatcher warning on a released post with a sha but no `/releases/` link | the dispatcher relay file, named at build time (`grep -c release csi-spl-orc/src/bash/run/spl-dispatch-check.func.sh` -> 0: that action checks dispatchers, not post content), + its `.tst.sh` | its `.tst.sh`: warns, never drops the post | L7 |
| L10 | weekly stable notes gain the lay column (Q9) | `csi-spl-orc/src/bash/run/release-stable.func.sh` | `csi-spl-orc/src/bash/tests/release-stable.tst.sh` (+ a case for `state=missing`) | L5 (rows to read) |
| L11 | the refusal: `release-note` part refuses; CI backstop job | `check-release-note.func.sh` (mode switch), `.github/workflows/10_ci-quality.yml` (one job) | `check-release-note.tst.sh` refusal cases; actionlint | L2; gated on **Q4** (yes = after one week of warnings, with the compliance n; no = ships with L2) |
| L12 | ingest backfill mode: reads `refs/notes/release-notes-backfill-*` as well, rows `state=backfill`; a note on `refs/notes/release-notes` (6.1) still wins | `release-note-ingest.func.sh` (one mode), `release-note-ingest.tst.sh` | its `.tst.sh`: backfill note -> `state=backfill`; a 6.1 correction overrides it | L5; Q6 scope confirmed |
| L13a | write backfill notes, versions 1..34 of the 100 before the version where L2 went live (newest first) | git notes on its own ref `refs/notes/release-notes-backfill-a` only; no file in the tree | `check-release-note.func.sh` (L2) over every note in the range: six trailers or a 5.2 form; the ingest hygiene filter on the note text | L2; Q6 scope confirmed |
| L13b | the same, versions 35..67 | `refs/notes/release-notes-backfill-b` only | as L13a | as L13a |
| L13c | the same, versions 68..100 | `refs/notes/release-notes-backfill-c` only | as L13a | as L13a |

L13a..c are disjoint because each pushes only its own notes ref; the ranges
are fixed as version lists once L2 is live, before the three lanes start.
The owner accepts lower quality for a backfilled note (Q6), so these lanes
write from the diff and the subject without asking the original lane.

Not built: the daily digest (Q8 no); deploy workflows posting links (Q14
no).
