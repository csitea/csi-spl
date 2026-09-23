/** Left-stripe tabs, top to bottom. Direct messages are the first tab. */

export const SIDE_TABS = ['dm', 'channels']

/**
 * The open route picks a tab when the page is one of those two lists.
 * Home, lobby, search and settings return null so the reader's own
 * choice stays; the call site starts on direct messages.
 * @param {string} path vue-router path, no query
 * @returns {'dm' | 'channels' | null}
 */
export function tabForPath(path) {
  const p = String(path || '')
  if (/\/dm(?:\/|$)/.test(p)) return 'dm'
  if (/\/channel(?:\/|$)/.test(p)) return 'channels'
  return null
}
