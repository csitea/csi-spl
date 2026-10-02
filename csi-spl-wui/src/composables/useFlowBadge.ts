/**
 * Spec 062: the Flow tab's number, the hub's unseen + unread total. -1 =
 * not known (no counts yet, or a hub without GET /v1/view/flow): the tab
 * then keeps its unread pip and the tab title its channel/DM total. Eager
 * and tiny on purpose: the Flow store that fills it loads lazily.
 */
const total = ref(-1)

export function useFlowBadge() {
  return total
}
