/*
 * spec 130 section 3.1 (owner e04820a5: "point to a certain set ... by
 * simply copy pasting the url"): ?flow=<id> on any page opens the Flow tab
 * on that member's Flow. ChannelSidebar calls it; the lazy FlowList reads
 * the request. A navigation away (opening a line) keeps the choice; the
 * same page without ?flow= (Back, the picker on "me") is the reader's own.
 */
import { FLOW_MEMBER_QUERY, flowMemberFromQuery } from '~/utils/flow-member.mjs'

/** The member the address asks for: null = no instruction, '' = the reader's own. */
export function useFlowMemberRequest() {
  return useState<string | null>('flow.member-route', () => null)
}

export function useFlowMemberRoute(open: () => void) {
  const route = useRoute()
  const want = useFlowMemberRequest()
  watch(() => [route.path, route.query[FLOW_MEMBER_QUERY]] as const, ([path], prev) => {
    const member = flowMemberFromQuery(route.query)
    if (member) {
      if (want.value !== member) open()
      want.value = member
    } else if (prev && prev[0] === path && prev[1]) want.value = ''
  }, { immediate: true })
}
