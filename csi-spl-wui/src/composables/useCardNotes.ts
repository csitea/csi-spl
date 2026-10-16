/*
 * The small lines under MessageCard's header (r13-01): where a moved card
 * came from, which topic a DM is about, and the topic a DM-view pointer is in.
 */
import { computed } from 'vue'
import { movedNote } from '~/utils/move.mjs'
import { cardTitle } from '~/utils/card-clip.mjs'
import { useDmRef } from '~/composables/useDmRef'
import { useChannelStore } from '~/stores/channel'
import type { SpoolMessage } from '~/types/spool'

export function useCardNotes(props: { msg: SpoolMessage }) {
  const { t } = useI18n({ useScope: 'global' })
  /* "moved from #x" on a card, "moved from <topic>" on a reply */
  const channelStore = useChannelStore()
  const movedInfo = computed(() => movedNote(props.msg))
  const movedFrom = computed(() => {
    const n = movedInfo.value
    return n ? (n.kind === 'channel' ? n.channel : n.task) : undefined
  })
  const movedText = computed(() => {
    const n = movedInfo.value
    if (!n) return ''
    if (n.kind === 'channel') return t('feed.move.from_channel', { channel: n.channel })
    const home = channelStore.messages.find((r) => String(r.task_id || '') === n.task && r.is_parent !== 0)
    const name = home ? cardTitle(String(home.body || '')) : ''
    return name ? t('feed.move.from_topic', { title: name.length > 48 ? `${name.slice(0, 47)}…` : name }) : t('feed.move.from_topic_unknown')
  })
  /* spec 067 rule 3: "about #channel / topic" on a DM that carries ref_task_id */
  const { refOf } = useDmRef()
  const dmRefTopic = computed(() => (props.msg.ref_task_id && !props.msg.channel ? refOf(String(props.msg.ref_task_id)).value : null))
  const dmRef = computed(() => Boolean(dmRefTopic.value))
  function dmAbout(cut: boolean) {
    const r = dmRefTopic.value
    if (!r) return ''
    const name = channelStore.channels.find((c) => c.channel_id === r.channel)?.name || r.channel
    return t('feed.dm_about', { channel: name, topic: cut && r.title.length > 48 ? `${r.title.slice(0, 47)}…` : r.title })
  }
  const dmRefText = computed(() => dmAbout(true))
  /* dc6d5e3f: the topic a DM-view pointer is in (its title from the same one-read cache) */
  const pointerTopic = computed(() => (props.msg.pointer && props.msg.channel ? refOf(String(props.msg.task_id || '')).value : null))
  function pointerIn(cut: boolean) {
    const ch = String(props.msg.channel || '').replace(/^#/, '')
    const name = channelStore.channels.find((c) => c.channel_id === ch)?.name || ch
    const title = pointerTopic.value?.title || ''
    return t('feed.dm_pointer', { channel: name, topic: cut && title.length > 48 ? `${title.slice(0, 47)}…` : title })
  }
  const pointerText = computed(() => pointerIn(true))
  const pointerTip = computed(() => pointerIn(false))
  const dmRefTip = computed(() => dmAbout(false))
  return { movedFrom, movedText, dmRef, dmRefText, dmRefTip, pointerText, pointerTip }
}
