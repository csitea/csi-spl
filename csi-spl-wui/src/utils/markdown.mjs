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
 *
 * Pure apart from the markdown-it import: node tests import this file
 * directly; the WUI imports it lazily, only when a page has such a block.
 */
import MarkdownIt from 'markdown-it'
import { classifyHref, linkOpen, NEW_TAB_REL } from './link-target.mjs'
import { docsLinkHref } from './docs.mjs'

/** Every element the tree may hold. */
export const TAGS = new Set([
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li', 'blockquote', 'hr', 'br',
  'pre', 'code', 'strong', 'em', 's',
  'table', 'thead', 'tbody', 'tfoot', 'caption', 'tr', 'th', 'td',
  'a',
])

/** Every attribute the tree may hold, per tag. */
export const ATTRS = {
  a: new Set(['href', 'title']),
  ol: new Set(['start']),
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

/** One inline token list -> nodes. `breaks`: a single newline is a <br>.
 * `docsRepo` (a string, '' allowed): a doc link becomes /docs/<path>
 * (docsLinkHref, SPL-1291); undefined leaves every link as written. */
function inline(tokens, breaks = false, docsRepo = undefined) {
  const root = el(null)
  const stack = [root]
  const top = () => stack.at(-1)
  for (const tok of tokens || []) {
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
      case 'code_inline':
        top().children.push(el('code', {}, [tok.content]))
        break
      case 'image': {
        const alt = textOf(tok.children)
        const href = safeHref(tok.attrGet('src'))
        const label = alt || href
        top().children.push(href ? el('a', { href, title: href }, [label]) : alt)
        break
      }
      default:
        // text, text_special, html_inline (html is off, but never trust it)
        if (tok.content) top().children.push(tok.content)
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

/**
 * The node tree of one markdown source. Always an array; an empty source is
 * an empty array. `breaks` makes a single newline a <br> and `html` lets an
 * HTML table through htmlTableNodes: both are for a whole message or
 * description (SPL-975); a ```md fence uses neither. `docsRepo` is the
 * repository web URL (cnf repo_web_url, '' = none): set, a link to one of its
 * docs, or a bare repo-relative .md path, opens /docs/<path> (SPL-1291).
 */
export function markdownTree(src, { breaks = false, html = false, docsRepo = undefined } = {}) {
  const tokens = md(html).parse(String(src ?? ''), {})
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
      top().children.push(...inline(tok.children, breaks, docsRepo))
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
