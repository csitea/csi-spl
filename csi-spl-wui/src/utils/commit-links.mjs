/**
 * Git commit hashes written in a message become links to the repository
 * (HUM-10): <repoWebUrl><repoCommitPath><hash>. Both come from cnf
 * (env.wui.repo_web_url, env.wui.repo_commit_path), served per instance in
 * /config.json; either one empty = the feature is off and a hash stays text.
 * Nothing here names a forge or a repository: the path shape is the cnf's
 * (GitHub /commit/, GitLab /-/commit/).
 *
 * A commit is a 7..40 hex token with at least one digit and one letter,
 * standing on its own: not part of a longer word, a uuid or a hyphenated id.
 * Code fences, inline code, an existing link (an id link included, which
 * runs first) and a bare url are left as written, the id-link rules.
 *
 * Loaded lazily (plugins/commit-links.client.ts) and reached through
 * utils/commit-link-hook.mjs, so the initial chunk does not grow. Pure: node
 * tests import this file directly.
 */

const HASH_RE = /(?<![0-9A-Za-z_\-/.#@])[0-9a-fA-F]{7,40}(?![0-9A-Za-z_\-/@]|\.[0-9A-Za-z])/g
const HAS_RUN = /[0-9a-fA-F]{7}/
const MD_LANG = /^(?:md|markdown)$/i

/* closed fences, inline code, markdown links, and bare urls (id-links.mjs) */
const PROTECT_RE = /```[\s\S]*?```|`{1,2}[^`\n]+`{1,2}|\[[^\]\n]+\]\([^)\n]+\)|https?:\/\/[^\s<>)\]]+|www\.[^\s<>)\]]+/gi

/** An http(s) url with no trailing slash, or '' when it is not one. */
export function repoBase(url) {
  const s = String(url ?? '').trim().replace(/\/+$/, '')
  return /^https?:\/\/[^\s"'<>]+$/i.test(s) ? s : ''
}

/** A url path that starts and ends with '/', or '' when it is not one. */
export function repoPath(path) {
  const s = String(path ?? '').trim()
  return /^\/[^\s"'<>?#]*\/$/.test(s) ? s : ''
}

/** Does the token read as a commit hash (not a word, not a plain number)? */
export function isCommitHash(token) {
  const s = String(token ?? '')
  return /^[0-9a-fA-F]{7,40}$/.test(s) && /[0-9]/.test(s) && /[a-fA-F]/.test(s)
}

/** The commit url prefix from the two cnf values, or '' (feature off). */
export function commitPrefix(webUrl, commitPath) {
  const b = repoBase(webUrl)
  const p = repoPath(commitPath)
  return b && p ? b + p : ''
}

/** <prefix><hash>, or '' when either is not usable. */
export function commitHref(prefix, hash) {
  if (!prefix || !isCommitHash(hash)) return ''
  return prefix + String(hash).toLowerCase()
}

function protectRanges(s) {
  const ranges = []
  PROTECT_RE.lastIndex = 0
  for (const m of s.matchAll(PROTECT_RE)) ranges.push([m.index, m.index + m[0].length])
  const openAt = s.lastIndexOf('```')
  if (openAt >= 0 && !ranges.some(([a, b]) => openAt >= a && openAt < b)) ranges.push([openAt, s.length])
  return ranges
}

function findHits(s) {
  const ranges = protectRanges(s)
  const hits = []
  HASH_RE.lastIndex = 0
  for (const m of s.matchAll(HASH_RE)) {
    const start = m.index
    const end = start + m[0].length
    if (!isCommitHash(m[0]) || ranges.some(([a, z]) => start >= a && end <= z)) continue
    hits.push({ start, end })
  }
  return hits
}

/** Text parts and link parts. `prefix` is commitPrefix(); '' = unchanged. */
export function linkifyCommitText(text, prefix) {
  const s = String(text ?? '')
  if (!prefix || !HAS_RUN.test(s)) return [{ type: 'text', text: s }]
  const hits = findHits(s)
  if (!hits.length) return [{ type: 'text', text: s }]
  const parts = []
  let last = 0
  for (const h of hits) {
    if (h.start > last) parts.push({ type: 'text', text: s.slice(last, h.start) })
    const hash = s.slice(h.start, h.end)
    parts.push({ type: 'link', text: hash, href: commitHref(prefix, hash) })
    last = h.end
  }
  if (last < s.length) parts.push({ type: 'text', text: s.slice(last) })
  return parts
}

/** The same markdown, a hash written as a link; code and links untouched. */
export function linkifyCommitMarkdown(src, prefix) {
  const s = String(src ?? '')
  const parts = linkifyCommitText(s, prefix)
  if (parts.length === 1 && parts[0].type === 'text') return s
  return parts.map((p) => (p.type === 'link' ? '[' + p.text + '](' + p.href + ')' : p.text)).join('')
}

function linkifyParts(parts, prefix) {
  const out = []
  for (const p of parts || []) {
    if (p && (p.type === 'text' || p.type === 'strong' || p.type === 'em') && typeof p.text === 'string') {
      const bits = linkifyCommitText(p.text, prefix)
      if (bits.length === 1 && bits[0].type === 'text') out.push(p)
      else for (const x of bits) out.push(x.type === 'link' ? x : { ...p, text: x.text })
      continue
    }
    out.push(p)
  }
  return out
}

/** A parseBody tree with hashes in text linked; code and links left alone. */
export function linkifyCommitBlocks(blocks, prefix) {
  if (!prefix || !Array.isArray(blocks)) return blocks
  return blocks.map((b) => {
    if (!b) return b
    if (b.type === 'code') {
      if (!MD_LANG.test(String(b.lang || ''))) return b
      const text = linkifyCommitMarkdown(b.text, prefix)
      return text === b.text ? b : { ...b, text }
    }
    if (Array.isArray(b.parts)) return { ...b, parts: linkifyParts(b.parts, prefix) }
    if (Array.isArray(b.items)) {
      return { ...b, items: b.items.map((it) => ({ ...it, parts: linkifyParts(it.parts, prefix) })) }
    }
    return b
  })
}

/** The linker utils/commit-link-hook.mjs holds: null when either value is unset. */
export function commitLinker(webUrl, commitPath) {
  const prefix = commitPrefix(webUrl, commitPath)
  if (!prefix) return null
  return {
    blocks: (blocks) => linkifyCommitBlocks(blocks, prefix),
    markdown: (src) => linkifyCommitMarkdown(src, prefix),
  }
}
