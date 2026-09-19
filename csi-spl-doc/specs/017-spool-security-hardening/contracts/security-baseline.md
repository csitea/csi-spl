# Security Baseline & Cryptographic Standards

This contract specifies the security invariants, cryptographic primitives, trust boundaries,
and verification baselines across the entire `csi-spl` estate (the spool hub, box clients,
WUI, and cloud infrastructure).

---

## 1. Cryptographic Primitives & Key Management

| Boundary | Algorithm / Primitive | Key Length / Cost | Purpose | Authority |
|---|---|---|---|---|
| Box Identity | Ed25519 (RFC 8032) | 256-bit seed / 32-byte pubkey | Box session authentication (`hello`) and envelope signing | `002-box-agent-messaging` §5, `003` `wire.go` |
| Tenant Root | Ed25519 (RFC 8032) | 256-bit seed / 32-byte pubkey | Authorizes box pinning (`POST /v1/pins`) and revocation (`DELETE /v1/pins`) | `004-spool-identity-routing`, `006` |
| Virtual Browser Box | Ed25519 (RFC 8032) | 256-bit seed / 32-byte pubkey | Signs server-side WUI dispatched task envelopes (`box-wui`) | `014-spool-wui-dispatch` §0 |
| Native Auth Passwords | Argon2id (RFC 9106) | m=19456 KiB, t=2, p=1, salt=16B | Password hash verification and storage | `015-spool-native-auth` FR-001 |
| Session & State Cookies | HMAC-SHA256 | 256-bit key (`SPOOL_HUB_AUTH_SESSION_KEY`) | Stateless session tokens and OAuth PKCE/state binding | `010-spool-social-auth`, `015` |
| Payment Webhooks | HMAC-SHA256 | 256-bit shared secret | Webhook payload signature verification | `006-spool-hub-rental` `checkout-v1` |
| Content Addressing | SHA-256 | 256-bit digest | File deduplication and capability identity (`/v1/files/{file_id}`) | `003` `http-v1.md` §3 |
| Transport Encryption | TLS 1.3 / TLS 1.2 | Google-managed ECDSA/RSA certs | Ingress HTTPS and secure WebSocket (`wss://`) termination | `007` `031-gcp-hub-ingress` |

---

## 2. Invariant Rules (Fail-Closed Gates)

1. **No Unsigned Inter-Box Envelopes on the Hub:**
   Every inter-box envelope traversing `/v1/ws` MUST carry an Ed25519 signature verifiable
   against a pinned public key registered in the tenant's active pin store. Unpinned or
   revoked keys are dropped immediately with code `4401 CloseUnauthorized`.

2. **Tenant Isolation via Canonical Namespaces:**
   - Database tables enforce `tenant_id` foreign keys and compound primary keys (`tenant_id, ...`).
   - GCS blob storage prefixes all objects with `t/{tenant_id}/files/{sha256}`.
   - Tenancy resolution extracts `{tenant}` strictly from verified host patterns (`{tenant}.{base_domain}`).

3. **Stateless Session Token Verification Order:**
   Every session or state cookie MUST have its HMAC signature validated in constant time
   BEFORE any deserialization or payload consumption occurs. Tokens with expired timestamps
   or mismatched subkey labels MUST be rejected.

4. **Zero Secrets in Source, Terraform State, or Logs:**
   All production secrets (Database DSNs, OAuth client secrets, session signing keys,
   box-wui keys, SMTP credentials) MUST reside solely within Google Cloud Secret Manager.
   Terraform manifests create empty secret slots; versions are injected strictly out of band.

5. **Strict Origin & Framing Defenses:**
   Web responses served by Cloud Run and Firebase Hosting MUST enforce HTTP security headers:
   `X-Frame-Options: DENY`, `X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`,
   and strict CORS credential validation against configured whitelists (`ViewCORSOrigins`).

---

## 3. Threat Model & Trust Boundary Matrix

```
   [Untrusted Internet]
           │ (HTTPS / WSS, Port 443)
           ▼
  ┌────────────────────────────────────────────────────────┐
  │ Google Front End (Cloud Run domain mapping, no LB,      │
  │ no Cloud Armor: owner 2026-09-19, as csi-rel)           │
  │ - TLS termination, appends X-Forwarded-For              │
  └────────────────────────┬───────────────────────────────┘
                           │ (ingress all; edge limits in-app, 017 FR-SEC-004)
                           ▼
  ┌────────────────────────────────────────────────────────┐
  │ Cloud Run Hub (`spool serve`, Distroless Static Nonroot)│
  │  ├─ /v1/ws : Ed25519 Box Handshake & Envelopes          │
  │  ├─ /v1/wui/ws : Session-Gated Live WebSocket           │
  │  ├─ /v1/view/* : Session / Token Gated Read Surface     │
  │  ├─ /v1/files : SHA256 Blob Capability Storage          │
  │  └─ /api/v1/auth : Social OIDC & Argon2id Native Auth  │
  └─────────────┬───────────────────────────┬──────────────┘
                │                           │
  (Cloud SQL Auth Proxy)             (GCS Object API)
                ▼                           ▼
  ┌────────────────────────┐      ┌────────────────────────┐
  │ Cloud SQL (PostgreSQL) │      │ GCS Files Bucket       │
  │ - Parameterized SQL    │      │ - Private Objects      │
  │ - Encrypted at Rest    │      │ - Uniform IAM Only     │
  │ - Automated PITR       │      │ - Soft-Delete 7 Days   │
  └────────────────────────┘      └────────────────────────┘
```

<!-- version: 1.0.0 · updated: 2026-09-19 · last-edit: 2026-09-19T13:00:00Z -->
