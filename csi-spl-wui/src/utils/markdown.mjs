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
 *   - a link's href must parse as an absolute http, https or mailto URL, the
 *     same three schemes as the plain-text linkify; anything else (javascript:,
 *     data:, vbscript:, file:, relative paths) renders as its text alone
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

/** Every element the tree may hold. */
export const TAGS = new Set([
  'p', 'h1', 'h2', 'h3', 'h4', 'h5', 'h6',
  'ul', 'ol', 'li', 'blockquote', 'hr', 'br',
  'pre', 'code', 'strong', 'em', 's',
  'table', 'thead', 'tbody', 'tr', 'th', 'td',
  'a',
])

/** Every attribute the tree may hold, per tag. */
export const ATTRS = {
  a: new Set(['href', 'title']),
  ol: new Set(['start']),
  th: new Set(['data-align']),
  td: new Set(['data-align']),
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

let engine = null

function md() {
  if (engine) return engine
  engine = new MarkdownIt('default', {
    html: false,
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

/** One inline token list -> nodes. */
function inline(tokens) {
  const root = el(null)
  const stack = [root]
  const top = () => stack[stack.length - 1]
  for (const tok of tokens || []) {
    if (tok.nesting === 1) {
      let node
      if (tok.type === 'link_open') {
        const href = safeHref(tok.attrGet('href'))
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
        top().children.push('\n')
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

/**
 * The node tree of one markdown source. Always an array; an empty source is
 * an empty array.
 */
export function markdownTree(src) {
  const tokens = md().parse(String(src ?? ''), {})
  const root = el(null)
  const stack = [root]
  const top = () => stack[stack.length - 1]
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
      top().children.push(...inline(tok.children))
    } else if (tok.type === 'fence' || tok.type === 'code_block') {
      const lang = String(tok.info || '').trim().split(/\s+/)[0].slice(0, 24)
      const text = tok.content.endsWith('\n') ? tok.content.slice(0, -1) : tok.content
      top().children.push(el('pre', lang ? { 'data-lang': lang } : {}, [el('code', {}, [text])]))
    } else if (tok.type === 'hr') {
      top().children.push(el('hr'))
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
 * tree through MarkdownBlock.vue, not this; links carry the component's
 * target and rel.
 */
export function treeToHtml(nodes) {
  return (nodes || []).map((n) => {
    if (typeof n === 'string') return esc(n)
    if (!TAGS.has(n.tag)) return treeToHtml(n.children)
    const allowed = ATTRS[n.tag] || new Set()
    let attrs = Object.entries(n.attrs || {})
      .filter(([k]) => allowed.has(k))
      .map(([k, v]) => ` ${k}="${esc(v)}"`)
      .join('')
    if (n.tag === 'a') attrs += ' target="_blank" rel="noopener noreferrer nofollow"'
    if (VOID.has(n.tag)) return `<${n.tag}${attrs}>`
    return `<${n.tag}${attrs}>${treeToHtml(n.children)}</${n.tag}>`
  }).join('')
}

/** Markdown source -> escaped, allow-listed HTML. */
export function markdownToHtml(src) {
  return treeToHtml(markdownTree(src))
}

/** spec 040's first name for markdownToHtml (1c099b52). */
export const renderMarkdown = markdownToHtml
