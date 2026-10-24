# User Settings & Key Management

> Generated from qto doc `ab35fc38-9d9b-4f47-87bb-37be5fa2bcba`; edit it there. This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.

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

<a id="ws-doc-1ee4def0-d20c-4a04-96b1-6000d31c7e97"></a>
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

<a id="ws-doc-7fa85868-e707-4cfe-ba47-f48ea1b90e6c"></a>
## 2. Profile (`/settings/profile`)

The **Profile** section shows who you are in the workspace:

- **Display Name**: the name shown on your messages and in the member list.
- **Email**: your registered email address.
- **Member ID**: your workspace-unique human identifier (e.g. `HUM-01`). Agents
  and system logs address you by this id.
- **Workspace**: the id of the workspace these settings apply to.
- **Picture**: your identity-provider picture, or a deterministic identicon when
  you have none. It is not edited here.

You can change your **Display name**. Type a new name (1–200
characters, a single line) and **Save**; the lists and message cards pick it up
without a reload.

**Interests** is a separate note, up to 1000 characters, about what you work
on or care about. It is shown on your card in the People section. Save it on
its own. Leave it empty and the card shows no interests.

> Your workspace **role** (e.g. Product Owner, Developer, Admin) is shown under
> your name in the avatar menu, not on this page.

**Status** (Busy or Unavailable, with a note and an end time) is not set here
but from your own row in the Direct Messages panel or **Set a status** in the
avatar menu: see [Setting your status](./channels-and-direct-messages.md#311-setting-your-status).

---

<a id="ws-doc-d9a42ce7-88b1-47f7-8508-2dfee5f5bcda"></a>
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

<a id="ws-doc-164ce7ba-d48c-4839-b778-1dcff2743ca5"></a>
## 4. Appearance (`/settings/appearance`)

<a id="ws-doc-b5f2261d-abb2-49d7-80a9-690ed72983c6"></a>
### 4.1 Theme
A palette-icon picker opens a list of the **seven themes**; each option shows its
own background and accent swatch:

- **Dark** (default)
- **Light**
- **Light Violet**, **Light Green**, **Light Yellow**, **Light Orange**,
  **Light Red** — light themes with different accent hues.

Your choice is kept in this browser and, when you are signed in, on your account.

<a id="ws-doc-273b8ebd-8de1-4c55-8dcc-1f03005d03f9"></a>
### 4.2 Font size
A five-step size control — five **A** samples as radio buttons, flanked by **−**
and **+** — scales every text size in the app (arrow keys move between the
levels). The **Comfortable** middle level is the default. The size is remembered
per browser.

<a id="ws-doc-01cf0117-c117-4f95-a83a-223a01dd235f"></a>
### 4.3 List density
Choose how much of each message the lists show: just **titles**, a few **rows**,
or the **full** text. This is the default for new lists; a single list can still
be expanded or collapsed on its own. With **rows**, every card in a list is the
same height: a one-line message leaves white space under its text, and a longer
one is cut with a grip under it to show the rest.

<a id="ws-doc-434d4e55-c262-4929-9757-b47f3beeb157"></a>
### 4.4 Debug pane
A checkbox that shows or hides the diagnostics panel at the bottom of the app.
The switch is kept on the hub for your account, so it follows you between
browsers.

It also decides how much an error says. With it off, a screen that could not
load says one plain sentence with a **Try again** button, and no "No messages
yet." under it (a list that did not load is not empty). The error bar at the
top says what went wrong in plain words. With it on, the technical
details show under that sentence: the status code, the error text and the
error reference to quote when you report it.

<a id="ws-doc-399d6739-37eb-4543-bce2-3ec10b59cd64"></a>
### 4.5 Time zone
Pick a zone, or leave **Browser time zone**. Every time in this workspace
shows in that zone, including an ISO time that carries a zone inside a
message. A time with no zone stays as written. The choice is kept for this
workspace.

<a id="ws-doc-f67fdff2-ccbc-4e52-8014-ebb9773e4b1b"></a>
### 4.6 Thinking animation
The mark on your message while it waits for an agent's answer
([waiting for an answer](omnibox-and-navigation.md)). The list has 17
animations, one under the other, each with a checkbox and its own running
sample: hourglass, running robot, brain, dancing robot, typing dots, spinner,
radar, gears, light bulb, coffee, orbit, pendulum, sound bars, pencil, rocket,
clock and wave. The ticked ones take turns, about 3 seconds each; with one
ticked, that one stays. At least one stays ticked: the last one cannot be
unticked. The default is the hourglass, the running robot and the brain.

With *reduce motion* on in your system the mark is a still hourglass. The
pick is kept in your account for this workspace, so another device or browser
shows the same animations. A pick made in this browser before it moved to the
account is carried over once.

---

<a id="ws-doc-1328d045-7fea-4f7a-a224-2fc3a561de9e"></a>
## 5. Behaviour (`/settings/behaviour`)

<a id="ws-doc-a6f977e2-8afe-4771-944b-8934467687cd"></a>
### 5.1 Text fields (Enter behaviour)
Choose what **Enter** does in every multi-line field:

- **Enter sends** the message.
- **Enter adds a line** and **Ctrl/Cmd + Enter** sends.

<a id="ws-doc-90209038-0738-4966-a4ab-866570ddd362"></a>
### 5.2 Left panel order
The left-rail icons in your own order. Reorder them by dragging a row's grip
(mouse or touch) or with the up / down buttons; **Reset** returns to the
default. This is the same order as dragging the icons in the rail itself, so a
change in either place shows up in the other at once.

<a id="ws-doc-de67bf78-b2a7-410a-a83e-fb0290362c72"></a>
### 5.3 Message order
**Newest first** (top) or **newest last** (bottom) in every message feed and
thread.

<a id="ws-doc-f7bca684-27fd-44b2-acd5-8a9b9bad27e3"></a>
### 5.4 Omnibox position
The omnibox in the **top** bar, or docked at the **bottom** (on tablets and
computers).

<a id="ws-doc-70b145d5-3cea-47f6-a9f6-567300838998"></a>
### 5.5 Close buttons
Where a pane's close button sits: **Mac style** (top left, the default) or
**Windows style** (top right). The X that removes an attachment from a file
card follows the same choice: left with Mac style, right with Windows style.

<a id="ws-doc-2f45a483-ca83-4c20-8419-9f101e16a6ca"></a>
### 5.6 Issues: default sort
The column and direction the **Issues** list opens in — column
(**priority**, **level**, **deadline**, **updated** or **created**) and
direction (**ascending** or **descending**). With nothing chosen the default is
**priority ascending** (priority 1 at the top). Clicking a column header still
re-sorts the current view; this only sets what Issues opens with. This one is
kept per workspace.

<a id="ws-doc-04e92ce8-f8d4-4ddc-97c2-fd22a02a9341"></a>
### 5.7 Keyboard shortcuts
A switch, on unless you turn it off. While it is on, **Shift + a letter**
acts on the selected message on a desktop (the list is in
[Keyboard Shortcuts](./keyboard-shortcuts.md)), and **Shift + ?** shows that
list. While it is off, those keys do nothing. The switch is kept for this
workspace.

<a id="ws-doc-b72cf373-4fff-4751-8637-b360caf33770"></a>
### 5.8 Link previews
A link in a message to a topic or a message of this workspace shows a small
card under the message: whether it is a topic or a message, its title (the
first 100 characters), up to three lines of what it says, who wrote it and
when. Click the card to open it. Only what you may read gets a card; a link to
something you cannot open stays a plain link. **On** by default. Untick it to
turn the cards off; this changes only your own view, never anyone else's.

<a id="ws-doc-0f9b4ad6-bc67-4543-a043-39871fcafa68"></a>
### 5.9 Email links open in
Which app opens when you click an email address in a message, whether it is a
bare address, a markdown link or a `mailto:` link:

- **Gmail in the browser** (the default): a Gmail compose window in a new tab.
- **Outlook on the web**: an Outlook compose window in a new tab.
- **System default (mailto:)**, **Thunderbird** or **Outlook (desktop app)**:
  a `mailto:` link, which your device hands to its default mail app. To get
  Thunderbird or the desktop Outlook, make it that default app on your device.

A subject or body that a `mailto:` link carries is kept. Kept on your account;
it changes only your own view.

<a id="ws-doc-db47ba3f-b44c-4c68-90c4-f8be709f879e"></a>
### 5.10 Phone numbers open in
Which app opens when you click a phone number written with **+** and the
country code: **WhatsApp** (the default), **Regular phone call** (`tel:`),
**Viber**, **Telegram**, **Signal** or **Microsoft Teams**. Kept on your
account; it changes only your own view.

---

<a id="ws-doc-66df809c-31e3-4c44-9d14-abe5ade6adbf"></a>
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

<a id="ws-doc-ca315d46-95f5-49e7-8717-7a91c4249195"></a>
## 7. Sign-in & security (`/settings/security`)

- **Signed in with**: the method your session used (email & password, or an
  identity provider).
- **Change password**: for accounts that sign in with email and password, enter
  your current password and a new one (stored hashed with argon2id). Accounts
  that sign in through an identity provider manage their password there.
  The account menu (your avatar) and your own profile card also carry a
  **Change password** link straight to this form; it is hidden for accounts
  without a password.
- **Sign out** of this browser.

---

<a id="ws-doc-72dc64a1-7b2b-4130-9c27-9901c9b610d5"></a>
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

<a id="ws-doc-22ff381c-86cf-4308-af14-e6bbaa7cfcee"></a>
## 9. Workspace settings (for admins)

Workspace administrators and business owners have a second, workspace-wide
settings area at `/tenant-settings`, reached from the **Workspace settings** entry
in the avatar menu (or, on desktop, the icon at the bottom-left of the sidebar).
It has the same look as your personal Settings and only appears if you hold the
permission. Its sections are:

- **Members**: the users of the workspace — invite, edit and manage them (the
  same list as the Users screen). A member can have an **Access until** day.
  After that day they can no longer sign in or act here; their account stays.
  **no end date** is the usual state. **Set the last day** stores the date,
  **Remove the end date** clears it, and a membership that has passed the day
  reads **access ended**. A pending invite shows **Mailed**: **Sent** and the
  time the invitation email went out, or **Not sent**. A resend is possible
  10 minutes after that time. In the list, each pending invite has a status
  next to its role: **expired**, **sent** (an invitation email went out) or
  **not sent**. An accepted invite leaves the list: the person is then a member.
  **Reset password** emails a member who signs in with a password a one-time
  link to set a new one (you never see it); by default it also signs them out
  everywhere. A member who signs in with Google or another provider has no
  password, so the button is greyed out and says so.
- **Agents**: the AI agents seated in the workspace and their online state, the
  fallback-responder order, and a *Connect an agent* block to paste on an
  agent's machine.
- **Vendor split**: how new agent work is shared among Claude, Grok, Antigravity,
  Qwen and Mistral. The five numbers add up to 100. They are a guideline, not a quota.
- **Agent takeover** (`/tenant-settings/takeover`): who takes over when an
  agent fails a task. One row per task kind (Specs and docs, Tests, Simple
  coding, Complex coding, Translations, Secrets and personal data). The row's
  order says which vendor works on the task first and who takes it over, on
  the same branch, after it failed **Max failures** times (a whole number from
  1 to 10). Move a vendor with its up and down arrows, remove it with its cross,
  and add one from **Add a vendor**; **Save** stores the rows you changed and
  **Reset to defaults** puts every row back. A row nobody changed says
  *default*. The defaults: coding and tests go Mistral, then Antigravity, then
  Claude, 2 failures each; specs, docs and translations go Antigravity, then
  Claude, 1 failure; secrets go Claude, then Mistral, 2 failures. Antigravity and
  Qwen never take secret work, so the Secrets row does not offer them.
- **Channels**: every channel of the workspace (including private ones), with
  visibility, member and agent counts, the no-fallback flag, and Archive.
- **General**: the workspace display name, its default language (used for invite
  mail), and the issue-key prefix.
- **Hours**: how time worked is counted for every member of the workspace: the
  period (a week, two weeks or a month), the days after a period ends during
  which members can still edit it, the idle cutoff (a gap between two actions up
  to this long counts as worked), and the time zone days and the freeze follow.
- **Performance**: how fast the app feels to the people of this workspace, from
  anonymous timings their browsers send (no names, no messages). One row per
  measurement, device and view, slowest first, with the number of samples (n)
  beside the 50th, 75th and 95th percentile in milliseconds; the 95th shows from
  50 samples. Pick a window of 7 or 30 days, and type a second build to compare
  two versions.
- **Fleet load**: the band a box's load should stay in, as a percent of its
  cores, and the order the boxes take a new agent. The section is
  `/tenant-settings/fleet-load`, and it shows only for an administrator of the
  workspace that runs the fleet. **Low %** and **High %** print their default
  beside the field, and **Reset to default** puts a stored value back. A new
  agent goes to the first box in the list that is under the high mark. An empty
  list leaves the order to each box. A box id is letters, digits and hyphens,
  up to 32 characters, and the list holds at most 32 boxes.

---

## 10. Google Calendar (`/settings/calendar-google`)

Connect your own Google account so that your calendar events stay in step
with a Google calendar. Each member connects their own account, per
workspace. Spool Hub creates a separate calendar, **Spool Hub
(workspace name)**, in your Google account and never writes into your main
calendar.

- **Connect**: click **Connect Google Calendar**, choose your Google account
  and allow access. Google sends you back to this section, which then shows
  your Google account, the synced calendar, the connection status and the
  last sync. **Sync now** asks for a sync at once.
- **Reconnect**: when the status reads **Access revoked** or **Sync error**,
  the reason shows under it; click **Reconnect** to connect again.
- **Disconnect**: click **Disconnect**. Spool Hub revokes its access at
  Google and forgets the connection. Events already imported from Google stay
  as your private events, unless you first tick **Also remove the events
  imported from Google**.
- **Not available**: in a workspace where Google Calendar is not switched on,
  the section says so and shows no Connect button.

---

<a id="ws-doc-5756c5d7-a606-4289-9a00-06004e996e42"></a>
## Next Steps

To learn how human developers orchestrate and command AI coding agents, continue
to [Collaborating with AI Agents](./agent-collaboration.md).

<!-- version: 1.3.0 · updated: 2026-10-14 -->
