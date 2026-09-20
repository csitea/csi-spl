/**
 * Lazy syntax highlighting, as tokens — never as markup.
 *
 * highlight.js is the grammar set (190 languages, plain regex tables), but
 * its stock output is a STRING OF HTML, which a Vue renderer can only show
 * through `v-html`. 013 FR-010 (4c204d0) deliberately removed the last
 * `v-html` from the message path so the WUI would keep one guarantee:
 * nothing in a message body can become markup. So we drive highlight.js with
 * our OWN emitter (`createTokenEmitter`, code-view.mjs) — the same five calls
 * its stock emitter answers, appending `{ text, cls }` runs instead of
 * concatenating `<span>`s. No HTML string is ever built, so there is nothing
 * for a `<script>` in a body to be inside.
 *
 * That is also why this does not use `lowlight`, the ready-made wrapper that
 * returns a hast tree. Measured 2026-09-20 on this tree with
 * `pnpm run generate`: lowlight's only entry point re-exports its `all` and
 * `common` grammar bundles, the package declares no `sideEffects: false`, and
 * Rollup therefore kept them — one 806 KB chunk that statically imports every
 * grammar, pulled in by the initial graph. Our emitter is 60 lines and costs
 * nothing.
 *
 * CSP (017 FR-SEC-005 / SEC-06): the grammars are regex tables — no `eval`,
 * no `new Function`, no WASM — so nothing needs `unsafe-eval` or
 * `wasm-unsafe-eval`. The theme is CSS in CodeLines.vue, compiled into the
 * stylesheet bundle, so nothing needs `unsafe-inline` either. Both are
 * asserted by tests/unit/code-view.test.mjs against the shipped runtime.
 *
 * COST: the engine and every grammar are dynamic imports, fetched the first
 * time a message actually shows code in that language. The main bundle pays
 * for the two `import()` call sites and nothing else.
 */

import { AUTODETECT_LANGS, createTokenEmitter, normalizeLang, plainTokens, tokensToLines } from './code-view.mjs'
import { LANG_LOADERS } from './code-langs.mjs'

/**
 * How sure auto-detection has to be before it colours anything.
 * highlight.js scores a guess by how many of a grammar's constructs it found;
 * measured on 2026-09-20 with only the sql grammar registered, the line
 * `SELECT a, b FROM t WHERE a = 1` scores 3 and the sentence "the quick brown
 * fox jumps over the lazy dog" scores 1. Below this a snippet is left plain:
 * mis-colouring prose as code is worse than not colouring code.
 */
export const MIN_AUTODETECT_RELEVANCE = 3

/** The one engine instance, created on first use. */
let enginePromise = null
/** grammar name -> promise of its registration (so two blocks share one fetch). */
const registered = new Map()

/** The configured highlight.js core, loaded once. */
function engine() {
  if (!enginePromise) {
    enginePromise = import('highlight.js/lib/core')
      .then((m) => {
        const hl = m.default
        hl.configure({ __emitter: createTokenEmitter(), classPrefix: 'hljs-' })
        return hl
      })
      .catch((err) => {
        // a failed chunk must degrade to plain text, not break the feed
        enginePromise = null
        throw err
      })
  }
  return enginePromise
}

/**
 * Load and register one grammar. Resolves to the grammar name on success and
 * to '' when there is no such grammar or its chunk failed to load.
 */
export async function loadGrammar(lang) {
  const name = normalizeLang(lang)
  if (!name || !LANG_LOADERS[name]) return ''
  if (!registered.has(name)) {
    const p = (async () => {
      const [hl, mod] = await Promise.all([engine(), LANG_LOADERS[name]()])
      hl.registerLanguage(name, mod.default)
      return name
    })().catch(() => {
      registered.delete(name)
      return ''
    })
    registered.set(name, p)
  }
  return registered.get(name)
}

/** The grammars already registered in this page — what auto-detect may guess between. */
export function loadedGrammars() {
  return [...registered.keys()]
}

/**
 * Highlight `text` as `langTag`, as `[{ text, cls }]`.
 *
 * - a known fence tag picks the grammar (`js`, `c++`, `yml` … see LANG_ALIASES)
 * - no tag, or an unknown one, falls back to auto-detection — but ONLY among
 *   grammars this page has ALREADY loaded, so the fallback never costs a
 *   network round trip it was not going to make anyway. With nothing loaded
 *   yet it returns plain tokens, which is also what a failed chunk returns.
 *
 * Never throws: every failure path is plain text.
 */
export async function highlightTokens(text, langTag) {
  const src = String(text ?? '')
  if (!src) return []
  try {
    const name = await loadGrammar(langTag)
    const hl = await engine()
    if (name) return hl.highlight(src, { language: name })._emitter.tokens
    // highlightAuto guesses between everything REGISTERED, which is exactly
    // the set this page already paid for — no extra chunk is ever fetched to
    // detect. The result is then accepted only for a language we would have
    // auto-detected on purpose, and only when the guess is strong enough.
    if (loadedGrammars().every((g) => !AUTODETECT_LANGS.includes(g))) return plainTokens(src)
    const guess = hl.highlightAuto(src)
    if (!guess.language || !AUTODETECT_LANGS.includes(guess.language)) return plainTokens(src)
    if ((guess.relevance ?? 0) < MIN_AUTODETECT_RELEVANCE) return plainTokens(src)
    return guess._emitter.tokens
  } catch {
    return plainTokens(src)
  }
}

/** `highlightTokens`, already split into one row per source line. */
export async function highlightLines(text, langTag) {
  return tokensToLines(await highlightTokens(text, langTag))
}

/** Test seam: forget the engine and every grammar (no effect in the app). */
export function __resetHighlighter() {
  enginePromise = null
  registered.clear()
}
