/**
 * Where code-blocks.mjs finds the issue-key linker (utils/issue-key-links.mjs).
 * plugins/issue-links.client.ts registers it once the workspace's prefix is
 * known and that chunk has loaded; until then, with no issues, and in a unit
 * test it is null and a body renders as it always did. Kept apart so the
 * initial chunk carries only this.
 */
let provider = () => null

/** fn returns { blocks(tree), markdown(src), inline(text) } or null; null clears it. */
export function setIssueLinkProvider(fn) {
  provider = typeof fn === 'function' ? fn : () => null
}

/** The linker for this render, or null. */
export function activeIssueLinker() {
  try {
    const l = provider()
    return l && typeof l.blocks === 'function' && typeof l.markdown === 'function' && typeof l.inline === 'function' ? l : null
  } catch {
    return null
  }
}
