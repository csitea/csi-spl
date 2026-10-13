# UI Panel: Mistral Seat (SPL-1727)

## Baseline Measurements
- **Initial chunk KB**: 300 KB (largest chunk), 5073 KB (total uncompressed JS).
- **First-paint time**: ~1.2s (simulated cold start, 3G network).

---

## Top 12 Lowest-Hanging Fixes

### Speed (First Paint, Initial Chunk KB)
| Rank | What | Files | Expected Gain | Effort | Measurement Command |
|---|---|---|---|---|---|
| 1 | Preload critical chunks | `nuxt.config.ts`, `src/utils/first-screen-hints.mjs` | -30% first-paint (300ms) | Low | `curl -s -o /dev/null -w "%{time_starttransfer}" http://localhost:3000/` |
| 2 | Enable Brotli compression | `firebase.json`, `nuxt.config.ts` | -20% initial KB (60 KB) | Low | `curl -H "Accept-Encoding: br" -s -o /dev/null -w "%{size_download}" http://localhost:3000/_nuxt/DqCMsh09.js` |
| 3 | Lazy-load non-critical locales | `nuxt.config.ts`, `src/utils/i18n-plain-messages.mjs` | -15% initial KB (45 KB) | Low | `ls -la .output/public/_nuxt/*.js \| grep -E 'vendor-i18n'` |
| 4 | Defer non-critical CSS | `nuxt.config.ts`, `src/layouts/default.vue` | -10% first-paint (100ms) | Low | Lighthouse audit |
| 5 | Split vendor chunks further | `nuxt.config.ts`, `src/utils/vendor-chunks.mjs` | -10% initial KB (30 KB) | Medium | `ls -la .output/public/_nuxt/ \| grep -E 'vendor-.*\\.js'` |

---

### Aesthetics
| Rank | What | Files | Expected Gain | Effort | Measurement Command |
|---|---|---|---|---|---|
| 6 | Reduce layout shift on mobile | `src/layouts/default.vue`, `src/components/TopBar.vue` | -50% CLS (0.2 → 0.1) | Low | Lighthouse audit |
| 7 | Optimize font loading | `nuxt.config.ts`, `src/assets/css/main.css` | -30% FOUT (200ms) | Low | `curl -s -o /dev/null -w "%{time_starttransfer}" http://localhost:3000/` |
| 8 | Reduce theme flicker | `src/utils/theme.mjs`, `src/components/ThemeToggle.vue` | -100% flicker (0ms) | Low | Visual inspection |

---

### Clean Code
| Rank | What | Files | Expected Gain | Effort | Measurement Command |
|---|---|---|---|---|---|
| 9 | Remove dead code | `src/utils/`, `src/stores/` | -5% total KB (250 KB) | Medium | `grep -r "deadCodeMarker" src/` |
| 10 | Consolidate duplicate utils | `src/utils/`, `src/composables/` | -3% total KB (150 KB) | Medium | `grep -r "duplicateFunction" src/` |
| 11 | TypeScript strictness | `nuxt.config.ts`, `tsconfig.json` | -2% runtime errors | Low | `pnpm run typecheck` |
| 12 | Remove unused imports | `src/**/*.vue`, `src/**/*.ts` | -1% total KB (50 KB) | Low | `pnpm run lint` |