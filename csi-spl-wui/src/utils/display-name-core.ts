// csi-spl-wui/src/utils/display-name-core.ts
//
// The one display-name step the entry chunk needs; the rest is in display-name.ts.

/**
 * Two id -> display name maps hold the same pairs (key order ignored).
 * useHumanNames compared two JSON.stringify strings per mount for this.
 */
export function sameNames(a: Record<string, string> | null | undefined, b: Record<string, string> | null | undefined): boolean {
  const x = a || {}
  const y = b || {}
  const keys = Object.keys(x)
  if (keys.length !== Object.keys(y).length) return false
  for (const k of keys) {
    if (!Object.prototype.hasOwnProperty.call(y, k) || x[k] !== y[k]) return false
  }
  return true
}
