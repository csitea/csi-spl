# 087 on a phone, Back is always one level, and the app reopens where you left off: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes. 043's rule holds: only `useMobileStack` / `utils/mobile-stack.mjs` write stack history.

---

### Phase 0: Specification
- [x] T001 **spec** (c-246): `spec.md` and this file.

### Phase 1: The Back gate, then the `/login` fix (FR-001, FR-002)
- [ ] T002 **Back matrix e2e** : new `tests/e2e/phone-back-matrix.test.mjs`: the spec §3.2 matrix (entries x methods x 360/390), printing every cell; the resumed-place entry is added by T004. It must fail on today's build only on the `/login` cells (spec §2 row 2), which is its control. Owns: that file and a helper in `tests/e2e/lib/` if needed. Done: runs in CI (not in `ci-skip.txt`), red only where the spec says.
- [ ] T003 **no sign-in page on Back** : when a popstate lands on the login route with a signed-in session, `useMobileStack` replaces the entry with the front door and calls `history.back()` once more, before the login page paints (a capture-phase popstate check, beside `onPopCapture`); a pure `isStaleLoginStep(path, sessionState)` in `src/utils/mobile-stack.mjs` with unit cases. Owns: those two functions, `tests/unit/mobile-stack.test.mjs` cases. Done: T002 all green, AC1, plus `mobile-back-stuck`, `mobile-overlay`, `login*` e2e green.

### Phase 2: Reopen where you left off (FR-003..FR-007)
- [ ] T004 **last place** : pure `src/utils/last-place.mjs` (`placeOfRoute`, `loadLastPlace(store, humanId, now)` with the 12 h window, `saveLastPlace`, `clearLastPlace`) over `src/utils/prefs.mjs` (`spool.lastPlace`); `useMobileStack.install()` saves on every level-2/3 change and on `pagehide`, and on a cold start at bare `/` (no query, hash, `/m/`, pending notify open) restores: `router.replace` to level 2, then the level-3 push with `push()`'s tags, then the scroll anchor through `useScrollAnchor`. `logout()` in `src/stores/session.ts` calls `clearLastPlace`. Owns: `src/utils/last-place.mjs`, `tests/unit/last-place.test.mjs`, the restore block in `src/composables/useMobileStack.ts` `install()`, one line in `logout()`. New e2e `tests/e2e/phone-resume.test.mjs` (AC3-AC6) and the resumed-place row added to `phone-back-matrix`. Depends on T003 (same composable). Done: the checks above, AC7.
- [ ] T005 **help** : `csi-spl-doc/doc/help/interface-overview.md` §8: the phone reopens where you left off (12 h), alerts and links win, the section chooser starts fresh; then `node src/node/help/sync-help.mjs`, `src/public/help-md/interface-overview.md` in its own commit. Done: `do_check_dist_hygiene`, `lint-mdlinks` green.

### Phase 3: The real gesture
- [ ] T006 **real phone** : iPhone (Safari, installed to the Home Screen) and Android (Chrome, installed): the AC2 tap path walked with the OS gesture (edge swipe / system Back), plus AC1 and AC3 by hand. Record device, OS, build version and every cell in this file; a failing cell becomes a bug task here. Done: the rows are here.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T01:00:00Z -->
