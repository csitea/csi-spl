# Spec: user settings, GitHub-style, and the Keys section (023)

**Feature**: `specs/023-spool-user-settings-keys` · **Created**: 2026-09-19 · **Lane**: CLE-3408

## 1. Owner order (verbatim, 2026-09-19)

> "enable the user setting called keys - on click the user will get into a
> page for the settings (like the github interface - each setting on the left
> and its content on the right) and the keys section will have a default
> public private key created and the user will be able to download the private
> key and the public key, or upload new public key"

## 2. What exists (measured on `de06bd7`)

| aspect | today | file |
|---|---|---|
| settings page | one page, four stacked cards: Profile, Language (CLE-3403 `<LanguageSetting/>`), Appearance, Sign-in and security (CLE-3402 `12ece07`) | `csi-spl-wui/src/pages/settings.vue` |
| entry | the user menu's Settings item → `localePath('/settings')` | `csi-spl-wui/src/components/UserMenu.vue:55-60` |
| routing | `/settings` is not prerendered: Firebase serves the SPA fallback, so any `/settings/<x>` deep link hydrates client-side | `nuxt.config.ts` (`PRERENDER_PAGES = ["/", "/login"]`) |
| box key format | private = base64(64-byte Ed25519 seed‖pub) + `\n`, file `box-<id>.key` 0600; public pin = base64(32 bytes) + `\n`, `box-<id>.pub` | `internal/sign/sign.go` (`GenerateKey`, `Pin`) |
| tenant root key | the same private format (`spool root-keygen --out`) | `cmd/spool/hub.go:311` |
| a human's key | none: a human (HUM-*, rdb 0006) authenticates only by the 010/015 session cookie; the hub verifies box signatures by pins (004), never a human's | `rdb 0006`, `internal/hub/rest.go` |
| SEC-03 | private key material is shown once, never stored by the hub, never mailed (006 FR-014 as amended by 017 T008) | `specs/006-spool-hub-rental/spec.md` FR-014 |

## 3. Decisions

### 3.1 Where the default key pair is generated — the browser (option a)

The default Ed25519 pair is generated **in the browser** (WebCrypto
`Ed25519`) the first time a signed-in human opens **Settings → Keys** with no
active key. The page uploads **only the public key**; the private key lives in
page memory, is offered as a download (and the public key too), and is gone
when the page is left. The hub never receives, stores, logs or returns a
private key.

Security reasoning:

- **No custody, no breach surface.** A hub that never holds a private key
  cannot leak one from its database, its backups, a log line or a stolen
  session. Server-side custody (b) turns every session-cookie theft into a
  key theft, and the Postgres backups into key backups.
- **Consistent with SEC-03** (017 T008): the tenant root key is minted once
  and shown once; keys are not escrowed or mailed. A human key follows the
  same rule.
- **The browser is already trusted with the session.** Generating in the page
  adds no new trust: the same origin already carries the session cookie.
  WebCrypto's generator is the platform CSPRNG; the private bytes are exported
  only into a `Blob` for the download.
- **Refusal on the wire.** The API rejects any body that carries a field it
  does not know (so no `private_key` can be sent), refuses a 64-byte key or a
  `PRIVATE KEY` block, and answers nothing but public material.

Consequence: "download later" of the **private** key is not possible after the
page is left. The page says so next to the download, and offers
**Generate a new key pair** (the old one is revoked, history kept) for a
human who lost it. The **public** key stays downloadable any time. Server
custody is refused (OQ-1 answered by the owner 2026-09-19: (a) browser only).

A browser without WebCrypto Ed25519 (Chrome < 137, Firefox < 129, Safari < 17)
gets no default pair: the page says so and shows the CLI route
(`spool root-keygen --out <file>` prints the public key to upload).

### 3.2 Formats — the ones the boxes already use, plus OpenSSH

| file | content | works with |
|---|---|---|
| `<HUM-n>.key` | base64(64-byte seed‖pub) + `\n` | exactly `spool keygen` / `root-keygen` output: `sign.LoadPrivate`, `--root-key` |
| `<HUM-n>.pub` | base64(32 bytes) + `\n` | exactly a pin value: `spool pin --pubkey "$(cat HUM-n.pub)"`, `hub-pin --pubkey` |
| `<HUM-n>.openssh.pub` | `ssh-ed25519 AAAA… spool:<HUM-n>` | OpenSSH `authorized_keys`, `ssh-keygen -lf` |

Upload accepts either public form: the 44-char base64 pin value or an
`ssh-ed25519` line (the comment is ignored). The fingerprint shown is
OpenSSH's (`SHA256:` + unpadded base64 of sha256 over the ssh wire blob), so
`ssh-keygen -lf <file>` prints the same string.

### 3.3 What the key is FOR

Today, **nothing in the hub verifies a human key**: box traffic is verified by
box pins (004 pin-semantics), and a human is authenticated by the session
cookie. The key is a registered, downloadable **identity key** for the human,
format-compatible with the box keys, so it can be used where a box key or a
root key is used:

- as the key of a personal box (`box-<id>.key` under `~/.spool/keys`, pinned
  with the `.pub`), which is the one use that works end to end today;
- as the future identity for a human signing as a box peer (a HUM-* signing a
  message from the CLI) — no hub consumer yet (OQ-2).

The Keys section says so on the page too: the hub keeps the public key as
your identity key and no spool feature requires it yet.

### 3.4 Settings layout — GitHub-style

`/settings` becomes a two-column page: a left nav of sections, the selected
section on the right. Each section is its own route and deep-linkable:

| route | section | content (moved, not duplicated) |
|---|---|---|
| `/settings` | → redirects to `/settings/profile` | |
| `/settings/profile` | Profile | the old Profile card |
| `/settings/language` | Language | CLE-3403's `<LanguageSetting/>` |
| `/settings/appearance` | Appearance | theme, font size (3.5) |
| `/settings/security` | Sign-in and security | method, password change, sign out |
| `/settings/keys` | Keys | 3.1-3.3 |

Locale prefixes apply (`/fi/settings/keys`). Below 720px the nav collapses to
a wrapping row of links above the content (no x-scroll). The signed-out state
renders once, in the parent, for every section.

### 3.5 Font size (CLE-3495, owner 2026-09-25) — Implemented

> "also make the default font a big bigger , actually we need a setting in the
> personal settings to regulate the size of the default onts , with + for
> getting bigger fornts and - for getting smaller - 5 levels with radio buttons"

- **Five levels**, a native radiogroup on `/settings/appearance`, with a `−`
  (one level smaller) and a `+` (one level bigger) each disabled at its end.
- **One root variable.** `html { font-size: var(--font-root) }`, set per level
  by `data-font-size` on `<html>`: 87.5 / 100 / 112.5 / 125 / 137.5 % of the
  browser default (16px → 14 / 16 / 18 / 20 / 22 px). Every text size in the
  WUI is rem so it follows; the exceptions are avatar initials (fixed-px
  circles) and the five "A" samples in the control. Gate:
  `tests/unit/font-size.test.mjs`.
- **Default is level 3 (18px).** Measured before the change on dev and prd
  (`/login`, headless Chrome, n=1 each): `html` and `body` computed 16px — that
  is level 2 now.
- **Persistence: per browser** (`localStorage` `spool-font-size`, like the
  theme — `utils/prefs.mjs`), not hub-side like `preferred_locale`. The locale
  is on the hub because the hub mails in it; nothing on the hub reads a font
  size, and a hub field would cost a migration, a hub roll and a preferences
  contract change for a purely visual choice. A reader on a phone and on a
  desktop may also want different sizes.

## 4. Requirements

- **FR-001** `/settings` is the two-column layout of 3.4; the user menu's
  Settings entry lands there; each section has its own route.
- **FR-002** On first visit to Keys with no active key and a WebCrypto
  Ed25519 browser, the page generates a pair, registers the public key
  (`source: generated`) and offers both downloads. The private key is never
  sent to the hub.
- **FR-003** Download the public key (pin form and OpenSSH form) at any time;
  download the private key only while the page that generated it is open.
- **FR-004** Upload a public key (paste or file): it replaces the active key;
  the old one is kept as history with `revoked_reason = replaced`.
- **FR-005** Revoke the active key (no replacement): history keeps it with
  `revoked_reason = revoked`; the next visit generates a new default pair.
- **FR-006** The hub validates an uploaded key as exactly 32 Ed25519 bytes
  (base64 pin form or `ssh-ed25519` line), refuses private-key material,
  malformed input and a key already registered to any human (`duplicate_key`,
  the same answer whoever owns it).
- **FR-007** Every keys route needs a member session carrying a HUM-*;
  a human sees and changes only their own keys (another human's key id is
  `404`, never `403`, so ids do not leak).
- **FR-008** Writes are rate-limited per human (in-process window) and
  audited: a structured log line per add / revoke (human id, key id,
  fingerprint, source, reason) plus the durable history rows.
- **FR-009** i18n: every string is a catalogue key in all 19 locales. Check
  (GRK-3380, 2026-09-21): 19 locale files each carry all 58 `settings` leaves;
  identical-to-English is 0 for es/ru/tr/uk/he/sv/nl and 1/58 for el
  (`settings.email` = `Email`).
- **FR-010** No document x-scroll at phone width; CSP unchanged (WebCrypto
  and `blob:` downloads need no new directive).
- **FR-011** Font size (3.5): five levels as radios plus `−` / `+`, one level
  per step, stopping at 1 and 5; the body font-size grows strictly level to
  level; the default is one level above the old 16px root; the choice
  survives a reload. Strings in all 19 locales.

## 5. Open questions (owner)

- **OQ-1 private key "download later".** Answered by the owner 2026-09-19:
  **(a) browser only** — the server never holds private keys. Built: the
  default Ed25519 pair is generated in the browser; the private key is
  downloadable while the generating page is open, never on the hub.
  Alternative **(b)** (hub stores the private key encrypted and serves it to
  a signed-in session) is refused: every session theft would become a key
  theft and it contradicts SEC-03. Nothing further to build.
- **OQ-2 consumer.** No hub feature verifies a human key yet. Candidates: a
  HUM-* signing CLI messages, or pinning a personal box from the WUI. Pick one
  before the key becomes load-bearing.

<!-- last-edit: 2026-09-19T16:40:00Z -->
