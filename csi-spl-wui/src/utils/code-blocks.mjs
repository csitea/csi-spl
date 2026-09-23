/**
 * Slack-style ``` code blocks and `inline code` for message bodies.
 *
 * The wire stays plain text with Markdown fences (no new message field, no
 * v:1 change), so boxes and agents read the same fences a human typed. This
 * module only turns that text into a tree of plain strings; the WUI renders
 * the tree with Vue text interpolation (MessageBody.vue), never innerHTML, so
 * nothing in a body can become markup.
 *
 * Rules (Slack's, plus an optional language label):
 *   - a run of 3+ backticks opens a fence anywhere on a line; the next run of
 *     at least as many backticks closes it, on any line
 *   - ```lang<newline> labels the block (a short word, then a newline)
 *   - one newline right after the opener and one right before the closer are
 *     dropped, so ```\ncode\n``` holds exactly "code"
 *   - an unclosed fence that starts a line runs to the end of the body (an
 *     agent's truncated output still reads as code); one opened mid-line
 *     stays literal text, as in Slack
 *   - 1 or 2 backticks open inline code closed by the same run on the same
 *     line; a ``` inside such a span is content, not a fence
 *   - CRLF / CR are read as LF
 *
 * Pure: node tests import this file directly.
 */

const LANG_RE = /^([A-Za-z0-9_+#.-]{1,24})\n/

function runAt(s, i) {
  let n = 0
  while (s[i + n] === '`') n++
  return n
}

/** CRLF and lone CR as LF. */
export function normalizeNewlines(src) {
  return String(src ?? '').replace(/\r\n?/g, '\n')
}

/** The first run of >= `min` backticks at or after `from`, or null. */
function findCloser(s, from, min) {
  let i = from
  while (i < s.length) {
    const at = s.indexOf('`', i)
    if (at < 0) return null
    const n = runAt(s, at)
    if (n >= min) return { at, n }
    i = at + n
  }
  return null
}

/** Inline span closer: a run of exactly `n` backticks before the end of the line. */
function findInlineCloser(s, from, n) {
  const eol = s.indexOf('\n', from)
  const end = eol < 0 ? s.length : eol
  let i = from
  while (i < end) {
    const at = s.indexOf('`', i)
    if (at < 0 || at >= end) return -1
    const r = runAt(s, at)
    if (r === n) return at
    i = at + r
  }
  return -1
}

/**
 * Tokenise a body into top-level segments:
 *   { type: 'text', text }          plain text (bold / mentions still to split)
 *   { type: 'inline', text }        `inline code`
 *   { type: 'code', text, lang, closed }   a fenced block
 * `openAnywhere` (the composer) treats an unclosed fence opened mid-line as
 * open too.
 */
export function tokenize(src, { openAnywhere = false } = {}) {
  const s = normalizeNewlines(src)
  const out = []
  let buf = ''
  const flush = () => {
    if (buf) out.push({ type: 'text', text: buf })
    buf = ''
  }
  let i = 0
  while (i < s.length) {
    if (s[i] !== '`') {
      const next = s.indexOf('`', i)
      const end = next < 0 ? s.length : next
      buf += s.slice(i, end)
      i = end
      continue
    }
    const n = runAt(s, i)
    if (n >= 3) {
      let body = i + n
      let lang = ''
      const m = LANG_RE.exec(s.slice(body, body + 26))
      if (m) {
        lang = m[1]
        body += m[0].length
      } else if (s[body] === '\n') {
        body += 1
      }
      const close = findCloser(s, body, n)
      const lineStart = i === 0 || s[i - 1] === '\n'
      if (close) {
        // a longer closing run keeps its extra backticks as content
        let text = s.slice(body, close.at) + '`'.repeat(close.n - n)
        if (text.endsWith('\n')) text = text.slice(0, -1)
        flush()
        out.push({ type: 'code', text, lang, closed: true })
        i = close.at + close.n
        if (s[i] === '\n') i += 1
        continue
      }
      if (lineStart || openAnywhere) {
        flush()
        out.push({ type: 'code', text: s.slice(body), lang, closed: false })
        i = s.length
        continue
      }
      buf += s.slice(i, i + n)
      i += n
      continue
    }
    const close = findInlineCloser(s, i + n, n)
    if (close > i + n) {
      flush()
      out.push({ type: 'inline', text: s.slice(i + n, close) })
      i = close + n
      continue
    }
    buf += s.slice(i, i + n)
    i += n
  }
  flush()
  return out
}

const RICH_RE = /\*\*([^*\n]+)\*\*|@([A-Z]{2,4}-\d+)/g

/** Split plain text into text / strong / mention parts. */
export function richParts(text) {
  const s = String(text)
  const parts = []
  let last = 0
  for (const m of s.matchAll(RICH_RE)) {
    if (m.index > last) parts.push({ type: 'text', text: s.slice(last, m.index) })
    if (m[1] !== undefined) parts.push({ type: 'strong', text: m[1] })
    else parts.push({ type: 'mention', text: '@' + m[2] })
    last = m.index + m[0].length
  }
  if (last < s.length) parts.push({ type: 'text', text: s.slice(last) })
  return parts
}

function trimPara(p) {
  const parts = p.parts.slice()
  if (parts[0]?.type === 'text') parts[0] = { ...parts[0], text: parts[0].text.replace(/^\n+/, '') }
  const k = parts.length - 1
  if (parts[k]?.type === 'text') parts[k] = { ...parts[k], text: parts[k].text.replace(/\n+$/, '') }
  return { type: 'para', parts: parts.filter((x) => x.text !== '') }
}

/**
 * The render tree of a body: blocks of
 *   { type: 'code', text, lang, closed }
 *   { type: 'para', parts: [{ type: 'text'|'strong'|'mention'|'inline', text }] }
 * Every `text` is a raw string for text interpolation — never HTML.
 */
export function parseBody(src) {
  const blocks = []
  let para = null
  for (const t of tokenize(src)) {
    if (t.type === 'code') {
      para = null
      blocks.push({ type: 'code', text: t.text, lang: t.lang, closed: t.closed })
      continue
    }
    if (!para) {
      para = { type: 'para', parts: [] }
      blocks.push(para)
    }
    if (t.type === 'inline') para.parts.push({ type: 'inline', text: t.text })
    else para.parts.push(...richParts(t.text))
  }
  // a paragraph that is only the newlines between two blocks is not a line
  return blocks
    .map((b) => (b.type === 'para' ? trimPara(b) : b))
    .filter((b) => b.type === 'code' || b.parts.length > 0)
}

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

/**
 * Escaped HTML of a body, for callers that need a string (tests, previews).
 * The WUI itself renders parseBody through MessageBody.vue, not this.
 */
export function bodyToHtml(src) {
  return parseBody(src).map((b) => {
    if (b.type === 'code') {
      const label = b.lang ? ` data-lang="${esc(b.lang)}"` : ''
      return `<pre${label}><code>${esc(b.text)}</code></pre>`
    }
    return b.parts.map((p) => {
      if (p.type === 'inline') return `<code>${esc(p.text)}</code>`
      if (p.type === 'strong') return `<strong>${esc(p.text)}</strong>`
      if (p.type === 'mention') return `<span class="mention">${esc(p.text)}</span>`
      return esc(p.text).replace(/\n/g, '<br>')
    }).join('')
  }).join('')
}

/* ---------- composer state ---------- */

/**
 * Is the caret inside an open ``` block? The composer is Slack's: typing ```
 * opens a block anywhere, typing ``` again closes it.
 * Returns { inCode, lang }.
 */
export function fenceStateAt(text, caret) {
  const s = String(text ?? '')
  const toks = tokenize(s.slice(0, caret ?? s.length), { openAnywhere: true })
  const last = toks[toks.length - 1]
  if (last && last.type === 'code' && !last.closed) return { inCode: true, lang: last.lang }
  return { inCode: false, lang: '' }
}

/**
 * What Enter does. Outside a block Enter sends and Shift+Enter is a newline
 * (unchanged); inside a block Enter is a newline. Ctrl/Cmd+Enter always sends.
 */
export function enterAction({ inCode = false, shift = false, alt = false, mod = false } = {}) {
  if (mod) return 'send'
  if (inCode || shift || alt) return 'newline'
  return 'send'
}

/**
 * Close the block the caret is in (Esc, Slack's exit): a closing fence on
 * its own line at the caret, the caret after it. Returns { text, cursor }.
 */
export function exitFence(text, caret) {
  const s = String(text ?? '')
  const c = caret ?? s.length
  const head = s.slice(0, c)
  const tail = s.slice(c)
  const pre = head === '' || head.endsWith('\n') ? '' : '\n'
  const post = tail.startsWith('\n') ? '' : '\n'
  const insert = pre + '```' + post
  return { text: head + insert + tail, cursor: c + insert.length }
}

/** On send: close a block the author left open, so the wire always balances. */
export function closeOpenFence(text) {
  const s = String(text ?? '')
  if (!fenceStateAt(s, s.length).inCode) return s
  // a one-line block closes on its line (```x``` — Slack's own form), so the
  // closer never turns its only word into a language label
  const opener = s.lastIndexOf('```')
  if (!s.slice(opener).includes('\n')) return s + '```'
  return s + (s.endsWith('\n') ? '' : '\n') + '```'
}
