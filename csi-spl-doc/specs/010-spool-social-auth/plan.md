# Implementation Plan: Spool social sign-in (010)

**Spec**: `./spec.md` · **Contract**: `./contracts/auth-v1.md` · **Runbook**: `./quickstart.md`

## 1. Shape

```
browser ── GET /api/v1/auth/<p>/start ──▶ hub internal/auth ──302──▶ IdP consent
   ▲                                            │ sets spool_oauth_state (nonce)
   │                                            ▼
   └─302 <APP_URL><redirect> ◀── callback: verify state+cookie ─▶ POST/GET token (client secret)
        sets spool_session                         └─▶ userinfo (Google) / Graph /me + appsecret_proof (Facebook)
                                                   └─▶ Registrar (hub, T012) → HUM-*
```

One package, stdlib `net/http` + the hub's existing deps (`caarlos0/env`,
`zerolog`, `internal/wire`). No new module dependency (`git diff 9be4b71~1 9be4b71 -- csi-spl-api/src/go/spool-hub-api/go.mod | wc -l` → 0).

| File | Role |
|---|---|
| `internal/auth/config.go` | `SPOOL_HUB_AUTH_*` → `Config`, fail-fast rules (FR-007) |
| `internal/auth/idp.go` | `IdP` interface, `Google`, `Facebook`; endpoint paths the fake mirrors |
| `internal/auth/token.go` | signed state + session, subkeys, redirect/tenant guards |
| `internal/auth/handler.go` | the five routes, `Registrar`, `SessionFromRequest` |
| `internal/auth/fakeidp/` | Google + Facebook stand-in (tests, lde, demo) |
| `internal/auth/cmd/auth-demo/` | local end-to-end walk-through |

## 2. Lanes (who changes what)

| Change | Lane | Task |
|---|---|---|
| `internal/auth/**`, `env.auth.social` in cnf, this spec | 010 (CLE-3346) | T001–T008 |
| mount on the hub, Registrar over the store, view door | 003 (CLE-3340) + 004 ids | T010–T013 |
| login page, buttons, error copy, Hosting rewrite | 005 (CLE-3342) | T014–T016 |
| render `env.auth.social` into 030, Secret Manager slots | 007 iac (CLE-3344 / apply CLE-3335) | T020–T022 |
| register apps, add secret versions, flip cnf | owner (tomorrow) | T030–T034 |

## 3. Why no PKCE, no id_token check

Confidential server-side client: the code is exchanged by the hub with its
client secret; the browser never holds one. CSRF is the signed state bound to
the browser cookie. Google claims come from userinfo over TLS with the fresh
access token (same as the csi-rel donor). An id_token signature check would
add a JWKS fetch for the same claims.

<!-- version: 0.1.0 · updated: 2026-09-18 · last-edit: 2026-09-18T19:34:00Z -->
