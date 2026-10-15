import { computed, onUnmounted, ref, shallowRef, watch, type Ref } from 'vue'
import { isAgentId } from '~/utils/agent-id.mjs'
import { useChannelStore } from '~/stores/channel'
import { useLiveFeed } from '~/stores/live'
import type { SpoolMessage } from '~/types/spool'

/**
 * SPL-1994: the hourglass on a person's received post until an agent answers
 * (utils/await-reply.mjs holds the rule). These are the two hosts' halves:
 * a thread pane marks the waiting post, the channel list marks the topic row.
 */
export type AwaitMark = 'spin' | 'wait' | null
type Rule = typeof import('~/utils/await-reply.mjs')
type AwaitHit = ReturnType<Rule['awaitState']>

/* the rule loads on demand (ci_home_gzip_kb): the mark needs the second
   catalogue anyway, so nothing shows before either is there */
const rule = shallowRef<Rule | null>(null)
let loading: Promise<unknown> | null = null
function useRule() {
  if (import.meta.client && !loading) loading = import('~/utils/await-reply.mjs').then((m) => { rule.value = m }, () => { loading = null })
  return rule
}

/* one timer per feed, set for the next spin -> wait (or wait -> gone) change;
   no ticking while nothing waits */
function useAwaitClock() {
  const now = ref(Date.now())
  let timer: ReturnType<typeof setTimeout> | null = null
  const clear = () => { if (timer) clearTimeout(timer); timer = null }
  function plan(next: number) {
    clear()
    if (!import.meta.client || !Number.isFinite(next)) return
    const ms = Math.min(Math.max(next - Date.now() + 50, 1000), 2 ** 31 - 1)
    timer = setTimeout(() => { timer = null; now.value = Date.now() }, ms)
  }
  onUnmounted(clear)
  return { now, plan }
}

/** cnf env.wui.await_reply_minutes (/config.json awaitReplyMinutes), as text. */
function spinMinutes() {
  return String(useRuntimeConfig().public.awaitReplyMinutes ?? '')
}

/** An agent is a member of this channel, or the DM's peer is one. */
function agentsNear(channelId: string | null | undefined, peer?: string | null) {
  if (peer && isAgentId(String(peer).split('@')[0])) return true
  const want = String(channelId || '').replace(/^#/, '').toLowerCase()
  if (!want) return false
  const ch = useChannelStore().channels.find((c) => c.channel_id.toLowerCase() === want || String(c.name || '').toLowerCase() === want)
  return Number(ch?.members?.agents || 0) > 0
}

/** A thread pane: the one post that waits, by msg_id. */
export function useThreadAwait(rows: () => SpoolMessage[], on: () => boolean) {
  const clock = useAwaitClock()
  const minutes = spinMinutes()
  const r = useRule()
  const hit = computed<AwaitHit>(() => {
    const m = r.value
    if (!m || !on()) return null
    const list = rows()
    const ch = list.find((x) => x.channel)?.channel
    return m.awaitState(list, { now: clock.now.value, spinMs: m.awaitSpinMs(minutes), agents: agentsNear(ch) })
  })
  watch(hit, (h) => clock.plan(h ? h.until : Infinity), { immediate: true })
  return (m: SpoolMessage): AwaitMark => (hit.value && m.msg_id && hit.value.msgId === m.msg_id ? hit.value.state : null)
}

/**
 * The channel / DM list: a topic row waits when its topic does. The rows are
 * the channel store's (a new topic and the replies the socket brought) plus
 * the right pane's when that topic is open there.
 */
export function useChannelAwait(): (taskId: string) => AwaitMark {
  const channel = useChannelStore()
  const pane = useLiveFeed('pane')
  const clock = useAwaitClock()
  const minutes = spinMinutes()
  const r = useRule()
  const states: Ref<Map<string, NonNullable<AwaitHit>>> = computed(() => {
    const rm = r.value
    if (!rm) return new Map()
    const by = new Map<string, SpoolMessage[]>()
    for (const m of channel.messages as (SpoolMessage & { topic_row?: boolean })[]) {
      if (m.topic_row || !m.task_id) continue
      const list = by.get(m.task_id)
      if (list) list.push(m)
      else by.set(m.task_id, [m])
    }
    const open = pane.taskId
    if (open) {
      const held = by.get(open) || []
      const seen = new Set(held.map((m) => m.msg_id))
      by.set(open, [...held, ...pane.messages.filter((m) => !seen.has(m.msg_id))])
    }
    const agents = agentsNear(channel.active, channel.peer)
    const out = new Map<string, NonNullable<AwaitHit>>()
    for (const [task, list] of by) {
      const s = rm.awaitState(list, { now: clock.now.value, spinMs: rm.awaitSpinMs(minutes), agents })
      if (s) out.set(task, s)
    }
    return out
  })
  watch(states, (s) => clock.plan(r.value ? r.value.nextAwaitChange([...s.values()]) : Infinity), { immediate: true })
  return (taskId: string) => states.value.get(taskId)?.state ?? null
}
