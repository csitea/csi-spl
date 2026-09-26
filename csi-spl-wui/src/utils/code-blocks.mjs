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
 *   - a line that is exactly {{wiki}} opens a markdown region; a line that
 *     is exactly {{/wiki}} closes it. Inside, headings, lists, quotes and
 *     emphasis render. An unclosed opener stays ordinary text. A fence
 *     inside the region can hold the closer as code.
 *
 * Pure: node tests import this file directly.
 */
import { classifyHref, linkOpen } from './link-target.mjs'

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

/*
 * Links (CLE-3494). Only plain text is scanned: ``` blocks and `inline code`
 * never reach here, and a mention or **bold** that starts first wins its run.
 * Three shapes, three schemes, nothing else:
 *   http:// https://   -> the text as written
 *   www.<host>         -> https://<text>
 *   a bare email       -> mailto:<text>
 * javascript:, data:, vbscript:, file: and the rest have no shape here, so
 * they stay text. A URL may not start glued to a word, a slash, a dot, a
 * colon or an @, so `javascript:https://…` and `x//www.…` stay text too.
 */
/**
 * Bidi embedding / override / isolate controls (U+202A..U+202E, U+2066..U+2069)
 * and the ALM/LRM/RLM marks (the hub refuses the same set, 323c76e5).
 * They are invisible and reorder the text around them,
 * so "evil.example/\u202egpj.doog" reads as another address (CLE-34987): a link
 * ends before one, and a display name drops them (stripBidiControls).
 */
const BIDI_CLASS = String.raw`\u061c\u200e\u200f\u202a-\u202e\u2066-\u2069`
const BIDI_RE = new RegExp(`[${BIDI_CLASS}]`, 'g')

/** The string without bidi controls: for one-line labels such as display names. */
export function stripBidiControls(s) {
  return String(s ?? '').replace(BIDI_RE, '')
}

const URL_SRC = String.raw`(?<![\w/.:@-])(?:[Hh][Tt][Tt][Pp][Ss]?:\/\/|[Ww][Ww][Ww]\.)[^\s<>\x60${BIDI_CLASS}]+`
const EMAIL_SRC = String.raw`(?<![\w.%+/:@-])[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}`
const LINK_RE = new RegExp(`(${URL_SRC})|(${EMAIL_SRC})`, 'g')
const RICH_RE = new RegExp(
  String.raw`\*\*([^*\n]+)\*\*|@([A-Z]{2,4}-\d+(?:@[a-z0-9][a-z0-9-]{0,31})?)|(${URL_SRC})|(${EMAIL_SRC})`,
  'g',
)

const count = (s, c) => s.split(c).length - 1

/** Sentence punctuation after a URL is not part of it; a balanced ( ) is. */
function trimUrl(u) {
  for (;;) {
    const c = u[u.length - 1]
    if ('.,;:!?*'.includes(c)) u = u.slice(0, -1)
    else if (c === ')' && count(u, '(') < count(u, ')')) u = u.slice(0, -1)
    else if (c === ']' && count(u, '[') < count(u, ']')) u = u.slice(0, -1)
    else if (c === '}' && count(u, '{') < count(u, '}')) u = u.slice(0, -1)
    else if ((c === "'" || c === '"') && count(u, c) % 2 === 1) u = u.slice(0, -1)
    else return u
  }
}

const SCHEMES = new Set(['http:', 'https:', 'mailto:'])

/** The link part of a URL / www / email match, or null when it is not one. */
function toLink(url, email) {
  if (email !== undefined) return { type: 'link', text: email, href: 'mailto:' + email }
  const text = trimUrl(url)
  const www = /^www\./i.test(text)
  if (!/^(?:https?:\/\/|www\.)[A-Za-z0-9]/i.test(text)) return null
  const href = www ? 'https://' + text : text
  try {
    const u = new URL(href)
    if (!SCHEMES.has(u.protocol) || !u.hostname) return null
  } catch {
    return null
  }
  return { type: 'link', text, href }
}

function splitRuns(s, re, part) {
  const parts = []
  let last = 0
  for (const m of s.matchAll(re)) {
    const p = part(m)
    if (!p) continue
    if (m.index > last) parts.push({ type: 'text', text: s.slice(last, m.index) })
    parts.push(p)
    last = m.index + (p.type === 'link' ? p.text.length : m[0].length)
  }
  if (last < s.length) parts.push({ type: 'text', text: s.slice(last) })
  return parts
}

/** Split plain text into text / link parts. */
export function linkParts(text) {
  return splitRuns(String(text), LINK_RE, (m) => toLink(m[1], m[2]))
}

/** Split plain text into text / strong / mention / link parts. */
export function richParts(text) {
  return splitRuns(String(text), RICH_RE, (m) => {
    if (m[1] !== undefined) return { type: 'strong', text: m[1] }
    if (m[2] !== undefined) return { type: 'mention', text: '@' + m[2] }
    return toLink(m[3], m[4])
  })
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
 *   { type: 'para'|'quote', parts }
 *   { type: 'heading', level, parts }
 *   { type: 'list', ordered, items: [{ parts }] }
 * parts are { type: 'text'|'strong'|'em'|'mention'|'inline', text }
 *         or { type: 'link', text, href }
 * Every `text` is a raw string for text interpolation — never HTML.
 */
const WIKI_OPEN_RE = /^\{\{wiki\}\}[ \t]*$/i
const WIKI_CLOSE_RE = /^\{\{\/wiki\}\}[ \t]*$/i
const WIKI_RE = new RegExp(
  String.raw`\[([^\]\n]{1,200})\]\(([^)\s]+)\)|\*\*([^*\n]+)\*\*|(?<![\w*])\*([^*\n]+)\*(?!\*)|(?<![\w])_([^_\n]+)_(?![\w])|@([A-Z]{2,4}-\d+(?:@[a-z0-9][a-z0-9-]{0,31})?)|` + `(${URL_SRC})|(${EMAIL_SRC})`,
  'g',
)

function mdLink(label, href) {
  const text = String(label || '').trim()
  const raw = String(href || '').trim()
  if (!text || !raw) return null
  if (/^mailto:/i.test(raw)) {
    const addr = raw.slice(7)
    if (!/^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$/.test(addr)) return null
    return { type: 'link', text, href: 'mailto:' + addr }
  }
  const c = classifyHref(raw)
  if (!c || c.href.startsWith('mailto:')) return null
  return { type: 'link', text, href: c.href }
}

/** Emphasis and markdown links, only inside a wiki region. */
function wikiRich(text) {
  return splitRuns(String(text), WIKI_RE, (m) => {
    if (m[1] !== undefined) return mdLink(m[1], m[2])
    if (m[3] !== undefined) return { type: 'strong', text: m[3] }
    if (m[4] !== undefined) return { type: 'em', text: m[4] }
    if (m[5] !== undefined) return { type: 'em', text: m[5] }
    if (m[6] !== undefined) return { type: 'mention', text: '@' + m[6] }
    return toLink(m[7], m[8])
  })
}

function wikiParts(text) {
  const parts = []
  for (const t of tokenize(text)) {
    if (t.type === 'inline') parts.push({ type: 'inline', text: t.text })
    else if (t.type === 'code') parts.push({ type: 'text', text: t.text })
    else parts.push(...wikiRich(t.text))
  }
  return parts.filter((p) => p.text !== '')
}

function fenceWidth(line) {
  const m = /^(```+)/.exec(line)
  return m ? m[1].length : 0
}

/** Plain runs and closed {{wiki}} regions. An unclosed opener stays plain. */
export function wikiRegions(src) {
  const lines = normalizeNewlines(src).split('\n')
  const regions = []
  let plain = []
  let wiki = null
  let opener = ''
  let fence = 0
  const pushPlain = () => {
    if (!plain.length) return
    regions.push({ type: 'plain', text: plain.join('\n') })
    plain = []
  }
  for (const line of lines) {
    if (wiki) {
      if (fence) {
        wiki.push(line)
        if (line.startsWith('`'.repeat(fence))) fence = 0
        continue
      }
      const width = fenceWidth(line)
      if (width) {
        fence = width
        wiki.push(line)
        continue
      }
      if (WIKI_CLOSE_RE.test(line)) {
        regions.push({ type: 'wiki', text: wiki.join('\n') })
        wiki = null
        continue
      }
      wiki.push(line)
      continue
    }
    if (WIKI_OPEN_RE.test(line)) {
      pushPlain()
      opener = line
      wiki = []
      continue
    }
    plain.push(line)
  }
  if (wiki) plain.push(opener, ...wiki)
  pushPlain()
  return regions
}

function wikiBlocks(src) {
  const lines = normalizeNewlines(src).replace(/^\n+|\n+$/g, '').split('\n')
  const blocks = []
  let i = 0
  while (i < lines.length) {
    const line = lines[i]
    if (line.trim() === '') { i += 1; continue }
    const width = fenceWidth(line)
    if (width) {
      let lang = line.slice(width).trim()
      if (!/^[A-Za-z0-9_+#.-]{1,24}$/.test(lang)) lang = ''
      const body = []
      i += 1
      let closed = false
      while (i < lines.length) {
        if (lines[i].startsWith('`'.repeat(width))) { closed = true; i += 1; break }
        body.push(lines[i])
        i += 1
      }
      blocks.push({ type: 'code', text: body.join('\n'), lang, closed })
      continue
    }
    const heading = /^(#{1,3})[ \t]+(\S.*)$/.exec(line)
    if (heading) {
      blocks.push({ type: 'heading', level: heading[1].length, parts: wikiParts(heading[2].trim()) })
      i += 1
      continue
    }
    const ul = /^[-*] /.test(line)
    const ol = /^\d+\. /.test(line)
    if (ul || ol) {
      const items = []
      while (i < lines.length && (ol ? /^\d+\. /.test(lines[i]) : /^[-*] /.test(lines[i]))) {
        const item = lines[i].replace(ol ? /^\d+\. / : /^[-*] /, '')
        items.push({ parts: wikiParts(item) })
        i += 1
      }
      blocks.push({ type: 'list', ordered: ol, items })
      continue
    }
    if (line.startsWith('>')) {
      const quoted = []
      while (i < lines.length && lines[i].startsWith('>')) {
        quoted.push(lines[i].replace(/^>[ \t]?/, ''))
        i += 1
      }
      blocks.push({ type: 'quote', parts: wikiParts(quoted.join('\n')) })
      continue
    }
    const para = []
    while (i < lines.length && lines[i].trim() !== '' && !fenceWidth(lines[i]) && !/^(#{1,3})[ \t]+\S/.test(lines[i]) && !/^[-*] /.test(lines[i]) && !/^\d+\. /.test(lines[i]) && !lines[i].startsWith('>')) {
      para.push(lines[i])
      i += 1
    }
    const parts = wikiParts(para.join('\n'))
    if (parts.length) blocks.push({ type: 'para', parts })
  }
  return blocks
}

function plainBlocks(src) {
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
  return blocks
    .map((b) => (b.type === 'para' ? trimPara(b) : b))
    .filter((b) => b.type === 'code' || b.parts.length > 0)
}

export function parseBody(src) {
  const blocks = []
  for (const region of wikiRegions(src)) {
    blocks.push(...(region.type === 'wiki' ? wikiBlocks(region.text) : plainBlocks(region.text)))
  }
  return blocks
}

/**
 * The start/stop marker for rendered markdown (SPL-73): a fence tagged `md`
 * or `markdown`, any case. Its text renders as markdown (markdown.mjs,
 * MarkdownBlock.vue); every other fence stays a code block. Tag the fence
 * `text` to show markdown source instead.
 */
export function isMarkdownLang(lang) {
  return /^(?:md|markdown)$/i.test(String(lang ?? ''))
}

/** Does the text hold at least one markdown block or {{wiki}} region? */
export function hasMarkdownBlock(src) {
  return wikiRegions(src).some((r) => r.type === 'wiki') ||
    tokenize(src).some((t) => t.type === 'code' && isMarkdownLang(t.lang))
}

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

function partsHtml(parts, origin) {
  return (parts || []).map((p) => {
    if (p.type === 'inline') return `<code>${esc(p.text)}</code>`
    if (p.type === 'strong') return `<strong>${esc(p.text)}</strong>`
    if (p.type === 'em') return `<em>${esc(p.text)}</em>`
    if (p.type === 'mention') return `<span class="mention">${esc(p.text)}</span>`
    if (p.type === 'link') {
      const open = linkOpen(p.href, origin)
      if (!open) return esc(p.text)
      const extra = open.internal ? '' : ` target="_blank" rel="${open.rel}"`
      return `<a class="msg-link" href="${esc(p.href)}"${extra}>${esc(p.text)}</a>`
    }
    return esc(p.text).replace(/\n/g, '<br>')
  }).join('')
}

/**
 * Escaped HTML of a body, for callers that need a string (tests, previews).
 * The WUI itself renders parseBody through MessageBody.vue, not this.
 */
export function bodyToHtml(src, origin) {
  return parseBody(src).map((b) => {
    if (b.type === 'code') {
      const label = b.lang ? ` data-lang="${esc(b.lang)}"` : ''
      return `<pre${label}><code>${esc(b.text)}</code></pre>`
    }
    if (b.type === 'heading') return `<h${b.level + 1}>${partsHtml(b.parts, origin)}</h${b.level + 1}>`
    if (b.type === 'list') {
      const tag = b.ordered ? 'ol' : 'ul'
      return `<${tag}>${b.items.map((item) => `<li>${partsHtml(item.parts, origin)}</li>`).join('')}</${tag}>`
    }
    if (b.type === 'quote') return `<blockquote>${partsHtml(b.parts, origin)}</blockquote>`
    return partsHtml(b.parts, origin)
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
 * What Enter does in the message composer.
 *
 * Owner, 2026-09-23: a bare Enter always inserts a newline, inside a ```
 * block and outside it. Ctrl+Enter and Cmd+Enter send. Shift and Alt do not.
 * `inCode`, `shift` and `alt` stay in the argument so a caller can still pass
 * the key state; they do not change the answer.
 *
 * Message edit does not use this. Enter still commits an edit (msg-edit.mjs,
 * the owner's order of 2026-09-22).
 */
export function enterAction({ mod = false } = {}) {
  return mod ? 'send' : 'newline'
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

/* ---------- markdown without a fence (SPL-975) ---------- */

/*
 * Owner, 2026-09-26 (topic 467d6325): markdown renders WITHOUT a fence, all
 * of the major syntax plus GFM and HTML tables. A body whose text outside
 * ``` blocks holds block or emphasis markdown renders whole as markdown
 * (markdownSource -> markdown.mjs, lazily); every other body keeps parseBody,
 * so a plain line, a **bold** word, a link or a code block renders as before.
 */
const MD_LINE_RES = [
  /^ {0,3}#{1,6}[ \t]+\S/m, // heading
  /^[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t]+\S/m, // bulleted / numbered list
  /^ {0,3}>/m, // quote
]
const MD_SPAN_RES = [
  /(?<![\w*\\])\*(?![\s*])[^*\n]*[^\s*\\]\*(?![\w*])|(?<![\w*\\])\*[^\s*]\*(?![\w*])/, // *em*
  /(?<![\w_\\])_(?![\s_])[^_\n]*[^\s_\\]_(?![\w_])|(?<![\w_\\])_[^\s_]_(?![\w_])/, // _em_
  /~~[^~\n]+~~/, // strike
  /\[[^\]\n]+\]\([^)\s]+\)/, // [link](url)
  /<table[\s>]/i, // HTML table
]
const CELL_SEP = String.raw`[ \t]*:?-+:?[ \t]*`
/* a GFM delimiter row: |---|:-:| or ---|--- or a one-column |---| */
const TABLE_SEP_RE = new RegExp(String.raw`^[ \t]*(?:\|?${CELL_SEP}(?:\|${CELL_SEP})+\|?|\|${CELL_SEP}\|)[ \t]*$`)

function hasPipeTable(s) {
  const lines = s.split('\n')
  return lines.some((l, i) => i > 0 && lines[i - 1].includes('|') && TABLE_SEP_RE.test(l))
}

/** The body's text outside code, `inline code` as a placeholder word. */
function proseOf(src) {
  return tokenize(src).map((t) => (t.type === 'text' ? t.text : t.type === 'inline' ? 'x' : '\n')).join('')
}

/** Does the text outside ``` blocks hold markdown that parseBody would show raw? */
export function looksLikeMarkdown(src) {
  const s = proseOf(src)
  if (MD_LINE_RES.some((re) => re.test(s)) || MD_SPAN_RES.some((re) => re.test(s))) return true
  return hasPipeTable(s)
}

function longestRun(s) {
  let best = 0
  for (const m of String(s).matchAll(/`+/g)) best = Math.max(best, m[0].length)
  return best
}

/**
 * The body as one CommonMark source. The body's own fences stay Slack's
 * (tokenize): a code block is re-fenced on its own lines with a fence longer
 * than any backtick run inside it, a ```md / ```markdown block is unwrapped
 * (its text IS the markdown), and a {{wiki}} / {{/wiki}} line is dropped.
 */
export function markdownSource(src) {
  let out = ''
  const block = (s) => {
    if (out && !out.endsWith('\n')) out += '\n'
    if (out && !out.endsWith('\n\n')) out += '\n'
    out += s + '\n\n'
  }
  for (const region of wikiRegions(src)) {
    if (region.type === 'wiki') { block(region.text); continue }
    for (const t of tokenize(region.text)) {
      if (t.type === 'text') out += t.text
      else if (t.type === 'inline') {
        const fence = '`'.repeat(longestRun(t.text) + 1)
        const pad = t.text.startsWith('`') || t.text.endsWith('`') ? ' ' : ''
        out += fence + pad + t.text + pad + fence
      } else if (isMarkdownLang(t.lang)) block(t.text)
      else {
        const fence = '`'.repeat(Math.max(3, longestRun(t.text) + 1))
        block(fence + (t.lang || '') + '\n' + t.text + '\n' + fence)
      }
    }
  }
  return out.replace(/\n+$/, '')
}

const MENTION_RE = /(?<![\w@])@([A-Z]{2,4}-\d+(?:@[a-z0-9][a-z0-9-]{0,31})?)/g

/** Split rendered markdown text into text / mention parts (MessageRuns). */
export function mentionParts(text) {
  return splitRuns(String(text), MENTION_RE, (m) => ({ type: 'mention', text: '@' + m[1] }))
}
