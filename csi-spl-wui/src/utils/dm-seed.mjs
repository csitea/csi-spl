/**
 * spec 109 FR-004: one DM seed read per load. The tab's first
 * `?dm=true&dm_counts=true` read (plugins/spool-live.client.ts) sends this
 * tab's dm_read= cursors. Where the hub read sync's first pull then moves
 * them, the seed was read again with the moved ones: 2 GET /v1/view/topics
 * per cold /lobby, 10 of 10 (spec 109 7.4), and 2 dm=true reads on the first
 * /lobby after a fresh sign-in, 2 of 2 (prd e2e after 1db5fe64b).
 *
 * Loaded on demand with read-sync-boot, never in the initial chunk: the
 * 155 KB initial budget (027) had 0.3 KB left.
 */
import { productPath } from './signed-out-redirect.mjs'

/** How long a held DM seed waits for the first pull before it reads anyway. */
export const SEED_WAIT_MS = 3000

/**
 * The feed pages whose onMounted starts the hub read sync
 * (pages/lobby.vue, pages/dm/[peer].vue, pages/channel/[name].vue).
 * @param {string} path vue-router path
 */
export function readSyncPage(path) {
  const p = productPath(path)
  return p === '/lobby' || p.startsWith('/dm/') || p.startsWith('/channel/')
}

/**
 * The seed waits for the first pull on a page that starts the read sync, and
 * in a browser that holds no dm: read cursor yet (a fresh profile, or the
 * form sign-in on /login, which then goes on to /lobby): there the pull moves
 * the dm: cursors. A stored dm: cursor off the feed pages seeds at once.
 * @param {string} path vue-router path
 * @param {Record<string, unknown>} cursors the stored read cursors (read-cursor.mjs loadCursors)
 */
export function seedWaitsForPull(path, cursors) {
  return readSyncPage(path) || !Object.keys(cursors || {}).some((k) => k.startsWith('dm:'))
}

/**
 * `after(ready, seed)` holds the seed until the first pull answers (or
 * `waitMs` passes), then reads it once, with the moved cursors. A pull that
 * moves dm: cursors while the seed is held calls `moved(seed)`, which does
 * not read: the held seed is still to go out. Once released, `moved` reads.
 */
export function createSeedGate() {
  let held = false
  return {
    async after(ready, seed, waitMs = SEED_WAIT_MS) {
      held = true
      let timer
      try {
        /* a failed pull still releases the seed: it reads with the cursors it has */
        await Promise.race([Promise.resolve(ready).catch(() => {}), new Promise((r) => { timer = setTimeout(r, waitMs) })])
      } finally {
        clearTimeout(timer)
        held = false
      }
      return seed()
    },
    moved(seed) {
      return held ? undefined : seed()
    },
  }
}
