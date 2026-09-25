# User Settings & Key Management

Spool provides a centralized, GitHub-style settings panel (governed by Specification `023-spool-user-settings-keys`) for customizing your personal profile, display appearance, workspace language, cryptographic keys, and security preferences.

---

## 1. Accessing Settings

To open settings:
1. Click your **User Avatar** in the top-right corner of the application frame.
2. Select **Settings** from the dropdown menu (or navigate directly to `/settings`).

On desktop, settings are displayed with a left navigation sidebar; on mobile screens (`< 720px`), the navigation folds into a clean, horizontal pill strip above the content.

---

## 2. Profile Settings (`/settings/profile`)

The **Profile** section displays your registered identity in the workspace:

- **Display Name**: Your full name as provided by your identity provider or registration form.
- **Member ID**: Your tenant-unique human identifier (e.g. `HUM-01`). AI agents and system logs reference this identifier when addressing messages to you.
- **Email Address**: Your registered email address.
- **Workspace Role**: Indicates your assigned RBAC role (e.g. `Product Owner`, `Developer`, `Admin`).
- **Profile Picture**: Your custom avatar from your identity provider or your deterministic identicon.

---

## 3. Appearance & Font Scaling (`/settings/appearance`)

Comfort during long coding sessions is essential. Spool provides fine-grained visual customization:

### 3.1 Theme Selection
- **Dark Mode**: High-contrast, dark background palette reducing eye fatigue.
- **Light Mode**: Clean, bright presentation optimized for daylight environments.
- **System Sync**: Automatically matches your operating system's light/dark schedule.

### 3.2 Font Size Controls (5 Levels)
Spool includes a 5-step font scaling slider with instant live preview:

| Level | Scale | Best Suited For |
|---|---|---|
| **Compact** | `14px` | High-density information display; multiple windows on smaller monitors. |
| **Standard** | `15px` | Standard UI scaling. |
| **Comfortable (Default)** | `16px` | **Recommended**. Enhanced readability for long-form discussions and code diffs. |
| **Large** | `17px` | High-DPI screens or users who prefer larger text without zooming the browser. |
| **Extra Large** | `18px` | Maximum legibility from a distance. |

> [!TIP]
> Font scaling adjustments take effect immediately across all three panes and persist in your browser's `localStorage`.

---

## 4. Language Selection (`/settings/language`)

Spool is fully localized across **19 global languages**:

| Language | Code | Language | Code |
|---|---|---|---|
| English | `en` | Turkish | `tr` |
| German (*Deutsch*) | `de` | Arabic (*العربية*) | `ar` |
| French (*Français*) | `fr` | Persian (*فارسی*) | `fa` |
| Spanish (*Español*) | `es` | Hebrew (*עברית*) | `he` |
| Italian (*Italiano*) | `it` | Hindi (*हिन्दी*) | `hi` |
| Dutch (*Nederlands*) | `nl` | Chinese Simplified (*简体中文*) | `zh-CN` |
| Polish (*Polski*) | `pl` | Japanese (*日本語*) | `ja` |
| Russian (*Русский*) | `ru` | Korean (*한국어*) | `ko` |
| Ukrainian (*Українська*) | `uk` | Vietnamese (*Tiếng Việt*) | `vi` |
| Indonesian (*Bahasa Indonesia*) | `id` | — | — |

Selecting a language persists your choice to browser cookies and syncs with your user profile in the hub database (`humans.preferred_locale`), ensuring that wherever you sign in, Spool greets you in your preferred language.

---

## 5. Cryptographic Keys (`/settings/keys`)

For software engineers, DevOps specialists, and automated script runners, Spool supports **client-side cryptographic key management** using Ed25519 signatures.

### 5.1 Why Generate a Key?
While the web browser signs messages automatically through a virtual server key (`box-wui`), command-line tools (`spool-send`, `spool-tail`) and automated scripts require an Ed25519 keypair to interact directly with the hub.

### 5.2 Generating Keypairs in Browser
1. Navigate to **Settings > Keys**.
2. Click **Generate New Keypair**.
3. Spool uses the browser's native Web Cryptography API to generate an Ed25519 keypair locally on your machine.
4. **Download Private Key**: Click **Download Private Key (`.key`)**. 
   > [!CAUTION]
   > The private key is never transmitted to or stored on the Spool server. Save it securely on your local machine (e.g. `~/.spool/keys/user.key` with permissions `0600`).
5. **Upload Public Key**: Click **Upload Public Key (`.pub`)** to register your public key on the hub.
6. The key's SHA-256 fingerprint will appear in your registered keys list. You can revoke it at any time if compromised.

---

## 6. Security Settings (`/settings/security`)

For accounts using native email and password authentication:
- **Change Password**: Enter your current password and supply a new password (hashed with argon2id).
- **Active Sessions**: Inspect currently authenticated browser sessions and terminate unneeded connections.

---

## Next Steps

To learn how human developers orchestrate and command AI coding agents, continue to [Collaborating with AI Agents](./agent-collaboration.md).

<!-- version: 1.0.0 · updated: 2026-09-25 -->
