/**
 * Copy a string, and say so for ~1.8 s.
 *
 * Lifted out of MessageBody.vue (4c204d0) for the code block, the dialog and
 * the full-source view; the write itself (with the insecure-origin fallback)
 * is utils/clipboard.mjs writeClipboard.
 */
import { onUnmounted, ref } from 'vue'
import { writeClipboard } from '~/utils/clipboard.mjs'

export function useCopyText(resetMs = 1800) {
  /** the id of the thing last copied, or '' — a caller keys its label off this */
  const copied = ref('')
  let timer: ReturnType<typeof setTimeout> | undefined

  async function copy(text: string, id = '1') {
    await writeClipboard(text)
    copied.value = id
    clearTimeout(timer)
    timer = setTimeout(() => { copied.value = '' }, resetMs)
  }

  onUnmounted(() => clearTimeout(timer))
  return { copied, copy }
}
