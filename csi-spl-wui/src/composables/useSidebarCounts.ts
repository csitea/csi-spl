/*
 * ChannelSidebar's numbers and pips (r13-04): the rail's unread counts, the
 * Issues count, a row's unread, draft pencil and DM badge. channelIds and
 * peerLabels read the rows the sidebar lists, so a section's number is the sum
 * of its rows' badges.
 */
import { computed, ref, watch } from 'vue'
import { useSessionStore } from '~/stores/session'
import { useNotificationStore } from '~/stores/notification'
import { useDrafts } from '~/composables/useDrafts'
import { useFlowBadge, useFlowKeys, useFlowRail } from '~/composables/useFlowBadge'
import { useUnread } from '~/composables/useUnread'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { useLive } from '~/composables/useLive'
import { dmBadgeText, dmTotalText } from '~/utils/notify.mjs'

function countLabel(n: number) {
  return n > 0 ? (n > 99 ? '99+' : String(n)) : ''
}
function useCountStart(api: ReturnType<typeof useSpoolApi>, live: ReturnType<typeof useLive>) {
  const session = useSessionStore()
  /* the number starts once signed in (or in the mock); the Flow store is its own
     lazy chunk, so it is loaded here and never rides the initial JS */
  const nuxtApp = useNuxtApp()
  let flowStarted = false
  /* owner (t1 de3c2cf5 msg 26c89f60): the Issues tab counts the viewer's open
     assigned issues, an unanswered blocker's among them; its own lazy chunk */
  const myIssues = ref(0)
  watch(() => api.mock || session.state === 'in', (on) => {
    if (!on || flowStarted || !import.meta.client) return
    flowStarted = true
    void import('~/stores/flow')
      .then((m) => nuxtApp.runWithContext(() => m.useFlowStore().startBadge()))
      .catch(() => { flowStarted = false })
    void import('~/utils/my-issues-count.mjs').then((m) => m.startMyIssuesCount({ api, live, count: myIssues }), () => {})
  }, { immediate: true })
  return myIssues
}

export function useSidebarCounts(api: ReturnType<typeof useSpoolApi>, live: ReturnType<typeof useLive>, channelIds: () => string[], peerLabels: () => string[]) {
  const notes = useNotificationStore()
  function sectionUnread(prefix: string) {
    return Object.entries(notes.unread).some(([k, n]) => k.startsWith(prefix) && Number(n) > 0)
  }
  const dmUnread = computed(() => sectionUnread('dm:'))
  const channelUnread = computed(() => sectionUnread('ch:'))
  const flowUnread = computed(() => dmUnread.value || channelUnread.value)
  /* spec 062: once the hub has counted (flowBadge >= 0) the number replaces the
     pip; a hub without the Flow route leaves -1 and the pip as it was */
  const flowBadge = useFlowBadge()
  const myIssues = useCountStart(api, live)
  const flowLabel = computed(() => countLabel(flowBadge.value))
  /* owner (t1 f4e6c677): once the hub splits its Flow unread (flowRail set),
     Channels and Direct messages show it as a number, and no pip at 0 */
  const flowRail = useFlowRail()
  /* owner (t1 77540e6f): once the hub sends its per-row unread (flowKeys), a
     section's number is the sum of the badges on the rows it lists - one map
     for both, so "7 new" never sits over rows that show nothing */
  const flowKeys = useFlowKeys()
  /* spec 079 FR-003, FR-007: rows and rail read the one unread model */
  const unread = useUnread()
  function unreadOf(key: string) {
    return unread.rowOf(key)
  }
  /* spec 080 FR-005: a pencil on a channel / DM / topic row that holds a draft */
  const drafts = useDrafts()
  function hasDraft(key: string) {
    return drafts.has(key)
  }
  /* a section's number: the model's rows it lists, each once (owner, t1 77540e6f:
     never more than the badges on its rows add up to) */
  function listedSum(prefix: string, ids: string[]) {
    let n = 0
    for (const id of new Set(ids)) n += unread.rowOf(prefix + id)
    return n
  }
  /* spec 079 FR-003: a DM row's "<new>/<total>" takes its new part from the
     model too (no second count from the notification store); the row template
     shows the plain total only when the model has nothing new for it */
  function dmBadgeLabel(label: string) {
    const key = 'dm:' + label
    return dmBadgeText(unreadOf(key), notes.dmTotal[key] || 0)
  }
  function dmTotalLabel(label: string) {
    return dmTotalText(notes.dmTotal['dm:' + label] || 0)
  }
  function railCount(id: string) {
    if (id === 'issues') return countLabel(myIssues.value)
    if (flowKeys.value) {
      if (id === 'channels') return countLabel(listedSum('ch:', channelIds()))
      if (id === 'dm') return countLabel(listedSum('dm:', peerLabels()))
      return ''
    }
    const r = flowRail.value
    if (!r) return ''
    if (id === 'channels') return countLabel(r.channels)
    if (id === 'dm') return countLabel(r.dms)
    return ''
  }
  function tabUnread(id: string) {
    if ((id === 'dm' || id === 'channels') && flowKeys.value) return false
    if ((id === 'dm' || id === 'channels') && flowRail.value) return false
    if (id === 'dm') return dmUnread.value
    if (id === 'channels') return channelUnread.value
    if (id === 'flow') return flowBadge.value < 0 && flowUnread.value
    return false
  }
  return { flowLabel, flowKeys, unreadOf, hasDraft, dmBadgeLabel, dmTotalLabel, railCount, tabUnread }
}
