# Implementation Plan: Spool Security Hardening & Threat Mitigation (017)

**Spec**: `./spec.md` · **Contract**: `./contracts/security-baseline.md` · **Tasks**: `./tasks.md`

## 1. Architectural Phases

```
  Phase 1: Local & Transport Hardening (M3)
  ┌────────────────────────┐      ┌────────────────────────┐
  │ Host Spool Group DAC   │      │ File Download Auth     │
  │ /var/spool-hub 2770    │      │ GET /v1/files Auth     │
  └────────────────────────┘      └────────────────────────┘

  Phase 2: Identity & Credential Isolation (M3/M4)
  ┌────────────────────────┐      ┌────────────────────────┐
  │ Zero-Knowledge Root Key│      │ Distributed Rate Limit │
  │ Interactive Claim Only │      │ Cloud Armor + Hop Pin  │
  └────────────────────────┘      └────────────────────────┘

  Phase 3: Edge & Perimeter Defense (M4)
  ┌────────────────────────┐      ┌────────────────────────┐
  │ Strict Ingress CIDR    │      │ Nonce-based Strict CSP │
  │ Cloud Armor Allowlist  │      │ Eliminate unsafe-inline│
  └────────────────────────┘      └────────────────────────┘
```

---

## 2. Component Modification Plan

| Component | Target File(s) | Planned Hardening Action |
|---|---|---|
| Orchestration | `csi-spl-orc/.../provision-spool-root.func.sh` | Update `/var/spool-hub` permissions to `2770`, bind dedicated agent group, drop world `o::rwx` |
| Config SSOT | `csi-spl-cnf/csi-spl/all.env.yaml` | Set default `env.box.spool_root_other: "---"`, define proxy hops |
| Hub REST API | `internal/hub/rest.go` | Require session or token verification on `handleGetFile` |
| Payments & Root Key | `internal/payments/handler.go` | Remove root private key from `TenantWelcome` email template; enforce web-only interactive reveal |
| Cloud Armor | `031-gcp-hub-ingress/03-cloud-armor.tf` | Implement edge rate-limiting rules for API and WebSocket paths; retire open `0.0.0.0/0` exception |
| WUI Deployment | `csi-spl-wui/firebase.json` | Parameterize `connect-src` for production domains; eliminate `'unsafe-inline'` script allowances |
| CI/CD Pipeline | `017-github-wif-deploy`, `.github/workflows` | Apply WIF repo secrets/variables and enforce strict branch protection |

---

## 3. Implementation Sequence & Dependency Order

1. **Local Box DAC:** Transition local agents to dedicated group membership before modifying permissions in `do_provision_spool_root` to prevent agent disruption.
2. **Authenticated Blob Access:** Add session and capability checks to `handleGetFile` while keeping backward compatibility for active agents via WebSocket upload tokens.
3. **Email Root Key Removal:** Update `TenantWelcome` template so only the tenant URL is emailed; ensure `checkout.vue` displays the private key securely in an unlogged modal.
4. **Cloud Armor & Ingress Hardening:** Align Cloud Armor policies with production IP ranges and rate-limiting profiles.
5. **WIF CI/CD Activation:** Apply step `017` terraform in GCP, export GitHub repository variables, and activate automated deployment pipelines.

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:00:00Z -->
