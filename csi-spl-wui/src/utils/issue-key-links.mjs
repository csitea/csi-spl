/**
 * Issue keys written in a message become links to the issue (HUM-10, t1
 * 0f2ed820 msg 98b9fae0: "the SPL code for those is converted into internal
 * links"): <PREFIX>-<n> opens /issues?issue=<KEY> in this tab. The prefix is
 * the workspace's own, as the hub's issue list reports it; nothing here names
 * one. No prefix = the feature is off and a key stays text.
 *
 * A key stands on its own: not part of a longer word (XSPL-1, SPL-12a), a
 * path or a host. Code fences, an existing link and a bare url are left as
 * written. An inline code span that holds only the key links too, shown as
 * code. Another workspace's prefix stays text.
 *
 * Loaded lazily (plugins/issue-links.client.ts) and reached through
 * utils/issue-link-hook.mjs, so the initial chunk does not grow. Pure: node
 * tests import this file directly.
 */

const MD_LANG = /^(?:md|markdown)$/i

/* closed fences, inline code, markdown links, and bare urls (commit-links.ts) */
const PROTECT_RE = /```[\s\S]*?```|`{1,2}[^`\n]+`{1,2}|\[[^\]\n]+\]\([^)\n]+\)|https?:\/\/[^\s<>)\]]+|www\.[^\s<>)\]]+/gi

/** The prefix as the hub stores it (upper case), or '' when it is not one. */
export function issueKeyPrefix(prefix) {
  const v = String(prefix ?? '').trim().toUpperCase()
  return /^[A-Z][A-Z0-9]{0,9}$/.test(v) ? v : ''
}

function keyRe(prefix) {
  return new RegExp(`(?<![0-9A-Za-z_\\-/.#@])${prefix}-[1-9][0-9]{0,8}(?![0-9A-Za-z_\\-/@]|\\.[0-9A-Za-z])`, 'g')
}

/** Is the text exactly one key of this prefix? */
export function isIssueKey(prefix, text) {
  const p = issueKeyPrefix(prefix)
  return Boolean(p) && new RegExp(`^${p}-[1-9][0-9]{0,8}$`).test(String(text ?? ''))
}

/** /issues?issue=<KEY> through pathFor (the locale prefix), or '' when not a key. */
export function issueHref(prefix, key, pathFor) {
  if (!isIssueKey(prefix, key)) return ''
  const path = '/issues?issue=' + encodeURIComponent(String(key))
  const out = typeof pathFor === 'function' ? pathFor(path) : path
  return String(out || path)
}

function protectRanges(s) {
  const ranges = []
  for (const m of s.matchAll(PROTECT_RE)) ranges.push([m.index, m.index + m[0].length])
  const openAt = s.lastIndexOf('```')
  if (openAt >= 0 && !ranges.some(([a, b]) => openAt >= a && openAt < b)) ranges.push([openAt, s.length])
  return ranges
}

/** Text parts and link parts; '' prefix = unchanged. */
export function linkifyIssueText(text, prefix, pathFor) {
  const s = String(text ?? '')
  const p = issueKeyPrefix(prefix)
  if (!p || !s.includes(p + '-')) return [{ type: 'text', text: s }]
  const ranges = protectRanges(s)
  const parts = []
  let last = 0
  for (const m of s.matchAll(keyRe(p))) {
    const start = m.index
    const end = start + m[0].length
    if (ranges.some(([a, z]) => start >= a && end <= z)) continue
    if (start > last) parts.push({ type: 'text', text: s.slice(last, start) })
    parts.push({ type: 'link', text: m[0], href: issueHref(p, m[0], pathFor) })
    last = end
  }
  if (!parts.length) return [{ type: 'text', text: s }]
  if (last < s.length) parts.push({ type: 'text', text: s.slice(last) })
  return parts
}

/** The same markdown, a key written as a link; code and links untouched. */
export function linkifyIssueMarkdown(src, prefix, pathFor) {
  const s = String(src ?? '')
  const parts = linkifyIssueText(s, prefix, pathFor)
  if (parts.length === 1 && parts[0].type === 'text') return s
  return parts.map((x) => (x.type === 'link' ? '[' + x.text + '](' + x.href + ')' : x.text)).join('')
}

/** An inline code span that is only a key: its href, or ''. */
export function inlineIssueHref(prefix, text, pathFor) {
  const s = String(text ?? '').trim()
  return issueHref(prefix, s, pathFor)
}

function linkifyParts(parts, prefix, pathFor) {
  const out = []
  for (const p of parts || []) {
    if (p && p.type === 'inline') {
      const href = inlineIssueHref(prefix, p.text, pathFor)
      out.push(href ? { type: 'link', text: String(p.text).trim(), href, code: true } : p)
      continue
    }
    if (p && (p.type === 'text' || p.type === 'strong' || p.type === 'em') && typeof p.text === 'string') {
      const bits = linkifyIssueText(p.text, prefix, pathFor)
      if (bits.length === 1 && bits[0].type === 'text') out.push(p)
      else for (const x of bits) out.push(x.type === 'link' ? x : { ...p, text: x.text })
      continue
    }
    out.push(p)
  }
  return out
}

/** A parseBody tree with keys linked; fences and links left alone. */
export function linkifyIssueBlocks(blocks, prefix, pathFor) {
  if (!issueKeyPrefix(prefix) || !Array.isArray(blocks)) return blocks
  return blocks.map((b) => {
    if (!b) return b
    if (b.type === 'code') {
      if (!MD_LANG.test(String(b.lang || ''))) return b
      const text = linkifyIssueMarkdown(b.text, prefix, pathFor)
      return text === b.text ? b : { ...b, text }
    }
    if (Array.isArray(b.parts)) return { ...b, parts: linkifyParts(b.parts, prefix, pathFor) }
    if (Array.isArray(b.items)) {
      return { ...b, items: b.items.map((it) => ({ ...it, parts: linkifyParts(it.parts, prefix, pathFor) })) }
    }
    return b
  })
}

/** The linker utils/issue-link-hook.mjs holds: null when the prefix is unset. */
export function issueLinker(prefix, pathFor) {
  const p = issueKeyPrefix(prefix)
  if (!p) return null
  return {
    blocks: (blocks) => linkifyIssueBlocks(blocks, p, pathFor),
    markdown: (src) => linkifyIssueMarkdown(src, p, pathFor),
    inline: (text) => inlineIssueHref(p, text, pathFor),
  }
}
