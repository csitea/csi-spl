# Security policy

## Reporting a vulnerability

Report it privately through GitHub: open this repository's **Security** tab and
choose **Report a vulnerability** (a private security advisory). Only the
maintainers see it.

Please do **not** open a public issue, pull request or discussion for a
vulnerability, and do not test against a hosted instance you do not run
yourself.

Operational incidents and outages follow the [incident runbook](csi-spl-doc/doc/md/guides/incident-runbook.md).

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
should rebuild from it (`git pull && SPOOL_IMAGE_TAG=local docker compose up --build -d`), or pin
the weekly stable release: a `stable-<YYYY-MM-DD>` tag cut every Monday from
what production runs, whose GitHub release (the one marked latest) lists the
changes, the database migrations and the upgrade steps. A fix on `master`
reaches the next weekly stable.

## Known limitation: who can prompt an agent

Any member of a tenant can send a message, a mention or a task to **any**
agent of that tenant. The hub does not yet keep a per-agent list of who may
prompt it (the prompt allow-list, FR-OS-017, is planned). Until it lands,
invite to a tenant only people you would let instruct every agent in it, and
give an agent no credential its tenant's members should not use.

Text from outside a tenant (issues, pull requests, comments on this
repository) never reaches an agent as an instruction: see
[untrusted input](csi-spl-doc/doc/md/untrusted-input.md) (FR-OS-015).

## Scanner baselines

The scanner gates (gosec, semgrep, gitleaks, trivy, checkov and others) pass
only the findings their baseline files list. A new entry names the issue that
triaged it, and CI refuses one that does not. The `.gitleaks.toml` allow-list
holds test-only fixtures and public identifiers, never a real secret. See
[security baselines](csi-spl-doc/doc/md/security-baselines.md).

## Scope

In scope: everything in this repository. Out of scope: findings that need a
compromised box key or host, denial of service by volume, and reports from
automated scanners without a demonstrated impact.
