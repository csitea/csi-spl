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
let box = null;

// Lazy-load the `entities` package in Node.js; the browser build aliases this file to replace it.
async function getEntities() {
  const entities = await import('entities');
  return entities;
}

/** Decode character references as the HTML parser does in text (legacy prefixes included). */
export async function decodeHTML(s) {
  if (s.indexOf('&') < 0) return s;
  if (typeof document === 'undefined') {
    const entities = await getEntities();
    return entities.decodeHTML(s);
  }
  if (!box) box = document.createElement('textarea');
  box.innerHTML = s;
  return box.value;
}

/**
 * Strict decoder: only decodes valid named entities, matching markdown-it 15's behavior.
 * Uses the `entities` package's decodeHTMLStrict directly.
 */
export async function decodeHTMLStrict(s) {
  if (typeof document === 'undefined') {
    const entities = await getEntities();
    return entities.decodeHTMLStrict(s);
  }
  return decodeHTML(s);
}
