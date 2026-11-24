# gpg-agent leak from the tests (SPL-6412, 2026-11-24)

A gpg-agent started for a throwaway `--homedir` holds one inotify instance
for as long as it runs. On one fleet box 49 leaked agents used up the user's inotify
cap (126 of 128) and the WUI unit part (`unit-runner-pool.test.mjs`) failed
with EMFILE.

## 1. Where that box's agents came from

Measured on that box at 2026-11-24T18:5xZ, gpg 2.4.7: of 108 gpg-agents of
the box owner user and the agent user, 107 came from another project's
tooling and tests, not from this repo. Each one carried that project's
working dirs in its environment (`PWD` or `HOME`, read from
`/proc/<pid>/environ`). The 108th was the owner user's own `--supervised`
agent. None came from a csi-spl test. Both reported homedir shapes, a bare
`mktemp -d` (`/tmp/tmp.*`) and a Perl `tempdir` with a `gnupg` subdir
(`/tmp/<10 chars>/gnupg`), are in that project's code. They went to its lane
through the orchestrator, and are not fixed here.

## 2. The csi-spl tests

Each candidate test ran alone under its own `TMPDIR`. The count is this
user's agents whose `--homedir` is under it. Every candidate left 0 when it
ran to the end (n=1 each): test-directive, channel-move-plan,
spl-box-state-mount, check-baseline-growth, ci-doc-only, sec-deps-scope,
spl-goals-backfill-git, spl-issue-key-rate and spl-skills-refresh.

They did leak when stopped mid-run. A run stopped with SIGTERM while its
agent ran left the agent behind: selftest-core had no EXIT trap, and the
EXIT trap of test-directive and channel-move-plan only ran `rm -rf`. The
removed homedir did not end those agents (they stayed idle; `gpgconf
--kill all` on the missing dir hung).

## 3. Fix and test

Every gpg-using test and directive selftest now runs `gpgconf --homedir
<dir> --kill all` in its EXIT trap, before the `rm -rf`: test-directive,
channel-move-plan, and selftest-core, -anyany, -list and -session.
`csi-spl-orc/src/bash/tests/gpg-agent-leak.tst.sh` covers it:

- C1: the whole runs leave 0 agents.
- C2: each of the three runs is stopped with SIGTERM once its agent runs,
  and leaves 0.
- C3 (control): a planted agent whose homedir stays is counted, so the 0s
  are not a blind count.

The new test against origin/master c7be3c19c: C2 red, 3 failures, one agent
left each by core, directive and move (n=1). On the fix: 0 failures (n=3).
