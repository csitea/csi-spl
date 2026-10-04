/**
 * Where code-blocks.mjs finds the commit linker (utils/commit-links.mjs).
 * plugins/commit-links.client.ts registers it once that chunk has loaded;
 * until then, with the cnf unset, and in a unit test it is null and a body
 * renders as it always did. Kept apart so the initial chunk carries only this.
 */
let provider = () => null

/** fn returns { blocks(tree), markdown(src) } or null; null clears it. */
export function setCommitLinkProvider(fn) {
  provider = typeof fn === 'function' ? fn : () => null
}

/** The linker for this render, or null. */
export function activeCommitLinker() {
  try {
    const l = provider()
    return l && typeof l.blocks === 'function' && typeof l.markdown === 'function' ? l : null
  } catch {
    return null
  }
}
