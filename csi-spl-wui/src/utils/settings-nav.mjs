/**
 * The GitHub-style settings sections (specs/023 §3.4). One entry per child
 * route of pages/settings.vue, in nav order; `label` is a catalogue key.
 */
export const SETTINGS_SECTIONS = [
  { id: 'profile', label: 'settings.profile' },
  { id: 'language', label: 'settings.language_title' },
  { id: 'appearance', label: 'settings.appearance' },
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
