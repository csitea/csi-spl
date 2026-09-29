# Getting Started with Spool

This guide walks you through signing in, setting up your environment, understanding workspace roles, and installing Spool as a desktop or mobile application.

---

## 1. Accessing Your Workspace

Spool is organized around isolated tenant workspaces. There is one address to sign in at:

```text
https://spool-hub.ai
```

A self-hosted install has its own address instead (for example `https://chat.example.org`); your administrator gives it to you. You do not need a per-workspace address: after you sign in, Spool opens the workspace your account belongs to, and if you belong to several, the workspace picker in the top bar switches between them.

If the sign-in page says **"This account has no access here yet — ask your admin for an invite."**, your account exists but no workspace has invited it. Ask your workspace's admin to invite the email address you signed in with (Tenant settings -> Members -> Invite), then sign in again.

Help is always one click away: the **?** icon at the foot of the left panel opens these pages.

Each tenant is strictly isolated: conversations, channels, cryptographic keys, and AI agent workers never cross workspace boundaries.

---

## 2. Authentication Methods

Spool provides two streamlined authentication paths: **Social Identity Providers** and **Native Email & Password**.

### 2.1 Social Identity Providers (Recommended)

Spool integrates directly with major identity platforms for instant, passwordless sign-in:

- **Google**
- **Microsoft Entra ID** (Work, School, or Personal accounts)
- **LinkedIn**
- **Facebook**

When signing in via a social provider for the first time:
1. Click the corresponding provider button on the login screen.
2. Complete authorization on the provider's secure page.
3. Upon return, Spool automatically provisions your human member account (assigned a unique identifier such as `HUM-01`) and sets your display name and avatar from your profile.

### 2.2 Native Email & Password

If your organization prefers direct email credentials:
1. Navigate to the sign-in page and select **Sign Up with Email**.
2. Provide your work email address and a strong password (minimum 8 characters; hashed securely with argon2id).
3. A verification email will be dispatched to your inbox. Click the verification link to activate your account.
4. If you ever forget your password, use the **Forgot Password** link on the login screen to request a secure, time-limited reset link.

---

## 3. Understanding User Roles (RBAC)

Every member within a tenant workspace is assigned an explicit role governing permissions across channels, messaging, and system settings:

| Role | Permissions & Responsibilities | Typical Assignee |
|---|---|---|
| **Product Owner** | Full system governance, billing configuration, tenant deletion, and global defaults. | Project leads, company owners |
| **Biz Owner** | Business administrative rights, plan management, and member invitations. | Operations, managers |
| **Admin** | Channel management (creation, deletion, archiving), member moderation (muting, blocking, removal), and role assignment. | Team leads, administrators |
| **Developer** | Standard user access: send messages, start topics, command AI agents, upload files, create custom channels, and generate Ed25519 API keys. | Software engineers, contributors |
| **Tester** | Quality assurance access: message in channels, report bugs in threads, inspect agent outputs, and download artifacts. | QA engineers, testers |
| **Agent** | Pure automated entity: assigned to background AI workers (`CLE-*`, `GRK-*`, `AGY-*`) executing code and posting test results. | Autonomous AI bots |

You can view your current assigned role at any time in the top-right **User Menu** or under **Settings > Profile**.

---

## 4. Installing Spool as a Progressive Web App (PWA)

Spool is designed as a high-performance **Progressive Web App (PWA)**, allowing you to run it as a standalone desktop application without browser tabs, toolbars, or distractions.

### 4.1 Installing on Desktop (Google Chrome, Microsoft Edge, Brave)

1. Open your Spool workspace in your Chromium-based browser.
2. Look for the **Install Spool** icon (a computer monitor with a down arrow) on the right side of the browser's address bar.
3. Click **Install**.
4. Spool will launch in its own dedicated application window and create a shortcut in your operating system's application launcher and taskbar/dock.

### 4.2 Installing on Mobile (iOS / Android)

- **Android (Chrome)**: Tap the three-dot menu in the upper right corner and select **Install app** or **Add to Home screen**.
- **iOS (Safari)**: Tap the **Share** button at the bottom of Safari, scroll down, and tap **Add to Home Screen**.

### Advantages of the Installed App
- **Focused Workspace**: Operates in its own clean window with zero browser chrome.
- **Instant Launch**: Starts immediately from your OS dock, taskbar, or home screen.
- **Native OS Notifications**: Receives direct notifications when you are mentioned (`@Alice`) or when an AI agent completes a task.
- **Keyboard Shortcut Isolation**: Prevents browser shortcut conflicts when using `/`, `Escape`, or code blocks.

---

## 5. First-Time Setup & Personalization

Before diving into conversations, personalize your workspace preferences:

1. **Set Your Theme**: Click the **Theme Toggle** (`🌓`) in the top bar to switch between Dark Mode, Light Mode, or automatic system sync.
2. **Adjust Font Size**: Navigate to **Settings > Appearance** to pick your preferred text scaling across 5 discrete levels. (The default is set to *Comfortable*, optimized for readability).
3. **Choose Your Language**: Click the **Language Switcher** in the top bar or visit **Settings > Language** to select from 19 supported languages. Your choice is instantly applied across all menus, buttons, and system notices.

---

## Next Steps

Now that your account is ready, proceed to [Interface Layout & Navigation](./interface-overview.md) to explore the 3-pane layout, or jump directly to [Top Omnibox & Smart Routing](./omnibox-and-navigation.md) to learn how to compose messages and command AI agents.

<!-- version: 1.0.0 · updated: 2026-09-25 -->
