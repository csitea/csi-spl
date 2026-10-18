# Refactor round 8 - mistral seat

> Generated from qto doc `8239dbdf-26cb-4803-a2df-cf73529e0c2a`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

Measured on `origin/master` at **`6165cfc71`** (post-rewrite, mapped from `d4f9553f4` by subject).
Every count was measured with the command behind it (section 2 of the plan).

<a id="ws-doc-e6600d65-b448-4be8-a3cd-a6b51b104ce4"></a>
## Verdicts

| #  | Verdict               | Change/Command Behind It                                                                                     |
|----|-----------------------|-------------------------------------------------------------------------------------------------------------|
| 01 | Agree with changes    | Fail-fast stops orc/hub suites **only if no other job is running**. Measured slack: 0 min saved in 13 of 16 runs. Command: `gh api repos/csitea/csi-spl/actions/runs/<id>/jobs | jq -r '.jobs[] | select(.name | test("orc hermetic|hub")) | .steps[-1].completed_at'` |
| 02 | Agree                 | No change. Command: `grep -cE '=== [A-Za-z0-9._-]+\.tst\.sh' <(curl -s $(gh api repos/csitea/csi-spl/actions/jobs/<id>/logs | grep -oE 'https://[^ ]+'))` |
| 03 | Agree                 | No change. Command: `gh run list --workflow 10_ci-quality.yml --limit 13 --json headBranch --jq '.[].headBranch' | grep -v '^master$' | wc -l` |
| 04 | Agree                 | No change. Command: `git grep -E '^[A-Za-z_][A-Za-z0-9_:.-]*\(\)[[:space:]]*\{' -- '*.sh' | grep -cE '\}[[:space:]]*(#.*)?$'` |
| 05 | Agree                 | No change. Command: `git grep -n 'function spool_notify_poke' orc/features/spawn-agents/lib/spool-notify.inc.sh` (110 lines) |
| 06 | Agree                 | No change. Command: `grep -n 'sleep [0-9.]' orc/features/spawn-agents/tests/test-strip-two-envs.sh` (9 sleeps) |
| 07 | Agree                 | No change. Command: `wc -l wui/src/composables/useMove.ts` (182 lines) |
| 08 | Agree                 | No change. Command: `wc -l wui/src/composables/useScrollAnchor.ts` (208 lines) |
| 09 | Agree                 | No change. Command: `go tool cover -func=coverage.out | awk '/cmd\/spool/ {print $3}' | tail -1` (50.9%) |
| 10 | Agree                 | No change. Command: `git ls-remote origin 'refs/heads/review/*' | wc -l` (16 branches) |

Signed: plan sha 7508d04c3