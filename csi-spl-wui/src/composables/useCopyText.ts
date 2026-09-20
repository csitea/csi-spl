/**
 * Copy a string, and say so for ~1.8 s.
 *
 * Lifted verbatim out of MessageBody.vue (4c204d0) when the code block, the
 * dialog and the full-source view all needed it: the selection fallback is
 * the part worth sharing, because `navigator.clipboard` is unavailable on an
 * insecure origin, which is exactly where lde runs.
 */
import { onUnmounted, ref } from 'vue'

export function useCopyText(resetMs = 1800) {
  /** the id of the thing last copied, or '' — a caller keys its label off this */
  const copied = ref('')
  let timer: ReturnType<typeof setTimeout> | undefined

  async function write(text: string) {
    try {
      await navigator.clipboard.writeText(text)
      return
    } catch {
      /* insecure context or denied: the selection fallback below */
    }
    const ta = document.createElement('textarea')
    ta.value = text
    ta.setAttribute('readonly', '')
    ta.className = 'sr-only'
    document.body.appendChild(ta)
    ta.select()
    document.execCommand('copy')
    ta.remove()
  }

  async function copy(text: string, id = '1') {
    await write(text)
    copied.value = id
    clearTimeout(timer)
    timer = setTimeout(() => { copied.value = '' }, resetMs)
  }

  onUnmounted(() => clearTimeout(timer))
  return { copied, copy }
}
