# csi-spl-doc

`doc/md/csi-spl.feature.md` — what the spool is, its projects, the relay bucket
contract, and how to create, apply and switch to it.

## Specs

**Git-spec index, redo ground rules, provisioning order and the cross-spec
consistency record: `specs/README.md`.**

| Path | What |
|---|---|
| `doc/help/index.md` | **Spool User Help Center & Interface Guide** (end-user documentation) |
| `doc/md/glossary.md` | **the app's lingo**: topic message, reply, card, channel, DM, section … one table, each term cited to en.json or code |
| `doc/md/csi-spl.feature.md` | git-rel GCS estate (operator how-to) |
| `doc/md/SPEC-spool-milestones.md` | **M1 technical proto → M2 public MVP (buy) → M3 rollout Slack UI** |
| `doc/md/SPEC-spool-hub-api-infra.md` | copy csi-rel/pas-psf infra+DNS, not the shop |
| `doc/md/SPEC-spool-hub-rental.md` | paid tenant product |
| `specs/002-box-agent-messaging/contracts/trust-modes.md` | local unsigned vs hub box keys (SSH-like) |
| `doc/md/SPEC-spool-message-bus.md` | agent message bus architecture (binding) |
| `doc/md/SPEC-spool-box-api.md` | uniform box API (CLI + MCP) |
| `doc/md/SPEC-spool-identity-routing.md` | global ids, pins, box id, dual-write |
| `doc/md/SPEC-spool-task-lifecycle.md` | `task_id` / `kind` meaning |
| `doc/md/SPEC-spool-wui.md` | Slack-like WUI (**M3 rollout**) |
| `doc/md/SPEC-spool-avatars.md` | every human and bot has an avatar (M3) |
| `doc/md/SPEC-spool-social-auth.md` | M3 WUI: Google, Facebook, Microsoft, LinkedIn, xAI |
| `doc/md/SPEC-spool-byo-gcp.md` | later: they pay GCP, you provision |
| `doc/md/SPEC-spool-m4-seats.md` | **M4:** seats + buy-minute GCP project id |
| `specs/009-spool-m4/` | git-spec for M4 (spec + tasks, all Planned) |
| `doc/md/SPEC-spool-cicd-logs.md` | **later:** `gh` fetches CI logs into chat |
| `doc/md/SPEC-spool-chat-reverse.md` | **M3 default:** type at top, prepend messages (013 shipped) |
| `specs/001-relay-bucket-estate/` | git-spec for the relay bucket |
| `specs/002-box-agent-messaging/` | git-spec for local folder spool (MVP) |
| `specs/003-spool-message-bus/` | git-spec for the hosted hub |
| `specs/004-spool-identity-routing/` | git-spec for pins + routing |
| `specs/005-spool-wui/` | git-spec for the WUI |
| `specs/006-spool-hub-rental/` | git-spec for paid multi-tenant hub |
| `specs/007-spool-hub-api-infra/` | git-spec: provisioning order (DNS zone step 3), terraform, lde, docker, DNS |
| `specs/008-spool-cicd-logs/` | CI/CD: M1 GitHub Actions gate + dev/prd deploy; after M3: Actions logs in threads |
| `specs/006-spool-hub-rental/contracts/payment.md` | M2 public MVP: buy on site, copy csi-rel payment |
| `doc/md/SPEC-spool-project-refactor.md` | whole-project refactoring architecture (binding) |
| `specs/011-spool-project-refactor/` | git-spec for whole-project refactoring (API, WUI, IaC, Orc, Doc) |

<!-- version: 0.3.0 · updated: 2026-09-18 · last-edit: 2026-09-18T20:35:00Z -->
