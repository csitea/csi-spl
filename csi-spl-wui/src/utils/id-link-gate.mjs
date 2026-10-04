// The linker loads after the first script. A body that is already on screen
// reads idLinkEpoch, so it links once that chunk arrives. Until then an id
// stays text.
import { shallowRef } from 'vue'

export const idLinkEpoch = shallowRef(0)

const EMPTY = Object.freeze({ empty: true })
let api = null

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

export function linkifyBlocks(blocks, index) {
  return api ? api.linkifyBlocks(blocks, index) : blocks
}

export function linkifyMarkdown(src, index) {
  return api ? api.linkifyMarkdown(src, index) : src
}
