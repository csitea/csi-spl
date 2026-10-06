<!-- CLE-77884 (owner, topic 635f8072 96a88e32): "the search results should be
     in the left most panel and not in the middle and one should be able to
     cycle quickly via the search result on the left and whenever clicking ...
     would open the topic or the private msg within the channel or the private
     msgs, and not the topics". The hits of the current /search query as the
     shared compact list (SideHitList): snippet with the match marked, who,
     where, when. ArrowUp/Down cycle, Enter / click / tap opens a posted hit in
     its ORIGINAL place (its channel or DM, the message scrolled to and
     marked); every other hit its FR-023 page. The query, the list, the chosen
     entry and the scroll position live in the search store, so they stay while
     the reader clicks through (desktop: the sidebar holds this panel; phone:
     pages/search.vue renders it full screen and Back returns to it).
     Lazy: neither this file nor the list is in the first paint (027). -->
<template>
  <div class="side-search" data-test="side-search">
    <div v-if="!inPage" class="sidebar-head side-search__head">
      <h2 class="side-search__title">{{ t('search.title') }}</h2>
      <button
        type="button"
        class="icon-btn"
        data-testid="side-search-close"
        :aria-label="t('search.close_results')"
        :title="t('search.close_results')"
        @click="emit('close')"
      >
        <UiIcon name="x" :size="16" />
      </button>
    </div>
    <p v-if="!inPage && search.q" class="side-search__q"><code dir="ltr">{{ search.q }}</code></p>
    <div ref="scrollEl" class="sidebar-scroll side-search__scroll" @scroll.passive="noteScroll">
      <p v-if="search.loading" class="muted side-search__note" data-test="side-search-loading" aria-live="polite">{{ t('search.loading') }}</p>
      <p v-else-if="search.error" class="muted side-search__note" data-test="side-search-error">{{ search.error.status === 503 ? t('search.budget', { s: SEARCH_BUDGET_S }) : t('search.failed', { detail: search.error.detail || search.error.token || String(search.error.status || '') }) }}</p>
      <p v-else-if="search.result && !rows.length" class="muted side-search__note" data-test="side-search-empty">{{ t('search.no_results') }}</p>
      <SideHitList
        v-else-if="rows.length"
        ref="listRef"
        mode="search"
        list-test="search-results"
        row-test="search-row"
        :items="items"
        :active-key="search.activeKey"
        :label="t('search.results_label', { q: search.q })"
        @active="(k: string) => (search.activeKey = k)"
        @open="onOpen"
        @menu="onMenu"
        @press="onPress"
        @keydown="onKey"
      >
        <template #group-end="{ group }">
          <button
            v-if="nextOf(group)"
            type="button"
            class="btn ghost search-more"
            :data-test="'search-more-' + typeOf(group)"
            :disabled="search.loadingMore === typeOf(group)"
            @click="search.more(typeOf(group))"
          >
            {{ search.loadingMore === typeOf(group) ? t('search.loading') : t('search.load_more') }}
          </button>
        </template>
      </SideHitList>
    </div>
    <!-- mounted on open only: the menu is not in the initial JS (specs/027) -->
    <LazySearchRowMenu
      v-if="menu.row"
      :open="!!menu.row"
      :x="menu.x"
      :y="menu.y"
      :items="menuItems(menu.row)"
      @close="closeMenu"
      @escape="listRef?.focus()"
      @choose="onMenuChoose"
    />
  </div>
</template>

<script setup lang="ts">
import SideHitList from '~/components/SideHitList.vue'
import { ISSUE_CHANNEL } from '~/utils/parent-section.mjs'
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'
import { useOmniboxStore } from '~/stores/omnibox'
import { SEARCH_BUDGET_S, useSearchStore } from '~/stores/search'
import { useTopicStore } from '~/stores/topic'
import { searchPath, type SearchRow } from '~/utils/search.mjs'
import { flattenGroups, highlightSegments, isPlacedRow, originalHref, rowAt, searchRowMenuItems, searchTarget, topicPageOf } from '~/utils/search-results.mjs'
import type { SideHitItem } from '~/utils/side-hit-list.mjs'
import { openThreadRow } from '~/utils/pane-scroll.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { namedText, shownPerson } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { createLongPress } from '~/utils/touch-ui.mjs'
import { useCopyText } from '~/composables/useCopyText'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useOpenMessage, type MessageRef } from '~/composables/useOpenMessage'

defineProps<{ inPage?: boolean }>()
const emit = defineEmits<{ (e: 'close'): void }>()

const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const search = useSearchStore()
const api = useSpoolApi()
const authClient = useAuthClient()
const omnibox = useOmniboxStore()
const pane = useLiveFeed('pane')
const topic = useTopicStore()
const people = useHumanNames()
const access = useAccessStore()
const roster = useRosterStore()
const liveIdentity = useLive().identity
const { copy: copyText } = useCopyText()
const { openMessage } = useOpenMessage()
/** the reader: the DM end that is not the peer (utils/parent-section.mjs) */
const viewerId = computed(() => String(access.me?.humanId || liveIdentity.value || roster.me?.id || ''))
const scrollEl = ref<HTMLElement | null>(null)
const listRef = ref<{ focus: () => void, rowEl: (key: string) => HTMLElement | null } | null>(null)

const rows = computed(() => (search.result ? flattenGroups(search.result.groups) : []))
const byKey = computed(() => new Map(rows.value.map((r) => [r.key, r])))

function groupLabel(type: string) { return t('search.group.' + type) }
function typeOf(label: string) {
  const g = search.result?.groups.find((x) => groupLabel(x.type) === label)
  return g ? g.type : ''
}
function nextOf(label: string) {
  const g = search.result?.groups.find((x) => groupLabel(x.type) === label)
  return !!(g && g.next)
}

function when(ts: unknown): string {
  if (!ts) return ''
  return isoDateTime(new Date(String(ts)))
}
function label(id: unknown, box: unknown) {
  const s = id ? String(id) : ''
  return s ? shownPerson(s, box ? String(box) : undefined, people.names.value) : ''
}
/** Where a hit lives: #channel, the Issues label for an issue's discussion (SPL-68), or a DM. */
function place(channel: unknown): string {
  const c = String(channel || '')
  if (!c) return t('search.in_dm')
  return c === ISSUE_CHANNEL ? t('search.group.issues') : '#' + c
}
function badgeOf(r: Record<string, unknown>): string {
  if (!isPlacedRow(r)) return ''
  if (r.type === 'messages' && r.parent_task_id && r.parent_task_id !== r.task_id) return '↳'
  return r.channel ? '#' : '@'
}

/** The meta of a non-posted hit, as the search page wrote it. */
function metaOf(row: SearchRow): string {
  const r = row as Record<string, any>
  switch (row.type) {
    case 'robots': return r.revoked ? t('search.revoked') : ''
    case 'channels': return r.count != null ? t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0) : ''
    case 'boxes': return Array.isArray(r.agents) ? r.agents.join(', ') : ''
    case 'tenants': {
      const role = String(r.role || '')
      const roleLabel = role && te('role.' + role) ? t('role.' + role) : ''
      return [String(r.tenant_id || ''), roleLabel, r.current ? t('search.current_tenant') : ''].filter(Boolean).join(' · ')
    }
    case 'events': return String(r.code || r.path || r.error_id || '')
    case 'issues': return [r.status, r.priority, r.assignee].filter((x) => x != null && x !== '').map(String).join(' · ')
    default: return ''
  }
}

function itemOf(row: SearchRow): SideHitItem {
  const r = row as Record<string, any>
  const segs = highlightSegments(row.display.text, row.display.highlights)
    .map((s: { text: string, mark: boolean }) => ({ text: row.type === 'messages' ? namedText(s.text, people.names.value) : s.text, mark: s.mark }))
  const base: SideHitItem = { key: row.key, type: row.type, group: groupLabel(row.type), segs, title: row.display.text, ts: rowAt(row) }
  if (r.msg_id && (row.type === 'messages' || row.type === 'files')) base.msgId = String(r.msg_id)
  switch (row.type) {
    case 'messages':
      return { ...base, badge: badgeOf(r), who: r.from ? { id: String(r.from), box: r.from_box ? String(r.from_box) : '' } : undefined, where: place(r.channel), when: when(r.received_at || r.created_at) }
    case 'topics':
      return { ...base, badge: badgeOf(r), where: [place(r.channel), t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0)].join(' · '), when: when(r.last_ts) }
    case 'files':
      return { ...base, badge: '📎', where: label(r.from, r.from_box), when: when(r.received_at) }
    case 'users': {
      const n = typeof r.display_name === 'string' ? r.display_name.trim() : ''
      return { ...base, who: { id: String(r.id || ''), box: r.box ? String(r.box) : '' }, segs: n ? [{ text: n, mark: false }] : [], where: metaOf(row) }
    }
    case 'robots':
      return { ...base, who: { id: String(r.id || ''), box: r.box ? String(r.box) : '' }, where: metaOf(row) }
    case 'channels':
      return { ...base, badge: '#', where: metaOf(row) }
    case 'events':
      return { ...base, where: metaOf(row), when: when(r.received_at) }
    default:
      return { ...base, where: metaOf(row) }
  }
}
const items = computed(() => rows.value.map(itemOf))

/* the chosen entry and the scroll survive a remount (a phone Back, a tab swap) */
function noteScroll() {
  if (scrollEl.value) search.scrollTop = scrollEl.value.scrollTop
}
onMounted(() => {
  nextTick(() => {
    if (scrollEl.value && search.scrollTop) scrollEl.value.scrollTop = search.scrollTop
  })
})
/* a new answer starts at the top, nothing chosen */
watch(() => search.result, (r, old) => {
  if (r && old && r.query === old.query) return
  search.activeKey = ''
  search.scrollTop = 0
  if (scrollEl.value) scrollEl.value.scrollTop = 0
})

/* ArrowDown in the Omnibox (search mode) hands the focus to the list */
watch(() => omnibox.focusResults, () => {
  if (!search.activeKey && items.value.length) search.activeKey = items.value[0].key
  listRef.value?.focus()
})

function onOpen(key: string) {
  /* the long press that opened the menu lifts with a click: that click is the menu's */
  if (longPress.takeClick()) return
  const row = byKey.value.get(key)
  if (row) void open(row)
}

/* 022 §10 FR-050: the row's right menu - right-click, a long press on a
   phone (the bottom sheet), or the menu key */
const menu = reactive<{ row: SearchRow | null, x: number, y: number }>({ row: null, x: 0, y: 0 })
function menuItems(row: SearchRow | null) { return row ? searchRowMenuItems(row) : [] }
function openMenuAt(row: SearchRow, x: number, y: number) {
  if (!menuItems(row).length) return
  search.activeKey = row.key
  menu.row = row
  menu.x = x
  menu.y = y
}
function closeMenu() { menu.row = null }
function onMenu(key: string, ev: MouseEvent) {
  const row = byKey.value.get(key)
  if (!row || !menuItems(row).length) return
  ev.preventDefault()
  openMenuAt(row, ev.clientX, ev.clientY)
}
let pressRow: SearchRow | null = null
const longPress = createLongPress({
  onPress: (x, y) => {
    if (!pressRow) return
    if (typeof navigator !== 'undefined' && typeof navigator.vibrate === 'function') navigator.vibrate(10)
    openMenuAt(pressRow, x, y)
  },
})
onBeforeUnmount(() => longPress.cancel())
function onPress(key: string, ev: PointerEvent) {
  pressRow = byKey.value.get(key) || null
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
function onKey(ev: KeyboardEvent, key: string) {
  /* FR-050: the keyboard's own menu key (or Shift+F10) opens the row's menu */
  if (!(ev.key === 'ContextMenu' || (ev.key === 'F10' && ev.shiftKey))) return
  const row = byKey.value.get(key)
  const el = listRef.value?.rowEl(key)
  if (!row || !el) return
  ev.preventDefault()
  const r = el.getBoundingClientRect()
  openMenuAt(row, r.left + 16, r.top + 24)
}
async function onMenuChoose(id: string) {
  const row = menu.row
  closeMenu()
  if (!row) return
  if (id === 'original') return void open(row)
  if (id === 'here') return void showHere(row)
  if (id === 'copy') {
    const href = originalHref(row, { self: viewerId.value, pathFor: localePath })
    if (href) await copyText(new URL(href, window.location.origin).href)
  }
}

/** 022 §10 FR-051: a click, Enter or a tap opens the row's ORIGINAL - a
    message, topic or file in the DM / channel it was posted in, scrolled to
    and marked; every other row its FR-023 page. The list stays. */
async function open(row: SearchRow) {
  search.activeKey = row.key
  /* the sidebar keeps this list across the navigation the list starts
     (ChannelSidebar holdSearch); any other navigation lets the rail follow */
  search.opening++
  try {
    await openRow(row)
  } finally {
    setTimeout(() => { search.opening = Math.max(0, search.opening - 1) }, 0)
  }
}
async function openRow(row: SearchRow) {
  const to = searchTarget(row)
  if (!to) return
  /* lane A (CLE-77882): a message or file hit opens in its original place -
     its channel or DM, a reply in its thread - marked; a deleted / unknown /
     forbidden one raises the shell notice. Only a failure to resolve at all
     falls back to the old original (its topic page). */
  if ((row.type === 'messages' || row.type === 'files') && row.msg_id) {
    const out = await openMessage(row as MessageRef)
    if (out.ok || out.reason !== 'error') return
  }
  if (isPlacedRow(row)) {
    const m = await import('~/utils/search-original.mjs')
    if (await m.openOriginal(row, { api, router, localePath, self: viewerId.value, fallback: topicPageOf(row) })) return
  }
  if ('topic' in to) return showHere(row)
  if ('tenant' in to) {
    if (api.mock) return
    if (row.current) return void router.push(localePath('/'))
    if (to.tenant) {
      const hostUrl = await tenantHostUrl(to.tenant, localePath('/')) // SPL-959
      if (hostUrl) return void window.location.assign(hostUrl)
      const out = await authClient.switchTenant(to.tenant)
      if (out.ok) window.location.assign(localePath('/'))
    }
    return
  }
  if ('path' in to) return void router.push(localePath(to.path))
  if ('search' in to) return void router.push(localePath(searchPath(to.search)))
}

/** FR-050 Show here: a posted hit's topic in the right pane, at that message. */
async function showHere(row: SearchRow) {
  search.activeKey = row.key
  const to = searchTarget(row)
  if (!to || !('topic' in to)) return
  topic.setTarget({ taskId: to.topic, mode: 'task', rootMsgId: '', parentTaskId: '' }, null)
  await pane.open(to.topic)
  if (to.focus) focusMessage(to.focus)
}

function focusMessage(msgId: string, tries = 30) {
  const el = document.querySelector<HTMLElement>(`.live-pane [data-msg-id="${CSS.escape(msgId)}"]`)
  if (!el) {
    if (tries > 0) setTimeout(() => focusMessage(msgId, tries - 1), 100)
    return
  }
  openThreadRow(el)
  el.classList.add('search-focus')
  setTimeout(() => el.classList.remove('search-focus'), 2400)
}

defineExpose({ focus: () => listRef.value?.focus() })
</script>

<style scoped>
.side-search { display: flex; flex-direction: column; flex: 1 1 auto; min-width: 0; min-height: 0; }
.side-search__title { margin: 0; }
.side-search__q { margin: 0 10px 6px; font-size: 0.75rem; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.side-search__q code { font-family: var(--font-mono); }
.side-search__note { margin: 4px 10px; font-size: 0.8125rem; }
.side-search__scroll { padding-inline: 4px; }
.search-more { margin: 2px 8px 0; }
</style>
