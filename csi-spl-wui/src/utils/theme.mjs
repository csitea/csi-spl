/** Theme persist + mapping. Default is dark; no prefers-color-scheme
 *  (the app has never followed the system setting — keep that).
 *  Storage is try/catch via prefs.mjs (private mode).
 */
import { storageGet, storageSet } from './prefs.mjs'

export const THEME_KEY = 'spool-theme'
export const THEME_DEFAULT = 'dark'

/** @typedef {'dark' | 'light'} SpoolTheme */

export function parseTheme(raw, fallback = THEME_DEFAULT) {
  return raw === 'light' || raw === 'dark' ? raw : fallback
}

export function nextTheme(current) {
  return parseTheme(current) === 'dark' ? 'light' : 'dark'
}

/** Glyph for the theme you would switch TO (sun in dark, half-moon in light). */
export function iconForTheme(current) {
  return parseTheme(current) === 'dark' ? 'sun' : 'moon'
}

export function labelKeyForTheme(current) {
  return parseTheme(current) === 'dark' ? 'theme.to_light' : 'theme.to_dark'
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
