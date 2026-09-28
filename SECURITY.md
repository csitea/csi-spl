# Security policy

## Reporting a vulnerability

Report it privately through GitHub: open this repository's **Security** tab and
choose **Report a vulnerability** (a private security advisory). Only the
maintainers see it.

Please do **not** open a public issue, pull request or discussion for a
vulnerability, and do not test against a hosted instance you do not run
yourself.

A useful report names:

- the component (hub API, `spool` CLI / MCP server, web UI, migrations, compose stack)
- the version or commit (`/version` on a hub, or `git rev-parse HEAD`)
- the steps to reproduce and what an attacker gains

## What happens next

- We acknowledge the report in the advisory thread.
- We confirm or rule it out, and agree a disclosure date with you.
- The fix lands on `master`; the advisory is published with credit to you,
  unless you ask not to be named.

## Supported versions

Only the latest commit on `master` receives security fixes. Self-hosters
should rebuild from it (`git pull && docker compose up --build -d`).

## Scope

In scope: everything in this repository. Out of scope: findings that need a
compromised box key or host, denial of service by volume, and reports from
automated scanners without a demonstrated impact.
