// How long the app may wait for the second i18n catalogue (P3-06,
// src/plugins/i18n-more.client.ts) before it boots or resolves a route anyway.
//
// A cold load of a page outside the first screen (/issues, /people, ...)
// awaited that chunk BEFORE the app mounted, with no bound. On 2026-10-12
// 16:55:12Z a cold load of a workspace's /issues, 17 s after a WUI
// deploy, showed only the shell for 33 s: the hub saw one GET
// /api/v1/auth/session and nothing else. Holding that one chunk (n=2, prd
// 7.2.3) gave the same page; /lobby, a first-screen route, booted.
// A failed chunk was already handled (keys show, the load is retried); a slow
// or stuck one is now handled too: past the bound the page renders, and the
// catalogue merges whenever it lands (vue-i18n re-renders the keys as text).

/** Boot and route waits for the second catalogue, in ms. */
export const MORE_WAIT_MS = 4000

/**
 * Resolves true when `p` settles (fulfilled or rejected) within `ms`, false
 * once `ms` passed first. Never rejects; `p` keeps running either way.
 * @param {Promise<unknown>} p
 * @param {number} [ms]
 * @param {{ set?: typeof setTimeout, clear?: typeof clearTimeout }} [timers]
 * @returns {Promise<boolean>}
 */
export function boundedWait(p, ms = MORE_WAIT_MS, { set = setTimeout, clear = clearTimeout } = {}) {
  return new Promise((resolve) => {
    let done = false
    const timer = set(() => {
      if (done) return
      done = true
      resolve(false)
    }, ms)
    const settle = () => {
      if (done) return
      done = true
      clear(timer)
      resolve(true)
    }
    Promise.resolve(p).then(settle, settle)
  })
}
