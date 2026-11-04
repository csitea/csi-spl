# Commit links: every commit cites an issue that links its discussion

SPL-4789, epic SPL-2402. Owner HUM-10, t1 ef94396b:

- msg fca24858: "we need to enforce the linking between the commits notes and
  the issues and the discussoins"
- msg 61bf7791: a committing agent "must add at least 1 link for an issue ,
  which was used to justify the work of the commit and at least 1 discussion
  where this issue originated from and the links must be clickable in this
  view" (Reporting -> Releases)
- msg 4dc6a7cd: "at least 1 means that there might be 1 or more links per
  topic or issuue"
- msg dd164168: "add the links for the existing commits and in the ui , just
  set to unknown for the OLDER already done commits , but after this feature
  has completed the usage of the unknown hsould be forbidden"

## 1. The rule

A commit on master names at least one issue key, `SPL-<n>`, as a whole word
anywhere in its message. The usual places are the subject scope
(`feat(orc, SPL-123): ...`) and a `Closes: SPL-123` or `Refs: SPL-123`
trailer. At least one of those keys must be an issue of the owning
workspace, cnf `env.hub.commit_issue_tenant` (t1), and that issue must link
at least one discussion other than the workspace's default backlog topic.

The issue tracker already guarantees the second half for a lane. An issue
cannot be created without `--discussions` (rdb 0194), and its last
discussion cannot be unlinked. A lane that opens its issue at spawn, from
its discussion, passes.

## 2. Where it is enforced

| layer | what | where |
|---|---|---|
| pre-push part `commit-links` | every tier, the outgoing commits `PRE_PUSH_BASE..HEAD` | `csi-spl-iac/src/bash/run/check-pre-push.func.sh` `_pp_part_commit_links`, test `csi-spl-iac/src/bash/tests/check-pre-push-commit-links.tst.sh` |
| the check | keys, one hub read, one FATAL per refused commit | `cd csi-spl-orc && ./run -a do_spl_commit_links_check`, test `csi-spl-orc/src/bash/tests/spl-commit-links-check.tst.sh` |
| the hub's answer | per key: found, own discussions, default only; operator SA only | `POST /v1/operator/commit-links`, `csi-spl-api/src/go/spool-hub-api/internal/hub/release_links.go` |
| CI | the pushed range, hub-checked on prd, also when the hook did not run | `.github/workflows/25_commit-links.yml` |

Hub-checked means the check asks the prd hub as the prd project SA, with the
key `~/.gcp/.csi/key-csi-spl-prd.json`. A box without that key checks the
form only: a key must be named. The summary then says `NOT hub-checked`,
and workflow 25 checks the links. A hub revision without the route (a plain
404) also falls back to the form only, with a WARN. Any other failed read
(the hub down, a 5xx) fails the check in CI and when the action is run by
hand (`COMMIT_LINKS_HARD=1`, the default). The pre-push hook passes
`COMMIT_LINKS_HARD=0`: there a hub that does not answer is a WARN and the
form only, and workflow 25 is the hard gate for the links.

## 3. A refused commit: the fixes

Each FATAL names the short sha, the subject, what is missing and the fix:

- **names no key**: put the issue in the subject scope or add a
  `Closes: SPL-<n>` trailer. If there is no issue yet, file one linked to
  the discussion it came from:
  `spool issue create --title <t> --discussions <topic id> --epic SPL-<epic>`
  (a lane: `LANE_ISSUE_OP=discussion ./run -a do_spl_lane_issue`).
- **names a key the workspace has no issue for**: a typo, or a key from
  another workspace. Cite the real issue.
- **its issue links only the backlog topic**: link the discussion it came
  from: `spool issue link --ref SPL-<n> --discussion <topic id>`.

Reword a commit that is not pushed yet with `git commit --amend`, or with
`git rebase -i` for older ones. Never force-push master.

## 4. The cut-over and older commits

The rule holds from the landing sha of the gate commit (the commit that adds
`do_spl_commit_links_check`). It is written into this file once that commit
is on master. Older commits are never re-checked.

Measured before the gate was turned on (prd t1, read-only, origin/master
cc54fb1db, n = 300 commits, 189 distinct keys): 300/300 name a key, 187/189
keys are t1 issues with at least one discussion (the 2 others are `SPL-0` and
`SPL-99999`, example text in bodies), and 0 of the 300 commits would fail. No
grace rule was needed.

## 5. The links in Reporting -> Releases

Each release note stores the keys its message cites and the workspace that
owns them: rdb 0261, `release_notes.issue_tenant` and `issue_keys`. The
deploy-time ingest (`do_release_note_ingest`) sends the workspace from cnf,
and the hub parses the keys of that workspace's issue prefix. The
discussions are read live from that workspace's `issue_discussions`, so a
link added later shows without a re-ingest.

`GET /v1/reporting/releases/commits` and `GET /v1/release-notes/{ref}` answer
each note with `issues[]`: `key`, `tenant`, `found`, `member` and
`discussions[]`. A discussion carries `task_id`, `title` and `state` only
when the viewer's session is a member of the owning workspace and may open
the topic (`can_open: true`). Anyone else gets the key and the count, never
a topic id or title of another workspace.

The Releases row, after the subject, and the release-note dialog
(`/releases/<sha>`), under the note's meta line, show the same links. The
component is `csi-spl-wui/src/components/reporting/ReleaseIssueLinks.vue`
and the pure builder `csi-spl-wui/src/utils/release-issue-links.mjs`:

- each issue is a link to `/issues?issue=<key>`, and each discussion a link
  to `/t/<id>` titled with its first line. In the page's own workspace the
  link is in-app; in another workspace it opens that workspace's host in a
  new tab.
- a key with no issue is shown struck through, not linked.
- a discussion the viewer may not open reads "discussion, <workspace>
  members only", with no link.
- a commit with no stored key, or none that resolves to a discussion, shows
  **unknown**: these are the older commits, from before this feature.
- a hub revision that sends no `issues` field shows nothing.

Tests: `csi-spl-wui/tests/unit/release-issue-links.test.mjs`, the SPL-4789
block of `tests/unit/reporting-releases.test.mjs` (mounted row), and the
SPL-4789 checks of `tests/e2e/reporting.test.mjs` on the mock bundle (every
seventh mock commit has no issue and reads unknown).

Backfill of the older commits: once the hub with rdb 0261 is on prd, one
`ENV=prd DRY_RUN=0 ./run -a do_release_note_backfill` (csi-spl-orc) re-sends
every commit with its keys. It is a prd write, run by the dispatch holder.
Until then a deploy's own ingest refills the newest 500.
