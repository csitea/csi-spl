// csi-spl-wui/src/utils/submit-key.mjs
//
// Settings -> Behaviour -> "Text fields" (SPL-976, spec 023 3.7): what Enter
// does in every multi-line text field of the WUI. One rule, one place; each
// field asks submitKeyAction() and never reads Enter itself.
//
//   'enter'      Enter sends / saves, Shift+Enter (or Alt+Enter) adds a line.
//   'ctrl-enter' Enter adds a line, Ctrl+Enter (Cmd+Enter on macOS) sends / saves.
//
// In both modes Ctrl/Cmd+Enter sends, and inside an open ``` block a bare
// Enter adds a line (code is typed line by line). The hub keeps the choice on
// the account (humans.submit_key, rdb 0062); the session answers it as the
// `submit_key` claim, null when never picked.

export const SUBMIT_KEYS = Object.freeze(['enter', 'ctrl-enter'])

/*
 * The mode of a person who never picked one. 'ctrl-enter' is how the message
 * composer has worked since the owner's order of 2026-09-23, so nobody's
 * composer changes when the setting ships. Flipping it is this one line.
 */
export const DEFAULT_SUBMIT_KEY = 'ctrl-enter'

/** One of SUBMIT_KEYS exactly, else the default. */
export function parseSubmitKey(raw) {
  return SUBMIT_KEYS.includes(raw) ? raw : DEFAULT_SUBMIT_KEY
}

/**
 * What one keydown in a text field means.
 *
 * @param {{ key?: string, shiftKey?: boolean, altKey?: boolean, ctrlKey?: boolean,
 *           metaKey?: boolean, isComposing?: boolean, keyCode?: number } | null | undefined} ev
 * @param {{ mode?: unknown, inCode?: boolean }} [opts]
 * @returns {'submit' | 'newline' | ''} '' = not Enter: not ours.
 */
export function submitKeyAction(ev, { mode, inCode = false } = {}) {
  if (!ev || String(ev.key) !== 'Enter') return ''
  /* an IME is committing a word (keyCode 229 on Safari): never a send */
  if (ev.isComposing || ev.keyCode === 229) return 'newline'
  if (ev.ctrlKey || ev.metaKey) return ev.shiftKey || ev.altKey ? 'newline' : 'submit'
  if (parseSubmitKey(mode) === 'ctrl-enter') return 'newline'
  if (inCode || ev.shiftKey || ev.altKey) return 'newline'
  return 'submit'
}

/**
 * The catalogue key of a hint that names the keys: `byMode[mode]`, else the
 * default mode's.
 * @param {unknown} mode
 * @param {Record<string, string>} byMode
 */
export function submitHintKey(mode, byMode) {
  return byMode[parseSubmitKey(mode)] || byMode[DEFAULT_SUBMIT_KEY] || ''
}

/**
 * The radio's save, optimistic like the Debug pane: mirror the claim at once
 * so every field follows, save it, and put the old value back on a refusal.
 * @param {unknown} want
 * @param {{ current: unknown, apply: (k: string) => void,
 *           save: (k: string) => Promise<{ ok: boolean }> }} io
 * @returns {Promise<{ ok: boolean, value: string, out?: unknown }>}
 */
export async function applySubmitKeySetting(want, { current, apply, save }) {
  const prev = parseSubmitKey(current)
  if (!SUBMIT_KEYS.includes(want)) return { ok: false, value: prev }
  if (want === prev && SUBMIT_KEYS.includes(current)) return { ok: true, value: prev }
  apply(want)
  let out
  try {
    out = await save(want)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (out && out.ok) return { ok: true, value: want }
  apply(prev)
  return { ok: false, value: prev, out }
}
