// perf round 3 P3-19: markdown-it's two named-entity decoders, done by the
// browser's own HTML parser instead of the `entities` package's 21 KB raw
// decode table. nuxt.config aliases `entities` to this file in the CLIENT
// build only; node (the unit tests, the prerender) keeps the real package.
//
// markdown-it calls these with one `&name;` at a time (its NAMED_RE /
// ENTITY_RE matches) and keeps the input when the result equals it:
//   decodeHTML       - common/utils.mjs, link destinations/titles, fence info
//   decodeHTMLStrict - rules_inline/entity.mjs, entities in text
// A detached <textarea> parses its innerHTML as RCDATA: character references
// are decoded and nothing else is (no element, no script), and `.value` reads
// the text back. That is the HTML parser's own reference table, the one
// `entities` copies. Unit-tested by tests/unit/entities-browser.test.mjs.

/** @type {HTMLTextAreaElement | null} */
let box = null

/** Decode character references as the HTML parser does in text (legacy prefixes included). */
function decodeLoose(s) {
  if (s.indexOf('&') < 0) return s
  if (!box) box = document.createElement('textarea')
  box.innerHTML = s
  return box.value
}

/**
 * The strict decoder from a loose one: `&name;` decodes only when the WHOLE
 * name is a reference. A loose decode of `&ampfoo;` is `&foo;` (the legacy
 * `&amp` prefix); strict keeps `&ampfoo;`, as entities' decodeHTMLStrict does.
 * @param {(s: string) => string} loose
 */
export function strictEntityDecoder(loose) {
  return (s) => {
    const d = loose(s)
    if (d === s) return s
    const tail = /[a-z0-9]+;$/i.exec(d)
    return tail && s.endsWith(tail[0]) ? s : d
  }
}

export const decodeHTML = decodeLoose
export const decodeHTMLStrict = strictEntityDecoder(decodeLoose)
