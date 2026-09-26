// SPL-976: the one way a text field reads Enter (spec 023 3.7). The mode is
// the signed-in human's `submit_key` session claim (Settings -> Behaviour ->
// "Text fields", kept on the hub), so a change there reaches every open field
// at once and every device on its next sign-in.
//
// Usage in a field:
//   const { onKeydown, hintKey } = useSubmitKey()
//   <textarea @keydown="onKeydown($event, send)" :placeholder="t(hintFor('x'))" />
// A field with its own keys (pickers, fences) asks keyAction() instead and
// acts on 'submit' itself.
import { useSessionStore } from '~/stores/session'
import { parseSubmitKey, submitHintKey, submitKeyAction, type SubmitKey } from '~/utils/submit-key.mjs'

export function useSubmitKey() {
  const session = useSessionStore()
  const mode = computed<SubmitKey>(() => parseSubmitKey(session.claims?.submit_key))

  function keyAction(ev: KeyboardEvent, opts: { inCode?: boolean } = {}) {
    return submitKeyAction(ev, { mode: mode.value, inCode: opts.inCode === true })
  }

  /** keydown handler: on 'submit' the default is stopped and `submit` runs. */
  function onKeydown(ev: KeyboardEvent, submit: () => unknown, opts: { inCode?: boolean } = {}) {
    if (keyAction(ev, opts) !== 'submit') return
    ev.preventDefault()
    void submit()
  }

  function hintKey(byMode: Record<SubmitKey, string>) {
    return submitHintKey(mode.value, byMode)
  }

  /**
   * A placeholder that names the keys: `base` is the Ctrl+Enter wording, and
   * `<base>_enter` the Enter-sends one, in every locale.
   */
  function hintFor(base: string) {
    return mode.value === 'enter' ? `${base}_enter` : base
  }

  return { mode, keyAction, onKeydown, hintKey, hintFor }
}
