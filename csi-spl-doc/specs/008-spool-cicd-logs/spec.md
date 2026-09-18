# Feature Specification: CI/CD logs in spool chat

**Feature ID**: `008-spool-cicd-logs`

**Created**: 2026-09-18

**Status**: Draft — **long-term, after M3**; M1 ships a **flagged-off stub**

**Narrative**: `csi-spl-doc/doc/md/SPEC-spool-cicd-logs.md`

**Input**: `gh` in the Cloud Run image, configured token, fetch Actions run
logs, present them in chats.

Depends on: M1 hub + files, M3 chat (or CLI-only delivery before WUI).

## User Story 1 (P3, later)

A pinned human or agent in a tenant thread asks for a GitHub Actions run.
The hub fetches the log with `gh` and posts a `note` + file on that
`task_id`.

**Acceptance**: token never appears in the message or Cloud Run logs; wrong
tenant cannot read another tenant’s repos.

## Requirements

- **FR-001**: Cloud Run image contains `gh` **after M3**. M1 image MUST NOT
  include `gh` (distroless static binary only).
- **FR-002**: Token from Secret Manager, per tenant, optional.
- **FR-003**: Repo allowlist per tenant (cnf).
- **FR-004**: Delivery is `v:1` `note` + file on the existing bus.
- **FR-005**: No token in git, image layers, chat, or application logs.
- **FR-006**: M1 stub is hub-side fetch+deliver (`internal/cicdlogs`),
  **flagged off by default**. Fail-closed in `prd` if the feature is enabled
  and the GitHub token secret is missing or a placeholder. Empty allowlist
  allows no repos (not an open proxy). Prefer a file attachment; cap one log
  at 32 MiB and say so in the body when truncated.

## Out of Scope

M1 image need not include `gh`. M2 checkout. Store logic. WUI. 031 ingress.
Baking tokens. Box-side `gh` / tokens on a box.

<!-- version: 0.1.1 · updated: 2026-09-18 · last-edit: 2026-09-18T17:53:00Z -->
