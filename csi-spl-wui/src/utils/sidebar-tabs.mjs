/** Left-stripe tabs, top to bottom. */

import { productPath } from './signed-out-redirect.mjs'

export const SIDE_TABS = ['dm', 'channels', 'threads', 'flow']

/**
 * The open route picks a tab when the page is one of the four lists.
 * Search and settings return null so the reader's own choice stays.
 * The call site starts on direct messages.
 * @param {string} path vue-router path, no query
 * @returns {'dm' | 'channels' | 'threads' | 'flow' | null}
 */
export function tabForPath(path) {
  const p = productPath(path)
  if (p === '/dm' || p.startsWith('/dm/')) return 'dm'
  if (p === '/channel' || p.startsWith('/channel/')) return 'channels'
  if (p === '/' || p === '/t' || p.startsWith('/t/')) return 'threads'
  if (p === '/lobby') return 'flow'
  return null
}
