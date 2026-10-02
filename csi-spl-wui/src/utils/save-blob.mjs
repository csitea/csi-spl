/**
 * Hand the browser a file to save: an object URL on a hidden <a download>,
 * clicked, then revoked. One helper for the key files, the checkout key and
 * the verified attachment (CLE-77915, refactor item 15: three copies revoked
 * after 0, 1 000 and 10 000 ms - a revoke on the same tick can cancel the
 * download in some browsers before it starts).
 */

/** How long the object URL outlives the click: long enough for any browser to start the save. */
export const OBJECT_URL_REVOKE_MS = 10_000

/**
 * @param {Blob} blob
 * @param {string} name the file name offered
 * @param {{ doc?: Document, url?: typeof URL, later?: (fn: () => void, ms: number) => unknown }} [env] seams for the unit test
 */
export function saveBlob(blob, name, env = {}) {
  const doc = env.doc ?? document
  const url = env.url ?? URL
  const later = env.later ?? setTimeout
  const href = url.createObjectURL(blob)
  const a = doc.createElement('a')
  a.href = href
  a.download = name
  a.rel = 'noopener'
  doc.body.appendChild(a)
  a.click()
  a.remove()
  later(() => url.revokeObjectURL(href), OBJECT_URL_REVOKE_MS)
}
