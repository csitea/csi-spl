# Implementation Plan: 018 Spool sign-in with Microsoft

**Spec**: `spec.md` · **Lane**: CLE-3386 · **Created**: 2026-09-19

## 1. Shape

Microsoft leaves the generic OIDC client. It gets its own client, `internal/auth/microsoft.go`, for the same reasons csi-rel keeps a
dedicated Google client: Microsoft is the one provider whose authority, issuer
and email trust depend on the account's tenant. LinkedIn and xAI stay on `oidc.go`, which the LinkedIn lane owns (CLE-3387).

| file | change |
|---|---|
| `internal/auth/microsoft.go` (new) | `Microsoft` IdP: AuthCodeURL with PKCE S256, `ExchangeNonce` (token → id_token → Identity), tenant rule, `xms_edov` rule |
| `internal/auth/idtoken.go` (new) | stdlib RS256 JWT verifier + JWKS cache (no new module dependency; `go.mod` untouched) |
| `internal/auth/idp.go` | `newIdP` routes `microsoft` to `newMicrosoft` |
| `internal/auth/handler.go` | callback calls `ExchangeNonce(ctx, code, st.Nonce)` when the IdP implements it (additive) |
| `internal/auth/config.go` | Microsoft block only: tenant default `common`, tenant syntax, scopes must hold `openid`+`email`, `TRUST_EMAIL` refused in prd |
| `internal/auth/oidc.go` | drop the `ProviderMicrosoft` case and its endpoint consts (nothing else) |
| `internal/auth/fakeidp/fakeidp.go` | Microsoft-shaped endpoints, RS256 signer, JWKS, PKCE check, per-person `tid` / `xms_edov`; `AddOIDC("microsoft")` delegates to it |
| `internal/auth/microsoft_test.go` (new) | SC-001, SC-002 |
| `csi-spl-cnf/csi-spl/all.env.yaml` | `SPOOL_HUB_AUTH_MICROSOFT_TENANT: common` + comment; re-render dev/prd json |

## 2. Why these choices

- **PKCE on a confidential client.** Microsoft recommends it for every
  auth-code client, and it binds the code to the flow. A code stolen from the
  redirect (logs, Referer, a proxy) cannot be redeemed without the verifier. The
  verifier comes from the session key and the nonce. The nonce is already
  inside the HMAC-signed state and in the browser-bound cookie, so the verifier
  needs no storage, never leaves the hub, and differs for every flow.
- **The id_token instead of userinfo.** In a multitenant app, `tid` and
  `xms_edov` exist only in the id_token (Graph `/oidc/userinfo` has neither),
  and both are needed for the per-tenant issuer check and the nOAuth rule. The
  token comes straight from the token endpoint over TLS, and it is still
  signature-checked, so a wrong key or an issuer mix-up fails closed.
- **The JWKS for the configured authority.** `<tenant>/discovery/v2.0/keys`
  serves the same Microsoft-wide signing keys for `common`, `consumers` and
  `organizations`. The cache holds them for 24 h. An unknown `kid` (Microsoft
  rolls keys) triggers one refetch, at most once per minute, so a flood of
  forged `kid`s cannot turn into a flood of fetches.
- **`<tid>/<oid>` as the subject.** See spec FR-004. No migration is needed:
  `microsoft` has never been listed in any env, so no row carries the old `sub`.
- **Stdlib crypto.** `crypto/rsa.VerifyPKCS1v15` over SHA-256 is all RS256
  needs. go-jose sits only indirectly in `go.mod`, and promoting it would add a
  dependency for about 60 lines of code.

## 3. Test plan

`go test -race -count=1 ./internal/auth/...` plus `bash csi-spl-api/src/bash/tests/run-all-tests.sh`.
The fake IdP issues real RS256 tokens, so the validation runs end to end:

| case | expect |
|---|---|
| personal account (`tid` = consumers GUID), mode `common` | 200 session, subject `<tid>/<oid>` |
| work account, `xms_edov=true`, mode `common` | 200 |
| work account, no `xms_edov` | `email_unverified` |
| work account, no `xms_edov`, `TRUST_EMAIL=true` (lde) | 200 |
| mode `consumers` + work `tid` / mode `organizations` + consumers `tid` / GUID mode + other `tid` | `exchange_failed` |
| id_token: wrong `aud`, wrong `iss`, wrong `nonce`, expired, unknown `kid`, flipped signature byte, `alg=none` | `exchange_failed` |
| PKCE: the fake refuses a token call whose verifier does not hash to the challenge | `exchange_failed` |
| authorize URL carries `code_challenge_method=S256`, no verifier | pass |
| config: bad tenant, scopes without `email`, TRUST_EMAIL in prd | boot error |

## 4. Collisions (live lanes, 2026-09-19)

- CLE-3387 (LinkedIn, 019): the shared seed action `do_spl_auth_idp_secret_seed`
  is theirs. They touch only the LinkedIn cases in `oidc.go`/`config.go`.
- CLE-55 (WUI): owns `SocialAuthButtons.vue`. The Microsoft button is sent to them (T025).
- CLE-3382 / CLE-3354 / CLE-3380 (API host, WUI host, cross-origin auth): they
  decide which host carries the callback. The runbook registers both hosts
  (spec §3), so their outcome needs no Azure change.
- CLE-3355 (deploy): owns the hub image tag bump that ships this code to dev/prd.

## 5. Rollout (dev → prd)

1. Code lands on trunk and CI is green. The deploy lane rolls a hub image that
   contains it. `curl -s https://<host>/version` shows the sha.
2. Owner: Azure app for dev (runbook §2), file `microsoft-client-dev.json` (§3).
3. `IDP=microsoft ENV=dev DRY_RUN=0 ./run -a do_spl_auth_idp_secret_seed` (as the dev SA).
4. cnf `dev.env.yaml`: `SPOOL_HUB_AUTH_MICROSOFT_CLIENT_ID: <id>`,
   `SPOOL_HUB_AUTH_PROVIDERS: google,microsoft` → `ENV=dev ./run -a do_tpl_gen`
   → commit → 030 apply by the deploy path.
5. Verify (spec SC-003) on dev, then repeat 2-5 for prd.

<!-- version: 0.1.1 · updated: 2026-09-25 · last-edit: 2026-09-25T18:40:00Z -->
