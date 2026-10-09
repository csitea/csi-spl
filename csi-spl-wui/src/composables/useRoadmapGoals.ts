/**
 * Spec 112 WUI-3 (6, 12.6): the goals of the workspace the roadmap shows,
 * shared by pages/roadmap.vue (the goal rows) and pages/goals/[id].vue.
 *
 * The workspace filter lists only what the viewer may see (utils/
 * roadmap-goals roadmapWorkspaces): signed in, their memberships; signed
 * out, the page host's workspace when its roadmap is public. A ?ws= outside
 * that list is `blocked`: nothing is read for it. The hub's member read is
 * the session's workspace, so another membership asks for the tenant switch
 * (`otherWs`) before its goals show. Imported by those two pages only, so
 * none of it rides the initial chunk.
 */
import { fetchMemberGoalEvents, fetchPublicGoalEvents } from '~/utils/roadmap-goals-api.mjs'
import { roadmapGoals, roadmapPickWs, roadmapWorkspaces, roadmapWs } from '~/utils/roadmap-goals.mjs'
import { useSessionStore } from '~/stores/session'
import { useTenantSwitch } from '~/composables/useTenantSwitch'

export type RoadmapGoal = ReturnType<typeof roadmapGoals>[number]

/* the mock workspace's id when the client names none (roadmap-goals-mock) */
const MOCK_WS = 'demo'

export function useRoadmapGoals() {
  const api = useSpoolApi()
  const session = useSessionStore()
  const route = useRoute()
  const router = useRouter()
  const sw = useTenantSwitch()

  const state = ref<'loading' | 'ready' | 'error'>('loading')
  const goals = ref<RoadmapGoal[]>([])
  const hostPublic = ref(false)

  const signedOut = computed(() => session.state === 'out')
  const tenant = computed(() => String(api.tenant || '') || (api.mock ? MOCK_WS : ''))
  const list = computed(() => roadmapWorkspaces({ signedOut: signedOut.value, claims: session.claims, tenant: tenant.value, hostPublic: hostPublic.value }))
  const pick = computed(() => roadmapPickWs(list.value, roadmapWs(route.query.ws)))
  const ws = computed(() => pick.value.ws)
  const blocked = computed(() => pick.value.blocked)
  /* a membership that is not the session's workspace: shown after the switch */
  const otherWs = computed(() => (!signedOut.value && ws.value && ws.value !== list.value.active ? ws.value : ''))

  let seq = 0
  async function load() {
    if (session.state === 'loading') return
    const mine = ++seq
    state.value = 'loading'
    try {
      let events: unknown[] = []
      if (signedOut.value) {
        events = tenant.value ? await fetchPublicGoalEvents(api, tenant.value) : []
        if (mine !== seq) return
        hostPublic.value = events.length > 0
      } else if (ws.value && !otherWs.value && !blocked.value) {
        events = await fetchMemberGoalEvents(api, ws.value, list.value.options.map((o: { id: string }) => o.id))
      }
      if (mine !== seq) return
      goals.value = roadmapGoals(events)
      state.value = 'ready'
    } catch {
      if (mine !== seq) return
      goals.value = []
      state.value = 'error'
    }
  }

  async function setWs(id: string) {
    await router.replace({ query: { ...route.query, ws: id || undefined, goal: undefined }, hash: route.hash })
  }

  async function switchToWs() {
    if (otherWs.value) await sw.switchTo(otherWs.value)
  }

  watch(() => [session.state, list.value.active, ws.value, blocked.value] as const, () => { void load() })
  onMounted(() => {
    /* a failed probe leaves the state as it is; the watch reloads once it settles */
    if (session.state === 'loading') void session.probe().catch(() => {})
    void load()
  })

  return { state, goals, workspaces: computed(() => list.value.options), ws, blocked, otherWs, signedOut, setWs, switchToWs, switching: sw.switching }
}
