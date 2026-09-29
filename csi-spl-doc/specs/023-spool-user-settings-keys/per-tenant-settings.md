# Addendum: personal settings are per-tenant (023 · CLE-35099)

**Lane**: CLE-35099 · **Issue**: SPL-1034 follow-up (epic 41) · **Authority**: this
file for the per-tenant scoping of the 023 personal settings. It does **not**
touch `046-spool-tenant-settings` (that is the tenant's *admin* settings — the
tenant language, users CRUD; a different concern).

## 1. Owner order (verbatim, prd t1 topic 3a589b54)

> "the user setting for the position of the channels is global for all tenants,
> but it should be just per tenant"

> "this applies to the theme, language and other settings too ... in the user
> settings"

Plus two additions relayed by CLE-001 in the same topic:

> "There should be a setting for the default sort order of the issues listing,
> and the global default for new users should be sorted by prio: 1, 2, 3 ...
> from top to bottom"

> "will there be any negative performance implications if we also save the
> sizes of the 2 vertical lines in the UI between the vertical panes?"

## 2. What existed (measured on trunk, 2026-09-29)

`channel_order` was already per-tenant on the membership row (rdb 0073, spec
045 §3.8) and is read/written for the **page's** tenant (SPL-959 hosts:
`auth.ActiveTenant` returns `pageTenantOf(r)` for both `GET /v1/view/me` and
`PUT /v1/me/channel-order`). So the channel order does **not** leak in the hub.

Every **other** personal setting lived on the hub-wide `humans` row and so was
identical across every tenant a person belonged to:

| setting | column (humans) | 023/rdb |
|---|---|---|
| language | `preferred_locale` | rdb 0017 |
| theme | `preferred_theme` | rdb 0057/0059 |
| submit key | `submit_key` | rdb 0062, SPL-976 |
| left-rail order | `rail_order` | rdb 0063/0064, SPL-979 |
| message order / composer position | `message_order`, `composer_position` | rdb 0070 |
| issues view | `issues_view` | rdb 0072, SPL-1028 |
| issues columns | `issues_columns` | rdb 0076, SPL-1132 |
| close buttons | `close_buttons` | rdb 0077, SPL-1133 |
| diagnostics (Debug pane) | `diagnostics_enabled` | rdb 0038 |

Those are the genuine leak the owner saw.

## 3. Model — a per-tenant override, humans row is the fallback

`tenant_memberships.settings jsonb` (rdb **0078**) holds a person's **override**
for the tenant of that membership: an object whose keys are the setting names
above (plus the two new ones in §5), each value the same shape the humans
column / claim uses. A key **absent** = no override in this tenant.

### Read (`GET /session`, native `POST /login`)

For the request's **active tenant** (`auth.ActiveTenant`, i.e. the page host
under SPL-959, else the session `t`), each claim resolves:

```
membership.settings[key]  ??  humans.<column> (global)  ??  product default
```

The overlay happens once per answer (`withSettings`), so the existing per-claim
readers are unchanged — they read the already-overlaid snapshot.

### Write (`PUT /api/v1/auth/preferences`)

The hub writes the value to **both** the humans global column (as today) **and**
the active tenant's `membership.settings` override. Dual-write keeps the global
as a fresh "last used" fallback for a tenant the person has no override in yet
(and for the sign-in page, §4), while every tenant they are already a member of
keeps its own override (§6 migration seeds one per membership), so a change in
tenant X never moves tenant Y.

When no tenant is active (sign-in, before a tenant resolves) only the global is
written — there is no membership to key it on.

## 4. Edge cases (decided)

- **Sign-in page, before a tenant is known** → the **global** humans value
  (the person's last-used / product default). No membership is in scope.
- **Display name and avatar** stay **per human** (`humans.display_name`,
  `humans.avatar_file_id`): a person is one identity across tenants. They are
  **not** in `membership.settings`.
- **Notification sound** — out of scope here; when added it is **per device**
  (a browser/localStorage choice, like the pre-first-paint theme cache), not
  per tenant and not per human. Registered as such.
- **Pre-first-paint theme cache** (`localStorage`) is keyed by active tenant so
  a switch to another host paints that tenant's theme with no flash; the session
  claim remains the source of truth.

## 5. Two new per-tenant settings

- **Issues default sort** (`issues_sort`): `{ "col": <column>, "dir": "asc"|"desc" }`.
  Product default (no stored value) = **priority ascending** (1 at the top), tie
  broken by **updated, newest first** (the hub's stable secondary order). Clicking
  a column header still re-sorts the current view (SPL-972/1027); Settings →
  Behaviour exposes the stored default and a "Save current sort as default".
- **Pane sizes** (`pane_sizes`): the widths of the two vertical dividers between
  the three panes, stored as **fractions of window width** (screen-independent),
  clamped to each pane's min/max, only for widths > 820 px (phones have one
  pane). Written **once on drag end** (pointerup), debounced, skipped when
  unchanged → **1 PUT per drag**. It rides the same session prefs (no extra
  request on load) and is applied via CSS variables before first paint (no
  reflow). "Reset pane sizes" in Settings and a double-click on a divider both
  restore the default. Issue: created under epic 41.

## 6. Migration (rdb 0079, `do_spl_db_bootstrap`, dev then prd)

Seed every existing membership's `settings` from the member's current humans
globals, so no one's settings reset when reads switch to the per-tenant path.
Count before (memberships with a non-null settings) and after; quoted in the
lane's report. New settings (§5) have no humans column, so existing members get
the product default until they choose.

## 7. Tests

- Hub: overlay + dual-write per setting (`internal/auth`, `internal/store`).
- e2e (the control, red before this change): set theme/locale/channel order in
  tenant X, switch to Y → Y keeps its own; back to X → X's values intact.

<!-- last-edit: 2026-09-29T15:00:00Z — CLE-35099 per-tenant personal settings -->
