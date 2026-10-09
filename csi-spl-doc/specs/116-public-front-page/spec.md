# 116 Public front page: a signed-out visitor's first look

**Feature ID**: 116-public-front-page · **Milestone**: M3 · **Status**: v0.1 (draft for owner review)
**Created**: 2026-10-09 · **Drafter**: m-682 · **Topic**: t1 2242b163-053f-4460-97c7-c35adef3ab24 · lane dispatch dispatch-2242b163
**Authority**: this file for behaviour; no code or cnf is changed in this spec. Every FR below is **Planned**.

---

## 0. The owner's ask (verbatim, HUM-10, t1 2242b163-053f-4460-97c7-c35adef3ab24, 2026-10-09 14:03-14:05Z)

| msg | text |
|---|---|
| 1 | total refactor of the front page |
| 2 | the front page HAS TO BE COOL |
| 3 | it has to provide pretty shortly as description on WHAT this is |
| 4 | and than links for futher reading what is it |

| 5 | yes before signing ... the forms for the logging in should be smaller, it should be more visual and there should be a textual description - one slogan and no more than 3 sentences what this is |
**Reading**: The page a visitor sees at the apex host (spool-hub.ai) **before signing in**. The sign-in form is **on this page** (not a separate click away) and **smaller**. The page is **mainly visual**, with **one slogan + ≤3 sentences** for the "what is this" text.
| 7 | we need mutiple posts, and those shoud be linked to the landing page |
| 5 | yes before signing ... the forms for the logging in should be smaller, it should be more visual and there should be a textual description - one slogan and no more than 3 sentences what this is || 6 | and it should be flashy, but style |
| 5 | yes before signing ... the forms for the logging in should be smaller, it should be more visual and there should be a textual description - one slogan and no more than 3 sentences what this is || 6 | and it should be flashy, but style |
| 5 | yes before signing ... the forms for the logging in should be smaller, it should be more visual and there should be a textual description - one slogan and no more than 3 sentences what this is || 6 | and it should be flashy, but style |
**Reading**: The page a visitor sees at the apex host (spool-hub.ai) before signing in. Today, a signed-out visitor at / is sent to /login (isProductScreen in csi-spl-wui/src/utils/signed-out-redirect.mjs), so there is no front page at all.
> The spool is the secure relay that moves encrypted files between teams and their devices. It powers git-rel, the signed-URL relay for Git repositories, and provides the infrastructure for decentralized collaboration.

## 2. The short "what is this" text

**Slogan candidates** (pick one):
1. *Where teams and AI agents work together*
2. *Channels, topics, and secure collaboration*
3. *Your workspace, in the browser and terminal*

**Text candidates** (≤3 sentences, pick one):
1. The spool is the workspace where teams and AI agents collaborate in channels and topics. Sign in to join a workspace, post messages, and share files—all from your browser or terminal. Every workspace is private, and every action is secure.
2. The spool powers team collaboration: channels for discussions, topics for threads, and secure file sharing. Sign in to join a workspace and start working—from your browser or terminal. Everything is private and encrypted.
3. The spool is the secure workspace for teams and AI agents. Sign in to join a workspace, post in channels, and share files—all from your browser or terminal. Every workspace is private, and every action is secure.

*(Marked as a draft for the owner’s review; agy has the final word on the 19 locales.)*

>
| **Public GitHub repo** | Yes | Spec 044: . |

## 3. Links for further reading

What exists today and is reachable signed-out:

| Link | Reachable signed-out? | Notes |
|---|---|---|
| **Help pages** (/help) | Yes | Static markdown under `csi-spl-wui/src/public/help-md/`. |
| **Blog** (/blog) | Yes | Spec 111: indexable, no app scripts. **Features area**: Links to blog posts (e.g., "How the spool works", "Secure collaboration in channels"). Built from the blog index at generate time. |
| **Release notes** (/releases) | Yes | No content today; not linked. |
| **Public GitHub repo** | Yes | Spec 044: `github.com/csitea/csi-spl`. |
| **Docs section** (/docs) | No | Redirects to /login (signed-out-redirect.mjs:60). |

**Features area** (built from the blog index at generate time):
- How the spool works
- Secure collaboration in channels
- AI agents in your workspace


## 5. Constraints

- **JS budget**: 160 KB ceiling (spec 027 `ci_initial_gzip_kb`). Citation: `csi-spl-doc/specs/027-spool-performance/contracts/perf-budgets.json:12`.
- **Noindex**: Override the default `noindex, nofollow` for / only. Citation: `render-wui-firebase-json.sh:120` (X-Robots-Tag), `nuxt.config.ts:200` (meta robots).
- **No hub API call**: No /v1/* call from a signed-out visitor’s browser. Citation: `signed-out-redirect.mjs:80` (isProductScreen).
- **i18n**: The text is in 19 locales; agy has the final word (language rule).
- **Login link**: Stays one click away (top-right or floating button).
- **Login form sizing**: The sign-in form is **on the front page** (not a separate click away) and **smaller** (max-width 400px, compact layout). Citation: `pages/login.vue:20` (login-landing-card).


## 4. "COOL": Three visual directions

All directions keep the existing theme tokens, light/dark modes, and the 160 KB JS budget. Each is a few lines; the build step will render mock pages with screenshots.

### Direction 1: Hero + Minimalist Links
- **Hero**: Full-width background image (relay visual), overlaid with the slogan in large, bold typography.
- **Links**: Three large cards below the hero, each linking to "/help", "/blog", and the GitHub repo.
- **Features area**: Horizontal row of blog post links (e.g., "How the spool works", "Secure collaboration in channels") below the links.
- **Login form**: Small card in the top-right corner (max-width 400px).
- **Flashy**: Animated gradient overlay on the hero image; hero image has a slow parallax effect.
- **Stylish**: Clean typography, no clutter, respects "prefers-reduced-motion".

### Direction 2: Interactive Terminal
- **Terminal**: A mock terminal window in the centre, showing a "git-rel" command in progress (e.g., "git rel send --to box1").
- **Slogan**: Above the terminal, in monospace font.
- **Links**: Small, monospace-style links below the terminal.
- **Features area**: Terminal-style list of blog post links (e.g., "$ cat how-it-works.md") below the links.
- **Login form**: Compact form in the bottom-right corner (max-width 400px).
- **Flashy**: Terminal cursor blinks; typing the command triggers a simulated transfer animation.
- **Stylish**: Limited colour palette, no distractions, motion off under "prefers-reduced-motion".

### Direction 3: Card Grid + Dark/Light Toggle
- **Grid**: A 2x2 grid of cards, each with an icon and a one-line description:
  - Channels (speech bubble icon)
  - Topics (thread icon)
  - AI agents (robot icon)
  - Terminal (prompt icon)
- **Slogan**: Above the grid, in large typography.
- **Links**: Small and centred below the grid.
- **Features area**: Grid of blog post cards (matching the style) below the links.
- **Login form**: Floating card in the bottom-right corner (max-width 400px).
- **Flashy**: Animated hover effects on cards; vibrant accent colours.
- **Stylish**: Consistent spacing, no clutter, respects "prefers-reduced-motion".

## 5. Constraints

- **JS budget**: 160 KB ceiling (spec 027 ci_initial_gzip_kb); load new things lazily.
- **Noindex**: Override the default noindex, nofollow for / only (render-wui-firebase-json.sh and nuxt.config.ts).
4. **Redirect logic**: Remove / from isProductScreen in signed-out-redirect.mjs.

## 7. Open questions for the owner

| Question | Options | Recommendation |
|---|---|---|
| **Visual direction** | Hero + Links, Interactive Terminal, Card Grid | Card Grid: balances clarity and "COOL" with minimal JS. |
| **Slogan** | Where teams and AI agents work together, Channels/topics/secure collaboration, Your workspace/in the browser and terminal | *Channels, topics, and secure collaboration*: concise and product-focused. |
| **Text** | Candidate 1, 2, or 3 | Candidate 2: clear and actionable. |

5. **SEO override**: Add / to the indexable paths in render-wui-firebase-json.sh and nuxt.config.ts.
6. **JS budget**: Lazy-load non-critical assets (e.g., animations).
7. **Visual build**: Render the chosen direction as a mock page with screenshots.
8. **Deploy**: Land on dev, then prd.

---

## 7. Open questions for the owner

| Question | Options | Recommendation |
|---|---|---|
| **Visual direction** | Hero + Links, Interactive Terminal, Card Grid | Card Grid: balances clarity and COOL with minimal JS. |
| **Login link placement** | Top-right, floating button, or inline | Floating button: less visual noise, always accessible. |
| **Background image** | Abstract network, relay visual, or none | Relay visual: reinforces the product name. |

---

## 8. Panel

| Reviewer | Role | Status | Notes |
|---|---|---|---|
|  |  |  |  |
|  |  |  |  |
|  |  |  |  |
