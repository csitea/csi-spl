/* SPL-2094 (owner HUM-10, t1 8f704763: "this 3 buttons on the desktop wui
   must be on the top row on the right side"): the doc view's bar is
   teleported into the page's header row (WorkspaceDocsPage
   #wsdocs-head-tools). SPL-3233 (owner t1 a1b42c34, msg 7caac933): on a
   phone too, the row of its own above the document is gone. The `-` prefix
   keeps Nuxt from registering this file as a component. */
import { ref } from 'vue'

export function useDocHeadBar() {
  const barEl = ref<HTMLElement | null>(null)
  /* on a narrow screen the contents drop down under the header holding the bar, wherever the document is scrolled */
  const tocTop = ref(0)
  function markTocTop() {
    const el = barEl.value?.closest('.feed-header') ?? barEl.value
    tocTop.value = Math.max(0, Math.round(el?.getBoundingClientRect().bottom ?? 0))
  }
  return { barEl, tocTop, markTocTop }
}
