/**
 * Files carried by a paste or a drop. The owner, 2026-09-25: a reply with a
 * file was stored with files = [] and no upload was ever made. 📎 Attach
 * was the only way in: a pasted screenshot went nowhere, and a file dropped
 * on the page was opened by the browser instead of attached.
 */

/**
 * Does this transfer carry files (a drag from the desktop, a copied file)?
 * @param {unknown} dt a DataTransfer, or null
 * @returns {boolean}
 */
export function carriesFiles(dt) {
  const d = /** @type {{ types?: ArrayLike<string> } | null} */ (dt)
  if (!d || !d.types) return false
  return Array.from(d.types).includes('Files')
}

/**
 * The files in a paste or a drop. `files` first; a clipboard that lists its
 * picture only under `items` (some browsers, for a screenshot) is read there.
 * @param {unknown} dt a DataTransfer, or null
 * @returns {File[]}
 */
export function filesOf(dt) {
  const d = /** @type {{ files?: ArrayLike<File>, items?: ArrayLike<{ kind: string, getAsFile: () => File | null }> } | null} */ (dt)
  if (!d) return []
  const listed = d.files ? Array.from(d.files).filter(Boolean) : []
  if (listed.length) return listed
  const out = []
  for (const item of d.items ? Array.from(d.items) : []) {
    if (item && item.kind === 'file') {
      const f = item.getAsFile()
      if (f) out.push(f)
    }
  }
  return out
}

/**
 * Should a paste attach its files instead of inserting text? Yes when it
 * carries files and no rich text. A copy from a document (text/html with an
 * embedded picture) stays a text paste.
 * @param {unknown} dt a DataTransfer, or null
 * @returns {boolean}
 */
export function pasteAttaches(dt) {
  const d = /** @type {{ types?: ArrayLike<string> } | null} */ (dt)
  if (!d || !d.types) return false
  const types = Array.from(d.types)
  return filesOf(dt).length > 0 && !types.includes('text/html')
}
