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
/** the one fetch of the auto-detect set, shared by every untagged block. */
let autodetectPromise = null

/** The configured highlight.js core, loaded once. */
function engine() {
  if (!enginePromise) {
    enginePromise = (async () => {
      try {
        const m = await import('highlight.js/lib/core')
        const hl = m.default
        hl.configure({ __emitter: createTokenEmitter(), classPrefix: 'hljs-' })
        return hl
      } catch (err) {
        // a failed chunk must degrade to plain text, not break the feed
        enginePromise = null
        throw err
      }
    })()
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
 * Load the AUTODETECT_LANGS set, once per page, for a block that carries NO
 * usable language tag.
 *
 * this used to be skipped, and an untagged block was therefore left
 * plain unless some OTHER block on the page had already happened to load an
 * auto-detectable grammar. Measured on this tree against a 5-line shell
 * script: tagged ```bash coloured 11 of 19 runs, the same text untagged
 * coloured 0 of 1 — and untagged is what a person typing ``` in a hurry, or
 * an agent pasting terminal output, actually sends. "Syntax highlighting" that
 * needs the author to name the language first is not the feature the owner
 * asked for.
 *
 * The cost this pays is bounded and still lazy: seven grammars (bash,
 * javascript, json, python, sql, xml, yaml), each an existing literal chunk
 * from LANG_LOADERS, fetched the first time an untagged block is on screen and
 * never before. The initial bundle is untouched, which is the constraint that
 * ruled out lowlight in the first place.
 *
 * Resolves to the names that actually registered — a failed chunk is simply
 * one fewer candidate, never an error.
 */
export function loadAutodetectGrammars() {
  if (!autodetectPromise) {
    autodetectPromise = Promise.all(AUTODETECT_LANGS.map((g) => loadGrammar(g)))
      .then((names) => names.filter(Boolean))
      .catch(() => [])
  }
  return autodetectPromise
}

/**
 * Highlight `text` as `langTag`, as `[{ text, cls }]`.
 *
 * - a known fence tag picks the grammar (`js`, `c++`, `yml` … see LANG_ALIASES)
 * - no tag, or an unknown one, falls back to auto-detection over the
 *   AUTODETECT_LANGS subset, loaded on demand (loadAutodetectGrammars). A
 *   guess is taken only when it is strong enough, so prose in a fence stays
 *   plain; a failed chunk is one fewer candidate, and no candidates at all is
 *   plain tokens.
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
    // No usable tag: fetch the auto-detect set (once) and guess between THOSE
    // grammars only. Naming the subset matters — `highlightAuto(src)` alone
    // guesses between everything registered, so a page that had already loaded
    // `go` for a tagged block could return a `go` guess this allow-list then
    // throws away, leaving a snippet plain that the subset would have coloured.
    await loadAutodetectGrammars()
    const subset = AUTODETECT_LANGS.filter((g) => loadedGrammars().includes(g))
    if (!subset.length) return plainTokens(src)
    const guess = hl.highlightAuto(src, subset)
    // belt and braces: the subset already bounds the answer
    if (!guess.language || !AUTODETECT_LANGS.includes(guess.language)) return plainTokens(src)
    // and a weak guess stays plain — mis-colouring prose is worse than not
    // colouring code (MIN_AUTODETECT_RELEVANCE)
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
  autodetectPromise = null
}
