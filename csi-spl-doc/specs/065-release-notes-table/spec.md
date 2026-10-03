# 065: the release notes table, one row per commit, lay and technical

Status: **draft for the owner, Q1..Q9 open** (section 9). Spec only; no
code, workflow, gate or `CLAUDE.md` was touched.
Draft 2026-10-03, c-053.
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

## 8. Build order (after the owner answers)

1. The trailer rule as one help page in `csi-spl-doc/doc/help/` (the 4.1
   example), pointed to from the agent seed prompt.
2. The pre-push lint part `release-note` (warning mode) + its test.
3. Migration `0105_release_note.sql` (next free number at build time), the
   hub ingest at deploy time, and the hygiene filter on ingest.
4. The WUI `/releases` page + the version link.
5. After a week of warnings: the refusal, and the CI backstop job.
6. The workflow 55 notes gain the lay column.

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
7. **Q7** A WUI page `/releases`, with the footer version linking to it?
   yes / no
8. **Q8** A daily digest post in a channel as well? yes / no (per-deploy
   posts are not offered: ~105 a day)
9. **Q9** Add the lay column to the weekly stable GitHub release notes?
   yes / no
