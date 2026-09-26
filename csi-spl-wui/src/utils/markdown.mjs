/**
 * Markdown compatibility (spec 039, owner 2026-09-26): a fenced block whose
 * language is `md` or `markdown` is rendered as standard markdown - headings,
 * emphasis, lists, tables, quotes, links, code - instead of as code.
 *
 * SAFETY: markdown-it with html:false, so raw HTML inside the block is shown
 * as text and never runs. Links are http, https and mailto only (the same
 * rule as message links, CLE-3494); anything else stays plain text. Every
 * link opens in a new tab with rel="noopener noreferrer nofollow".
 */
import MarkdownIt from 'markdown-it'

const SAFE_LINK = /^(https?:|mailto:)/i

const md = new MarkdownIt({ html: false, linkify: true, typographer: false, breaks: false })
md.validateLink = (url) => SAFE_LINK.test(String(url || '').trim())

const defaultLinkOpen = md.renderer.rules.link_open ||
  ((tokens, idx, options, _env, self) => self.renderToken(tokens, idx, options))
md.renderer.rules.link_open = (tokens, idx, options, env, self) => {
  tokens[idx].attrSet('target', '_blank')
  tokens[idx].attrSet('rel', 'noopener noreferrer nofollow')
  return defaultLinkOpen(tokens, idx, options, env, self)
}

/** The fence languages that mean "render me as markdown". */
export function isMarkdownLang(lang) {
  const l = String(lang || '').trim().toLowerCase()
  return l === 'md' || l === 'markdown'
}

/** HTML for a markdown source; safe to bind with v-html (see SAFETY above). */
export function renderMarkdown(src) {
  return md.render(String(src || ''))
}
