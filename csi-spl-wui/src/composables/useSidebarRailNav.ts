/*
 * ChannelSidebar's rail and section navigation (r19-01): a rail tab's click,
 * the Issues number, the search list's X. It writes the sidebar's `tab`,
 * `holdFlow` and `holdSearch` and moves the router.
 */
import type { Ref } from 'vue'
import { useMobileStack } from '~/composables/useMobileStack'
import { useSectionExit } from '~/composables/useSectionExit'
import { useOperatorPane } from '~/stores/operator-pane'
import { useLiveFeed } from '~/stores/live'
import { useTopicStore } from '~/stores/topic'
import { chatKind, isSectionPage } from '~/utils/section-strip.mjs'
import { ARCHIVE_TAB, CALENDAR_TAB, EXPENSES_TAB, ISSUES_TAB, MONITORING_TAB, NOTES_TAB, PEOPLE_TAB, REPORTING_TAB, isSearchPage, tabForPath } from '~/utils/sidebar-tabs.mjs'
import { productPath } from '~/utils/signed-out-redirect.mjs'

const PHONE_LIST_TABS = new Set<string>(['dm', 'channels', 'flow', 'people'])
const withoutQuery = (path: string) => path.split(/[?#]/)[0]
function railSwitchPath(next: string, kind: string, sectionExit: ReturnType<typeof useSectionExit>, localePath: ReturnType<typeof useLocalePath>) {
  if (next === 'dm' && kind === 'channel') return withoutQuery(sectionExit.target('dm')) || localePath('/dm')
  const back = next === 'channels' && kind === 'dm' ? withoutQuery(sectionExit.target('channels')) : ''
  return back.startsWith('/lobby') ? localePath(back) : back
}

/* a section with a page of its own opens it, unless the route is on it already */
async function openSectionPage(next: string, phoneList: boolean, query: Record<string, string> | undefined, route: ReturnType<typeof useRoute>, localePath: ReturnType<typeof useLocalePath>) {
  if (next === ARCHIVE_TAB && tabForPath(route.path) !== ARCHIVE_TAB) await navigateTo(localePath('/archive'))
  if (next === ISSUES_TAB && query) await navigateTo({ path: localePath('/issues'), query })
  else if (next === ISSUES_TAB) await navigateTo(localePath('/issues'))
  /* CLE-77794: People lands on its index (the "pick someone" card in the
     middle pane); a click on a row then opens /people/<id>. */
  if (next === PEOPLE_TAB && !phoneList && tabForPath(route.path) !== PEOPLE_TAB) await navigateTo(localePath('/people'))
  if (next === CALENDAR_TAB && tabForPath(route.path) !== CALENDAR_TAB) await navigateTo(localePath('/calendar'))
  if (next === MONITORING_TAB && tabForPath(route.path) !== MONITORING_TAB) await navigateTo(localePath('/monitoring'))
  if (next === REPORTING_TAB && tabForPath(route.path) !== REPORTING_TAB) await navigateTo(localePath('/reporting'))
  if (next === NOTES_TAB && tabForPath(route.path) !== NOTES_TAB) await navigateTo(localePath('/notes'))
  if (next === EXPENSES_TAB && tabForPath(route.path) !== EXPENSES_TAB) await navigateTo(localePath('/expenses'))
}

export function useSidebarRailNav<T extends string>(opts: {
  tab: Ref<T>
  holdFlow: Ref<boolean>
  holdSearch: Ref<boolean>
  stripOnly: Readonly<Ref<boolean>>
  onRailLink: Readonly<Ref<boolean>>
  helpRailOnly: Readonly<Ref<boolean>>
  docsRailOnly: Readonly<Ref<boolean>>
}) {
  const { tab, holdFlow, holdSearch, stripOnly, onRailLink, helpRailOnly, docsRailOnly } = opts
  const route = useRoute()
  const mobileStack = useMobileStack()
  const sectionExit = useSectionExit()
  const localePath = useLocalePath()
  const livePane = useLiveFeed('pane'), topic = useTopicStore(), operatorPane = useOperatorPane()
  /* Flow stays on this page and mixes the
     lists. Direct messages and channels only swap the sidebar. */
  /* owner HUM-10 (t1 27b3ab77 msg 3aee57ba): "no way for me to find out what
     these three issues are" - the Issues number opens the list filtered to
     exactly the issues it counts (?unread=1); the rest of the tab stays the tab */
  function onCountClick(id: T, ev: Event) {
    if (id !== ISSUES_TAB) return
    ev.stopPropagation()
    void selectTab(id, { unread: '1' })
  }
  async function selectTab(next: T, query?: Record<string, string>) {
    /* CLE-77886: on a phone, a tap on the section already selected above its
       own page shows that section's list at level 1 (the Issues epics, ...),
       where the page's Back chevron used to lead */
    if (!query && stripOnly.value && next === tab.value && !onRailLink.value) {
      mobileStack.home()
      return
    }
    holdFlow.value = next === 'flow'
    holdSearch.value = false
    tab.value = next
    /* CLE-77886: on a phone a section whose content is this sidebar's list
       (Channels, DMs, Flow, People, Agents, Boxes) shows it at level 1 under
       the strip - from a section page's strip too - instead of a bare page */
    const phoneList = mobileStack.isMobile.value && PHONE_LIST_TABS.has(next)
    if (phoneList && mobileStack.level.value > 1) mobileStack.home()
    /* CLE-77886 (HUM-24, csitea 7930dfbf: no exit from Issues): on a desktop
       Channels / Direct messages / Flow picked over a section page (Issues,
       Event log, ...) also bring back the conversation the reader left - the
       list on the left alone kept the page and read as a dead end. Owner
       (t1 777d6c9a): on a rail-only page (Docs (Qto) /workspace/docs, a Help
       or Docs document) the sidebar hides its list, so the tab alone changed
       nothing and the rail read as frozen: leave it, to the lobby at least. */
    const railOnlyPage = helpRailOnly.value || docsRailOnly.value
    if (!mobileStack.isMobile.value && (next === 'channels' || next === 'dm' || next === 'flow') && (railOnlyPage || (isSectionPage(route.path) && productPath(route.path) !== '/'))) {
      const back = withoutQuery(sectionExit.target(next)) || (railOnlyPage ? '/lobby' : '')
      if (back) await navigateTo(back.startsWith('/lobby') ? localePath(back) : back)
    }
    await openSectionPage(next, phoneList, query, route, localePath)
  }
  /* SPL-2765 (owner, 2026-10-21): every click on a leftmost section closes the
     reply panel and the list of the section left (a lobby topic left open on a
     DM took a person's note, prd msg 86530802). A way back drops ?topic=; on a
     phone the list is the screen. The panes close after the route: a topic
     closed first replaces ?topic=, which cancelled the navigation. A topic's
     page (/t/<id>) is the thread itself, no reply panel (spec 109 T007). */
  async function railClick(next: T) {
    if (/^\/t\/[^/]+$/.test(productPath(route.path))) return selectTab(next)
    const to = mobileStack.isMobile.value ? '' : railSwitchPath(next, chatKind(route.path), sectionExit, localePath)
    if (to) await navigateTo(to)
    await selectTab(next)
    livePane.close(); topic.close(); operatorPane.close()
  }
  /* CLE-77884: the search list's X - back to the list the page belongs to */
  function closeSearch() {
    holdSearch.value = false
    tab.value = (tabForPath(route.path) || 'channels') as T
    if (isSearchPage(route.path)) void navigateTo(localePath('/'))
  }
  return { selectTab, railClick, closeSearch, onCountClick }
}
