/**
 * Put text on the clipboard: the async Clipboard API first, then the old
 * selection copy, because `navigator.clipboard` is missing or refused on an
 * insecure origin (exactly where lde runs) and under some permission
 * policies. Resolves true when either path copied, false when both failed -
 * a caller that shows "copied" / "could not copy" reads that, never an
 * exception.
 *
 * One helper for every copy in the WUI (CLE-77915, refactor item 25): the
 * fallback was copied into useCopyText, SidebarRowMenu and MessageCard, and
 * five other copies had no fallback at all.
 */

/**
 * @param {string} text
 * @param {{ nav?: Navigator, doc?: Document }} [env] seams for the unit test
 * @returns {Promise<boolean>}
 */
export async function writeClipboard(text, env = {}) {
  const nav = env.nav ?? globalThis.navigator
  const doc = env.doc ?? globalThis.document
  try {
    await nav.clipboard.writeText(text)
    return true
  } catch {
    /* insecure context or denied: the selection fallback below */
  }
  try {
    const ta = doc.createElement('textarea')
    ta.value = text
    ta.setAttribute('readonly', '')
    /* fixed, 1 px and transparent: selecting it neither scrolls nor flashes */
    Object.assign(ta.style, { position: 'fixed', left: '0', top: '0', width: '1px', height: '1px', opacity: '0' })
    doc.body.appendChild(ta)
    ta.select()
    const ok = doc.execCommand('copy')
    ta.remove()
    return ok !== false
  } catch {
    return false
  }
}
