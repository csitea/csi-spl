/**
 * Where the renderers find the doc-path linker (SPL-1592, utils/doc-paths.mjs).
 * The list of docs is asked once, the first time a rendered text could hold
 * a doc path (plugins/doc-path-links.client.ts registers the loader); a body
 * on screen reads docPathEpoch, so it links when the list arrives. Until
 * then, with no loader, and in a unit test, a path stays text. Kept apart so
 * the initial chunk carries only this.
 */
import { shallowRef } from 'vue'

export const docPathEpoch = shallowRef(0)

const MAY_HOLD = /[\w-]\/[\w./-]*\.md\b/
let loader = null
let linker = null
let asked = false

/** fn() loads the list and calls setDocPathLinker; null clears it. */
export function setDocPathLoader(fn) {
  loader = typeof fn === 'function' ? fn : null
  asked = false
  /* a body that rendered before the loader came asks now */
  if (loader) docPathEpoch.value += 1
}

/** { resolve(raw), blocks(tree) } or null. Bodies already on screen run again. */
export function setDocPathLinker(next) {
  linker = next && typeof next.resolve === 'function' && typeof next.blocks === 'function' ? next : null
  docPathEpoch.value += 1
}

/** The linker for a render of `src`, or null (then the list is asked once). */
export function activeDocPathLinker(src) {
  void docPathEpoch.value
  if (!linker && !asked && loader && MAY_HOLD.test(String(src ?? ''))) {
    asked = true
    const run = loader
    setTimeout(() => { Promise.resolve().then(run).catch(() => { /* paths stay text */ }) }, 0)
  }
  return linker
}
