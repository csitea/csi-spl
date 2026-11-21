/**
 * SPL-6139 (owner HUM-10, t1 60bf4e56, msg 2dda6b09: "make the docs by
 * default with white background, but add also the option to specify
 * background ... a dialog box with some predefined thems"): the Qto doc
 * view's page background, per viewer, in this browser's localStorage (no hub
 * setting holds it; every access is try/catch, a private window falls back
 * to the default).
 *
 * `auto`, nothing stored: a white page under a light app theme, the app's own
 * dark page under the dark theme (a white sheet in a dark app glares, and its
 * text tokens are the dark theme's). Any other choice sets the page and its
 * own text colours, so it reads the same under every app theme. The colours
 * are WorkspaceDocView's .wsdoc--bg-<id> classes, never a style attribute
 * (the deployed CSP hashes styles).
 */
export type DocBg = 'auto' | 'white' | 'paper' | 'grey' | 'dark'

export const DOC_BG_KEY = 'spool-qto-doc-bg'
export const DOC_BG_DEFAULT: DocBg = 'auto'

/** the dialog's swatches, in order; `swatch` is the page colour it shows */
export const DOC_BGS: readonly { id: DocBg, labelKey: string, swatch: string }[] = [
  { id: 'auto', labelKey: 'ws_doctree.doc_bg.auto', swatch: '#ffffff' },
  { id: 'white', labelKey: 'ws_doctree.doc_bg.white', swatch: '#ffffff' },
  { id: 'paper', labelKey: 'ws_doctree.doc_bg.paper', swatch: '#f7f0e1' },
  { id: 'grey', labelKey: 'ws_doctree.doc_bg.grey', swatch: '#eceef1' },
  { id: 'dark', labelKey: 'ws_doctree.doc_bg.dark', swatch: '#14171c' },
]

type Store = Pick<Storage, 'getItem' | 'setItem'>

function storage(store?: Store | null): Store | null {
  if (store) return store
  try {
    return globalThis.localStorage ?? null
  } catch {
    return null
  }
}

export function parseDocBg(v: unknown): DocBg {
  return DOC_BGS.some((b) => b.id === v) ? (v as DocBg) : DOC_BG_DEFAULT
}

export function readDocBg(store?: Store | null): DocBg {
  try {
    return parseDocBg(storage(store)?.getItem(DOC_BG_KEY))
  } catch {
    return DOC_BG_DEFAULT
  }
}

/** Persist a choice; returns whether the write landed (the page applies it either way) */
export function writeDocBg(bg: DocBg, store?: Store | null): boolean {
  try {
    const s = storage(store)
    if (!s) return false
    s.setItem(DOC_BG_KEY, parseDocBg(bg))
    return true
  } catch {
    return false
  }
}
