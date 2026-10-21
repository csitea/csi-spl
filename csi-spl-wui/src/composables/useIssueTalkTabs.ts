import { ref, watch, type Ref } from 'vue'

/**
 * rdb 0181: the issue discussion's two tabs, Discussion | History; a newly
 * opened issue starts on Discussion. SPL-2784 (plan issue-tabs-panel-plan.md
 * row 02): the tabs' keys (WAI-ARIA tabs): Left / Right wrap, Home / End go
 * to the ends; the tab reached is selected and takes the focus (the page
 * gives only the selected tab tabindex 0).
 */
export const TALK_TABS = ['discussion', 'history'] as const
export type TalkTab = (typeof TALK_TABS)[number]

export function useIssueTalkTabs(openKey: Ref<string>) {
  const talkTab = ref<TalkTab>('discussion')
  watch(openKey, () => { talkTab.value = 'discussion' })

  function onTalkTabKey(e: KeyboardEvent) {
    if (e.altKey || e.ctrlKey || e.metaKey || e.shiftKey) return
    const last = TALK_TABS.length - 1
    const i = TALK_TABS.indexOf(talkTab.value)
    const n = ({ ArrowRight: i === last ? 0 : i + 1, ArrowLeft: i === 0 ? last : i - 1, Home: 0, End: last } as Record<string, number>)[e.key]
    if (n === undefined) return
    e.preventDefault()
    e.stopPropagation()
    talkTab.value = TALK_TABS[n]
    document.getElementById('issues-talk-tab-' + TALK_TABS[n])?.focus()
  }

  return { talkTab, onTalkTabKey }
}
