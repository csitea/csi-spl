/** #feedback, the default channel where any member tags the business owner
 *  (owner, 2026-09-25). The hub seeds the row; the name and the description
 *  the sidebar and the channel header show come from the active locale. */

export const FEEDBACK_CHANNEL_ID = 'feedback'


/** The channel slug in a route, including a locale prefix (`/fi/channel/feedback`). */
export function feedbackChannelFromPath(path) {
  const m = String(path || '').match(/\/channel\/([^/?#]+)/)
  if (!m) return ''
  try {
    return decodeURIComponent(m[1])
  } catch {
    return m[1]
  }
}

/** True for the feedback slug, with or without a leading #. */
export function isFeedbackChannel(id) {
  const s = String(id || '').replace(/^#/, '').trim().toLowerCase()
  return s === FEEDBACK_CHANNEL_ID
}

/**
 * Localized name and description for #feedback. `copy` is the locale pair
 * `{ name, description }`. A description already stored on the channel wins,
 * so a tenant that set one is not overwritten by the locale string.
 * Any other channel returns null and the caller keeps the hub row.
 *
 * @param {string | null | undefined} channelId
 * @param {{ name?: string, description?: string } | null | undefined} copy
 * @param {string} [storedDescription]
 * @returns {{ name: string, description: string } | null}
 */
export function feedbackChannelCopy(channelId, copy, storedDescription = '') {
  if (!isFeedbackChannel(channelId)) return null
  const stored = String(storedDescription || '').trim()
  const src = copy && typeof copy === 'object' ? copy : {}
  return {
    name: String(src.name || FEEDBACK_CHANNEL_ID),
    description: stored || String(src.description || ''),
  }
}
