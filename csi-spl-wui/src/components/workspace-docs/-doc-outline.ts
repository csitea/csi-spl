/* The doc outline's numbering, one helper for the WUI (spec 137 T012a): an
   item whose attrs.numbered is false has no outline number and does not
   count among its siblings; the items under it have no number either. The
   store derives the hub's outline the same way (csi-spl-api
   internal/store/workspace_docs_read.go, wsDocNumSQL + outlineOf) and the
   CLI export prints it (cmd/spool/doctree_export.go): change them together.
   The `-` prefix keeps Nuxt from registering this file as a component. */

type Numbered = { attrs?: Record<string, unknown> }
type Ranked = Numbered & { id: string, ord: number }
type Placed = { id: string, depth: number }

/** false when the item opted out of numbering (attrs.numbered = false) */
export function isNumbered(it: Numbered): boolean {
  const v = it.attrs?.numbered
  return v !== false && v !== 'false'
}

/** each sibling's number among them, in ord order: 0 for an unnumbered one, else the count of numbered siblings up to it */
export function siblingNumbers(siblings: Ranked[]): Map<string, number> {
  const out = new Map<string, number>()
  let n = 0
  for (const it of [...siblings].sort((a, b) => a.ord - b.ord)) out.set(it.id, isNumbered(it) ? ++n : 0)
  return out
}

/** the outline of a number path (1 / 1.1 / 1.1.1): '' for the root, an unnumbered item and anything under one */
export function outlineOf(path: number[]): string {
  return path.length && !path.includes(0) ? path.join('.') : ''
}

/** a heading's text: the outline number and the title, the title alone when it has no number;
    dot writes the number "1." (attrs.outline_dot, the md author's form, SPL-1900) */
export function headingText(outline: string, title: string, dot = false): string {
  return outline ? `${outline}${dot ? '.' : ''} ${title}` : title
}

/** the item and everything under it, in document order: the items after it that are deeper (by depth: an unnumbered item has no outline prefix) */
export function branchOf<T extends Placed>(items: T[], id: string): T[] {
  const i = items.findIndex((x) => x.id === id)
  if (i < 0) return []
  let end = i + 1
  while (end < items.length && items[end].depth > items[i].depth) end++
  return items.slice(i, end)
}
