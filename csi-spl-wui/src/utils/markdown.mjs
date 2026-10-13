/**
 * Markdown between a start and a stop marker (spec 040 markdown
 * compatibility; SPL-73, epic SPL-74).
 *
 * The marker is a fence tagged `md` or `markdown` (isMarkdownLang in
 * code-blocks.mjs): everything outside it renders as before. This module
 * turns the text INSIDE one such fence into a tree of plain nodes
 *
 *   node = string                                   text, never markup
 *        | { tag, attrs, children: node[] }         an allow-listed element
 *
 * which MarkdownBlock.vue renders with Vue's h(), never v-html.
 *
 * Why nothing hostile survives:
 *   - markdown-it runs with html: false, so <script>, <iframe>, <img onerror>
 *     and every other raw tag arrive as TEXT tokens, and text is a string here
 *   - the tree is built from an allow-list: a token whose tag is not in TAGS
 *     keeps its children and loses itself, and no token attribute is copied
 *     through; the only attributes are the ones this file writes
 *     (href, title, start, data-align, data-lang)
 *   - a link is an absolute http, https or mailto URL, or a relative URL
 *     that stays on the base origin (link-target.mjs). javascript:, data:,
 *     vbscript:, file:, protocol-relative and a backslash that escapes the
 *     host render as text. Same-origin and relative links have no target;
 *     every other link opens in a new tab (rel=noopener noreferrer nofollow)
 *   - images are never fetched (no network from a message, and the deployed
 *     CSP img-src is self + data: anyway): ![alt](https://x/y.png) becomes a
 *     link to the picture, labelled with its alt text
 *   - no style attribute ever: a table cell's alignment is data-align, styled
 *     by the component
 *   - task lists, footnotes and heading ids (spec 137 T018) are passes of
 *     this file over the tree, not markdown-it plugins; an id is always
 *     ANCHOR_PREFIX + a slug, never text copied as written
 *
 * Pure apart from the markdown-it import: node tests import this file
 * directly; the WUI imports it lazily, only when a page has such a block.
 */
import MarkdownIt from 'markdown-it'
import { classifyHref, linkOpen, NEW_TAB_REL } from './link-target.mjs'
import { docsLinkHref } from './docs.mjs'
import { codeDocHref, docPathParts } from './doc-paths.mjs'

/** Every element the tree may hold. */
export const TAGS = new Set([
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li', 'blockquote', 'hr', 'br',
  'pre', 'code', 'strong', 'em', 's',
  'table', 'thead', 'tbody', 'tfoot', 'caption', 'tr', 'th', 'td',
  'a', 'sup',
])

/** Every attribute the tree may hold, per tag. */
export const ATTRS = {
  a: new Set(['href', 'title']),
  ol: new Set(['start', 'data-footnotes']),
  p: new Set(['data-cite']),
  li: new Set(['id', 'data-task']),
  sup: new Set(['id']),
  h1: new Set(['id']), h2: new Set(['id']), h3: new Set(['id']),
  h4: new Set(['id']), h5: new Set(['id']), h6: new Set(['id']),
  th: new Set(['data-align', 'colspan', 'rowspan']),
  td: new Set(['data-align', 'colspan', 'rowspan']),
  pre: new Set(['data-lang']),
}

const SCHEMES = new Set(['http:', 'https:', 'mailto:'])

/** The href when it is an absolute http / https / mailto URL, else ''. */
export function safeHref(raw) {
  const s = String(raw ?? '').trim()
  if (!s) return ''
  let u
  try {
    u = new URL(s)
  } catch {
    return ''
  }
  if (!SCHEMES.has(u.protocol)) return ''
  if (u.protocol !== 'mailto:' && !u.hostname) return ''
  return u.href
}

const engines = new Map()

/* html: true only for a whole message or description (SPL-975): an HTML
   <table> block then reaches htmlTableNodes' allow-list; every other raw tag
   still arrives as text. A ```md fence keeps html: false. */
function md(html = false) {
  let engine = engines.get(html)
  if (engine) return engine
  engine = new MarkdownIt('default', {
    html,
    linkify: true,
    typographer: false,
    breaks: false,
    maxNesting: 20,
  })
  // bare URLs and addresses only, as outside the marker: no "example.com"
  engine.linkify.set({ fuzzyLink: false, fuzzyEmail: true, fuzzyIP: false })
  // safeHref decides; markdown-it must not drop a link silently, so an
  // unsafe one still shows its text
  engine.validateLink = () => true
  engines.set(html, engine)
  return engine
}

const el = (tag, attrs = {}, children = []) => ({ tag, attrs, children })

function alignOf(tok) {
  const m = /text-align:\s*(left|right|center)/.exec(tok.attrGet('style') || '')
  return m ? m[1] : ''
}

function textOf(children) {
  return (children || []).map((c) => (c.type === 'image' ? textOf(c.children) : c.content || '')).join('')
}

/** Text nodes with each listed doc path a link (SPL-1592, doc-paths.mjs). */
function docPathNodes(s, docPath) {
  if (!docPath) return [s]
  return docPathParts(s, docPath).map((p) => (p.type === 'link' ? el('a', { href: p.href, title: p.href }, [p.text]) : p.text))
}

/** One inline token list -> nodes. `breaks`: a single newline is a <br>.
 * `docsRepo` (a string, '' allowed): a doc link becomes /docs/<path>
 * (docsLinkHref, SPL-1291); undefined leaves every link as written.
 * `docPath` (doc-paths.mjs resolver): a doc path written as text or as a
 * whole `code` span, outside a link, becomes a link (SPL-1592). */
function inline(tokens, breaks = false, docsRepo = undefined, docPath = null) {
  const root = el(null)
  const stack = [root]
  const top = () => stack.at(-1)
  let inLink = 0
  for (const tok of tokens || []) {
    if (tok.type === 'link_open') inLink++
    else if (tok.type === 'link_close' && inLink) inLink--
    const paths = inLink ? null : docPath
    if (tok.nesting === 1) {
      let node
      if (tok.type === 'link_open') {
        const raw = tok.attrGet('href')
        const doc = typeof docsRepo === 'string' ? docsLinkHref(raw, docsRepo) : null
        const href = classifyHref(doc ?? raw)?.href || ''
        node = href ? el('a', { href, title: href }) : el(null)
      } else {
        node = el(TAGS.has(tok.tag) ? tok.tag : null)
      }
      top().children.push(node)
      stack.push(node)
      continue
    }
    if (tok.nesting === -1) {
      if (stack.length > 1) stack.pop()
      continue
    }
    switch (tok.type) {
      case 'softbreak':
        top().children.push(breaks ? el('br') : '\n')
        break
      case 'hardbreak':
        top().children.push(el('br'))
        break
      case 'code_inline': {
        const href = paths ? codeDocHref(tok.content, paths) : ''
        const code = el('code', {}, [tok.content])
        top().children.push(href ? el('a', { href, title: href }, [code]) : code)
        break
      }
      case 'image': {
        const alt = textOf(tok.children)
        const href = safeHref(tok.attrGet('src'))
        const label = alt || href
        top().children.push(href ? el('a', { href, title: href }, [label]) : alt)
        break
      }
      default:
        // text, text_special, html_inline (html is off, but never trust it)
        if (tok.content) top().children.push(...(tok.type === 'text' ? docPathNodes(tok.content, paths) : [tok.content]))
    }
  }
  return root.children
}

/** Merge adjacent strings and unwrap tag-less fragments. */
function tidy(nodes) {
  const out = []
  const push = (k) => {
    if (typeof k === 'string') {
      if (k === '') return
      if (typeof out[out.length - 1] === 'string') out[out.length - 1] += k
      else out.push(k)
    } else out.push(k)
  }
  for (const n of nodes) {
    if (typeof n === 'string') { push(n); continue }
    const kids = tidy(n.children)
    if (n.tag === null) kids.forEach(push)
    else push({ tag: n.tag, attrs: n.attrs, children: kids })
  }
  return out
}

/*
 * HTML tables (owner, SPL-975: "html tables as well"). An html_block that
 * holds a <table> is read by this allow-list, never handed to the browser as
 * markup: table elements plus a few inline ones become tree nodes, every other
 * tag is dropped (its text stays text), script-like elements are dropped with
 * their content, and no attribute is copied except align / text-align
 * (as data-align) and a small numeric colspan / rowspan.
 */
const HTML_MAP = {
  table: 'table', thead: 'thead', tbody: 'tbody', tfoot: 'tfoot', caption: 'caption',
  tr: 'tr', th: 'th', td: 'td',
  b: 'strong', strong: 'strong', i: 'em', em: 'em', s: 's', del: 's', strike: 's',
  code: 'code', br: 'br', p: 'p', ul: 'ul', ol: 'ol', li: 'li',
}
const HTML_DROP = new Set(['script', 'style', 'template', 'iframe', 'object', 'embed', 'noscript',
  'textarea', 'title', 'svg', 'math', 'select', 'xmp', 'noembed', 'noframes', 'plaintext'])
const TABLE_PARTS = new Set(['table', 'thead', 'tbody', 'tfoot', 'tr'])
const HTML_TAG_RE = /<!--[\s\S]*?(?:-->|$)|<(\/?)([A-Za-z][A-Za-z0-9-]*)((?:[^>"']|"[^"]*"|'[^']*')*)>/g
const ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0' }

function decodeEntities(s) {
  return s.replace(/&(#x[0-9a-f]{1,6}|#\d{1,7}|[a-z]{2,8});/gi, (m, e) => {
    if (e[0] !== '#') return ENTITIES[e.toLowerCase()] ?? m
    const cp = e[1] === 'x' || e[1] === 'X' ? Number.parseInt(e.slice(2), 16) : Number.parseInt(e.slice(1), 10)
    if (!(cp > 0 && cp <= 0x10ffff) || (cp >= 0xd800 && cp <= 0xdfff)) return '\ufffd'
    return String.fromCodePoint(cp)
  })
}

/* The attribute and close-tag matchers are built from a FIXED, tiny name set
   (cellAttrs asks for style/align/colspan/rowspan; the close matcher for the
   HTML_DROP tags), so compile each once and reuse it. A table cell hit
   `new RegExp` four times per cell — pure recompilation on the hot path. The
   patterns carry no `g` flag, so `.exec` keeps no state and reuse is safe. */
const ATTR_RE = new Map()
function attrRe(name) {
  let re = ATTR_RE.get(name)
  if (!re) {
    re = new RegExp(`(?:^|\\s)${name}\\s*=\\s*(?:"([^"]*)"|'([^']*)'|([^\\s"'>]+))`, 'i')
    ATTR_RE.set(name, re)
  }
  return re
}

const CLOSE_RE = new Map()
function closeRe(name) {
  let re = CLOSE_RE.get(name)
  if (!re) {
    re = new RegExp(`</${name}\\s*>`, 'i')
    CLOSE_RE.set(name, re)
  }
  return re
}

function attrOf(attrs, name) {
  const m = attrRe(name).exec(attrs)
  return m ? (m[1] ?? m[2] ?? m[3] ?? '') : ''
}

function cellAttrs(attrs) {
  const out = {}
  const style = /text-align\s*:\s*(left|right|center)/i.exec(attrOf(attrs, 'style'))
  const align = [attrOf(attrs, 'align').trim().toLowerCase(), style ? style[1].toLowerCase() : '']
    .find((v) => v === 'left' || v === 'right' || v === 'center')
  if (align) out['data-align'] = align
  for (const k of ['colspan', 'rowspan']) {
    const v = attrOf(attrs, k).trim()
    if (/^\d{1,2}$/.test(v) && Number(v) >= 1 && Number(v) <= 50) out[k] = String(Number(v))
  }
  return out
}

/** The allow-listed nodes of an HTML fragment (see HTML_MAP). */
export function htmlTableNodes(html) {
  const s = String(html ?? '')
  const root = el(null)
  const stack = [root]
  const top = () => stack.at(-1)
  const text = (t) => {
    if (!t) return
    if (TABLE_PARTS.has(top().tag) && !t.trim()) return
    top().children.push(decodeEntities(t))
  }
  const re = new RegExp(HTML_TAG_RE.source, 'g')
  let last = 0
  for (let m = re.exec(s); m; m = re.exec(s)) {
    text(s.slice(last, m.index))
    last = re.lastIndex
    if (m[2] === undefined) continue
    const name = m[2].toLowerCase()
    if (!m[1] && HTML_DROP.has(name)) {
      const c = closeRe(name).exec(s.slice(last))
      last = c ? last + c.index + c[0].length : s.length
      re.lastIndex = last
      continue
    }
    const tag = HTML_MAP[name]
    if (!tag) continue
    if (m[1]) {
      const at = stack.map((n) => n.tag).lastIndexOf(tag)
      if (at > 0) stack.length = at
      continue
    }
    const node = el(tag, tag === 'th' || tag === 'td' ? cellAttrs(m[3]) : {})
    top().children.push(node)
    if (tag !== 'br' && !/\/\s*$/.test(m[3])) stack.push(node)
  }
  text(s.slice(last))
  return tidy(root.children)
}

/*
 * Spec 137 T018 (§1.4, F18-F20): task lists, footnotes and heading ids, so a
 * repo doc reads in the WUI as it reads on a forge. No markdown-it plugin:
 * each is a small pass over the source or over the allow-listed tree, so no
 * attribute is copied from a token and the tree stays the only output.
 *   - a list item that starts with "[ ] " or "[x] " is a task: its li carries
 *     data-task="todo" | "done" (the component draws the box), the marker goes
 *   - "[^id]: note" lines (outside a code fence) are taken out of the source;
 *     each "[^id]" in the text that has a note becomes a superscript number,
 *     and the notes follow the document as one numbered list
 *     (ol data-footnotes), in the order they are first cited
 *   - `anchors` (a document page, not a chat message): each heading has an
 *     id from its text (GitHub's slug rule), a footnote number links to its
 *     note and back, and a "#slug" link finds its heading. Every id is
 *     prefixed with ANCHOR_PREFIX so a heading never clashes with an id of
 *     the page around it, nor shadows a global (DOM clobbering)
 */
export const ANCHOR_PREFIX = 'md-'

const FENCE_OPEN = /^ {0,3}(`{3,}|~{3,})/
const NOTE_DEF = /^ {0,3}\[\^([^\]\s]{1,64})\]:[ \t]?(.*)$/
const NOTE_REF = /\[\^([^\]\s]{1,64})\]/g
const TASK = /^\[([ xX])\][ \t]+/

/**
 * The source without its footnote definitions, and the definitions by id
 * (a definition's indented lines continue it; the first one of an id wins).
 */
export function splitFootnotes(src) {
  const lines = String(src ?? '').split('\n')
  const keep = []
  const notes = new Map()
  let fence = ''
  let note = null
  for (const line of lines) {
    if (fence) {
      keep.push(line)
      if (line.trim().startsWith(fence) && /^\s*([`~])\1*\s*$/.test(line)) fence = ''
      continue
    }
    if (note && /^(?: {4}|\t)\S/.test(line)) {
      note.push(line.replace(/^(?: {4}|\t)/, ''))
      continue
    }
    note = null
    const def = NOTE_DEF.exec(line)
    if (def) {
      note = [def[2]]
      if (!notes.has(def[1])) notes.set(def[1], note)
      continue
    }
    const f = FENCE_OPEN.exec(line)
    if (f) fence = f[1]
    keep.push(line)
  }
  const out = new Map()
  for (const [id, body] of notes) out.set(id, body.join('\n').trim())
  return { body: keep.join('\n'), notes: out }
}

/** GitHub's heading slug: lower case, punctuation dropped, spaces as dashes. */
export function headingSlug(text) {
  return String(text ?? '').trim().toLowerCase().replace(/[^\p{L}\p{M}\p{N}\s_-]/gu, '').replace(/\s/g, '-')
}

function plainText(nodes) {
  return (nodes || []).map((n) => (typeof n === 'string' ? n : plainText(n.children))).join('')
}

/** a task item: its li marked and the "[ ] " marker taken off its first text */
function markTask(li) {
  let host = li
  while (host.children.length && typeof host.children[0] !== 'string' && host.children[0].tag === 'p') host = host.children[0]
  const first = host.children[0]
  if (typeof first !== 'string') return
  const m = TASK.exec(first)
  if (!m) return
  li.attrs = { ...li.attrs, 'data-task': m[1] === ' ' ? 'todo' : 'done' }
  host.children = [first.slice(m[0].length), ...host.children.slice(1)].filter((c) => c !== '')
}

/* spec 137 T011 (owner, t1 b1661d1c "citates"): a quote's last paragraph
   that starts with a dash ("— Source", "-- Source") is its attribution line,
   p[data-cite]; the component sets it apart from the quoted passage */
const CITE = /^(?:\u2014|\u2015|--)(?:\s|$)/
function markCite(q) {
  const last = q.children.at(-1)
  if (q.children.length < 2 || typeof last === 'string' || last.tag !== 'p') return
  if (typeof last.children[0] === 'string' && CITE.test(last.children[0])) last.attrs = { ...last.attrs, 'data-cite': 'true' }
}

const HEADING = new Set(['h1', 'h2', 'h3', 'h4', 'h5', 'h6'])

/**
 * The extras over a finished tree (see the block above). `notes` is
 * splitFootnotes' map, `noteTree` renders one note's markdown.
 */
function gfmExtras(nodes, notes, noteTree, anchors) {
  const order = []
  const slugs = new Map()
  const idOf = (base) => {
    const n = slugs.get(base) ?? 0
    slugs.set(base, n + 1)
    return ANCHOR_PREFIX + (n ? `${base}-${n}` : base)
  }
  const refs = (s) => {
    const out = []
    let last = 0
    for (const m of s.matchAll(NOTE_REF)) {
      if (!notes.has(m[1])) continue
      out.push(s.slice(last, m.index))
      let at = order.indexOf(m[1])
      const first = at < 0
      if (first) at = order.push(m[1]) - 1
      const num = String(at + 1)
      const fid = headingSlug(m[1]) || num
      out.push(anchors
        ? el('sup', first ? { id: `${ANCHOR_PREFIX}fnref-${fid}` } : {}, [el('a', { href: `#${ANCHOR_PREFIX}fn-${fid}`, title: `#${ANCHOR_PREFIX}fn-${fid}` }, [num])])
        : el('sup', {}, [num]))
      last = m.index + m[0].length
    }
    if (!out.length) return [s]
    out.push(s.slice(last))
    return out.filter((c) => c !== '')
  }
  const walk = (list, inText) => list.flatMap((n) => {
    if (typeof n === 'string') return inText && notes.size ? refs(n) : [n]
    if (n.tag === 'li') markTask(n)
    if (n.tag === 'blockquote') markCite(n)
    if (anchors && n.tag === 'a' && /^#./.test(n.attrs.href || '') && !n.attrs.href.startsWith('#' + ANCHOR_PREFIX)) {
      const href = '#' + ANCHOR_PREFIX + n.attrs.href.slice(1)
      n.attrs = { ...n.attrs, href, title: href }
    }
    n.children = walk(n.children, inText && n.tag !== 'code' && n.tag !== 'pre' && n.tag !== 'a')
    if (anchors && HEADING.has(n.tag)) {
      const slug = headingSlug(plainText(n.children))
      if (slug) n.attrs = { ...n.attrs, id: idOf(slug) }
    }
    return [n]
  })
  const out = walk(nodes, true)
  if (!order.length) return out
  const items = order.map((id, i) => {
    const fid = headingSlug(id) || String(i + 1)
    let body = noteTree(notes.get(id))
    if (body.length === 1 && typeof body[0] !== 'string' && body[0].tag === 'p') body = body[0].children
    const back = anchors ? [' ', el('a', { href: `#${ANCHOR_PREFIX}fnref-${fid}`, title: `#${ANCHOR_PREFIX}fnref-${fid}` }, ['↩'])] : []
    return el('li', anchors ? { id: `${ANCHOR_PREFIX}fn-${fid}` } : {}, [...body, ...back])
  })
  return [...out, el('hr'), el('ol', { 'data-footnotes': 'true' }, items)]
}

/**
 * The node tree of one markdown source. Always an array; an empty source is
 * an empty array. `breaks` makes a single newline a <br> and `html` lets an
 * HTML table through htmlTableNodes: both are for a whole message or
 * description (SPL-975); a ```md fence uses neither. `docsRepo` is the
 * repository web URL (cnf repo_web_url, '' = none): set, a link to one of its
 * docs, or a bare repo-relative .md path, opens /docs/<path> (SPL-1291).
 * `docPath` is doc-paths.mjs' resolver: a listed doc path written as text
 * links to its /docs page (SPL-1592); null leaves text as written.
 * `anchors` gives headings and footnotes their ids (spec 137 T018, above):
 * a document page sets it, a chat message does not.
 */
export function markdownTree(src, { anchors = false, ...opts } = {}) {
  const { body, notes } = splitFootnotes(src)
  return gfmExtras(baseTree(body, opts), notes, (note) => baseTree(note, opts), anchors)
}

function baseTree(src, { breaks = false, html = false, docsRepo = undefined, docPath = null } = {}) {
  const tokens = md(html).parse(src, {})
  const root = el(null)
  const stack = [root]
  const top = () => stack.at(-1)
  for (const tok of tokens) {
    if (tok.nesting === 1) {
      let node
      // a tight list's paragraphs are hidden: keep their text, drop the <p>
      if (tok.hidden || !TAGS.has(tok.tag)) node = el(null)
      else if (tok.tag === 'ol') {
        const start = Number.parseInt(tok.attrGet('start') || '', 10)
        node = el('ol', Number.isFinite(start) && start !== 1 ? { start: String(start) } : {})
      } else if (tok.tag === 'th' || tok.tag === 'td') {
        const align = alignOf(tok)
        node = el(tok.tag, align ? { 'data-align': align } : {})
      } else node = el(tok.tag)
      top().children.push(node)
      stack.push(node)
      continue
    }
    if (tok.nesting === -1) {
      if (stack.length > 1) stack.pop()
      continue
    }
    if (tok.type === 'inline') {
      top().children.push(...inline(tok.children, breaks, docsRepo, docPath))
    } else if (tok.type === 'fence' || tok.type === 'code_block') {
      const lang = String(tok.info || '').trim().split(/\s+/)[0].slice(0, 24)
      const text = tok.content.endsWith('\n') ? tok.content.slice(0, -1) : tok.content
      top().children.push(el('pre', lang ? { 'data-lang': lang } : {}, [el('code', {}, [text])]))
    } else if (tok.type === 'hr') {
      top().children.push(el('hr'))
    } else if (tok.type === 'html_block' && html && /<table[\s>]/i.test(tok.content)) {
      top().children.push(...htmlTableNodes(tok.content))
    } else if (tok.content) {
      // html_block and anything unknown: its source, as text
      top().children.push(tok.content)
    }
  }
  return tidy(root.children)
}

function esc(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;')
}

const VOID = new Set(['br', 'hr'])

/**
 * Escaped HTML of a tree, for tests and string callers. The WUI renders the
 * tree through MarkdownBlock.vue, not this. `origin` is the page origin:
 * a same-origin or relative link has no target; everything else is a new
 * tab. Omit origin and every absolute URL is external.
 */
export function treeToHtml(nodes, origin) {
  return (nodes || []).map((n) => {
    if (typeof n === 'string') return esc(n)
    if (!TAGS.has(n.tag)) return treeToHtml(n.children, origin)
    let open = null
    if (n.tag === 'a') {
      open = linkOpen(n.attrs && n.attrs.href, origin)
      if (!open) return treeToHtml(n.children, origin)
    }
    const allowed = ATTRS[n.tag] || new Set()
    // an internal link may be rewritten to the canonical https product URL
    // (SPL-951 regression: a www or http link to this site), so the anchor
    // carries the URL that actually loads; an external link is left as written.
    const outAttrs = open && open.internal ? { ...n.attrs, href: open.href } : n.attrs
    let attrs = Object.entries(outAttrs || {})
      .filter(([k]) => allowed.has(k))
      .map(([k, v]) => ` ${k}="${esc(v)}"`)
      .join('')
    if (open && !open.internal) attrs += ` target="_blank" rel="${NEW_TAB_REL}"`
    if (VOID.has(n.tag)) return `<${n.tag}${attrs}>`
    return `<${n.tag}${attrs}>${treeToHtml(n.children, origin)}</${n.tag}>`
  }).join('')
}

/** Markdown source -> escaped, allow-listed HTML. */
export function markdownToHtml(src, origin, opts) {
  return treeToHtml(markdownTree(src, opts), origin)
}

/** spec 040's first name for markdownToHtml (1c099b52). */
export const renderMarkdown = markdownToHtml
