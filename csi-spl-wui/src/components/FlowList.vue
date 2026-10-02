<template>
  <!-- Flow (topic 635f8072): short message entries, newest first, in the left
       panel (the shared SideHitList, lane C). A click / Enter opens the
       message in its original place; the list, its scroll and its selection
       stay while the middle pane changes route. -->
  <!-- spec 062: Mine (only what concerns me, the default) or All; the chips
       split Mine's unread by kind and filter on a click (a 0 chip is dimmed) -->
  <div v-if="flow.available !== false" class="flow-head" data-testid="flow-head">
    <div class="flow-scope" role="radiogroup" :aria-label="t('flow.scope_label')">
      <button
        v-for="s in FLOW_SCOPES"
        :key="s"
        type="button"
        role="radio"
        class="flow-scope__btn"
        :aria-checked="flow.scope === s ? 'true' : 'false'"
        :data-testid="'flow-scope-' + s"
        @click="flow.setScope(s)"
      >{{ t('flow.scope_' + s) }}</button>
    </div>
    <div v-if="flow.mineOn" class="flow-chips" role="group" :aria-label="t('flow.chips_label')">
      <button
        v-for="c in chips"
        :key="c.kind"
        type="button"
        class="flow-chip"
        :class="{ 'flow-chip--zero': !c.n }"
        :aria-pressed="flow.kind === c.kind ? 'true' : 'false'"
        :aria-disabled="!c.n && flow.kind !== c.kind ? 'true' : undefined"
        :title="t('flow.chip_' + c.kind, { n: c.n })"
        :aria-label="t('flow.chip_' + c.kind, { n: c.n })"
        :data-testid="'flow-chip-' + c.kind"
        :data-count="c.n"
        @click="pickKind(c.kind, c.n)"
      ><span aria-hidden="true">{{ c.icon }}</span> {{ c.n }}</button>
    </div>
  </div>
  <div ref="scrollEl" class="sidebar-scroll flow-scroll" @scroll.passive="onScroll">
    <p v-if="!items.length" class="muted topic-empty" data-testid="flow-empty">{{ loadingNow ? t('flow.loading') : flow.mineOn ? t('flow.empty_mine') : t('feed.empty') }}</p>
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
    <!-- owner 73c9704c: a page of 30 entries first, older ones on request -->
    <button
      v-if="items.length && flow.hasMore"
      type="button"
      class="btn ghost flow-more"
      data-testid="flow-load-more"
      :disabled="flow.loadingMore"
      @click="flow.loadMore()"
    >{{ flow.loadingMore ? t('feed.loading_older') : t('feed.load_more') }}</button>
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
import { FLOW_SCOPES } from '~/utils/flow-badge.mjs'
import type { FlowKind } from '~/utils/flow-badge.mjs'
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

const loadingNow = computed(() => (flow.mineOn ? flow.mineLoading : flow.loading))

/* spec 062 §3.1: @ mentions (pokes included), ↳ replies in my threads, ✉ DMs */
const CHIP_ICONS: Record<FlowKind, string> = { mention: '@', reply: '↳', dm: '✉' }
const chips = computed(() => (['mention', 'reply', 'dm'] as FlowKind[]).map((kind) => ({
  kind,
  icon: CHIP_ICONS[kind],
  n: Number((flow.unread || flow.counts)?.[kind] || 0),
})))
function pickKind(kind: FlowKind, n: number) {
  /* a 0 chip does not filter, unless it is the filter on (a click clears it) */
  if (!n && flow.kind !== kind) return
  flow.setKind(kind)
}

function placeTitle(e: FlowEntry, place: string) {
  if (e.event === 'mention') return t('flow.mention_in', { place })
  return e.reply ? t('flow.reply_in', { place }) : place
}

const items = computed<SideHitItem[]>(() => flow.visible.map((e: FlowEntry) => {
  const peer = e.kind === 'dm' ? personOf(e.where) : null
  const where = e.kind === 'channel' ? channelName(String(e.channel)) : shownPerson(peer!.id, peer!.box, people.names.value)
  const place = (e.kind === 'channel' ? '#' : '@') + where
  const reply = e.event ? e.event === 'reply' : e.reply
  return {
    key: e.key,
    msgId: e.msg_id,
    type: e.event === 'mention' ? 'mention' : reply ? 'reply' : e.kind,
    badge: e.event === 'mention' ? '@' : reply ? '↳' : e.kind === 'channel' ? '#' : '@',
    who: { id: e.from, box: e.from_box },
    where,
    when: phoneCardTime(formatMsgListTs(e.at), e.at, now.value),
    text: e.text || '📎',
    title: placeTitle(e, place) + '\n' + e.text,
    unread: flowUnread(e, cursors.value, flow.opened),
  }
}))

/**
 * The message in its original place (lane A, CLE-77882): its channel or DM
 * scrolled to it and highlighted, a reply in its thread. The row is passed
 * whole, so no lookup; the Flow list stays while it navigates.
 */
async function openKey(key: string) {
  const row = flow.visible.find((r: FlowEntry) => r.key === key)
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
/* spec 062 Q4: the pane on screen clears the number (a phone shows it at level 1 only) */
const onScreen = computed(() => props.active && (!stack.isMobile.value || stack.level.value === 1))
function syncSeen() {
  flow.setPaneOpen(onScreen.value && !(typeof document !== 'undefined' && document.hidden))
}
watch(onScreen, syncSeen)
onMounted(() => {
  syncSeen()
  document.addEventListener('visibilitychange', syncSeen)
})
onBeforeUnmount(() => {
  document.removeEventListener('visibilitychange', syncSeen)
  flow.setPaneOpen(false)
})
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

<style scoped>
.flow-more { margin: 4px 8px 8px; }
.flow-head { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 4px 8px 6px; }
.flow-scope { display: inline-flex; border: 1px solid var(--color-border); border-radius: var(--radius-pill); overflow: hidden; }
.flow-scope__btn { padding: 2px 10px; font-size: 0.8125rem; color: var(--color-muted); background: transparent; border: 0; cursor: pointer; }
.flow-scope__btn[aria-checked="true"] { color: var(--color-fg); background: var(--color-surface-hover); font-weight: 600; }
.flow-chips { display: inline-flex; gap: 4px; }
.flow-chip { padding: 1px 8px; font-size: 0.8125rem; border: 1px solid var(--color-border); border-radius: var(--radius-pill); background: transparent; color: var(--color-fg); cursor: pointer; }
.flow-chip[aria-pressed="true"] { border-color: var(--color-accent); color: var(--color-accent); font-weight: 600; }
.flow-chip--zero { opacity: 0.5; cursor: default; }
</style>
