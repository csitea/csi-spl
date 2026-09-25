import { useSpoolApi } from '~/composables/useSpoolApi'
import { useLive } from '~/composables/useLive'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useChannelStore } from '~/stores/channel'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import { reactionOp } from '~/utils/emoji.mjs'
import type { ReactionUpdate, SpoolMessage } from '~/types/spool'

/**
 * Add or remove the viewer's emoji on a message, then paint it everywhere
 * that message is held.
 *
 * The middle list (is_parent 1) and the topic pane (is_parent 0, and the
 * opening line again) are different stores holding the same msg_id. One
 * call updates all of them. A store that does not hold the id ignores it.
 */
export function useMessageEmoji() {
  const api = useSpoolApi()
  const live = useLive()
  const access = useAccessStore()
  const roster = useRosterStore()

  const viewerId = computed(() => String(access.me?.humanId || live.identity.value || roster.me?.id || ''))

  async function setReaction(msg: SpoolMessage, emoji: string): Promise<ReactionUpdate> {
    const id = String(msg?.msg_id || '')
    if (!id) throw Object.assign(new Error('msg_id required'), { status: 400, token: 'bad_json' })
    const op = reactionOp(msg.reactions, emoji, viewerId.value)
    return api.setReaction(id, emoji, op, msg.reactions) as Promise<ReactionUpdate>
  }

  function applyEverywhere(update: ReactionUpdate | null | undefined) {
    if (!update || !update.msg_id) return
    useChannelStore().applyReactions(update)
    useLiveFeed('main').applyReactions(update)
    useLiveFeed('pane').applyReactions(update)
    useTopicStore().applyReactionsUpdate(update)
  }

  return { viewerId, setReaction, applyEverywhere }
}
