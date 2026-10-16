/* SPL-2094 (owner HUM-10, t1 8f704763: "this 3 buttons on the desktop wui
   must be on the top row on the right side"): the doc view's bar. Above the
   phone breakpoint (useMobileStack) it is teleported into the page's header
   row (WorkspaceDocsPage #wsdocs-head-tools); a phone keeps it sticky above
   the document. The `-` prefix keeps Nuxt from registering this file as a
   component. */
import { computed, ref } from 'vue'
import { useMobileStack } from '~/composables/useMobileStack'

export function useDocHeadBar() {
  const barEl = ref<HTMLElement | null>(null)
  const stack = useMobileStack()
  const inHead = computed(() => !stack.isMobile.value)
  /* on a narrow screen the contents drop down under the bar (on a desktop the header holding it), wherever the document is scrolled */
  const tocTop = ref(0)
  function markTocTop() {
    const el = inHead.value ? barEl.value?.closest('.feed-header') : barEl.value
    tocTop.value = Math.max(0, Math.round(el?.getBoundingClientRect().bottom ?? 0))
  }
  return { barEl, inHead, tocTop, markTocTop }
}
