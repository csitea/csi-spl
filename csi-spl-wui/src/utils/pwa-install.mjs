/**
 * The install step of this origin's web app (t1 HUM-10, msg 44200ea2, owner
 * pick C+ msg 19bde28c): Settings -> Appearance -> "Apps on this phone".
 *
 * Chrome fires `beforeinstallprompt` once, soon after the manifest is linked
 * (plugins/pwa.client.ts, after onNuxtReady), usually before anyone opens
 * Settings. So the plugin keeps the event at boot in `window.__spoolPwa`
 * ({ ev, done }) and fires `spool-pwa` on window on every change; this module
 * reads that state and is loaded only with Settings' Appearance chunk, never
 * in the first download (ci_home_gzip_kb).
 * Safari and Firefox never fire it: `canPrompt` stays false and the row shows
 * the manual "Add to Home Screen" step instead of a dead button.
 */

/** @typedef {{ canPrompt: boolean, installed: boolean }} PwaInstallState */

const CHANGED = 'spool-pwa'

/** @returns {{ ev: { prompt: () => Promise<void>, userChoice?: Promise<{ outcome?: string }> } | null, done: boolean }} */
function kept() {
  const w = /** @type {any} */ (window)
  return (w.__spoolPwa ||= { ev: null, done: false })
}

/** True when this page runs as the installed app (a home-screen launch). */
export function isStandalone(win) {
  const w = win || (typeof window === 'undefined' ? null : window)
  if (!w) return false
  try {
    if (w.matchMedia && w.matchMedia('(display-mode: standalone)').matches) return true
  } catch { /* no matchMedia */ }
  return Boolean(w.navigator && w.navigator.standalone)
}

/** @returns {PwaInstallState} */
export function pwaInstallState() {
  const k = kept()
  const installed = k.done || isStandalone(window)
  return { canPrompt: Boolean(k.ev) && !installed, installed }
}

/** Calls fn on every change; returns the unsubscribe. */
export function onPwaInstallChange(fn) {
  const on = () => fn(pwaInstallState())
  window.addEventListener(CHANGED, on)
  return () => { window.removeEventListener(CHANGED, on) }
}

/**
 * Shows the browser's install dialog. The event is single-use: it is dropped
 * either way, and Chrome fires a fresh one later if the person declined.
 * @returns {Promise<string>} 'accepted' | 'dismissed' | '' (nothing to prompt)
 */
export async function promptPwaInstall() {
  const k = kept()
  const e = k.ev
  if (!e || pwaInstallState().installed) return ''
  k.ev = null
  let outcome = ''
  try {
    await e.prompt()
    const choice = e.userChoice ? await e.userChoice : null
    outcome = String((choice && choice.outcome) || '')
  } catch { /* the browser refused: the manual step shows */ }
  if (outcome === 'accepted') k.done = true
  window.dispatchEvent(new Event(CHANGED))
  return outcome
}
