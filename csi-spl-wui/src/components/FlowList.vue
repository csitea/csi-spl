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
import { useChannelStore } from '~/stores/channel'
import { useNotificationStore } from '~/stores/notification'
import { useHumanNames } from '~/composables/useHumanNames'
import { useNowTick } from '~/composables/useNowTick'
import { useMobileStack } from '~/composables/useMobileStack'
import { flowUnread } from '~/utils/flow-entries.mjs'
import type { FlowKind } from '~/utils/flow-badge.mjs'
import type { FlowEntry } from '~/utils/flow-entries.mjs'
import { FLOW_LINE_GLYPH, flowLineOffered, flowLineTarget } from '~/utils/flow-fold.mjs'
import type { FlowLine } from '~/utils/flow-fold.mjs'
import { FLOW_LINE_ACTIONS, flowShortcutFor, flowShortcutHint, flowShortcutItem } from '~/utils/msg-shortcuts.mjs'
import { useMsgShortcutsHelp, useMsgShortcutsOn } from '~/composables/useMsgShortcuts'
import { writeClipboard } from '~/utils/clipboard.mjs'
import type { SideHitItem } from '~/utils/side-hit-list'
import { loadCursors } from '~/utils/read-cursor.mjs'
import { formatMsgListTs, phoneCardTime, shownPerson } from '~/utils/channel-feed.mjs'
import { createLongPress } from '~/utils/touch-ui'
import { isAiMessage } from '~/utils/typed-by.mjs'
import { useAiListRun } from '~/composables/useAiListRun'
import type { PointMenuItem } from '~/components/UiPointMenu.vue'

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
const listEl = ref<{ focus: () => void, rowEl: (key: string) => HTMLElement | null | undefined } | null>(null)

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

/** Mine shows the hub's folded lines (spec 130); the mock's whole-feed fixture still shows entries. */
function isLine(r: FlowLine | FlowEntry | null | undefined): r is FlowLine {
  return Boolean(r && flow.mineOn)
}

/** The place a topic line is in: its channel, else the DM's first other id. */
function linePlace(l: FlowLine) {
  if (l.channel) return '#' + channelName(String(l.channel))
  const peer = personOf(String(l.where || (l.ids && l.ids[0]) || ''))
  return peer.id ? shownPerson(peer.id, peer.box, people.names.value) : ''
}

/**
 * The line's one-line summary (spec 130 section 2.1): the count when > 1,
 * the topic title, up to two ids then "+N"; a release line its version span.
 * The kind leads as the badge, the time sits on the right.
 */
function lineSummary(l: FlowLine) {
  if (l.kind === 'release') {
    return l.version_from && l.version_from !== l.version_to
      ? t('flow.line_release', { from: l.version_from, to: l.version_to, n: l.versions })
      : String(l.version_to || '')
  }
  const ids = (l.ids || []).map((id) => {
    const p = personOf(id)
    return shownPerson(p.id, p.box, people.names.value)
  })
  const who = ids.length ? ' · ' + ids.join(', ') + (l.ids_more ? ` +${l.ids_more}` : '') : ''
  const title = l.title || l.text || '📎'
  return (l.count > 1 ? l.count + ' ' : '') + t('flow.line_in', { title }) + who
}

function lineItem(l: FlowLine): SideHitItem {
  const summary = lineSummary(l)
  return {
    key: l.key,
    msgId: l.msg_id || '',
    type: l.kind,
    badge: FLOW_LINE_GLYPH[l.kind] || '',
    where: l.kind === 'release' ? t('flow.kind.release') : linePlace(l),
    when: phoneCardTime(formatMsgListTs(l.at), l.at, now.value),
    text: summary,
    title: t('flow.kind.' + l.kind) + ' · ' + summary + (l.title && l.text ? '\n' + l.text : ''),
    unread: l.unread && !flow.opened.has(l.key),
    fold: true,
  }
}

const items = computed<SideHitItem[]>(() => flow.visible.map((r: FlowLine | FlowEntry) => {
  if (isLine(r)) return lineItem(r)
  const e = r as FlowEntry
  let where: string
  if (e.kind === 'channel') {
    where = channelName(String(e.channel))
  } else {
    const peer = personOf(e.where)
    where = shownPerson(peer.id, peer.box, people.names.value)
  }
  const place = (e.kind === 'channel' ? '#' : '@') + where
  const reply = e.event ? e.event === 'reply' : e.reply
  return {
    key: e.key,
    msgId: e.msg_id,
    type: e.event === 'mention' ? 'mention' : reply ? 'reply' : e.kind,
    badge: e.event === 'mention' ? '@' : reply ? '↳' : e.kind === 'channel' ? '#' : '@',
    who: { id: e.from, box: e.from_box },
    ai: isAiMessage(e),
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

/* t1 b6c742f0 (HUM-10 14dc0232: "add those same actions to every msg card
   in every view"): an entry's menu - right-click, a long press on a phone
   (the bottom sheet), or the menu key. An AI pick opens the message where it
   lives, then runs there (composables/useAiListRun.ts). */
const MENU_ITEMS: PointMenuItem[] = [{ id: 'original', icon: 'open', labelKey: 'search.menu.original' }]
const menu = reactive<{ row: FlowLine | FlowEntry | null, x: number, y: number }>({ row: null, x: 0, y: 0 })
const menuLine = computed(() => (isLine(menu.row) ? menu.row : null))
/* a folded line: the entries it offers (flowLineOffered), each with its Shift key */
const menuItems = computed<PointMenuItem[]>(() => {
  const line = menuLine.value
  if (!line) return MENU_ITEMS
  const offered = flowLineOffered(line)
  return FLOW_LINE_ACTIONS.filter((a) => offered.includes(a.id))
    .map((a) => ({ id: a.id, icon: a.icon, labelKey: a.labelKey, keyHint: flowShortcutHint(a.id) }))
})
/* the AI actions act on a topic line's topic (aiSubject 'topic'); a release line has none */
const menuAi = computed(() => {
  const line = menuLine.value
  if (!line) return menu.row
  return line.kind === 'release' ? null : { ai_kind: 'topic', task_id: line.task_id, title: line.title || line.text || '' }
})
const aiList = useAiListRun()
const aiError = ref('')
const router = useRouter()
const localePath = useLocalePath()
const shortcutsOn = useMsgShortcutsOn()
const shortcutsHelp = useMsgShortcutsHelp()
function entryOf(key: string): FlowLine | FlowEntry | null {
  return flow.visible.find((r: FlowLine | FlowEntry) => r.key === key) || null
}
function openMenuAt(row: FlowLine | FlowEntry, x: number, y: number) {
  flow.select(row.key)
  aiError.value = ''
  menu.row = row
  menu.x = x
  menu.y = y
}
function onMenu(key: string, ev: MouseEvent) {
  const row = entryOf(key)
  if (!row) return
  ev.preventDefault()
  openMenuAt(row, ev.clientX, ev.clientY)
}
let pressRow: FlowLine | FlowEntry | null = null
const longPress = createLongPress({
  onPress: (x, y) => {
    if (!pressRow) return
    if (typeof navigator !== 'undefined' && typeof navigator.vibrate === 'function') navigator.vibrate(10)
    openMenuAt(pressRow, x, y)
  },
})
onBeforeUnmount(() => longPress.cancel())
function onPress(key: string, ev: PointerEvent) {
  pressRow = entryOf(key)
  longPress.down(ev)
  const el = ev.currentTarget as HTMLElement | null
  if (!el) return
  const off = () => { el.removeEventListener('pointermove', longPress.move); el.removeEventListener('pointerup', up); el.removeEventListener('pointercancel', cancel) }
  const up = () => { longPress.up(); off() }
  const cancel = () => { longPress.cancel(); off() }
  el.addEventListener('pointermove', longPress.move)
  el.addEventListener('pointerup', up)
  el.addEventListener('pointercancel', cancel)
}
function menuAtRow(row: FlowLine | FlowEntry) {
  const r = listEl.value?.rowEl(row.key)?.getBoundingClientRect()
  openMenuAt(row, r ? r.left + 16 : 16, r ? r.top + 24 : 16)
}
function onKey(ev: KeyboardEvent, key: string) {
  const row = entryOf(key)
  if (!row) return
  if (ev.key === 'ContextMenu' || (ev.key === 'F10' && ev.shiftKey)) {
    ev.preventDefault()
    return menuAtRow(row)
  }
  /* spec 130, owner t1 1cde1dd4 (f9300a98): the message keys on the selected
     line, each the menu entry of the same meaning (FLOW_LINE_ACTIONS) */
  if (!isLine(row)) return
  const sc = flowShortcutFor(ev, { enabled: shortcutsOn.value, phone: stack.isMobile.value })
  if (!sc) return
  ev.preventDefault()
  if (sc.type === 'help') {
    shortcutsHelp.value = true
    return
  }
  if (sc.key === 'R') return menuAtRow(row)
  const id = flowShortcutItem(sc.key, flowLineOffered(row))
  if (id) void runLine(row, id)
}

/** Run one action of a folded line (its menu entry or its Shift key). */
async function runLine(line: FlowLine, id: string) {
  if (id === 'open') return openLine(line, 'message')
  if (id === 'issue') return openLine(line, 'issue')
  if (id === 'release') return openLine(line, 'release')
  if (id === 'read') return flow.markOpened(line.key)
  if (id === 'copy') {
    const target = flowLineTarget(line)
    const path = target.to === 'release' ? target.path : line.link
    return void writeClipboard(window.location.origin + localePath(path))
  }
  if (id === 'copy-text') return void writeClipboard(lineSummary(line) + (line.title && line.text ? '\n' + line.text : ''))
  if (id.startsWith('ai-') && line.task_id) {
    flow.markOpened(line.key)
    aiError.value = await aiList.runTopic(id, line.task_id)
  }
}

async function onMenuChoose(id: string) {
  const row = menu.row
  menu.row = null
  if (!row) return
  if (isLine(row)) return runLine(row, id)
  if (id === 'original') return void openKey(row.key)
  if (id.startsWith('ai-')) {
    flow.markOpened(row.key)
    aiError.value = await aiList.run(id, row)
  }
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
.flow-ai-error { margin: 4px 8px; }
.flow-head { display: flex; flex-wrap: wrap; align-items: center; gap: 6px; padding: 4px 8px 6px; }
.flow-chips { display: inline-flex; gap: 4px; }
.flow-chip { padding: 1px 8px; font-size: 0.8125rem; border: 1px solid var(--color-border); border-radius: var(--radius-pill); background: transparent; color: var(--color-fg); cursor: pointer; }
.flow-chip[aria-pressed="true"] { border-color: var(--color-accent); color: var(--color-accent); font-weight: 600; }
.flow-chip--zero { opacity: 0.5; cursor: default; }
</style>
