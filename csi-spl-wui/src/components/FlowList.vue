<template>
  <!-- Flow (topic 635f8072): short message entries, newest first, in the left
       panel (the shared SideHitList, lane C). A click / Enter opens the
       message in its original place; the list, its scroll and its selection
       stay while the middle pane changes route. -->
  <div ref="scrollEl" class="sidebar-scroll flow-scroll" @scroll.passive="onScroll">
    <p v-if="!items.length" class="muted topic-empty">{{ flow.loading ? t('flow.loading') : t('feed.empty') }}</p>
    <LazySideHitList
      v-else
      ref="listEl"
      mode="flow"
      :items="items"
      :active-key="flow.activeKey"
      :label="t('flow.list')"
      @active="flow.select"
      @open="openKey"
    />
  </div>
</template>

<script setup lang="ts">
import { useFlowStore } from '~/stores/flow'
import { useOpenMessage } from '~/composables/useOpenMessage'
import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { useHumanNames } from '~/composables/useHumanNames'
import { useNowTick } from '~/composables/useNowTick'
import { useMobileStack } from '~/composables/useMobileStack'
import { flowUnread } from '~/utils/flow-entries.mjs'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import type { SideHitItem } from '~/utils/side-hit-list.mjs'
import { loadCursors } from '~/utils/read-cursor.mjs'
import { formatMsgListTs, phoneCardTime, shownPerson } from '~/utils/channel-feed.mjs'

const props = withDefaults(defineProps<{ active?: boolean }>(), { active: true })

const { t } = useI18n({ useScope: 'global' })
const { openMessage } = useOpenMessage()
const flow = useFlowStore()
const channel = useChannelStore()
const notes = useNotificationStore()
const people = useHumanNames()
const stack = useMobileStack()
const now = useNowTick(() => props.active)
const scrollEl = ref<HTMLElement | null>(null)
const listEl = ref<{ focus: () => void } | null>(null)

/* the unread dot reads the same local cursors the badges do; a badge cleared
   elsewhere (notes.unread changes) re-reads them */
const cursors = computed(() => {
  void notes.unread
  return import.meta.client ? loadCursors() : {}
})

function personOf(label: string) {
  const at = label.indexOf('@')
  return at > 0 ? { id: label.slice(0, at), box: label.slice(at + 1) } : { id: label, box: '' }
}

function channelName(id: string) {
  const c = channel.channels.find((r) => String(r.channel_id || '') === id)
  return String((c && c.name) || id)
}

const items = computed<SideHitItem[]>(() => flow.entries.map((e: FlowEntry) => {
  const peer = e.kind === 'dm' ? personOf(e.where) : null
  const where = e.kind === 'channel' ? channelName(String(e.channel)) : shownPerson(peer!.id, peer!.box, people.names.value)
  const place = (e.kind === 'channel' ? '#' : '@') + where
  return {
    key: e.key,
    msgId: e.msg_id,
    type: e.reply ? 'reply' : e.kind,
    badge: e.reply ? '↳' : e.kind === 'channel' ? '#' : '@',
    who: { id: e.from, box: e.from_box },
    where,
    when: phoneCardTime(formatMsgListTs(e.at), e.at, now.value),
    text: e.text || '📎',
    title: (e.reply ? t('flow.reply_in', { place }) : place) + '\n' + e.text,
    unread: flowUnread(e, cursors.value, flow.opened),
  }
}))

/**
 * The message in its original place (lane A, CLE-77882): its channel or DM
 * scrolled to it and highlighted, a reply in its thread. The row is passed
 * whole, so no lookup; the Flow list stays while it navigates.
 */
async function openKey(key: string) {
  const row = flow.entries.find((r: FlowEntry) => r.key === key)
  if (!row) return
  flow.select(key)
  flow.markOpened(key)
  /* the keyboard stays on the list, so the next ArrowDown keeps cycling */
  const keyboard = Boolean(scrollEl.value && scrollEl.value.contains(document.activeElement))
  await openMessage(row)
  if (keyboard && !stack.isMobile.value) listEl.value?.focus()
}

/* the scroll survives the panel being hidden (another tab, a phone at level
   2): it is kept per tab and put back when the list shows again */
const scrollTop = useState('flow.scroll-top', () => 0)
function onScroll() {
  if (scrollEl.value && scrollEl.value.offsetParent !== null) scrollTop.value = scrollEl.value.scrollTop
}
function restoreScroll() {
  void nextTick(() => {
    const el = scrollEl.value
    if (el && el.offsetParent !== null && el.scrollTop !== scrollTop.value) el.scrollTop = scrollTop.value
  })
}
watch(() => [props.active, stack.level.value] as const, ([on, level]) => {
  if (!on) return
  flow.ensure()
  restoreScroll()
  /* phone: Back to the list puts the keyboard on the chosen entry again */
  if (stack.isMobile.value && level === 1 && flow.activeKey) void nextTick(() => listEl.value?.focus())
})
onMounted(() => {
  flow.ensure()
  restoreScroll()
})
</script>
