<template>
  <!-- Flow (topic 635f8072): short message entries, newest first, in the left
       panel (the shared SideHitList, lane C). A click / Enter opens the
       message in its original place; the list, its scroll and its selection
       stay while the middle pane changes route. -->
  <!-- spec 062: Mine, only what concerns me (spec 130 Q2: always, no All
       switch); the chips split Mine's unread by kind and filter on a click (a 0 chip is dimmed) -->
  <div v-if="flow.available !== false" class="flow-head" data-testid="flow-head">
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
      @menu="onMenu"
      @press="onPress"
      @keydown="onKey"
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
  <p v-if="aiError" class="msg-edit-error flow-ai-error" role="alert" data-testid="msg-ai-error">{{ t(aiError) }}</p>
  <!-- t1 b6c742f0: an entry's menu (right-click, a long press, the menu key).
       Spec 130 (owner t1 1cde1dd4, f4b6977e): a folded line's menu is what
       it points to - Open discussion, Open issue, Open release log, Copy
       link, Copy text, Mark read (FLOW_LINE_ACTIONS, the table its Shift keys
       share) - and on a topic line the AI actions group.
       Mounted on open only: not in the initial JS (027). -->
  <LazySearchRowMenu
    v-if="menu.row"
    :open="!!menu.row"
    :x="menu.x"
    :y="menu.y"
    :items="menuItems"
    :ai-msg="menuAi"
    :label="t(menuLine ? 'flow.menu.label' : 'feed.msg_menu.label')"
    testid="flow-menu"
    @close="menu.row = null"
    @escape="listEl?.focus()"
    @choose="onMenuChoose"
  />
</template>

<script setup lang="ts">
import { useFlowStore } from '~/stores/flow'
import { useOpenMessage } from '~/composables/useOpenMessage'
import { useHumanNames } from '~/composables/useHumanNames'
import { useNowTick } from '~/composables/useNowTick'
import { useMobileStack } from '~/composables/useMobileStack'
import type { FlowKind } from '~/utils/flow-badge.mjs'
import { flowLineTarget } from '~/utils/flow-fold.mjs'
import type { FlowLine } from '~/utils/flow-fold.mjs'
import { useFlowLineMenu } from '~/composables/useFlowLineMenu'
import { useFlowListItems } from '~/composables/useFlowListItems'

const props = withDefaults(defineProps<{ active?: boolean }>(), { active: true })

const { t } = useI18n({ useScope: 'global' })
const { openMessage } = useOpenMessage()
const flow = useFlowStore()
const people = useHumanNames()
const stack = useMobileStack()
const now = useNowTick(() => props.active)
const scrollEl = ref<HTMLElement | null>(null)
const listEl = ref<{ focus: () => void, rowEl: (key: string) => HTMLElement | null | undefined } | null>(null)

/* how a Flow row becomes a left-list item: composables/useFlowListItems.ts */
const { items, isLine, lineSummary } = useFlowListItems({ flow, people, now, t })

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

/**
 * The message in its original place (lane A, CLE-77882): its channel or DM
 * scrolled to it and highlighted, a reply in its thread. The row is passed
 * whole, so no lookup; the Flow list stays while it navigates.
 */
async function openKey(key: string) {
  /* the long press that opened the menu lifts with a click: that click is the menu's */
  if (longPress.takeClick()) return
  const row = entryOf(key)
  if (!row) return
  /* spec 130 section 2.4: a blocked line opens its issue, a release line its log */
  if (isLine(row)) return openLine(row, flowLineTarget(row).to)
  flow.select(key)
  flow.markOpened(key)
  /* the keyboard stays on the list, so the next ArrowDown keeps cycling */
  const keyboard = Boolean(scrollEl.value && scrollEl.value.contains(document.activeElement))
  await openMessage(row)
  if (keyboard && !stack.isMobile.value) listEl.value?.focus()
}

/**
 * Open a folded line where `to` says (spec 130 section 2.4): its newest
 * message in its original place, the topic's issue, or the release log.
 * Opening it marks all of it read (FR-009: t:<task_id> / f:rel:<version>).
 */
async function openLine(line: FlowLine, to: 'message' | 'issue' | 'release') {
  flow.select(line.key)
  flow.markOpened(line.key)
  const keyboard = Boolean(scrollEl.value && scrollEl.value.contains(document.activeElement))
  if (to === 'message') await openMessage({ msg_id: line.msg_id, task_id: line.task_id, parent_task_id: line.parent_task_id || null })
  else if (to === 'issue') await router.push(localePath('/issues?issue=' + line.issue))
  else await router.push(localePath('/releases/' + encodeURIComponent(String(line.sha || ''))))
  if (keyboard && !stack.isMobile.value) listEl.value?.focus()
}

/* the entry's menu (right-click, a long press, the menu key) and a folded
   line's Shift keys: composables/useFlowLineMenu.ts */
const router = useRouter()
const localePath = useLocalePath()
const { menu, menuLine, menuItems, menuAi, aiError, entryOf, longPress, onMenu, onPress, onKey, onMenuChoose } =
  useFlowLineMenu({ flow, listEl, stack, isLine, lineSummary, openLine, openKey })

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
.flow-ai-error { margin: 4px 8px; }
.flow-head { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 4px 8px 6px; }
.flow-chips { display: inline-flex; gap: 4px; }
.flow-chip { padding: 1px 8px; font-size: 0.8125rem; border: 1px solid var(--color-border); border-radius: var(--radius-pill); background: transparent; color: var(--color-fg); cursor: pointer; }
.flow-chip[aria-pressed="true"] { border-color: var(--color-accent); color: var(--color-accent); font-weight: 600; }
.flow-chip--zero { opacity: 0.5; cursor: default; }
</style>
