/**
 * Where the composer's draft holds code, as runs that cover the draft exactly
 * (t1 3558e416, owner: "`foobar`" should look like code while typing, and
 * ``` should turn into a code block at once, with no closing fence typed).
 *
 * Read with the composer's own rule (tokenize openAnywhere, fenceStateAt's):
 * an unclosed ``` is a block from its opener to the end of the draft. The
 * runs join back to the draft character for character, backticks included,
 * so a mirror of the textarea lines up with what the person typed.
 *
 * Returns [{ text, kind? }], kind 'inline' | 'block'. Pure: node tests import it.
 * Loaded only with ComposerCodeMarks.vue, a lazy chunk.
 */
import { tokenize } from './code-blocks.mjs'

function ticksAt(s, i) {
  let n = 0
  while (s[i + n] === '`') n++
  return n
}

/** tokenize's closer: the first run of >= n backticks at or after `from` */
function fenceEnd(s, from, n) {
  let i = from
  while (i < s.length) {
    const at = s.indexOf('`', i)
    if (at < 0) return s.length
    const r = ticksAt(s, at)
    if (r >= n) return at + r
    i = at + r
  }
  return s.length
}

/** The draft as runs [{ text, kind? }]; kind 'inline' | 'block' marks code. */
export function composerCodeRuns(src) {
  const s = String(src ?? '')
  const runs = []
  let at = 0
  const take = (end, kind) => {
    if (end <= at) return
    runs.push(kind ? { text: s.slice(at, end), kind } : { text: s.slice(at, end) })
    at = end
  }
  if (!s.includes('`') || /\r/.test(s)) return s ? [{ text: s }] : []
  for (const t of tokenize(s, { openAnywhere: true })) {
    if (t.type === 'text') { take(at + t.text.length); continue }
    const n = ticksAt(s, at)
    if (t.type === 'inline') { take(at + 2 * n + t.text.length, 'inline'); continue }
    if (!t.closed) { take(s.length, 'block'); continue }
    let body = at + n
    if (t.lang) body += t.lang.length + 1
    else if (s[body] === '\n') body += 1
    take(fenceEnd(s, body, n), 'block')
    // tokenize drops the one newline after a closer; it is plain text here
    if (s[at] === '\n') take(at + 1)
  }
  take(s.length)
  // a draft the walk could not cover exactly is shown unmarked, never shifted
  const ok = runs.map((r) => r.text).join('') === s &&
    runs.every((r) => !r.kind || (r.text[0] === '`' && (r.kind === 'block' || r.text.endsWith('`'))))
  return ok ? runs : [{ text: s }]
}
