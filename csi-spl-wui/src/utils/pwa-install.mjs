/**
 * The install step of this origin's web app (t1 HUM-10, msg 44200ea2, owner
 * pick C+ msg 19bde28c): Settings -> Appearance -> "Apps on this phone".
 *
 * Chrome fires `beforeinstallprompt` once, soon after the manifest is linked
 * (plugins/pwa.client.ts, after onNuxtReady), usually before anyone opens
 * Settings. So the plugin calls capturePwaInstall(window) at boot and the
 * event waits here until the Install button calls promptPwaInstall().
 * Safari and Firefox never fire it: `canPrompt` stays false and the row shows
 * the manual "Add to Home Screen" step instead of a dead button.
 *
 * Framework-free and small: it is in the initial chunk with the plugin.
 */

/** @typedef {{ canPrompt: boolean, installed: boolean }} PwaInstallState */

/** @type {{ prompt: () => Promise<void>, userChoice?: Promise<{ outcome?: string }> } | null} */
let held = null
let installed = false
/** @type {Set<(s: PwaInstallState) => void>} */
const subs = new Set()

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
  return { canPrompt: Boolean(held) && !installed, installed }
}

function emit() {
  const s = pwaInstallState()
  for (const fn of subs) fn(s)
}

/** Calls fn on every change; returns the unsubscribe. */
export function onPwaInstallChange(fn) {
  subs.add(fn)
  return () => { subs.delete(fn) }
}

/** Keeps the browser's install event for the Install button (once per window). */
export function capturePwaInstall(win) {
  if (!win || win.__spoolPwaInstall) return
  win.__spoolPwaInstall = true
  installed = isStandalone(win)
  win.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault()
    held = e
    emit()
  })
  win.addEventListener('appinstalled', () => {
    held = null
    installed = true
    emit()
  })
}

/**
 * Shows the browser's install dialog. The event is single-use: it is dropped
 * either way, and Chrome fires a fresh one later if the person declined.
 * @returns {Promise<string>} 'accepted' | 'dismissed' | '' (nothing to prompt)
 */
export async function promptPwaInstall() {
  const e = held
  if (!e || installed) return ''
  held = null
  let outcome = ''
  try {
    await e.prompt()
    const choice = e.userChoice ? await e.userChoice : null
    outcome = String((choice && choice.outcome) || '')
  } catch { /* the browser refused: the manual step shows */ }
  if (outcome === 'accepted') installed = true
  emit()
  return outcome
}
