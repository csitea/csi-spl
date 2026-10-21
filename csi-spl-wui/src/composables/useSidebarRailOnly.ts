/*
 * ChannelSidebar's rail-only pages (r16-06): the sections whose page holds
 * the whole view, so the sidebar keeps the icon rail alone (.sidebar--rail).
 */
import type { Ref } from 'vue'
import type { RouteLocationNormalizedLoaded } from 'vue-router'
import { railLinkSection } from '~/utils/section-strip.mjs'
import { CALENDAR_TAB, MONITORING_TAB, REPORTING_TAB } from '~/utils/sidebar-tabs.mjs'

export function useSidebarRailOnly(tab: Ref<string>, isMobile: Ref<boolean>, route: RouteLocationNormalizedLoaded) {
  /* No "All issues" row. With no epic rows the panel is empty, so the
     sidebar keeps the icon rail and the issue list takes the width. */
  const issueEpics = useState<Array<{ key: string }>>('issue-epics', () => [])
  const issuesRailOnly = computed(() => tab.value === 'issues' && issueEpics.value.length === 0)
  /* spec 089 T007: /calendar is a single sheet like Issues - the sidebar keeps
     the icon rail only; the page holds the year strip and the main view. */
  const calendarRailOnly = computed(() => tab.value === CALENDAR_TAB)
  /* SPL-1991: so is /monitoring - its own tab bar is the page's, not a list here */
  const monitoringRailOnly = computed(() => tab.value === MONITORING_TAB)
  /* spec 143 1.3 (SPL-2351): and /reporting, its tab bar the page's too */
  const reportingRailOnly = computed(() => tab.value === REPORTING_TAB)
  /* t1 67f91532 (owner: "the help section should have only 2 panes"): on
     /help the sidebar keeps the icon rail only; the help page itself is the
     two panes, its page list left and the document right. A phone keeps its
     one-pane stack (the section strip above the page). */
  const helpRailOnly = computed(() => !isMobile.value && railLinkSection(route.path) === 'help')
  /* t1 c13e8023 (owner): on /docs the sidebar keeps the icon rail only; the
     docs page is the two panes, the explorer left and the document right.
     A phone keeps its one-pane stack. */
  const docsRailOnly = computed(() => !isMobile.value && railLinkSection(route.path) === 'docs')
  /* any of the above: the sidebar is the icon rail alone (.sidebar--rail) */
  const railOnly = computed(() => issuesRailOnly.value || calendarRailOnly.value || monitoringRailOnly.value || reportingRailOnly.value || helpRailOnly.value || docsRailOnly.value)
  return { issueEpics, issuesRailOnly, calendarRailOnly, monitoringRailOnly, reportingRailOnly, helpRailOnly, docsRailOnly, railOnly }
}
