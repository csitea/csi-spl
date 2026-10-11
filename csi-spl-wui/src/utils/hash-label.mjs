/**
 * A link whose visible text is a full git hash (40 hex), or a url whose last
 * path part is one, reads short: the first 8 characters and "..." (owner, t1
 * da98036e msg 8bfe3812: "Shorten them to 8 characters and add three dots").
 * The href keeps the full hash and the hover (title) shows it. Any other
 * text, an 8-char hash or a word included, stays as written.
 *
 * Pure and tiny: MessageRuns (initial chunk), MarkdownBlock and the release
 * notes dialog share it; node tests import this file directly.
 */

const FULL_RE = /^[0-9a-f]{40}$/i
const URL_END_RE = /^(?:https?:\/\/|www\.)\S*\/([0-9a-f]{40})\/?$/i

/** The first 8 characters of a hash and "...". */
export function shortHash(hash) {
  return String(hash ?? '').slice(0, 8) + '...'
}

/** { text, title } for a full hash or a url ending in one, else null. */
export function shortHashLabel(text) {
  const s = String(text ?? '').trim()
  const hash = FULL_RE.test(s) ? s : URL_END_RE.exec(s)?.[1]
  return hash ? { text: shortHash(hash), title: hash } : null
}
