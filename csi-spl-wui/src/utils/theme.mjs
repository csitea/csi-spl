/** Theme persist + mapping. Default is dark; no prefers-color-scheme
 *  (the app has never followed the system setting — keep that).
 *  CLE-34994: five themes, chosen from the palette picker (ThemeToggle.vue).
 *  Storage is try/catch via prefs.mjs (private mode).
 */
import { storageGet, storageSet } from './prefs.mjs'

export const THEME_KEY = 'spool-theme'
export const THEME_DEFAULT = 'dark'

/** @typedef {'dark' | 'light' | 'light-violet' | 'light-green' | 'light-yellow' | 'light-orange' | 'light-red'} SpoolTheme */

/** CLE-34994: the palette picker's options, dark to light, in menu order.
 *  `swatch` is the theme's own --color-bg / --color-accent pair, so each
 *  option previews its theme whatever theme is active. */
export const THEMES = [
  { id: 'dark', labelKey: 'theme.dark', swatch: ['#060912', '#34d5f0'] },
  { id: 'light', labelKey: 'theme.light', swatch: ['#eaf1fb', '#0a97c4'] },
  { id: 'light-violet', labelKey: 'theme.light_violet', swatch: ['#f1ecfb', '#6a3fd0'] },
  { id: 'light-green', labelKey: 'theme.light_green', swatch: ['#eaf5ee', '#16733f'] },
  { id: 'light-yellow', labelKey: 'theme.light_yellow', swatch: ['#fbf6e3', '#855400'] },
  { id: 'light-orange', labelKey: 'theme.light_orange', swatch: ['#fbf3ea', '#a34b00'] },
  { id: 'light-red', labelKey: 'theme.light_red', swatch: ['#fbeeee', '#9a3d58'] },
]

export const THEME_IDS = THEMES.map((t) => t.id)

export function parseTheme(raw, fallback = THEME_DEFAULT) {
  return THEME_IDS.includes(raw) ? raw : fallback
}

/** i18n key of a theme's name (the picker's option text). */
export function labelKeyForTheme(theme) {
  const id = parseTheme(theme)
  return THEMES.find((t) => t.id === id).labelKey
}

/** Index of a theme in THEMES (the listbox's active option). */
export function themeIndex(theme) {
  return THEME_IDS.indexOf(parseTheme(theme))
}

export function readStoredTheme(store, fallback = THEME_DEFAULT) {
  return parseTheme(storageGet(THEME_KEY, null, store), fallback)
}

export function writeStoredTheme(theme, store) {
  return storageSet(THEME_KEY, parseTheme(theme), store)
}

export function applyThemeAttr(theme, el) {
  const t = parseTheme(theme)
  if (el && typeof el.setAttribute === 'function') el.setAttribute('data-theme', t)
  return t
}

/**
 * CLE-34994: keep a palette pick on the account too (PUT preferences
 * preferred_theme), so the operator default and the person's own choice are
 * one field and a new device starts from it. Only for a signed-in member
 * (claims.hum), and not when the account already says so. A failed save is
 * silent: this browser keeps the pick in localStorage either way.
 * io: { claims, save(theme) -> Promise<{ ok }>, apply(theme) }.
 * Resolves true when the account was written.
 */
export async function saveThemeToAccount(theme, io) {
  const id = parseTheme(theme, '')
  const c = io && io.claims
  if (!id || !c || typeof c.hum !== 'string' || !c.hum || c.preferred_theme === id) return false
  try {
    const res = await io.save(id)
    if (!res || !res.ok) return false
    io.apply(id)
    return true
  } catch {
    return false
  }
}
