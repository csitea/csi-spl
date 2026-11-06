/**
 * SPL-4893 (owner HUM-10, t1 ba784026, msgs de86531f and e6a8148b): the note
 * editor's toolbar writes wiki marks into the plain-text body, never HTML:
 *   **bold**   ++underline++ (utils/markdown.mjs)   "1. " numbered   "- " bullets
 * Each function takes the text and the selection and returns the new text and
 * selection; NoteBodyEditor.vue applies it to its textarea. Pure: node tests
 * import this file directly.
 */

/** @typedef {{ text: string, start: number, end: number }} Edit */

/**
 * Wrap the selection in `mark`, or take the mark off when the selection (or
 * the text right around it) already carries it. No selection: the two marks
 * go in with the caret between them. Whitespace at the selection's edges
 * (a double-click takes the trailing space on some platforms) stays outside
 * the marks: "**word **" would render as plain text (R7 c-232 N2).
 * @returns {Edit}
 */
export function toggleMark(text, start, end, mark) {
  while (start < end && /\s/.test(text[start])) start++
  while (end > start && /\s/.test(text[end - 1])) end--
  const n = mark.length
  const sel = text.slice(start, end)
  if (sel.length >= 2 * n && sel.startsWith(mark) && sel.endsWith(mark)) {
    const inner = sel.slice(n, sel.length - n)
    return { text: text.slice(0, start) + inner + text.slice(end), start, end: start + inner.length }
  }
  if (text.slice(start - n, start) === mark && text.slice(end, end + n) === mark && start >= n) {
    return { text: text.slice(0, start - n) + sel + text.slice(end + n), start: start - n, end: end - n }
  }
  return { text: text.slice(0, start) + mark + sel + mark + text.slice(end), start: start + n, end: end + n }
}

const BULLET = /^(\s*)[-*] /
const NUMBER = /^(\s*)\d+[.)] /

/**
 * Make every line the selection touches a list item of `kind` ('bullet' or
 * 'number', numbered 1, 2, 3 ...), or plain lines again when they all already
 * are that kind. Empty lines stay empty and are not counted (R7 c-232 N3).
 * The selection grows to the whole lines.
 * @returns {Edit}
 */
export function toggleList(text, start, end, kind) {
  const from = text.lastIndexOf('\n', start - 1) + 1
  const nl = text.indexOf('\n', end > start && text[end - 1] === '\n' ? end - 1 : end)
  const to = nl < 0 ? text.length : nl
  const lines = text.slice(from, to).split('\n')
  const same = kind === 'number' ? NUMBER : BULLET
  const blank = (l) => !l.trim()
  const all = lines.every((l) => blank(l) || same.test(l))
  let count = 0
  const out = lines.map((l) => {
    if (blank(l)) return l
    const bare = l.replace(BULLET, '$1').replace(NUMBER, '$1')
    if (all) return bare
    const lead = /^\s*/.exec(bare)[0]
    return lead + (kind === 'number' ? `${++count}. ` : '- ') + bare.slice(lead.length)
  }).join('\n')
  return { text: text.slice(0, from) + out + text.slice(to), start: from, end: from + out.length }
}
