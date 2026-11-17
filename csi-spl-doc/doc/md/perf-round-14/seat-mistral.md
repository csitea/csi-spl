# Perf round 14 (p14): mistral panel seat (m-031@sat)

Seat: m-031@sat, ask 8aaab744, placement `mistral:c002-perf-round-14-mistral-panel-seat`.
Brief: `briefs/c002-perf-round-14-mistral-panel-seat.md` (Issue SPL-5795, Epic SPL-2402, Spec `csi-spl-doc/specs/027-spool-performance`, kind specs_and_docs).
Review target: branch `review/c001-perf-round-14-planner`. Per the brief this seat signs ONLY a sha that c-025@sat names as a plan version in a message to m-031 or on task `dispatch-perf-r14`; it does not review a moving head.

## Verdict

**PENDING — no plan sha named yet.** Read at 2026-11-17T14:34:24Z:

- `SPOOL_ROOT=/var/spool-hub spool tail --task dispatch-perf-r14 | grep -oE '[0-9a-f]{40}' | sort -u` -> (empty, 0 matches)
- `SPOOL_ROOT=/var/spool-hub spool recv --as m-031` -> `[]`
- `git ls-remote origin refs/heads/review/c001-perf-round-14-planner` -> `5929030f0c3683bf324c81a1703e58038d7a27a9` (plan draft v0.1, 1 row; pushed but NOT named by c-025 on the task)
- Ask note sent to c-025@sat on `dispatch-perf-r14` at 2026-11-17T13:52:20Z (msg `2f837cc1`): "please name the draft plan sha here once pushed".

## Checks run (each with the command and what it printed)

1. Slug p14 unused (2026-11-17, ~13:50Z, on origin/master):
   - `git log origin/master --oneline -E --grep='\(p14-' | wc -l` -> `0`
   - `git ls-remote origin 'refs/heads/*p14-*' | wc -l` -> `0`
6. `cd csi-spl-iac && ./run -a do_check_dist_hygiene` -> `INFO distribution-hygiene: clean over the tracked tree of /opt/csi/csi-spl-wt/m-031`, exit 0.
5. Lane map on this seat file only (the rows' paths wait for the named sha):
   `lane-map.sh --check csi-spl-doc/doc/md/perf-round-14/seat-mistral.md --agent m-031` -> exit 4: `WARN no live lane lists csi-spl-doc/doc/md/perf-round-14/seat-mistral.md, but 15 live lane(s) record no files`; the 15 `unknown:` lanes, all on the second box: c-054, c-060, c-161, c-167, c-382, c-390, c-528, c-545, c-570, c-669, c-714, c-888, c-924, c-927, c-966. None records this path.

Checks 2, 3, 4 and the row part of 5 run once c-025 names the plan sha; the verdict above is then filled in on this same file (second commit on `review/c002-perf-round-14-mistral-seat`).

## Defects

None yet — no named sha has been reviewed.

## Notes

- N1: origin/master moved to `013cb71bf` while waiting; the worktree branch was rebased onto it (2026-11-17T14:34Z).
- N2: rotation note `8548c8e1` (c-001, task `lane-rotate-m-031`, 2026-11-17T14:32:29Z, "rotation at 14:46Z UTC: push what is green, write your state"): this file is that state, pushed to `review/c002-perf-round-14-mistral-seat`; no reply sent, per the note.
- N3: the plan draft at `5929030f0` was read (not signed): `git show 5929030f0 --stat` -> adds `csi-spl-doc/doc/md/perf-round-14-plan.md` (234 lines) and `csi-spl-doc/doc/md/perf-round-14/editor.md`; subject `docs(p14-plan, SPL-5795): perf round 14 plan v0.1, 1 row: the WUI unit runner runs its files 4 at a time`.
