# Contributing

Thank you for looking. spool is maintained by a small team, and pull requests
are not accepted lightly: read this before you spend time on one.

## Before you write code

Open an issue first and describe the problem or the change. A pull request
without an agreed issue may be closed without review. For a security problem,
follow [SECURITY.md](SECURITY.md) instead — never an issue.

## How changes are merged

- **Only maintainers merge.** Every outside pull request is reviewed by a
  maintainer, and a maintainer decides whether it lands.
- There is no automatic action on outside issues or pull requests.
- History on `master` stays linear: a merged change is rebased, never merged
  with a merge commit.

## CI on pull requests from forks

- Workflows for a fork's pull request run **only after a maintainer approves
  them**.
- They run **only on GitHub-hosted runners**, with read-only permissions and no
  secrets. Fork code never runs on the project's own runners.
- Deploy workflows never run for a pull request.

## Sign your commits off (DCO)

Every commit must carry a `Signed-off-by:` line certifying the
[Developer Certificate of Origin 1.1](https://developercertificate.org/): that
you wrote the change, or otherwise have the right to submit it under this
project's licence (AGPL-3.0-only).

```bash
git commit -s
```

The sign-off must use your real name and an address you can be reached at. A
pull request with an unsigned commit is not merged.

## The change itself

- Keep it small and on one topic; explain the why in the commit message.
- Run the tests for what you touched:
  - `bash csi-spl-api/src/bash/tests/run-all-tests.sh` for `csi-spl-api`
  - `pnpm run typecheck` and `pnpm run test:unit` in `csi-spl-wui`
- Never edit an applied migration in `csi-spl-rdb`: add a new one.
- Never commit a secret, a filled-in `.env`, a key file or an organisation's
  host name. Use `example.com` placeholders.

By contributing you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
