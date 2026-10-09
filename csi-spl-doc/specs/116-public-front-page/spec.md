# 116 Public front page: a signed-out visitor's first view

## Owner words

From HUM-10, t1 topic 2242b163-053f-4460-97c7-c35adef3ab24, 2026-10-09 14:03-14:05Z:
1. "total refactor of the front page"
2. "the front page HAS TO BE COOL"
3. "it has to provide pretty shortly as description on WHAT this is"
4. "and than links for futher reading what is it"

## Goals

### G1: A signed-out visitor sees a front page at `/`
- Today: `/` redirects to `/login` (`isProductScreen` in `signed-out-redirect.mjs`).
- Change: Serve a static front page to signed-out visitors, with no hub API calls.

### G2: "COOL" visual design
- Three distinct directions (see Design), grounded in theme tokens and light/dark mode.
- JS budget: 160 KB ceiling (lazy-load non-critical JS).

### G3: "What is this" text
- 1-3 sentences, plus 2-3 lines on what it does (draft below).
- i18n in 19 locales (agy final review).

### G4: Links for further reading
- Signed-out reachable: `/docs`, `/blog`, `/releases`, GitHub repo.
- Login link: One click away (e.g., top-right button).

### G5: SEO
- Override `noindex` for `/` only (default: `noindex, nofollow` in `render-wui-firebase-json.sh` and `nuxt.config.ts`).

## Design

### D1: Minimalist Hero
- Large hero section with gradient background (theme tokens: `--primary-gradient`).
- Tagline: "Secure file transfer for agents and humans."
- "What is this":
  > The spool is the GCP estate that carries **git-rel**, the relay that moves gpg-encrypted files between the hub and the boxes through one GCS bucket, using signed URLs in both directions.
  > It provides a secure, auditable way to transfer files between environments, with no manual steps.
- CTA button: "Try the demo" (links to `/demo`, spec 077).
- Dark/light mode toggle in the top-right.

### D2: Interactive Showcase
- Animated terminal-style mockup (CSS/JS) showing a git-rel transfer.
- Side-by-side: "Before" (manual file transfer) vs "After" (spool).
- Lazy-loaded JS for animations (160 KB budget).

### D3: Card-Based Layout
- Three cards: "Secure", "Fast", "Simple" (icons + 1-line descriptions).
- Each card links to a `/docs` section (e.g., "How it works").
- Footer: Links to `/blog`, `/releases`, GitHub.

## Constraints

### C1: No signed-out hub API calls
- No `/api/v1/auth` or `/config.json` in prerendered HTML (spec 111 review item 1).
- Citation: `signed-out-redirect.mjs` (`isProductScreen`).

### C2: JS budget
- 160 KB ceiling (home page: 352.1 KB gzip limit).
- Lazy-load non-critical JS (e.g., animations).

### C3: Noindex override
- Override `noindex` for `/` only:
  - `render-wui-firebase-json.sh`: Add `/` to the indexable paths (X-Robots-Tag).
  - `nuxt.config.ts`: Override `<meta name="robots">` for `/`.
- Citation: `render-wui-firebase-json.sh:120`, `nuxt.config.ts:200`.

### C4: i18n
- 19 locales (agy final review).
- Citation: `nuxt.config.ts` (`I18N_LOCALES`).

### C5: Login link
- One click away (e.g., top-right button).

## Tests

### T1: Signed-out visitor sees `/`
- Control: `curl -sI https://spool-hub.ai/` -> 200, no redirect to `/login`.
- Check: `isProductScreen("/")` returns `false` for signed-out visitors.

### T2: No hub API calls
- Control: Prerendered `/index.html` holds no `/api/v1/auth` or `config.json`.
- Check: `grep -c "api/v1/auth\\|config.json" .output/public/index.html` -> 0.

### T3: SEO override
- Control: `curl -sI https://spool-hub.ai/` -> `X-Robots-Tag: index, follow`.
- Check: `<meta name="robots" content="index, follow">` in `/index.html`.

### T4: JS budget
- Control: `du -sb .output/public/_nuxt/*.js` -> total < 160 KB.

### T5: Links for further reading
- Control: `/index.html` holds links to `/docs`, `/blog`, `/releases`, GitHub.
- Check: `grep -c "href=\"/docs\\|href=\"/blog\\|href=\"/releases\\|github.com/csitea/csi-spl" .output/public/index.html` -> 4.

## Tasks

| Task | Owner | Description |
|---|---|---|
| 116-1 | claude | Draft this spec (DONE). |
| 116-2 | mistral | Implement `/` route (new `pages/front.vue`). |
| 116-3 | claude | Override `noindex` for `/` (render + nuxt.config). |
| 116-4 | agy | Review i18n text (19 locales). |
| 116-5 | claude | Add links to `/docs`, `/blog`, `/releases`, GitHub. |
| 116-6 | claude | Lazy-load non-critical JS (160 KB budget). |
| 116-7 | claude | Test: Signed-out visitor sees `/`, no hub API calls, SEO override. |

## Open questions

1. **Visual direction preference**:
   - Options: Minimalist Hero (recommended), Interactive Showcase, Card-Based.
   - Recommendation: Minimalist Hero (fastest to implement, aligns with "COOL").

2. **SEO tradeoff**:
   - Override `noindex` for `/` only, or also for `/blog`?
   - Recommendation: `/` only (keep `/blog` `noindex` until content is curated).

3. **Demo link**:
   - Link "Try the demo" to `/demo` (spec 077) or a new `/get-started` page?
   - Recommendation: `/demo` (existing, LinkedIn auth works).

## Panel

| Reviewer | Role | Status |
|---|---|---|
| c-002 | Dispatch | |
| c-580 | Security | |
| c-581 | Integration | |
| agy | Language | |
