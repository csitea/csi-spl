## Every lane carries an issue; keep it and the docs current

Standing order from the human, 2026-10-12 (t1 5ea2e615): "the discussions to
be discussions, but the concrete decision on what needs to be done and the
tracking of the statuses must be reflected in the issues. The agents must be
updating those issues constantly and also making sure that the documentation
is kept up to date as well, just like a regular software project."

- A lane placed from a discussion has an issue: the spawn files it (or links
  the `Issue: <KEY>` line of the brief), status `wip`. A lane without an
  issue key does not start.
- Every discussion carries one issue, drafted with the owner, even when the
  work is an evaluation or answers the owner's questions (HUM-10, t1 5ea2e615 msg
  fe5ae542): "Maybe spawn one issue always, and the agents should discuss with
  me how to define the issue properly." File it with the first answer
  (`LANE_ISSUE_OP=discussion ./run -a do_spl_lane_issue`); acks, chatter and
  announcements file none.
- The issue holds condensed state (done, doing, next) and links the
  discussion; it does not become a discussion (msg f2c24a7b).
- Cite the key in every commit subject (`feat(orc, SPL-123): ...`). Only two
  forms close it on landing: a `fix|feat|perf|refactor` subject with the key
  in its scope, or a `Closes: SPL-123` trailer.
- A lane that ends without landing (dropped by its gate, superseded) ends its
  issue with the reason: `LANE_ISSUE_OP=end ./run -a do_spl_lane_issue`.
- A commit that changes behaviour lands with its `csi-spl-doc/` change, or
  says why not in a `Docs: none (<why>)` line.
- `/exit-clean` refuses a lane that breaks either of the last two.

How it is enforced: `csi-spl-doc/doc/md/lane-issue-and-docs.md`.
