# Plan: Sign in with Facebook (049)

**Spec**: `spec.md` · **Lane**: CLE-35097

## Approach

The donor's Facebook client and Meta callbacks were ported onto spool's `IdP` interface
by spec 010 (`f17210e`). 049 does not re-port them. It closes what a Live Meta app needs
and what was never proven against Facebook's own shapes:

1. **Tests** (`internal/auth/facebook_test.go`): a Graph-shaped `httptest` server, not the
   generic fake, so the exact token and `/me` requests are asserted (GET, client secret,
   `appsecret_proof`, the field list). Every refusal is paired with a control that passes
   on the same stub, so a refusal cannot pass because the stub is broken.
2. **Status page** (`facebook_callbacks.go`): content negotiation on the existing GET; an
   inline page with no external asset, `Content-Security-Policy: default-src 'none'`.
3. **Policy pages** (`csi-spl-wui/src/public/privacy.html`, `terms.html`): Hosting's
   `cleanUrls` serves them at `/privacy` and `/terms`; static files win over the SPA
   fallback, and there is no JavaScript for Meta's crawler to miss.
4. **Rollout**: the owner's runbook, then cnf + the seed action + 030 through the
   tf-runner, dev first.

## Files

| file | change |
|---|---|
| `csi-spl-api/src/go/spool-hub-api/internal/auth/facebook_test.go` | new |
| `csi-spl-api/src/go/spool-hub-api/internal/auth/facebook_callbacks.go` | HTML status page |
| `csi-spl-wui/src/public/privacy.html`, `terms.html` | new |
| `csi-spl-cnf/csi-spl/{dev,prd}.env.yaml` | App ID, provider list (T051/T052) |

<!-- version: 0.1.0 · updated: 2026-09-29 · last-edit: 2026-09-29T05:00:00Z -->
