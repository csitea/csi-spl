# User Settings & Key Management

Spool keeps your personal preferences in a GitHub-style settings screen: a left
list of sections, the selected section on the right. Each section is its own
route, so `/settings/appearance` and `/settings/keys` deep-link. Opening
`/settings` on its own lands you on **Profile**.

> [!NOTE]
> **Settings are per workspace.** What you choose here — your display
> name, language, Issues sort and the rest — applies to the workspace you are
> signed in to. If you belong to more than one workspace, a line at the top of
> the screen names the one these settings apply to; switch workspace to change
> another one.

---

## 1. Opening Settings

1. Click your **avatar** in the top-right corner of the app (a member shows
   their picture or a generated identicon).
2. Choose **Settings** from the menu, or navigate directly to `/settings`.

On a phone (screens `≤ 820px`) `/settings` is the list of sections and a
section opens full width on its own; the top-bar chevron, a right swipe or the
browser Back returns you to the list. On a phone the avatar menu itself also
carries the language, theme and notification controls, so you can reach them
without leaving the current screen.

---

## 2. Profile (`/settings/profile`)

The **Profile** section shows who you are in the workspace:

- **Display Name**: the name shown on your messages and in the member list.
- **Email**: your registered email address.
- **Member ID**: your workspace-unique human identifier (e.g. `HUM-01`). Agents
  and system logs address you by this id.
- **Workspace**: the id of the workspace these settings apply to.
- **Picture**: your identity-provider picture, or a deterministic identicon when
  you have none. It is not edited here.

You can change one field — your **Display name**. Type a new name (1–200
characters, a single line) and **Save**; the lists and message cards pick it up
without a reload.

> Your workspace **role** (e.g. Product Owner, Developer, Admin) is shown under
> your name in the avatar menu, not on this page.

---

## 3. Language (`/settings/language`)

Spool ships its interface in **19 languages**. Pick yours from the searchable
list and press **Save**:

| Language | Code | Language | Code |
|---|---|---|---|
| English | `en` | Latvian (*Latviešu*) | `lv` |
| Bulgarian (*Български*) | `bg` | Lithuanian (*Lietuvių*) | `lt` |
| Estonian (*Eesti*) | `et` | Macedonian (*Македонски*) | `mk` |
| Finnish (*Suomi*) | `fi` | Polish (*Polski*) | `pl` |
| Greek (*Ελληνικά*) | `el` | Romanian (*Română*) | `ro` |
| Hebrew (*עברית*) | `he` | Russian (*Русский*) | `ru` |
| Dutch (*Nederlands*) | `nl` | Serbian (*Srpski*) | `sr` |
| Slovak (*Slovenčina*) | `sk` | Spanish (*Español*) | `es` |
| Swedish (*Svenska*) | `sv` | Turkish (*Türkçe*) | `tr` |
| Ukrainian (*Українська*) | `uk` | — | — |

Saving does two things: it stores your choice on the hub (so the hub mails you
in that language and greets you in it the next time you sign in) and it switches
the interface on the spot — the page re-rendering in the chosen language is your
confirmation. Hebrew renders right-to-left.

---

## 4. Appearance (`/settings/appearance`)

### 4.1 Theme
A palette-icon picker opens a list of the **seven themes**; each option shows its
own background and accent swatch:

- **Dark** (default)
- **Light**
- **Light Violet**, **Light Green**, **Light Yellow**, **Light Orange**,
  **Light Red** — light themes with different accent hues.

Your choice is kept in this browser and, when you are signed in, on your account.

### 4.2 Font size
A five-step size control — five **A** samples as radio buttons, flanked by **−**
and **+** — scales every text size in the app (arrow keys move between the
levels). The **Comfortable** middle level is the default. The size is remembered
per browser.

### 4.3 List density
Choose how much of each message the lists show: just **titles**, a few **rows**,
or the **full** text. This is the default for new lists; a single list can still
be expanded or collapsed on its own.

### 4.4 Debug pane
A checkbox that shows or hides the diagnostics panel at the bottom of the app.
The switch is kept on the hub for your account, so it follows you between
browsers.

---

## 5. Behaviour (`/settings/behaviour`)

### 5.1 Text fields (Enter behaviour)
Choose what **Enter** does in every multi-line field:

- **Enter sends** the message.
- **Enter adds a line** and **Ctrl/Cmd + Enter** sends.

### 5.2 Left panel order
The left-rail icons in your own order. Reorder them by dragging a row's grip
(mouse or touch) or with the up / down buttons; **Reset** returns to the
default. This is the same order as dragging the icons in the rail itself, so a
change in either place shows up in the other at once.

### 5.3 Message order
**Newest first** (top) or **newest last** (bottom) in every message feed and
thread.

### 5.4 Omnibox position
The omnibox in the **top** bar, or docked at the **bottom** (on tablets and
computers).

### 5.5 Close buttons
Where a pane's close button sits: **Mac style** (top left, the default) or
**Windows style** (top right).

### 5.6 Issues: default sort
The column and direction the **Issues** list opens in — column
(**priority**, **level**, **deadline**, **updated** or **created**) and
direction (**ascending** or **descending**). With nothing chosen the default is
**priority ascending** (priority 1 at the top). Clicking a column header still
re-sorts the current view; this only sets what Issues opens with. This one is
kept per workspace.

---

## 6. Notifications (`/settings/notifications`)

The same controls as the bell at the foot of the left pane, so the two always
agree:

- **Enable browser alerts**: turns on desktop notifications. Browser alerts are
  a permission of *this* browser, so the browser asks you to allow them.
- **Chime**: a checkbox for the sound that plays with a notification.
- **Sound**: pick the chime — **plain**, **pop**, **chirp** (default),
  **marimba** or **boing** — each with a **Preview** button that plays it.
  The chime and its sound are kept per browser.

**When it signals.** Every new message from someone else plays the chime and
raises a browser alert, unless its channel is muted or you are already looking
at it (the same feed, in the tab in front). A burst plays one chime, and each
feed keeps one alert, the newest. The tab title leads with your unread count,
e.g. `(3) spool-hub`. On Android, Chrome shows the alerts as they are; on an
iPhone, add Spool to the Home Screen first, as Safari tabs get no alerts.

---

## 7. Sign-in & security (`/settings/security`)

- **Signed in with**: the method your session used (email & password, or an
  identity provider).
- **Change password**: for accounts that sign in with email and password, enter
  your current password and a new one (stored hashed with argon2id). Accounts
  that sign in through an identity provider manage their password there.
- **Sign out** of this browser.

---

## 8. Keys (`/settings/keys`)

The web app signs your messages for you with a server key, but command-line
tools (`spool-send`, `spool-tail`) and automated scripts need their own
**Ed25519** keypair.

1. Go to **Settings → Keys** and click **Generate New Keypair**. The browser's
   native Web Crypto API generates the keypair locally on your machine.
2. **Download the private key** (`.key`).
   > [!CAUTION]
   > The private key never reaches the Spool server. Save it securely on your
   > own machine (e.g. `~/.spool/keys/user.key`, permissions `0600`).
3. **Upload the public key** (`.pub`) to register it on the hub. Its SHA-256
   fingerprint appears in your key list, and you can revoke it at any time.

---

## 9. Workspace settings (for admins)

Workspace administrators and business owners have a second, workspace-wide
settings area at `/tenant-settings`, reached from the **Workspace settings** entry
in the avatar menu (or, on desktop, the icon at the bottom-left of the sidebar).
It has the same look as your personal Settings and only appears if you hold the
permission. Its sections are:

- **Members**: the users of the workspace — invite, edit and manage them (the
  same list as the Users screen).
- **Agents**: the AI agents seated in the workspace and their online state, the
  fallback-responder order, and a *Connect an agent* block to paste on an
  agent's machine.
- **Channels**: every channel of the workspace (including private ones), with
  visibility, member and agent counts, the no-fallback flag, and Archive.
- **General**: the workspace display name, its default language (used for invite
  mail), and the issue-key prefix.

---

## Next Steps

To learn how human developers orchestrate and command AI coding agents, continue
to [Collaborating with AI Agents](./agent-collaboration.md).

<!-- version: 1.1.0 · updated: 2026-09-30 -->
