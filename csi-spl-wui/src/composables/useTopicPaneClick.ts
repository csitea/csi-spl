import { topicPaneClickAction } from '~/utils/topic-open.mjs'
import { useTopicStore } from '~/stores/topic'

/** A click on the topic pane selects the pane. The topic row that opened it stays selected. */
export function useTopicPaneClick() {
  const topic = useTopicStore()

  function onTopicPaneClick(ev: MouseEvent) {
    const sel = typeof window !== 'undefined' ? window.getSelection() : null
    const selecting = Boolean(sel && !sel.isCollapsed && String(sel).trim())
    if (topicPaneClickAction(ev.target, { selecting }) !== 'pane') return
    topic.selectPane()
    /* A click on a message selects that message. Leave it focused so Delete
       and e apply to it. A click on the rest of the pane still blurs a
       message, which is how the pane itself becomes the selected surface. */
    const target = ev.target
    if (target instanceof Element && target.closest('article.msg')) return
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
