import { useSpoolApi } from '~/composables/useSpoolApi'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import type { SpoolMessage } from '~/types/spool'
import { heldTopic } from '~/utils/poll-topic.mjs'

/* SPL-5954 (owner HUM-10, csitea 51150550): a poll form's answers are replies
   in its topic, already stored in the hub. The feed around a form holds only
   a window of them (the channel feed keeps 30 lines across its topics, the
   topic pane its newest page), so an answer outside the window left the form
   unanswered, for every reader and after every reload. A form reads its
   whole topic here, oldest first, shared by every form of that topic; a form
   mounted again after FRESH_MS (utils/poll-topic.mjs) reads it again (a
   sleep: anything the live socket missed); a sign-out drops it. Replies that come while it is open arrive live in
   the channel and topic stores the form also reads. */
const PAGE = 200
const MAX_PAGES = 10

type TopicPage = { messages?: SpoolMessage[], next?: string | null }
type Api = ReturnType<typeof useSpoolApi>

async function readAll(api: Api, task: string): Promise<SpoolMessage[]> {
  const out: SpoolMessage[] = []
  let after: string | undefined
  for (let i = 0; i < MAX_PAGES; i++) {
    const page = await withSessionRetry(api, () => api.getTopic(task, { limit: PAGE, after })) as TopicPage
    const rows = page.messages || []
    out.push(...rows)
    after = page.next || undefined
    if (!after || rows.length < PAGE) break
  }
  return out
}

function held(api: Api, task: string): { rows: Ref<SpoolMessage[]> } {
  if (!import.meta.client) return { rows: shallowRef<SpoolMessage[]>([]) }
  return heldTopic(task, (t: string) => readAll(api, t))
}

/** the whole topic of a poll form ([] until the read lands) */
export function usePollTopic(task: () => string): ComputedRef<SpoolMessage[]> {
  const api = useSpoolApi()
  const id = computed(() => task())
  const h = computed(() => (id.value ? held(api, id.value) : null))
  return computed(() => h.value?.rows.value || [])
}
