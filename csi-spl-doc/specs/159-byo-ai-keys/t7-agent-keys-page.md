# Spec 159 T7: the Agent keys page, as built

Row T7 of [spec 159](spec.md) section 11, with
[spec 127](../127-workspace-vendor-keys/spec.md) row W1. Issue SPL-3745,
epic SPL-2398. This file says what the page does on the tree that adds it,
and which parts of spec 159 section 10 wait for another row's hub route.

`sk-test-0000` is the only key that appears in the tests; no real key,
token or host is in the code or here.

## 1. What the page does

Workspace settings -> **Agent keys**, `/tenant-settings/agent-keys`
(`csi-spl-wui/src/pages/tenant-settings/agent-keys.vue`, the row controls in
`src/components/VendorKeyControls.vue`, the reading of the routes and the
mock hub in `src/utils/vendor-keys.mjs`).

| spec | requirement | how |
|---|---|---|
| 159 10, 3 | visible to `vendor_keys.manage`, so `biz_owner` and `admin` | the nav entry's permission (`utils/tenant-settings-nav.ts`); the page itself shows one line and no control to anyone without it; the hub answers 403 on every route |
| 159 10 | per kind: set, not set, exhausted with retry, not available | one row per kind, `data-state` = `vendorKeyState()`; Retry shows only on an exhausted key |
| 159 4.2, 127 R5.2 | grok and mistral "waiting for the vendor's terms", agy "not supported" | the hub's `available: false`; the agy line differs from the others |
| 159 3, 127 5.1 | an unconfirmed (operator-made) manager reads, changes nothing | the hub's `confirmed: false`: the rows show, with one line saying who can confirm; no input and no button |
| 127 8 | Set / Replace / Remove; qwen also its https `base_url` | `PUT` / `DELETE /v1/vendor-keys/{kind}`; Remove asks first |
| 127 L12 | a password field, `autocomplete=new-password`, the value cleared after the PUT, never in storage | the controls clear the typed key the moment they hand it to the page, whatever the hub answers; the key is never in Pinia, localStorage or sessionStorage |
| 127 L17 | no beacon carries the key | the e2e watches every request the page makes |
| 159 10 | new text in every locale, agy reviews it last | `tenant_settings.agent_keys_nav` and `tenant_settings.agent_keys.*` in all 19 catalogues; the agy review is a step before the landing |

The routes the page reads are those of row T1 (spec 127 4.3):
`GET /v1/vendor-keys` answers `{kinds: [{kind, available, set, last4,
base_url, set_by, set_at}], confirmed}`.

## 2. What waits for another row

The page reads two things no hub route answers yet. Both are read as
optional, so the page works on the T1 hub today:

- **`exhausted`** on a kind of the GET, and **`POST
  /v1/vendor-keys/{kind}/retry`** (204): row T5 (spec 159 9, "a
  `biz_owner` or `admin` replaces the key or presses retry"). Until T5
  lands no key reads exhausted, so Retry never shows.

The other parts of section 10 have no route yet, so the page does not show
them:

| part of 159 10 | waits for |
|---|---|
| the toggle "run our agents on spool-hub's shared boxes", with the 5.4 risk, and the boxes marked "shared spool-hub box" | T3 |
| the toggle "fall back to spool-hub's metered agents" | T5 |
| "Sign in with my Claude subscription", who signed in, sign-out | T8, off until O1 |
| the usage line per kind, "paid to your vendor" | T6 and 127 8.1 |
| the key-box list with "may use agent keys" | 127 H2 |
| the date of the last terms check on a not available row | T9 |

## 3. Tests

- `csi-spl-wui/tests/e2e/agent-keys.test.mjs`, in a real browser on the mock
  bundle: a `biz_owner` sees the page and a `developer` does not; an
  exhausted key shows Retry and Retry clears it; after Set, the input, the
  page text, the Pinia store, localStorage and sessionStorage hold no
  `sk-test-0000`, and no request carries it; qwen without a base URL is
  refused; Remove asks; an unconfirmed manager sees no control.
- `csi-spl-wui/tests/unit/vendor-keys.test.mjs`: the GET reading, the
  states, the PUT body checks, and a mock hub that keeps the last 4
  characters only (so the e2e's storage check proves the page, not the
  mock).
- Red controls, each run with the defect planted and seen red on its step:
  the key not cleared after save (step 4), the section shown without its
  permission (step 2), Retry hidden (step 6). Before the page existed the
  e2e failed at step 1.

<!-- version: 1.0.0 · updated: 2026-10-27 -->
