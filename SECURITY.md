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

## Fix-time SLAs and post-disclosure monitoring

### Fix-time SLAs by severity

Once a vulnerability is confirmed and assigned a severity rating, remediation adheres to the following target fix-time SLAs:

| Severity | Definition / Scope | Target Fix-Time SLA | Status |
|---|---|---|---|
| **Critical** | Remote code execution, unauthenticated cross-tenant data access, host escape, or credential compromise with active exploitation | **72 hours** (72 h) | Enforced |
| **High** | Authenticated privilege escalation, cross-tenant leaks requiring prerequisites, or authentication bypass without active exploitation | **14 days** (14 d) | Enforced |
| **Medium** | Denial of service, authenticated informational leak, or cross-site request forgery without session compromise | **30 days** (30 d) | *(proposed)* |
| **Low** | Defense-in-depth gaps, non-sensitive configuration exposure, or local denial of service | **90 days** (90 d) | *(proposed)* |

### How the clock starts

- **Acknowledgement**: We acknowledge receipt of vulnerability reports within 24 hours of submission.
- **Clock start**: The SLA clock begins the moment maintainers reproduce and triage the vulnerability (confirming its validity and severity classification) in the GitHub private security advisory thread.
- **Clock stop**: The SLA clock stops when the validated patch lands on `master` and passes all continuous integration deployment gates (`10_ci-quality`, `20_hub-build-deploy`, `30_wui-build-deploy`) or is cut into an emergency release.

### Post-disclosure monitoring

Following patch deployment and advisory publication:

- **What is watched**:
  - Runtime logs and telemetry: error spikes, authentication failures, abnormal Cloud Run request rates, and WebSocket connection drops across `dev` and `prd`.
  - Automated security gates and regression tests: continuous execution of regression suites and exploit reproduction controls in CI.
  - Inbound reports: monitoring the private security advisory queue and issue tracker for bypass attempts, variant attack vectors, or patch regressions.
- **For how long**:
  - Heightened active monitoring lasts for **14 days** following deployment on `master` and publication of the advisory.
- **Who is told**:
  - The reporting researcher is notified immediately in the private advisory thread upon deployment to verify the remediation before public disclosure.
  - Operators and self-hosters are informed through the GitHub Security Advisory (GHSA), changelog entries, and release notes accompanying the weekly stable release or emergency hotfix tag.
  - Affected tenant administrators are notified directly in accordance with the [incident runbook](csi-spl-doc/doc/md/guides/incident-runbook.md) if tenant data was exposed prior to the fix.

## Supported versions

Only the latest commit on `master` receives security fixes. Self-hosters
should rebuild from it (`git pull && SPOOL_IMAGE_TAG=local docker compose up --build -d`), or pin
the weekly stable release: a `stable-<YYYY-MM-DD>` tag cut every Monday from
what production runs, whose GitHub release (the one marked latest) lists the
changes, the database migrations and the upgrade steps. A fix on `master`
reaches the next weekly stable.

## Who can prompt an agent

A workspace admin can give each agent a sender allow-list (FR-OS-017,
SPL-1018: Workspace settings -> Agents). A direct message to that agent, or
an @mention of it, then comes only from the members on the list; the hub
refuses anyone else's send with 403 `sender_not_allowed` before it is stored,
so the agent never receives it. An empty list means nobody. The rules:
[sender allow-list contract](csi-spl-doc/specs/044-spool-open-source/contracts/sender-allow-list.md).

Known limitation: an agent with **no** list takes messages from every member
of its tenant (the default, so nothing changed when the list shipped), and a
channel post that does not @mention the agent is not covered. Set a list on
every agent whose instructions should come from a few people, and give an
agent no credential the members who may prompt it should not use.

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
