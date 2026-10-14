/**
 * SPL-1592 (owner HUM-10, t1 cda174ef): a repo doc written as plain text,
 * "Source: csi-spl-doc/specs/002-box-agent-messaging/tasks.md", is a link to
 * that doc's page, /docs/<path>, in every message card, every issue field
 * and every doc the docs pages render.
 *
 * A reference is a path of at least two segments ending in .md, an optional
 * #anchor kept, written on its own (not part of a url, a word or a longer
 * path). A leading /, ./ or ../ is dropped. It links only to a doc the docs
 * store lists (tree.json): the exact path, else the ONE listed doc that ends
 * with it ("specs/072-x/spec.md"). An unknown path, or one that ends two
 * listed docs, stays text: never a dead link.
 * `inline code` links only when the whole span is such a path. Fences,
 * existing links and urls are never touched (the callers hand only text).
 *
 * Loaded lazily (doc-path-install.ts) and reached through
 * utils/doc-path-hook.mjs. Pure: node tests import this file directly.
 */
import { docsRoute, validDocsPath } from './docs.mjs'

const SEG = '[A-Za-z0-9_-][A-Za-z0-9._-]*'
const PATH_SRC = String.raw`(?:\/|(?:\.\.?\/)+)?(?:${SEG}\/)+${SEG}\.md(?:#[\w-]+)?`
/* not inside a url, an email, a word or a longer path; not "x.md.bak" */
const PATH_RE = new RegExp(String.raw`(?<![\w.\/:@~-])${PATH_SRC}(?![\w\/-]|\.\w)`, 'g')
const WHOLE_RE = new RegExp(String.raw`^${PATH_SRC}$`)

/** Cheap pre-check: could the text hold a doc path at all? */
export function mayHoldDocPath(text) {
  return /[\w-]\/[\w./-]*\.md\b/.test(String(text ?? ''))
}

/**
 * The resolver over the listed doc paths: raw reference -> /docs/<path>
 * (+ anchor), or '' when it is not exactly one listed doc.
 */
export function docPathResolver(paths, route = docsRoute) {
  const known = new Set((Array.isArray(paths) ? paths : []).filter(validDocsPath))
  const memo = new Map()
  const find = (p) => {
    if (memo.has(p)) return memo.get(p)
    let hit = ''
    if (known.has(p)) hit = p
    else {
      const tail = '/' + p
      for (const k of known) {
        if (!k.endsWith(tail)) continue
        if (hit) { hit = ''; break }
        hit = k
      }
      /* a checkout path, /opt/<dir>/<repo path>: the longest listed tail */
      const segs = p.split('/')
      for (let i = 1; !hit && i < segs.length - 1; i++) {
        const t = segs.slice(i).join('/')
        if (known.has(t)) hit = t
      }
    }
    memo.set(p, hit)
    return hit
  }
  return (raw) => {
    const s = String(raw ?? '').trim()
    const at = s.indexOf('#')
    const anchor = at >= 0 ? s.slice(at) : ''
    const p = (at >= 0 ? s.slice(0, at) : s).replace(/^\/+/, '').replace(/^(?:\.\.?\/)+/, '')
    if (!validDocsPath(p)) return ''
    const hit = find(p)
    return hit ? route(hit) + anchor : ''
  }
}

/** Text parts and link parts of one plain text. */
export function docPathParts(text, resolve) {
  const s = String(text ?? '')
  if (typeof resolve !== 'function' || !mayHoldDocPath(s)) return [{ type: 'text', text: s }]
  const parts = []
  let last = 0
  for (const m of s.matchAll(PATH_RE)) {
    const href = resolve(m[0])
    if (!href) continue
    if (m.index > last) parts.push({ type: 'text', text: s.slice(last, m.index) })
    parts.push({ type: 'link', text: m[0], href })
    last = m.index + m[0].length
  }
  if (!parts.length) return [{ type: 'text', text: s }]
  if (last < s.length) parts.push({ type: 'text', text: s.slice(last) })
  return parts
}

/** The href of an `inline code` span that is wholly a listed doc path, or ''. */
export function codeDocHref(code, resolve) {
  const s = String(code ?? '').trim()
  return typeof resolve === 'function' && WHOLE_RE.test(s) ? resolve(s) : ''
}

function linkParts(parts, resolve) {
  const out = []
  for (const p of parts || []) {
    if (p && p.type === 'inline' && typeof p.text === 'string') {
      const href = codeDocHref(p.text, resolve)
      out.push(href ? { type: 'link', text: p.text, href, code: true } : p)
      continue
    }
    if (p && (p.type === 'text' || p.type === 'strong' || p.type === 'em') && typeof p.text === 'string') {
      const bits = docPathParts(p.text, resolve)
      if (bits.length === 1 && bits[0].type === 'text') out.push(p)
      else for (const x of bits) out.push(x.type === 'link' ? x : { ...p, text: x.text })
      continue
    }
    out.push(p)
  }
  return out
}

/** A parseBody tree with doc paths linked; code blocks and links untouched. */
export function linkDocPathBlocks(blocks, resolve) {
  if (typeof resolve !== 'function' || !Array.isArray(blocks)) return blocks
  return blocks.map((b) => {
    if (!b || b.type === 'code') return b
    if (Array.isArray(b.parts)) return { ...b, parts: linkParts(b.parts, resolve) }
    if (Array.isArray(b.items)) return { ...b, items: b.items.map((it) => ({ ...it, parts: linkParts(it.parts, resolve) })) }
    return b
  })
}

/** The linker utils/doc-path-hook.mjs holds. */
export function docPathLinker(paths, route) {
  const resolve = docPathResolver(paths, route)
  return { resolve, blocks: (blocks) => linkDocPathBlocks(blocks, resolve) }
}
