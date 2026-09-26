// SPL-985 (spec 042 §3): after a text is STORED, each person or agent it
// newly mentions gets a direct message from the author asking them to act -
// the same DM a person would type, so an agent's desk and pane get it like
// any other DM (spec 028). Rules are utils/mention-poke.mjs (unit-tested):
// who is poked (K3), the words (K1), who may be told (K4). A refusal or a
// failed poke is one snackbar line (K4, K6); the stored text is never rolled
// back for it.
import { noteError } from '@/composables/errorJournal.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore } from '~/stores/roster'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { sendWithResend } from '~/utils/send-failure.mjs'
import {
  cardLink,
  channelAccess,
  issueLink,
  pokeBody,
  pokeTargets,
  splitByAccess,
  type MentionAccess,
} from '~/utils/mention-poke.mjs'

function newId() {
  return globalThis.crypto && globalThis.crypto.randomUUID ? globalThis.crypto.randomUUID() : ''
}

export interface PokeWhere {
  /** a card, reply or comment: its task id; an issue: its key */
  taskId?: string
  issueKey?: string
  /** where the text lives, for K4: a channel id, a DM peer (id@box), or an issue */
  channel?: string
  peer?: string
  /** a DM topic's two ends (utils/mention-poke.mjs topicWhere) */
  ends?: string[]
  issue?: boolean
  /** where is not known: tell nobody (K4) */
  unknown?: boolean
}

export function useMentionPoke() {
  const api = useSpoolApi()
  const roster = useRosterStore()
  const live = useLive()
  /* the global instance: this runs from stores too, outside any setup() */
  const i18n = useNuxtApp().$i18n

  async function accessOf(where: PokeWhere, selfId: string): Promise<MentionAccess> {
    if (where.unknown) return null
    if (where.issue) return { kind: 'open' }
    if (where.ends) return { kind: 'dm', ends: where.ends }
    if (where.peer) return { kind: 'dm', ends: [selfId, where.peer] }
    if (!where.channel) return { kind: 'open' } /* the lobby */
    try {
      return channelAccess(await withSessionRetry(api, () => api.listChannelMembers(String(where.channel))))
    } catch {
      return null /* unknown: tell nobody rather than leak */
    }
  }

  async function sendDm(id: string, body: string) {
    const client = live.ensure()
    if (!client) throw new Error('live socket unavailable')
    const frame = { task_id: newId(), msg_id: newId() || undefined, kind: 'note', body, files: [], to: id, is_parent: 1 as const }
    await sendWithResend(() => client.send(frame))
  }

  function warn(key: string, ids: string[]) {
    noteError({ source: 'mention', name: 'MentionPoke', message: i18n.t(key, { ids: ids.join(', ') }) })
  }

  /**
   * `text` was just stored at `where`. `before` is the text before an edit
   * (only new mentions poke); `addressee` the agent the send itself went to.
   * Resolves to what happened; never throws.
   */
  async function poke(opts: { text: string, before?: string, addressee?: string, where: PokeWhere }) {
    /* the mock tenant has nobody to tell, and its feeds are what the e2e reads */
    if (api.mock) return { told: [] as string[], refused: [] as string[], failed: [] as string[] }
    const self = roster.self ? roster.self.id : ''
    const ids = pokeTargets({ text: opts.text, before: opts.before || '', selfId: self, addressee: opts.addressee || '' })
    if (!ids.length) return { told: [] as string[], refused: [] as string[], failed: [] as string[] }
    const { ok, refused } = splitByAccess(ids, await accessOf(opts.where, self))
    if (refused.length) warn('mention.not_told', refused)
    const origin = typeof window !== 'undefined' ? window.location.origin : ''
    const link = opts.where.issueKey ? issueLink(origin, opts.where.issueKey) : cardLink(origin, opts.where.taskId || '')
    const body = pokeBody({ author: self, link, text: opts.text })
    const told: string[] = []
    const failed: string[] = []
    for (const id of ok) {
      try {
        await sendDm(id, body)
        told.push(id)
      } catch {
        failed.push(id)
      }
    }
    if (failed.length) warn('mention.poke_failed', failed)
    return { told, refused, failed }
  }

  return { poke }
}
