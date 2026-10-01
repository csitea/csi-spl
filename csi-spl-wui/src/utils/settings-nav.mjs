/**
 * The GitHub-style settings sections (specs/023 §3.4). One entry per section
 * of components/SettingsDialog.vue (components/settings/<id>.vue), in nav
 * order; `label` is a catalogue key.
 */
export const SETTINGS_SECTIONS = [
  { id: 'profile', label: 'settings.profile' },
  { id: 'language', label: 'settings.language_title' },
  { id: 'appearance', label: 'settings.appearance' },
  { id: 'behaviour', label: 'settings.behaviour' },
  { id: 'notifications', label: 'settings.notifications' },
  { id: 'security', label: 'settings.signin_security' },
  { id: 'keys', label: 'settings.keys_title' },
]

export const DEFAULT_SETTINGS_SECTION = 'profile'

/**
 * The section id of a route path ('/settings/keys', '/fi/settings/keys/'),
 * '' when the path is not a known section (e.g. '/settings').
 */
export function settingsSectionOf(path) {
  const m = /\/settings\/([a-z]+)\/?$/.exec(String(path || '').split(/[?#]/)[0])
  return m && SETTINGS_SECTIONS.some((s) => s.id === m[1]) ? m[1] : ''
}

/*
 * CLE-77853 (bug 49568e8b, owner pick "B. - a pop-up modal dialog - similar
 * to the one of edit epic"): Settings is a modal OVER the current view, not a
 * page that replaces it. Its state is one query key on whatever route is open
 * (`/channel/general?settings=notifications`), so the page behind keeps its
 * instance (scroll, open topic, drafts), browser Back closes it, and closing
 * goes back without a reload. The old addresses (/settings, /settings/<id>,
 * /fi/settings/keys) still work: middleware/settings-modal.global.ts turns
 * them into the modal over the last view, or over the lobby when cold.
 */
export const SETTINGS_QUERY = 'settings'

/**
 * The open section from a route query: null = closed, '' = open on no
 * particular section (the list on a phone, the default section on a desktop),
 * else a known section id. An unknown value opens on '' rather than nothing.
 */
export function settingsQuerySection(query) {
  if (!query || !Object.prototype.hasOwnProperty.call(query, SETTINGS_QUERY)) return null
  let v = query[SETTINGS_QUERY]
  if (Array.isArray(v)) v = v[0]
  v = String(v ?? '')
  return SETTINGS_SECTIONS.some((s) => s.id === v) ? v : ''
}

/** The section shown for a query value: a desktop never shows the bare list. */
export function settingsShownSection(section, isMobile) {
  if (section === null) return null
  return section || (isMobile ? '' : DEFAULT_SETTINGS_SECTION)
}

const SETTINGS_PATH = /^(\/[a-z]{2}(?:-[A-Za-z]+)?)?\/settings(?:\/([a-z]+))?\/?$/

/** True for an old Settings address: /settings, /settings/keys, /fi/settings/keys. */
export function isSettingsPath(path) {
  return SETTINGS_PATH.test(String(path || '').split(/[?#]/)[0])
}

/** A query without the Settings key (a fresh object; the input is left alone). */
export function withoutSettings(query) {
  const q = { ...(query || {}) }
  delete q[SETTINGS_QUERY]
  return q
}

/**
 * Where an old Settings address goes: the view the person came from (its
 * path and query) with ?settings=<section>, or the locale's lobby when there
 * is no such view (a cold deep link, or a move from one Settings address to
 * another). `from` is { path, query, matched } with `matched` the number of
 * matched route records (0 on the app's first navigation).
 */
export function settingsModalTarget(toPath, from) {
  const path = String(toPath || '').split(/[?#]/)[0]
  const m = SETTINGS_PATH.exec(path)
  const prefix = (m && m[1]) || ''
  const section = settingsSectionOf(path)
  const usable = from && from.matched > 0 && from.path && !isSettingsPath(from.path)
  const base = usable ? from.path : prefix + '/lobby'
  const query = usable ? withoutSettings(from.query) : {}
  query[SETTINGS_QUERY] = section
  return { path: base, query }
}

/**
 * How closing gets back to the view: 'back' when the history entry under this
 * one IS that view without Settings (it was opened in the app, so Back is the
 * same as closing and leaves no forward entry behind), 'replace' otherwise (a
 * cold deep link: there is nothing of ours under it).
 */
export function settingsCloseStep(historyBack, viewFullPath) {
  return historyBack && historyBack === viewFullPath ? 'back' : 'replace'
}
