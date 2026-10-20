// csi-spl-wui/src/utils/submit-key.ts
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

export type SubmitKey = 'enter' | 'ctrl-enter'

export const SUBMIT_KEYS: readonly SubmitKey[] = Object.freeze(['enter', 'ctrl-enter'] as const)

/*
 * The mode of a person who never picked one (humans.submit_key NULL):
 * Enter sends, the chat default (owner, 2026-09-27, topic a4bc52dc). The hub
 * names the same default (auth.DefaultSubmitKey). A person who picked a mode
 * keeps it; the owner's rows were pinned to 'ctrl-enter' before the flip.
 */
export const DEFAULT_SUBMIT_KEY: SubmitKey = 'enter'

function isSubmitKey(raw: unknown): raw is SubmitKey {
  return (SUBMIT_KEYS as readonly unknown[]).includes(raw)
}

/** One of SUBMIT_KEYS exactly, else the default. */
export function parseSubmitKey(raw: unknown): SubmitKey {
  return isSubmitKey(raw) ? raw : DEFAULT_SUBMIT_KEY
}

/**
 * What one keydown in a text field means.
 *
 * @returns '' = not Enter: not ours.
 */
export function submitKeyAction(
  ev: { key?: string, shiftKey?: boolean, altKey?: boolean, ctrlKey?: boolean, metaKey?: boolean, isComposing?: boolean, keyCode?: number } | null | undefined,
  { mode, inCode = false }: { mode?: unknown, inCode?: boolean } = {},
): 'submit' | 'newline' | '' {
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
 */
export function submitHintKey(mode: unknown, byMode: Record<string, string>): string {
  return byMode[parseSubmitKey(mode)] || byMode[DEFAULT_SUBMIT_KEY] || ''
}

/**
 * A placeholder key that names the keys: `base` is the Ctrl+Enter wording,
 * and `<base>_enter` the Enter-sends one, in every locale.
 */
export function submitHintFor(mode: unknown, base: string): string {
  return parseSubmitKey(mode) === 'enter' ? `${base}_enter` : base
}

/**
 * The radio's save, optimistic like the Debug pane: mirror the claim at once
 * so every field follows, save it, and put the old value back on a refusal.
 */
export async function applySubmitKeySetting(
  want: unknown,
  { current, apply, save }: { current: unknown, apply: (k: string) => void, save: (k: string) => Promise<{ ok: boolean }> },
): Promise<{ ok: boolean, value: SubmitKey, out?: unknown }> {
  const prev = parseSubmitKey(current)
  if (!isSubmitKey(want)) return { ok: false, value: prev }
  if (want === prev && isSubmitKey(current)) return { ok: true, value: prev }
  apply(want)
  let out: { ok: boolean, error?: unknown }
  try {
    out = await save(want)
  } catch (e) {
    out = { ok: false, error: e }
  }
  if (out && out.ok) return { ok: true, value: want }
  apply(prev)
  return { ok: false, value: prev, out }
}
