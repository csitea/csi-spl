# 087 on a phone, Back is always one level, and the app reopens where you left off: tasks

Authority for what is built (`spec.md` holds the behaviour). Each task names the files it owns and its done check. Status vocabulary: `../README.md` §2.3. Paths are under `csi-spl-wui/` unless they start with `csi-spl-doc/`.

Every WUI task is done only when, from `csi-spl-wui/`: `pnpm run test:unit`, `pnpm run typecheck`, its named e2e green against a generated mock bundle (`BASE_URL=<bundle> pnpm run test:e2e <names>`), and `cd ../csi-spl-iac && ./run -a do_check_pre_push` passes. 043's rule holds: only `useMobileStack` / `utils/mobile-stack.mjs` write stack history.

---

### Phase 0: Specification
- [x] T001 **spec** (c-246): `spec.md` and this file.

### Phase 1: The Back gate, then the `/login` fix (FR-001, FR-002)
- [x] T002 **Back matrix e2e** (c-283): new `tests/e2e/phone-back-matrix.test.mjs`: the spec §3.2 matrix (6 entries x 6 methods x 360/390 = 72 cells, one fresh tab each), printing every cell; the resumed-place entry is added by T004. Red today by design, behind its in-file `KNOWN_RED` (a known-red cell that passes fails the run, so the fixing task removes its lines): the 12 `login` cells (T003) and the 16 deep-link browser-Back cells (T007). Measured on origin/master `ddc59252`, mock bundle: 44 green, 28 known red, 0 other; full matrix n = 1, the browser-Back cells n = 3, 3/3 identical. Runs in CI (not in `ci-skip.txt`).
- [ ] T003 **no sign-in page on Back** : when a popstate lands on the login route with a signed-in session, `useMobileStack` replaces the entry with the front door and calls `history.back()` once more, before the login page paints (a capture-phase popstate check, beside `onPopCapture`); a pure `isStaleLoginStep(path, sessionState)` in `src/utils/mobile-stack.mjs` with unit cases. Owns: those two functions, `tests/unit/mobile-stack.test.mjs` cases. Done: T002 all green, AC1, plus `mobile-back-stuck`, `mobile-overlay`, `login*` e2e green.
- [ ] T007 **browser Back from a deep link** (unassigned; Owns: left for the lane that takes it): browser Back (and the OS gesture) on a deep-link entry skips levels or leaves the app. Measured by T002, origin/master `ddc59252`, mock bundle, n = 3 per cell, 3/3 identical; the 16 cells, each at 360 and at 390, in the `browser` and `sheet` columns (the sheet column walks with browser Back): fresh tab at `?topic=` 3 -> out; fresh tab at `/channel/lobby` 2 -> out; `/` then the `?topic=` link 3 -> 1 (back to the `/` document); `/m/<msg_id>` 3 -> 2 -> out. Cause, **unchecked** in code: a deep link builds no history entries under itself, so the in-app Backs step down in place (`pop()`) while browser Back just leaves. T004 depends on T007 (the restore needs the same level entries). Done: those cells green in `phone-back-matrix`, their `KNOWN_RED` lines removed in the same commit.

### Phase 2: Reopen where you left off (FR-003..FR-007)
- [ ] T004 **last place** : pure `src/utils/last-place.mjs` (`placeOfRoute`, `loadLastPlace(store, humanId, now)` with the 12 h window, `saveLastPlace`, `clearLastPlace`) over `src/utils/prefs.mjs` (`spool.lastPlace`); `useMobileStack.install()` saves on every level-2/3 change and on `pagehide`, and on a cold start at bare `/` (no query, hash, `/m/`, pending notify open) restores: `router.replace` to level 2, then the level-3 push with `push()`'s tags, then the scroll anchor through `useScrollAnchor`. `logout()` in `src/stores/session.ts` calls `clearLastPlace`. Owns: `src/utils/last-place.mjs`, `tests/unit/last-place.test.mjs`, the restore block in `src/composables/useMobileStack.ts` `install()`, one line in `logout()`. New e2e `tests/e2e/phone-resume.test.mjs` (AC3-AC6) and the resumed-place row added to `phone-back-matrix`. Depends on T003 (same composable) and T007 (the same level entries). Done: the checks above, AC7.
- [ ] T005 **help** : `csi-spl-doc/doc/help/interface-overview.md` §8: the phone reopens where you left off (12 h), alerts and links win, the section chooser starts fresh; then `node src/node/help/sync-help.mjs`, `src/public/help-md/interface-overview.md` in its own commit. Done: `do_check_dist_hygiene`, `lint-mdlinks` green.

### Phase 3: The real gesture
- [ ] T006 **real phone** : iPhone (Safari, installed to the Home Screen) and Android (Chrome, installed): the AC2 tap path walked with the OS gesture (edge swipe / system Back), plus AC1 and AC3 by hand. Record device, OS, build version and every cell in this file; a failing cell becomes a bug task here. Done: the rows are here.

<!-- version: 0.1.0 · updated: 2026-10-05 · last-edit: 2026-10-05T01:00:00Z -->
