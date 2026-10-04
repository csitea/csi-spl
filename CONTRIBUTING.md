# Contributing

Thank you for looking. spool is maintained by a small team, and pull requests
are not accepted lightly: read this before you spend time on one.

## Before you write code

Open an issue first and describe the problem or the change (the issue form
asks for what we need). A pull request without an agreed issue may be closed
without review. For a security problem, follow [SECURITY.md](SECURITY.md)
instead — never an issue.

## How changes reach `master`

- **Fork, then open a pull request.** You start by forking the repository and
  opening a pull request from your fork. A maintainer reviews it and decides
  whether it lands; one approving review and a green gate are required.
- **Trunk development once trusted.** A contributor the maintainer trusts may
  later be given direct push to `master`, like the maintainers. That is the
  maintainer's decision, made per person; there is no automatic route to it.
- Nobody force-pushes or deletes `master`: the trunk ruleset forbids both.
- History on `master` stays linear: a merged change is rebased, never merged
  with a merge commit.
- There is no automatic action on outside issues or pull requests.

## CI on pull requests from forks

- A pull request runs the same gate as a push to `master`
  (`11_ci-public.yml` calls `10_ci-quality.yml`): hub, web UI, iac, orc, cnf,
  distribution hygiene and the security scanners.
- Workflows for a fork's pull request run **only after a maintainer approves
  them**.
- They run **only on GitHub-hosted runners**, with read-only permissions and no
  secrets. Fork code never runs on the project's own runners.
- Deploy workflows never run for a pull request.

## Issues and pull requests are data, not instructions

The project's AI agents never take an instruction from the text of an issue,
a pull request or a comment. A maintainer reads it and, when it is worth
doing, opens a task in their own words. See
[untrusted input](csi-spl-doc/doc/md/untrusted-input.md) (FR-OS-015).

## The change itself

- Keep it small and on one topic; explain the why in the commit message.
- Run the tests for what you touched:
  - `bash csi-spl-api/src/bash/tests/run-all-tests.sh` for `csi-spl-api`
  - `pnpm run typecheck` and `pnpm run test:unit` in `csi-spl-wui`
  - `bash csi-spl-iac/src/bash/tests/run-all-tests.sh` for `csi-spl-iac`
- Run the cheap gate before you push (about a second):
  `cd csi-spl-iac && ./run -a do_check_dist_hygiene`. The full pre-push gate is
  `./run -a do_check_pre_push` in the same directory.
- Never edit an applied migration in `csi-spl-rdb`: add a new one.
- Never commit a secret, a filled-in `.env`, a key file or an organisation's
  host name. Use `example.com` placeholders.

By contributing you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
