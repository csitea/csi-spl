/**
 * Code viewing: size limits, bounded previews, and the token shape the
 * highlighter hands to the renderer.
 *
 * Owner (2026-09-19): "the code snippets must not have horizontal scrolling,
 * if the code is too big it should have a small icon based 'open' to open it
 * fully … if the source code snippet is greater than 3 A4, then an error
 * during the upload should be presented prompting to do a file upload
 * instead".
 *
 * This module is the ONE place both numbers live — the send limit ("3 A4")
 * and the preview cut — so a component, a test and the spec can never quote
 * three different values. It is pure: node tests import it directly, and it
 * never touches the DOM, i18n or the highlighter.
 *
 * NOTHING here produces markup. The token functions return `{ text, cls }`,
 * where `text` is a raw string the WUI renders with Vue text interpolation
 * and `cls` is a class name from the grammar — so a `<script>` in a message
 * body stays eight characters of text, exactly as it does in MessageBody.vue
 * (013 FR-010, 4c204d0).
 */

import { normalizeNewlines, parseBody } from './code-blocks.mjs'

/* ---------- the size of a page ---------- */

/**
 * One A4 page of monospace source, printed: 50 lines of up to ~60 effective
 * columns. Deliberately a round, explainable pair rather than a typographic
 * calculation — the user-facing promise is "about three printed pages", and
 * whichever of the two runs out first ends the page.
 */
export const A4_PAGE = Object.freeze({ lines: 50, chars: 3000 })

/** The owner's cut: a snippet bigger than this is a file, not a message. */
export const MAX_SEND_PAGES = 3

/** The send limit in the units a message is measured in. */
export const SEND_LIMIT = Object.freeze({
  lines: A4_PAGE.lines * MAX_SEND_PAGES,
  chars: A4_PAGE.chars * MAX_SEND_PAGES,
})

/**
 * The bounded preview shown inside a message card. A card is a glance, not a
 * reading surface: past this the snippet collapses to its first lines and the
 * rest is one click away in the dialog.
 */
export const PREVIEW_LIMIT = Object.freeze({ lines: 20, chars: 1200 })

/* ---------- measuring ---------- */

/** Lines in `text` (a trailing newline does not open a new line). */
export function countLines(text) {
  const s = normalizeNewlines(text)
  if (s === '') return 0
  const body = s.endsWith('\n') ? s.slice(0, -1) : s
  return body.split('\n').length
}

/**
 * How big a snippet is: `{ lines, chars, pages }`.
 * `pages` is the worse of the two ratios, so 300 short lines and one
 * 9000-character line both read as three pages.
 */
export function measureCode(text) {
  const s = normalizeNewlines(text)
  const lines = countLines(s)
  const chars = s.length
  const pages = Math.max(lines / A4_PAGE.lines, chars / A4_PAGE.chars)
  return { lines, chars, pages }
}

/** Is this snippet past the send limit? (exactly at the limit is allowed) */
export function overSendLimit(text) {
  const m = measureCode(text)
  return m.lines > SEND_LIMIT.lines || m.chars > SEND_LIMIT.chars
}

/**
 * The fenced code blocks of a body that are too big to send.
 * Returns `[{ index, lang, lines, chars, pages }]`, `index` counting code
 * blocks (not all blocks), so a caller can name "the 2nd code block".
 */
export function oversizeBlocks(body) {
  const out = []
  let i = 0
  for (const b of parseBody(body)) {
    if (b.type !== 'code') continue
    i += 1
    if (!overSendLimit(b.text)) continue
    const m = measureCode(b.text)
    out.push({ index: i, lang: b.lang, lines: m.lines, chars: m.chars, pages: m.pages })
  }
  return out
}

/**
 * The refusal a composer shows instead of sending, or null when the body is
 * fine. i18n-ready by construction: a key plus its parameters, never a
 * sentence — the 19 catalogues own the wording.
 */
export function sendLimitError(body) {
  const over = oversizeBlocks(body)
  if (over.length === 0) return null
  const worst = over.reduce((a, b) => (b.pages > a.pages ? b : a))
  return {
    key: 'code.too_big',
    params: {
      pages: MAX_SEND_PAGES,
      lines: SEND_LIMIT.lines,
      chars: SEND_LIMIT.chars,
      actual_lines: worst.lines,
      actual_chars: worst.chars,
    },
    blocks: over,
  }
}

/* ---------- the bounded preview ---------- */

/**
 * The head of a snippet that fits a card.
 * `{ text, truncated, shownLines, totalLines, hiddenLines, totalChars }`.
 * Cutting on the character budget still cuts on a line boundary, so a
 * preview never ends mid-token and never re-highlights differently from the
 * full source above the cut.
 */
export function previewOf(text, limit = PREVIEW_LIMIT) {
  const s = normalizeNewlines(text)
  const all = s === '' ? [] : (s.endsWith('\n') ? s.slice(0, -1) : s).split('\n')
  const totalLines = all.length
  let kept = []
  let chars = 0
  for (const line of all.slice(0, limit.lines)) {
    // +1 for the newline that rejoins it
    const next = chars + line.length + (kept.length ? 1 : 0)
    if (kept.length && next > limit.chars) break
    kept.push(line)
    chars = next
  }
  // a single first line longer than the whole budget is still shown: the cut
  // is by LINES, and wrapping (not scrolling) is what makes it readable
  if (kept.length === 0 && all.length) kept = [all[0]]
  const truncated = kept.length < totalLines
  return {
    text: kept.join('\n'),
    truncated,
    shownLines: kept.length,
    totalLines,
    hiddenLines: totalLines - kept.length,
    totalChars: s.length,
  }
}

/* ---------- grammar names ---------- */

/**
 * Fence tag -> highlight.js grammar name. The fence tag is whatever the
 * author typed, so `js`, `JS`, `sh`, `c++` and `yml` all have to land on the
 * grammar the loader knows. An unknown tag returns '' — the caller then
 * either auto-detects among the grammars already loaded, or renders plain.
 */
export const LANG_ALIASES = Object.freeze({
  js: 'javascript', jsx: 'javascript', mjs: 'javascript', cjs: 'javascript', node: 'javascript',
  ts: 'typescript', tsx: 'typescript',
  py: 'python', python3: 'python',
  sh: 'bash', shell: 'bash', zsh: 'bash', console: 'bash',
  yml: 'yaml',
  md: 'markdown',
  rb: 'ruby',
  golang: 'go',
  'c++': 'cpp', cc: 'cpp', hpp: 'cpp', cxx: 'cpp',
  'c#': 'csharp', cs: 'csharp',
  htm: 'xml', html: 'xml', svg: 'xml', vue: 'xml',
  ps1: 'powershell',
  postgres: 'sql', psql: 'sql',
  docker: 'dockerfile',
  make: 'makefile',
  text: '', txt: '', plain: '', plaintext: '',
})

/** Grammars the WUI can load. Each is a separate lazy chunk (code-langs.mjs). */
export const SUPPORTED_LANGS = Object.freeze([
  'bash', 'c', 'cpp', 'csharp', 'css', 'diff', 'dockerfile', 'go', 'graphql',
  'ini', 'java', 'javascript', 'json', 'kotlin', 'less', 'lua',
  'makefile', 'markdown', 'nginx', 'objectivec', 'perl', 'php',
  'powershell', 'protobuf', 'python', 'r', 'ruby', 'rust',
  'scala', 'scss', 'sql', 'swift', 'typescript', 'vim', 'xml', 'yaml',
])

/** The grammars auto-detection is allowed to guess between (a cheap fallback). */
export const AUTODETECT_LANGS = Object.freeze([
  'bash', 'javascript', 'json', 'python', 'sql', 'xml', 'yaml',
])

/** Canonical grammar name for a fence tag, or '' when there is none. */
export function normalizeLang(tag) {
  const raw = String(tag ?? '').trim().toLowerCase()
  if (!raw) return ''
  const mapped = Object.prototype.hasOwnProperty.call(LANG_ALIASES, raw) ? LANG_ALIASES[raw] : raw
  return SUPPORTED_LANGS.includes(mapped) ? mapped : ''
}

/* ---------- tokens ---------- */

/**
 * A highlight.js scope name (`keyword`, `title.function_`, `language:xml`) as
 * the class string its own HTML renderer would emit.
 *
 * Transcribed from `scopeToCSSClass` in highlight.js/lib/core.js (11.11): a
 * tiered scope prefixes only its first piece and suffixes the rest with
 * underscores, and a sub-language scope becomes `language-<name>`. Keeping
 * the same class names is what lets any `hljs-*` theme — including ours in
 * CodeLines.vue — work unchanged.
 */
export function scopeToClass(name, prefix = 'hljs-') {
  const s = String(name)
  if (s.startsWith('language:')) return s.replace('language:', 'language-')
  if (s.includes('.')) {
    const pieces = s.split('.')
    return [prefix + pieces.shift(), ...pieces.map((x, i) => x + '_'.repeat(i + 1))].join(' ')
  }
  return prefix + s
}

/**
 * A highlight.js emitter that builds `[{ text, cls }]` instead of a string of
 * HTML.
 *
 * highlight.js drives an emitter through five calls — `addText`, `startScope`
 * / `endScope` (and the older `openNode` / `closeNode`), `__addSublanguage`,
 * `finalize`, `toHTML` — and its stock emitter concatenates `<span>`s into a
 * buffer. Ours keeps a stack of open scopes and appends flat runs, so THE
 * MARKUP IS NEVER BUILT: there is no string for a `<script>` in a message to
 * end up inside, and the renderer gets text it interpolates. `toHTML` returns
 * the empty string deliberately — `result.value` is the HTML nobody here
 * wants, and building it would defeat the point.
 *
 * Pure: it never touches the DOM, and a node test drives it directly.
 */
export function createTokenEmitter() {
  return class TokenEmitter {
    constructor(options) {
      this.options = options || {}
      this.prefix = typeof this.options.classPrefix === 'string' ? this.options.classPrefix : 'hljs-'
      /** the flat token run, in source order */
      this.tokens = []
      /** class strings of the scopes currently open, outermost first */
      this.scopes = []
    }

    get cls() {
      return this.scopes.join(' ')
    }

    addText(value) {
      if (value === '') return
      const cls = this.cls
      const last = this.tokens[this.tokens.length - 1]
      // adjacent runs of the same scope are one token: fewer spans, and the
      // line splitter downstream has less to walk
      if (last && last.cls === cls) last.text += value
      else this.tokens.push({ text: value, cls })
    }

    openNode(name) {
      this.scopes.push(scopeToClass(String(name), this.prefix))
    }

    closeNode() {
      this.scopes.pop()
    }

    startScope(name) {
      this.openNode(name)
    }

    endScope() {
      this.closeNode()
    }

    /** an embedded language (JS inside HTML): its tokens, under our scopes */
    __addSublanguage(other, name) {
      const outer = [this.cls, name ? `language-${name}` : ''].filter(Boolean).join(' ')
      for (const t of other.tokens) {
        this.tokens.push({ text: t.text, cls: [outer, t.cls].filter(Boolean).join(' ') })
      }
    }

    finalize() {}

    /** highlight.js assigns this to `result.value`; we never read it. */
    toHTML() {
      return ''
    }
  }
}

/** Plain, unhighlighted tokens for `text` — the fallback and the control. */
export function plainTokens(text) {
  const s = normalizeNewlines(text)
  return s === '' ? [] : [{ text: s, cls: '' }]
}

/**
 * Split tokens into one array per source line: `[[{text, cls}, …], …]`.
 *
 * The renderer draws a row per line, which is what makes both cheap: a line
 * number is the row index, and a soft-wrapped row is one row of one line
 * rather than an unbounded `<pre>` that has to scroll sideways.
 */
export function tokensToLines(tokens) {
  const lines = [[]]
  for (const tok of tokens || []) {
    const parts = normalizeNewlines(tok.text).split('\n')
    parts.forEach((part, i) => {
      if (i > 0) lines.push([])
      if (part !== '') lines[lines.length - 1].push({ text: part, cls: tok.cls })
    })
  }
  // a trailing newline closes the last line rather than opening an empty one
  if (lines.length > 1 && lines[lines.length - 1].length === 0) lines.pop()
  return lines
}

/** `text` as lines of plain tokens — highlighting off, or not loaded yet. */
export function plainLines(text) {
  return tokensToLines(plainTokens(text))
}

/** The text of a line of tokens — the control a test uses to prove nothing is lost. */
export function lineText(line) {
  return (line || []).map((t) => t.text).join('')
}
