// The linker loads after the first script. A body that is already on screen
// reads idLinkEpoch, so it links once that chunk arrives. Until then an id
// stays text.
import { shallowRef } from 'vue'

export const idLinkEpoch = shallowRef(0)

const EMPTY = Object.freeze({ empty: true })
let api = null
let lookup = null

/** id-links.mjs calls this as it loads. It does not repaint by itself. */
export function registerIdLinks(next) {
  if (next && typeof next.activeIdIndex === 'function') api = next
}

/** The catalog is installed. Bodies that already rendered run again. */
export function idLinksReady() {
  idLinkEpoch.value += 1
}

export function activeIdIndex() {
  idLinkEpoch.value
  return api ? api.activeIdIndex() : EMPTY
}

/**
 * id-catalog-install.ts registers the hub lookup (id-lookup.mjs). A body
 * that is linked hands it its source (noteIds), so the ids the tab has not
 * loaded are asked once, after the paint.
 */
export function registerIdLookup(fn) {
  lookup = typeof fn === 'function' ? fn : null
}

export function noteIds(src, index) {
  if (lookup) lookup(src, index)
}

export function linkifyBlocks(blocks, index) {
  return api ? api.linkifyBlocks(blocks, index) : blocks
}

export function linkifyMarkdown(src, index) {
  return api ? api.linkifyMarkdown(src, index) : src
}
