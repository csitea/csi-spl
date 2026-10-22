/**
 * The shell's route-change navigation and focus (layouts/default.vue,
 * r18-01): the topic pane close on a navigation (t1 6e21c7d8, spec 078), the
 * focus and the live region after a route change and the skip link (081
 * T006), and the vim keys installed on window idle (spec 103 T005). Called
 * in the layout's setup: the router and page hooks register at once; the
 * layout runs startVim on mount and dispose on unmount.
 */
import type { Ref } from 'vue'
import { focusPane } from '~/composables/useGlobalKeys'
import { MIDDLE, routeTakesFocus } from '~/utils/pane-focus'
import { routeLeavesTopic } from '~/utils/topic-pane.mjs'
import { perfWhenIdle } from '~/utils/perf-idle.mjs'
import type { useSessionStore } from '~/stores/session'
import type { useLiveFeed } from '~/stores/live'
import type { useTopicStore } from '~/stores/topic'
import type { useOperatorPane } from '~/stores/operator-pane'

export type ShellRouteFocusOptions = {
  session: ReturnType<typeof useSessionStore>
  isMobile: Readonly<Ref<boolean>>
  topicPaneOpen: Readonly<Ref<boolean>>
  livePane: ReturnType<typeof useLiveFeed>
  topic: ReturnType<typeof useTopicStore>
  operatorPane: ReturnType<typeof useOperatorPane>
}

const ROUTE_FOCUS_MS = 3000
function typingNow() {
  return Boolean(document.activeElement?.closest?.('textarea, input, select, [contenteditable="true"]'))
}
/* HUM-10 (t1 7d9e1681): a channel opened from its row keeps the focus there */
function inChannelList() {
  return Boolean(document.activeElement?.closest?.('#sidebar-panel-channels a.nav-item'))
}
function skipToMsgs() {
  focusPane(MIDDLE)
}

export function useShellRouteFocus({ session, isMobile, topicPaneOpen, livePane, topic, operatorPane }: ShellRouteFocusOptions) {
  /* t1 6e21c7d8: on a phone the topic pane covers the page, so a link from a
     post to another page (an in-post /t/<id> link) closes it and the page it
     went to shows; Back returns to the post (its entry still holds ?topic=).
     Back / Forward never closes it here: history.listen sees only popstates. */
  const router = useRouter()
  /* 081 T006: the skip link and the focus after a route change */
  const routeAnnounce = ref('')
  let routeFocusDue = 0
  let popNav = false
  const offPop = router.options.history.listen(() => { popNav = true })
  const offNav = router.afterEach((to, from, failure) => {
    const popstate = popNav
    popNav = false
    if (failure) return
    const nav = { mobile: isMobile.value, open: topicPaneOpen.value, popstate, fromPath: from.path, toPath: to.path, toQuery: to.query }
    /* spec 078 FR-004, Q3: on desktop a section page or /search closes the
       right pane too, whichever section it holds (the operator console too) */
    if (routeLeavesTopic(nav)) { livePane.close(); topic.close(); operatorPane.close() }
    /* 081 T006 (FR-009): a navigation that is not Back / Forward puts the
       focus on the new middle pane's selected row or heading, once the page
       has rendered (page:finish), and the live region says its title */
    const initial = from.matched.length === 0
    if (routeTakesFocus({ ...nav, initial, typing: typingNow(), channelList: inChannelList() })) routeFocusDue = Date.now()
  })
  function focusAfterRoute() {
    if (!routeFocusDue || Date.now() - routeFocusDue > ROUTE_FOCUS_MS) return
    routeFocusDue = 0
    if (typingNow() || document.querySelector('[role="dialog"][aria-modal="true"], dialog[open]')) return
    if (!document.querySelector('.spool-main')?.contains(document.activeElement)) focusPane(MIDDLE, { firstRow: false })
    /* the head writes the new title a frame later; clear first so the same title is said again */
    routeAnnounce.value = ''
    setTimeout(() => { routeAnnounce.value = document.title }, 150)
  }
  const offPageFinish = useNuxtApp().hook('page:finish', () => { void nextTick(focusAfterRoute) })
  /* spec 103 T005: the vim keys (h j k l, g g, G, Esc) - ONE global listener,
     imported on window idle so it, its store and its ring css stay out of the
     initial chunk (composables/useVimNavigation.ts) */
  let offVim = () => {}
  let vimGone = false
  const startVim = () => perfWhenIdle(() => {
    import('~/composables/useVimNavigation').then((m) => {
      if (vimGone) return
      offVim = m.installVimNavigation({ claim: () => session.claims?.keyboard_shortcuts, phone: () => isMobile.value, router })
    }).catch(() => { /* a chunk gone after a deploy: no vim keys on this tab */ })
  })
  function dispose() {
    offPop(); offNav(); offPageFinish()
    vimGone = true; offVim()
  }
  return { routeAnnounce, skipToMsgs, startVim, dispose }
}
