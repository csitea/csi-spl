/**
 * Rows of tokens for a snippet, highlighted when (and only when) the grammar
 * has arrived.
 *
 * The first render is always PLAIN — on the server, and on the client before
 * the lazy chunk resolves. That is deliberate twice over: the prerendered
 * HTML stays identical whatever grammars a page happens to use (so the CSP
 * style/script hashes the Hosting render computes do not move, 017
 * FR-SEC-005), and a failed or slow chunk degrades to readable text rather
 * than to nothing.
 *
 * Highlighting is skipped entirely on the server: `highlightTokens` would
 * pull the engine into the SSR bundle for output the client immediately
 * replaces.
 */
import { ref, shallowRef, watch, type Ref } from 'vue'

import { plainLines } from '~/utils/code-view.mjs'
import { highlightLines } from '~/utils/highlighter.mjs'

type Token = { text: string; cls: string }

export function useCodeLines(text: Ref<string>, lang: Ref<string>, enabled?: Ref<boolean>) {
  const lines = shallowRef<Token[][]>(plainLines(text.value))
  /** true once a grammar actually coloured this snippet */
  const highlighted = ref(false)
  /** only the newest request may write; an older one that resolves late is dropped */
  let seq = 0

  watch(
    [text, lang, () => (enabled ? enabled.value : true)],
    async ([src, tag, on]) => {
      const mine = ++seq
      lines.value = plainLines(src)
      highlighted.value = false
      if (!import.meta.client || !on || !src) return
      const rows = await highlightLines(src, tag)
      if (mine !== seq) return
      lines.value = rows
      highlighted.value = rows.some((row) => row.some((t) => t.cls !== ''))
    },
    { immediate: true },
  )

  return { lines, highlighted }
}
