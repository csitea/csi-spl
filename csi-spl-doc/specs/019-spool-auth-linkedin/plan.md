# Plan: Sign in with LinkedIn (019)

**Spec**: `spec.md` · **Lane**: CLE-3387 · **Base**: `f17210e` (010 T041)

## 1. Approach

No new rails. LinkedIn stays a generic OIDC provider (`internal/auth/oidc.go`); 019
adds guards and proofs around it, one shared seed action, and the owner inputs.

| area | change | owner |
|---|---|---|
| `internal/auth/config.go` | `validateProvider` case `linkedin`: scopes must contain `openid` + `email` (FR-L2) | 019 |
| `internal/auth/oidc_linkedin_test.go` (new) | LinkedIn-shaped userinfo contract (FR-L3): verified bool/string accepted, false/missing/empty email refused, name + avatar | 019 |
| `csi-spl-orc/src/bash/run/spl-auth-idp-secret-seed.func.sh` (new) | `do_spl_auth_idp_secret_seed`, IDP = facebook, microsoft, linkedin, xai (FR-L4); refuses a bare-GUID Microsoft "Secret ID" (request from 018) | 019 |
| `csi-spl-orc/src/bash/tests/auth-idp-secret-seed.tst.sh` (new) | stubbed gcloud + file-backed store, same shape as `auth-secrets-seed.tst.sh` | 019 |
| `do_spl_merged_cnf` callback derivation on the WUI apex (FR-L5 / T030; owner 2026-09-19) | already rendered | 019 |
| WUI LinkedIn brand mark (FR-L6) | request sent | CLE-55 |
| cnf `SPOOL_HUB_AUTH_LINKEDIN_CLIENT_ID` + `SPOOL_HUB_AUTH_PROVIDERS` per env (FR-L7) | after the owner files exist | 019 |
| hub image + 030 deploy | the deploy path (spec 008) | CLE-3355 / CI |

## 2. The seed action

```
IDP=linkedin ENV=dev [DRY_RUN=0] ./run -a do_spl_auth_idp_secret_seed     (from csi-spl-orc)
```

1. `do_spl_cloud_cnf` → `$SPL_CNF`, `$SPL_PROJECT`; `do_gcp_pin_account` (per-env SA, `--account` on every call).
2. Slot = `.env.auth.social.secret_env.SPOOL_HUB_AUTH_<IDP>_CLIENT_SECRET`; cnf id =
   `.env.auth.social.env.SPOOL_HUB_AUTH_<IDP>_CLIENT_ID` (refused when unset / `PLACEHOLDER-*`).
3. File `$HOME/.gcp/.<org>/.<app>/<idp>-client-<env>.json`: must exist, mode `600`, JSON
   with non-empty `client_id` == cnf and `client_secret`.
4. Latest version sha256 == file secret sha256 → nothing. Else DRY_RUN reports, `DRY_RUN=0`
   adds a version on stdin and re-reads it to verify.

It never mints the session key (that stays `do_spl_auth_secrets_seed`).

## 3. Rollout (dev, then prd)

1. Owner: runbook §2–§3 → the two files (spec §4).
2. Agent: commit the env's client id in cnf; `IDP=linkedin ENV=dev ./run -a do_spl_auth_idp_secret_seed`
   (dry), then `DRY_RUN=0`.
3. Agent: add `linkedin` to dev `SPOOL_HUB_AUTH_PROVIDERS`, render, push; the CI deploy rolls 030.
4. Verify SC-L3 on dev; owner signs in once. Then the same for prd.

## 4. Risks

- The owner must register the **WUI-apex** redirect URLs already in rendered cnf
  (T030, owner 2026-09-19, 010 OQ-A2): `https://dev.spool-hub.ai/api/v1/auth/linkedin/callback`
  and `https://spool-hub.ai/api/v1/auth/linkedin/callback`. An API-host URI is declined.
- Pairwise `sub`: replacing an app orphans identities (spec OQ-L2).

<!-- version: 0.1.0 · updated: 2026-09-19 -->
