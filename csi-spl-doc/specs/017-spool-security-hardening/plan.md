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
| Edge limits (no LB, owner 2026-09-19) | `internal/edge`, `internal/hub/server.go`, cnf `hub.env.SPOOL_HUB_EDGE_*` | In-app per-IP socket/handshake/auth limits and socket timeouts (Cloud Armor superseded); `SPOOL_HUB_TRUSTED_PROXY_HOPS` per env from the measured chain |
| WUI Deployment | `csi-spl-wui/firebase.json` | Parameterize `connect-src` for production domains; eliminate `'unsafe-inline'` script allowances |
| CI/CD Pipeline | `017-github-wif-deploy`, `.github/workflows` | Apply WIF repo secrets/variables and enforce strict branch protection |

---

## 3. Implementation Sequence & Dependency Order

1. **Local Box DAC:** Transition local agents to dedicated group membership before modifying permissions in `do_provision_spool_root` to prevent agent disruption.
2. **Authenticated Blob Access:** Add session and capability checks to `handleGetFile` while keeping backward compatibility for active agents via WebSocket upload tokens.
3. **Email Root Key Removal:** Update `TenantWelcome` template so only the tenant URL is emailed; ensure `checkout.vue` displays the private key securely in an unlogged modal.
4. **In-App Edge Limits & Hop Pin:** Ship the hub's per-IP limits, measure the X-Forwarded-For chain of the Cloud Run domain mapping, then pin `SPOOL_HUB_TRUSTED_PROXY_HOPS` per env (Cloud Armor superseded by the owner's no-LB decision).
5. **Deploy credentials:** superseded -- deploys use the per-env SA key secrets `GCP_KEY_CSI_SPL_<ENV>` (iac 120); WIF stays the alternative.

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:00:00Z -->
