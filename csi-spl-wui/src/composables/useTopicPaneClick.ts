import { topicPaneClickAction } from '~/utils/topic-open.mjs'
import { useTopicStore } from '~/stores/topic'

/** A click on the topic pane selects the pane and clears the selected message. */
export function useTopicPaneClick() {
  const topic = useTopicStore()

  function onTopicPaneClick(ev: MouseEvent) {
    const sel = typeof window !== 'undefined' ? window.getSelection() : null
    const selecting = Boolean(sel && !sel.isCollapsed && String(sel).trim())
    if (topicPaneClickAction(ev.target, { selecting }) !== 'pane') return
    topic.selectPane()
    const pane = ev.currentTarget
    const active = typeof document !== 'undefined' ? document.activeElement : null
    if (
      pane instanceof Node
      && active instanceof HTMLElement
      && pane.contains(active)
      && active.closest('article.msg')
    ) active.blur()
  }

  return { onTopicPaneClick }
}
