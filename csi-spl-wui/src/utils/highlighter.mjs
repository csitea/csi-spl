/**
 * Lazy syntax highlighting, as tokens — never as markup.
 *
 * Why lowlight and not a highlighter that returns HTML: every other option
 * (highlight.js directly, Prism, marked+hljs) hands back a *string of HTML*,
 * which a Vue renderer can only show through `v-html`. 013 FR-010 (4c204d0)
 * deliberately removed the last `v-html` from the message path, so the WUI
 * would keep one guarantee — nothing in a message body can become markup.
 * lowlight is a thin wrapper over the same highlight.js grammars that returns
 * a TREE of `{ type:'element', properties:{className}, children }` and
 * `{ type:'text', value }` nodes, so the guarantee is kept by construction
 * rather than by sanitising afterwards. `flattenTokens` (code-view.mjs) turns
 * that tree into `{ text, cls }` pairs and Vue interpolates the text.
 *
 * CSP (017 FR-SEC-005 / SEC-06): the grammars are plain regex tables — no
 * `eval`, no `new Function`, no WASM, so nothing here needs `unsafe-eval` or
 * `wasm-unsafe-eval`. The theme is CSS in a component's `<style>` block,
 * compiled into the stylesheet bundle, so nothing needs `unsafe-inline`
 * either. Both are asserted by tests/unit/code-view.test.mjs.
 *
 * COST: the engine and every grammar are dynamic imports, fetched the first
 * time a message actually shows code in that language. The main bundle pays
 * for the two `import()` call sites and nothing else.
 */

import { AUTODETECT_LANGS, flattenTokens, normalizeLang, plainTokens, tokensToLines } from './code-view.mjs'
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

/** @returns {Promise<import('lowlight').Lowlight>} */
function engine() {
  if (!enginePromise) {
    enginePromise = import('lowlight')
      .then((m) => m.createLowlight())
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
      const [low, mod] = await Promise.all([engine(), LANG_LOADERS[name]()])
      low.register({ [name]: mod.default })
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
    const low = await engine()
    if (name) return flattenTokens(low.highlight(name, src))
    // highlightAuto guesses between everything REGISTERED, which is exactly
    // the set this page already paid for — no extra chunk is ever fetched to
    // detect. The result is then accepted only for a language we would have
    // auto-detected on purpose, and only when the guess is strong enough.
    if (loadedGrammars().every((g) => !AUTODETECT_LANGS.includes(g))) return plainTokens(src)
    const guess = low.highlightAuto(src)
    const detected = guess.data && guess.data.language
    if (!detected || !AUTODETECT_LANGS.includes(detected)) return plainTokens(src)
    if ((guess.data.relevance ?? 0) < MIN_AUTODETECT_RELEVANCE) return plainTokens(src)
    return flattenTokens(guess)
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
