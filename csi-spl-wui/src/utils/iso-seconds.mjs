// RFC 3339 UTC at seconds precision, no fraction.
// toISOString always emits three fraction digits; the old call sites
// stripped that suffix with two equivalent patterns. Omit the argument
// to stamp now. An invalid Date throws; the caller guards NaN first.

/**
 * @param {Date} [at] the instant to stamp; now when omitted
 * @returns {string} `YYYY-MM-DDTHH:MM:SSZ`
 */
export function isoSeconds(at = new Date()) {
  return at.toISOString().replace(/\.\d+Z$/, 'Z')
}
