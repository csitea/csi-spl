// csi-spl-wui/src/composables/apiHealth.mjs
//
// The two pure classifiers the error journal shares with any future outage
// banner, so "was that an abort?" and "which HTTP status was it?" cannot drift
// into two different answers. No Vue, no DOM, no network of its own.

/**
 * @param {unknown} error
 * @returns {boolean}
 */
export function isAbortError(error) {
  if (!error || typeof error !== 'object') return false
  const name = String(/** @type {{name?: unknown}} */ (error).name || '')
  if (name === 'AbortError') return true
  const cause = /** @type {{cause?: unknown}} */ (error).cause
  if (cause && typeof cause === 'object') {
    if (String(/** @type {{name?: unknown}} */ (cause).name || '') === 'AbortError') {
      return true
    }
  }
  return false
}

/**
 * @param {{ status?: unknown, statusCode?: unknown, error?: unknown, response?: { status?: unknown } }} [input]
 * @returns {number | undefined}
 */
export function statusFrom(input) {
  if (!input || typeof input !== 'object') return undefined
  const direct = [input.status, input.statusCode]
  const err = input.error && typeof input.error === 'object' ? input.error : null
  if (err) {
    direct.push(
      /** @type {{statusCode?: unknown}} */ (err).statusCode,
      /** @type {{status?: unknown}} */ (err).status,
    )
    const resp = /** @type {{response?: { status?: unknown }}} */ (err).response
    if (resp && typeof resp === 'object') direct.push(resp.status)
  }
  if (input.response && typeof input.response === 'object') {
    direct.push(input.response.status)
  }
  for (const v of direct) {
    if (typeof v === 'number' && Number.isFinite(v)) return v
  }
  return undefined
}

