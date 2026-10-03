// SPL-985 (spec 042 §3): after a text is STORED, each person or agent it
// newly mentions gets a direct message from the author asking them to act -
// the same DM a person would type, so an agent's desk and pane get it like
// any other DM (spec 028). Rules are utils/mention-poke.mjs (unit-tested):
// who is poked (K3), the words (K1), who may be told (K4). A refusal or a
// failed poke is one snackbar line (K4, K6); the stored text is never rolled
// back for it. CLE-77852: an agent seated in the workspace but not in the
// channel is DM-poked anyway, and the author gets a notice saying so.
// Spec 067 (Q3, rule 3): a PERSON is never poked (the @mention reaches them in
// Flow), and an agent's poke carries ref_task_id, the channel topic it is about.
import { noteError } from '@/composables/errorJournal.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useRosterStore } from '~/stores/roster'
import { withSessionRetry } from '~/utils/live-follow.mjs'
import { sendWithResend } from '~/utils/send-failure.mjs'
import {
  agentTargets,
  cardLink,
  channelAccess,
  issueLink,
  mentionBoxes,
  pokeBody,
  pokeFrame,
  pokeTargets,
  splitPokes,
  type MentionAccess,
} from '~/utils/mention-poke.mjs'

function newId() {
  return globalThis.crypto && globalThis.crypto.randomUUID ? globalThis.crypto.randomUUID() : ''
}

/** CLE-77852: how long the "sent as a direct message" notice stays up. */
export const DIRECT_NOTE_MS = 6000

type DirectNote = { id: number, text: string }

/* one notice per tab, shared by the poking store and the shell's toast */
const directNote = shallowRef<DirectNote | null>(null)
let noteSeq = 0

/** The shell's MentionDirectToast reads and dismisses the notice. */
export function useMentionDirectNote() {
  return { note: directNote, dismiss: () => { directNote.value = null } }
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

/* spec 067 rule 3: the channel topic a poke is about; none from an issue or a DM */
function refOf(where: PokeWhere) {
  return where.issue || where.ends || where.peer ? '' : String(where.taskId || '')
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

  async function sendDm(id: string, body: string, toBox?: string, refTaskId?: string) {
    const client = live.ensure()
    if (!client) throw new Error('live socket unavailable')
    const frame = pokeFrame({ to: id, body, toBox, taskId: newId(), msgId: newId(), refTaskId })
    await sendWithResend(() => client.send(frame))
  }

  function noteDirect(ids: string[]) {
    directNote.value = { id: ++noteSeq, text: i18n.t('mention.sent_direct', { ids: ids.join(', ') }) }
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
    const none = { told: [] as string[], refused: [] as string[], failed: [] as string[] }
    const self = roster.self ? roster.self.id : ''
    const ids = agentTargets(pokeTargets({ text: opts.text, before: opts.before || '', selfId: self, addressee: opts.addressee || '' }))
    if (!ids.length) return none
    const seated = roster.people.map((p) => p.id)
    /* the mock tenant has nobody to tell, and its feeds are what the e2e reads:
       it sends nothing and warns nothing, but shows the direct notice (e2e) */
    if (api.mock) {
      if (opts.where.channel) {
        const { direct } = splitPokes(ids, await accessOf(opts.where, self), seated)
        if (direct.length) noteDirect(direct)
      }
      return none
    }
    const { ok, direct, refused } = splitPokes(ids, await accessOf(opts.where, self), seated)
    if (refused.length) warn('mention.not_told', refused)
    const origin = typeof window !== 'undefined' ? window.location.origin : ''
    const link = opts.where.issueKey ? issueLink(origin, opts.where.issueKey) : cardLink(origin, opts.where.taskId || '')
    const body = pokeBody({ author: self, link, text: opts.text })
    const told: string[] = []
    const failed: string[] = []
    const boxes = mentionBoxes(opts.text)
    for (const id of [...ok, ...direct]) {
      try {
        await sendDm(id, body, boxes[id], refOf(opts.where))
        told.push(id)
      } catch {
        failed.push(id)
      }
    }
    if (failed.length) warn('mention.poke_failed', failed)
    const sentDirect = direct.filter((id) => told.includes(id))
    if (sentDirect.length) noteDirect(sentDirect)
    return { told, refused, failed }
  }

  return { poke }
}
