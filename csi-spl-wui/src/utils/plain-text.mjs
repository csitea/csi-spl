/**
 * Markdown to plain text for one-line rows (spec 082 FR-001, FR-006).
 * Pure: list rows (Topics, Flow) and their aria text show what a person
 * reads, never the marks. Mentions and channel names stay as text.
 */

const ELLIPSIS = '…'

/** Line-start marks: fences, headings, block quotes, list bullets. */
function plainLine(line) {
  if (/^\s*(```|~~~)/.test(line)) return ''
  return line
    .replace(/^\s*(>\s?)+/, '')
    .replace(/^\s{0,3}#{1,6}\s+/, '')
    .replace(/\s+#+\s*$/, '')
    .replace(/^\s*([-*+]|\d+[.)])\s+(\[[ xX]\]\s+)?/, '')
}

/* An escaped mark (`\*`) is literal text: park it on a private-use
   character so the emphasis rules never see it, then put it back. */
const PARK = 0xe000

/** Inline marks: images, links, code ticks, emphasis, strike, escapes. */
function plainInline(text) {
  return text
    .replace(/\\([\\`*_{}[\]()#+\-.!>~|])/g, (_, c) => String.fromCharCode(PARK + c.charCodeAt(0)))
    .replace(/!\[([^\]]*)\]\([^)]*\)/g, '$1')
    .replace(/\[([^\]]+)\]\([^)]*\)/g, '$1')
    .replace(/<((?:https?|mailto):[^>\s]+)>/g, '$1')
    .replace(/(`+)(.+?)\1/g, '$2')
    .replace(/(\*\*|__)(?=\S)(.+?)(?<=\S)\1/g, '$2')
    .replace(/(^|[^\w*])\*(?=\S)(.+?)(?<=\S)\*(?!\*)/g, '$1$2')
    .replace(/(^|[^\w])_(?=\S)(.+?)(?<=\S)_(?!\w)/g, '$1$2')
    .replace(/~~(?=\S)(.+?)(?<=\S)~~/g, '$1')
    .replace(/[\ue000-\ue07f]/g, (c) => String.fromCharCode(c.charCodeAt(0) - PARK))
}

/**
 * `md` as plain text on one line, whitespace collapsed. With `max` > 0 a
 * longer result keeps `max` characters and ends with "…".
 */
export function plainText(md, max) {
  const lines = String(md ?? '').split('\n').map(plainLine)
  const flat = plainInline(lines.join(' ')).replace(/\s+/g, ' ').trim()
  const chars = Array.from(flat)
  if (!(max > 0) || chars.length <= max) return flat
  return chars.slice(0, max).join('') + ELLIPSIS
}
