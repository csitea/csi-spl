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

/**
 * Owner (t1 f4e6c677): the Channels and Direct messages tabs' numbers, the
 * hub's unread in the viewer's own discussions split by channel / DM. Null
 * = not known (no counts yet, or a hub without the split): the pip stays.
 */
const rail = ref<{ channels: number, dms: number } | null>(null)

export function useFlowRail() {
  return rail
}

/**
 * Owner (t1 77540e6f): the hub's Flow unread per sidebar row (ch:<channel>,
 * dm:<peer>, t:<task_id>), the one source of every row badge and section
 * number. Null = not known (no counts yet, or a hub without `keys`): the
 * rows keep their own counts.
 */
const keys = ref<Record<string, number> | null>(null)

export function useFlowKeys() {
  return keys
}
