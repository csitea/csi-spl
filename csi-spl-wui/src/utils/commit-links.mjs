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
 * Code fences, an existing link (an id link included, which runs first) and
 * a bare url are left as written, the id-link rules. An inline code span
 * whose whole content is a hash links too (HUM-10 t1 0f2ed820 msg 8847e183:
 * agents write shas as `368450c92`), shown as code; an 8-hex span that is a
 * known topic or message id (isId) stays an id, never a commit.
 *
 * Loaded lazily (plugins/commit-links.client.ts) and reached through
 * utils/commit-link-hook.mjs, so the initial chunk does not grow. Pure: node
 * tests import this file directly.
 */

const HASH_RE = /(?<![0-9A-Za-z_\-/.#@])[0-9a-fA-F]{7,40}(?![0-9A-Za-z_\-/@]|\.[0-9A-Za-z])/g
const HAS_RUN = /[0-9a-fA-F]{7}/
const MD_LANG = /^(?:md|markdown)$/i
/* HUM-10 t1 67e2039a (SPL-1164 "in topic bea3a4e6"): a hex the text names as
   a topic, discussion or message is an id, never a commit */
const ID_WORD_RE = /\b(?:topics?|discussions?|threads?|msgs?|messages?|replies|reply|task(?:_id)?|msg_id)\s*(?:id\s*)?[:#=]?\s*$/i

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

/**
 * A release note's commit: its sha is a commit by definition, so an
 * all-digit one links too. <prefix><sha>, or '' when either is not usable.
 */
export function shaHref(prefix, sha) {
  const s = String(sha ?? '')
  return prefix && /^[0-9a-fA-F]{7,40}$/.test(s) ? prefix + s.toLowerCase() : ''
}

function protectRanges(s) {
  const ranges = []
  PROTECT_RE.lastIndex = 0
  for (const m of s.matchAll(PROTECT_RE)) ranges.push([m.index, m.index + m[0].length])
  const openAt = s.lastIndexOf('```')
  if (openAt >= 0 && !ranges.some(([a, b]) => openAt >= a && openAt < b)) ranges.push([openAt, s.length])
  return ranges
}

/** Is the hex at start an id: a known topic/message (isId) or named as one? */
function namedAsId(s, start, token, isId) {
  if (typeof isId === 'function' && isId(token)) return true
  return ID_WORD_RE.test(s.slice(Math.max(0, start - 24), start))
}

function findHits(s, isId) {
  const ranges = protectRanges(s)
  const hits = []
  HASH_RE.lastIndex = 0
  for (const m of s.matchAll(HASH_RE)) {
    const start = m.index
    const end = start + m[0].length
    if (!isCommitHash(m[0]) || ranges.some(([a, z]) => start >= a && end <= z) || namedAsId(s, start, m[0], isId)) continue
    hits.push({ start, end })
  }
  return hits
}

/**
 * Text parts and link parts. `prefix` is commitPrefix(); '' = unchanged.
 * isId(token) = an id the id linker owns (never a commit).
 */
export function linkifyCommitText(text, prefix, isId) {
  const s = String(text ?? '')
  if (!prefix || !HAS_RUN.test(s)) return [{ type: 'text', text: s }]
  const hits = findHits(s, isId)
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
export function linkifyCommitMarkdown(src, prefix, isId) {
  const s = String(src ?? '')
  const parts = linkifyCommitText(s, prefix, isId)
  if (parts.length === 1 && parts[0].type === 'text') return s
  return parts.map((p) => (p.type === 'link' ? '[' + p.text + '](' + p.href + ')' : p.text)).join('')
}

/** An inline code span that is only a hash: its commit href, or ''. before = the text in front of it. */
export function inlineCommitHref(prefix, text, isId, before = '') {
  const s = String(text ?? '').trim()
  if (!isCommitHash(s) || (typeof isId === 'function' && isId(s)) || ID_WORD_RE.test(String(before).slice(-24))) return ''
  return commitHref(prefix, s)
}

function linkifyParts(parts, prefix, isId) {
  const out = []
  let before = ''
  for (const p of parts || []) {
    const after = p && typeof p.text === 'string' ? p.text : ''
    if (p && p.type === 'inline') {
      const href = inlineCommitHref(prefix, p.text, isId, before)
      before = after
      out.push(href ? { type: 'link', text: String(p.text).trim(), href, code: true } : p)
      continue
    }
    before = after
    if (p && (p.type === 'text' || p.type === 'strong' || p.type === 'em') && typeof p.text === 'string') {
      const bits = linkifyCommitText(p.text, prefix, isId)
      if (bits.length === 1 && bits[0].type === 'text') out.push(p)
      else for (const x of bits) out.push(x.type === 'link' ? x : { ...p, text: x.text })
      continue
    }
    out.push(p)
  }
  return out
}

/**
 * A parseBody tree with hashes in text and hash-only code spans linked;
 * fences and links left alone. isId(token) = an id the id linker owns.
 */
export function linkifyCommitBlocks(blocks, prefix, isId) {
  if (!prefix || !Array.isArray(blocks)) return blocks
  return blocks.map((b) => {
    if (!b) return b
    if (b.type === 'code') {
      if (!MD_LANG.test(String(b.lang || ''))) return b
      const text = linkifyCommitMarkdown(b.text, prefix)
      return text === b.text ? b : { ...b, text }
    }
    if (Array.isArray(b.parts)) return { ...b, parts: linkifyParts(b.parts, prefix, isId) }
    if (Array.isArray(b.items)) {
      return { ...b, items: b.items.map((it) => ({ ...it, parts: linkifyParts(it.parts, prefix, isId) })) }
    }
    return b
  })
}

/** The linker utils/commit-link-hook.mjs holds: null when either value is unset. */
export function commitLinker(webUrl, commitPath) {
  const prefix = commitPrefix(webUrl, commitPath)
  if (!prefix) return null
  return {
    blocks: (blocks, isId) => linkifyCommitBlocks(blocks, prefix, isId),
    markdown: (src, isId) => linkifyCommitMarkdown(src, prefix, isId),
    inline: (text, isId, before) => inlineCommitHref(prefix, text, isId, before),
  }
}
