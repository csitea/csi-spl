// SPL-5780: the body of useMentionPoke().poke, loaded with the first poke and
// never with the entry (155 KB gzip): a poke only follows a stored text,
// after first paint. useMentionPoke.ts keeps what the first screen needs
// (the composable's setup, the direct-notice state) and hands its setup here.
// The rules (who is poked, the words, who may be told) are still
// utils/mention-poke.mjs, loaded through loadMentionPoke.
import { noteError } from '@/composables/errorJournal.mjs'
import type { useSpoolApi } from '~/composables/useSpoolApi'
import type { useLive } from '~/composables/useLive'
import type { useRosterStore } from '~/stores/roster'
import type { PokeOpts, PokeWhere, loadMentionPoke } from '~/composables/useMentionPoke'
import { withSessionRetry } from '~/utils/live-follow-core.mjs'
import { sendWithResend } from '~/utils/send-failure.mjs'
import type { MentionAccess } from '~/utils/mention-poke.mjs'

export interface MentionPokeCtx {
  api: ReturnType<typeof useSpoolApi>
  roster: ReturnType<typeof useRosterStore>
  live: ReturnType<typeof useLive>
  i18n: ReturnType<typeof useNuxtApp>['$i18n']
  loadMentionPoke: typeof loadMentionPoke
  noteDirect: (ids: string[]) => void
}

function newId() {
  return globalThis.crypto && globalThis.crypto.randomUUID ? globalThis.crypto.randomUUID() : ''
}

/* spec 067 rule 3: the channel topic a poke is about; none from an issue or a DM */
function refOf(where: PokeWhere) {
  return where.issue || where.ends || where.peer ? '' : String(where.taskId || '')
}

/** K4: who may be told about a text at `where` (null: unknown, tell nobody). */
async function accessOf(ctx: MentionPokeCtx, where: PokeWhere, selfId: string): Promise<MentionAccess> {
  const { api, loadMentionPoke } = ctx
  if (where.unknown) return null
  if (where.issue) return { kind: 'open' }
  if (where.ends) return { kind: 'dm', ends: where.ends }
  if (where.peer) return { kind: 'dm', ends: [selfId, where.peer] }
  if (!where.channel) return { kind: 'open' } /* the lobby */
  try {
    const { channelAccess } = await loadMentionPoke()
    return channelAccess(await withSessionRetry(api, () => api.listChannelMembers(String(where.channel))))
  } catch {
    return null /* unknown: tell nobody rather than leak */
  }
}

/** useMentionPoke().poke for one composable instance's setup. */
export function mentionPokeRunner(ctx: MentionPokeCtx) {
  const { api, roster, live, i18n, loadMentionPoke, noteDirect } = ctx

  async function sendDm(id: string, body: string, toBox?: string, refTaskId?: string) {
    const client = live.ensure()
    if (!client) throw new Error('live socket unavailable')
    const { pokeFrame } = await loadMentionPoke()
    const frame = pokeFrame({ to: id, body, toBox, taskId: newId(), msgId: newId(), refTaskId })
    await sendWithResend(() => client.send(frame))
  }

  function warn(key: string, ids: string[]) {
    noteError({ source: 'mention', name: 'MentionPoke', message: i18n.t(key, { ids: ids.join(', ') }) })
  }

  async function poke(opts: PokeOpts) {
    const none = { told: [] as string[], refused: [] as string[], failed: [] as string[] }
    const self = roster.self ? roster.self.id : ''
    const rules = await loadMentionPoke().catch(() => null)
    if (!rules) return none
    const { agentTargets, cardLink, issueLink, mentionBoxes, pokeBody, pokeTargets, splitPokes } = rules
    const ids = agentTargets(pokeTargets({ text: opts.text, before: opts.before || '', selfId: self, addressee: opts.addressee || '' }))
    if (!ids.length) return none
    const seated = roster.people.map((p) => p.id)
    /* the mock tenant has nobody to tell, and its feeds are what the e2e reads:
       it sends nothing and warns nothing, but shows the direct notice (e2e) */
    if (api.mock) {
      if (opts.where.channel) {
        const { direct } = splitPokes(ids, await accessOf(ctx, opts.where, self), seated)
        if (direct.length) noteDirect(direct)
      }
      return none
    }
    const { ok, direct, refused } = splitPokes(ids, await accessOf(ctx, opts.where, self), seated)
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

  return poke
}
