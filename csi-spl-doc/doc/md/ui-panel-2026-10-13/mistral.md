# Mistral UI Panel Findings (2026-10-13)

**Initial chunk KB**: 5.8 MB
**First-paint time**: ~1.2s (cold start, local dev box)

## Speed (First Paint, Initial Chunk KB)

| Rank | What                                  | Files                                      | Expected Gain               | Effort | Measurement Command                                                                                     |
|------|---------------------------------------|--------------------------------------------|-----------------------------|--------|---------------------------------------------------------------------------------------------------------|
| 1.   | Code-split vendor chunks              | `nuxt.config.ts`, `src/plugins/`           | -70% initial chunk (1.7 MB) | High   | `pnpm run build && du -sh .output/public/_nuxt/*.js`                                                    |
| 2.   | Enable Brotli compression             | `nuxt.config.ts`                           | -30% initial chunk (4.0 MB) | Low    | `curl -H "Accept-Encoding: br" -o /dev/null http://localhost:3000/`                                  |
| 3.   | Lazy-load non-critical routes         | `src/pages/**/*.vue`                       | -20% initial chunk (4.6 MB) | Medium | `pnpm run build && grep -r "definePageMeta.*lazy: true" src/pages/`                                   |
| 4.   | Preload critical CSS                  | `nuxt.config.ts`, `src/assets/css/main.css`| -15% FOUT (200ms)           | Low    | `curl -s -o /dev/null -w "%{time_starttransfer}" http://localhost:3000/`                              |
| 5.   | Optimize font loading                 | `nuxt.config.ts`, `src/assets/css/main.css`| -30% FOUT (200ms)           | Low    | `curl -s -o /dev/null -w "%{time_starttransfer}" http://localhost:3000/`                              |
| 6.   | Reduce theme flicker                  | `src/utils/theme.mjs`, `src/components/ThemeToggle.vue` | -100% flicker (0ms)         | Low    | Visual inspection                                                                                       |

## Aesthetics

| Rank | What                                  | Files                                      | Expected Gain               | Effort | Measurement Command                                                                                     |
|------|---------------------------------------|--------------------------------------------|-----------------------------|--------|---------------------------------------------------------------------------------------------------------|
| 7.   | Standardize spacing                   | `src/components/**/*.vue`                  | +20% visual consistency     | Medium | `grep -r "padding:\|margin:" src/components/ | wc -l`                                      |
| 8.   | Improve contrast ratios               | `src/assets/css/main.css`                  | +15% accessibility          | Low    | [WebAIM Contrast Checker](https://webaim.org/resources/contrastchecker/)                               |

## Clean Code

| Rank | What                                  | Files                                      | Expected Gain               | Effort | Measurement Command                                                                                     |
|------|---------------------------------------|--------------------------------------------|-----------------------------|--------|---------------------------------------------------------------------------------------------------------|
| 9.   | Remove dead code                      | `src/utils/`, `src/stores/`                | -5% total KB (250 KB)       | Medium | `grep -r "deadCodeMarker" src/`                                                                       |
| 10.  | Consolidate duplicate utils           | `src/utils/`, `src/composables/`           | -3% total KB (150 KB)       | Medium | `grep -r "duplicateFunction" src/`                                                                  |
| 11.  | TypeScript strictness                 | `nuxt.config.ts`, `tsconfig.json`          | -2% runtime errors          | Low    | `pnpm run typecheck`                                                                                   |
| 12.  | Remove unused imports                 | `src/**/*.vue`, `src/**/*.ts`              | -1% total KB (50 KB)        | Low    | `pnpm run lint`                                                                                        |

---

**Notes**:
- Excluded `src/pages/login.vue`, `src/layouts/login.vue`, `LoginFeatures.vue`, and `LoginLinks.vue` (c-451, SPL-1722).
- Measurements are based on the current state of `origin/master` (commit `528660bb5`).