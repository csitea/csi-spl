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

**Reading**: The page a visitor sees at the apex host (spool-hub.ai) before signing in. Today, a signed-out visitor at / is sent to /login (isProductScreen in csi-spl-wui/src/utils/signed-out-redirect.mjs), so there is no front page at all.

---

## 1. What / serves today

- **Signed-out visitor**: Redirected to /login (exempt screens: /login, /reset-password, /verify-email, /checkout).
- **Signed-in visitor**: Served the home page (pages/index.vue), as specified in spec 109 T003–T008.
- **No public front page**: The apex host (spool-hub.ai) today shows a signed-out redirect to /login, so no content is served at /.

---

## 2. The short what is this text

Draft (grounded in csi-spl-doc/doc/md/csi-spl.feature.md and the help pages):

> **What is the spool?**
> The spool is the secure relay that moves encrypted files between teams and their devices. It powers git-rel, the signed-URL relay for Git repositories, and provides the infrastructure for decentralized collaboration.
>
> **What does it do?**
> It replaces centralized hubs with a peer-to-peer model: every team runs its own relay, and files move directly between devices without a single point of control. All transfers are end-to-end encrypted, and every URL is signed and time-limited.

*(Marked as a draft for the owner's review; agy has the final word on the 19 locales.)*

---

## 3. Links for further reading

What exists today and is reachable signed-out:

| Link | Reachable signed-out? | Notes |
|---|---|---|
| **Help pages** (/help) | Yes | Static markdown under csi-spl-wui/src/public/help-md/. |
| **Docs section** (/docs) | Yes | Spec 075: static pages, indexable. |
| **Blog** (/blog) | Yes | Spec 111: indexable, no app scripts. |
| **Release notes** (/releases) | No | Redirects to /login. |
| **Public GitHub repo** | Yes | Spec 044: github.com/csitea/csi-spl. |

---

## 4. COOL: Three visual directions

All directions keep the existing theme tokens, light/dark modes, and the 160 KB JS budget. Each is a few lines; the build step will render mock pages with screenshots.

### Direction 1: Hero + Minimalist Links
- **Hero**: Full-width background image (e.g., abstract network or relay visual), overlaid with the what is this text in large, bold typography.
- **Links**: Three large cards below the hero, each linking to /help, /docs, and /blog. No navigation bar; the login link is a small button in the top-right corner.
- **Animation**: Subtle fade-in on load; the hero image has a slow parallax effect.

### Direction 2: Interactive Terminal
- **Terminal**: A mock terminal window in the centre, showing a git-rel command in progress (e.g., git rel send --to box1). The what is this text sits above it.
- **Links**: Small, monospace-style links below the terminal, mimicking a CLI help output.
- **Animation**: The terminal cursor blinks; typing the command triggers a simulated transfer animation.

### Direction 3: Card Grid + Dark Mode First
- **Grid**: A 2x2 grid of cards, each with an icon and a one-line description:
  - Secure relay (shield icon)
  - Decentralized (network icon)
  - Encrypted (lock icon)
  - Open source (GitHub icon)
- **Links**: The what is this text sits above the grid; the links are small and centred below.
- **Dark mode**: Defaults to dark; the login link is a floating button in the bottom-right corner.

---

## 5. Constraints

- **JS budget**: 160 KB ceiling (spec 027 ci_initial_gzip_kb); load new things lazily.
- **Noindex**: Override the default noindex, nofollow for / only (render-wui-firebase-json.sh and nuxt.config.ts).
- **No hub API call**: No /v1/* call from a signed-out visitor's browser (spec 111 review item 1).
- **i18n**: The text is in 19 locales; agy has the final word (language rule).
- **Login link**: Stays one click away (top-right or floating button).

---

## 6. Task list outline

1. **Spec consensus**: Owner picks a visual direction (this spec).
2. **i18n draft**: agy reviews the what is this text (lane: /agy-spawn).
3. **Static page**: Add pages/front.vue (or reuse pages/index.vue for signed-out visitors).
4. **Redirect logic**: Remove / from isProductScreen in signed-out-redirect.mjs.
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
