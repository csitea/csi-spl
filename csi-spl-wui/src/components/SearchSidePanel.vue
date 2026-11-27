<!-- CLE-77884 (owner, topic 635f8072 96a88e32): the hits of the current
     search as the shared compact list (SideHitList): snippet with the match
     marked, who, where, when. SPL-6675 (owner HUM-10, t1 bcfd15e1): this is
     the body of the search panel (SearchPanel, its own slide-in column, not
     the sidebar's list), with the answer's notes, errors and, for a bare
     search, the help. A click or Up / Down previews a hit on the right and
     the list stays; Enter, a double-click or the row's Open opens it for
     real and closes the search. The query, the list, the chosen entry and
     the scroll live in the search store. Lazy: neither this file nor the
     list is in the first paint (027). -->
<template>
  <div class="side-search" data-test="side-search">
    <div class="sidebar-head side-search__head">
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
    <p v-if="search.q" class="side-search__q"><code dir="ltr">{{ search.q }}</code></p>
    <p v-if="aiError" class="msg-edit-error side-search__note" role="alert" data-testid="msg-ai-error">{{ t(aiError) }}</p>
    <div ref="scrollEl" class="sidebar-scroll side-search__scroll" @scroll.passive="noteScroll">
      <ul v-if="search.result && search.result.warnings.length" class="side-search__notes" data-test="search-warnings">
        <li v-for="(w, i) in search.result.warnings" :key="i" class="muted">
          <code v-if="w.token" dir="ltr">{{ w.token }}</code> {{ w.detail }}
        </li>
      </ul>
      <!-- spec 160 3.6: the answer's notices, one line each (a stable code -> a text key) -->
      <ul v-if="search.result && search.result.notices && search.result.notices.length" class="side-search__notes" data-test="search-notices">
        <li v-for="n in search.result.notices" :key="n" class="muted">{{ te('search.notice.' + n) ? t('search.notice.' + n) : n }}</li>
      </ul>
      <!-- a bare /search: how to search, each example one click -->
      <LazySearchPanelHelp v-if="!search.q" @search="(q: string) => search.openPanel(q)" />
      <p v-else-if="search.loading" class="muted side-search__note" data-test="side-search-loading" aria-live="polite">{{ t('search.loading') }}</p>
      <template v-else-if="search.error">
        <ViewTokenForm v-if="search.error.status === 401" :detail="search.error.detail" @saved="search.run(search.q)" />
        <div v-else-if="search.error.token === 'bad_query'" class="side-search__note" data-test="search-bad-query" role="alert">
          <p>{{ t('search.bad_query', { detail: search.error.detail }) }}</p>
          <p v-if="badAt" dir="ltr"><code>{{ badAt.before }}<mark>{{ badAt.bad }}</mark>{{ badAt.after }}</code></p>
        </div>
        <!-- SPL-1833: the plain sentence, technical part only with the Debug pane on -->
        <LazySearchErrorNotice
          v-else
          class="side-search__note"
          :error="search.error"
          test-id="side-search-error"
          @retry="search.run(search.q)"
        />
      </template>
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
        @cycle="onCycle"
        @commit="onCommit"
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
      :ai-msg="menu.row.type === 'messages' ? menu.row : undefined"
      @close="closeMenu"
      @escape="listRef?.focus()"
      @choose="onMenuChoose"
    />
  </div>
</template>

<script setup lang="ts">
import SideHitList from '~/components/SideHitList.vue'
import { useAiListRun } from '~/composables/useAiListRun'
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSearchStore } from '~/stores/search'
import { useTopicStore } from '~/stores/topic'
import type { SearchRow } from '~/utils/search.mjs'
import { isPlacedRow, originalHref, searchRowMenuItems, searchTarget, topicPageOf } from '~/utils/search-results.mjs'
import { useSearchSideItems } from '~/composables/useSearchSideItems'
import { openThreadRow } from '~/utils/pane-scroll.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import { createLongPress } from '~/utils/touch-ui'
import { useCopyText } from '~/composables/useCopyText'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'
import { useOpenMessage, type MessageRef } from '~/composables/useOpenMessage'
import { useMobileStack } from '~/composables/useMobileStack'
import { useViewPrefs } from '~/composables/useViewPrefs'

const emit = defineEmits<{ (e: 'close'): void }>()

const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const router = useRouter()
const route = useRoute()
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
const stack = useMobileStack()
const { newestLast } = useViewPrefs()
/** the reader: the DM end that is not the peer (utils/parent-section.mjs) */
const viewerId = computed(() => String(access.me?.humanId || liveIdentity.value || roster.me?.id || ''))
const scrollEl = ref<HTMLElement | null>(null)
const listRef = ref<{ focus: () => void, rowEl: (key: string) => HTMLElement | null } | null>(null)

const { rows, byKey, items, typeOf, nextOf } = useSearchSideItems({ search, t, te, names: people.names })

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

/* SPL-6675 (owner HUM-10, t1 bcfd15e1 msgs aa7dd3cf, 2f0259cc, 6cb72656):
   a click or Up / Down PREVIEWS a hit - it shows on the right, alone, and
   this list stays; Enter, a double-click or the row's Open opens it for
   real - the search panel closes and the section's own left pane is back.
   A phone has no room beside the list: a tap shows the hit over it, and
   Back brings the list back, its scroll and chosen entry kept. */
function onOpen(key: string) {
  /* the long press that opened the menu lifts with a click: that click is the menu's */
  if (longPress.takeClick()) return
  const row = byKey.value.get(key)
  if (!row) return
  if (stack.isMobile.value) return void tapOpen(row)
  clearTimeout(cycleTimer)
  void preview(row)
}
/* the keys walk fast: a hit is previewed once the walk rests on it */
const CYCLE_REST_MS = 180
let cycleTimer: ReturnType<typeof setTimeout> | undefined
onBeforeUnmount(() => clearTimeout(cycleTimer))
function onCycle(key: string) {
  if (stack.isMobile.value) return
  clearTimeout(cycleTimer)
  cycleTimer = setTimeout(() => {
    const row = byKey.value.get(key)
    if (row && search.activeKey === key) void preview(row)
  }, CYCLE_REST_MS)
}
function onCommit(key: string) {
  clearTimeout(cycleTimer)
  const row = byKey.value.get(key)
  if (row) void commit(row)
}

/** the bad token of a 400, marked inside the query (pos is a UTF-16 offset = String.slice) */
const badAt = computed(() => {
  const e = search.error
  const q = search.q
  if (!e || e.pos < 0 || e.pos > q.length) return null
  const n = Math.max(1, e.badToken.length)
  return { before: q.slice(0, e.pos), bad: q.slice(e.pos, e.pos + n) || ' ', after: q.slice(e.pos + n) }
})

/* 022 §10 FR-050: the row's right menu - right-click, a long press on a
   phone (the bottom sheet), or the menu key */
const menu = reactive<{ row: SearchRow | null, x: number, y: number }>({ row: null, x: 0, y: 0 })
const aiList = useAiListRun()
const aiError = ref('')
function menuItems(row: SearchRow | null) { return row ? searchRowMenuItems(row) : [] }
function openMenuAt(row: SearchRow, x: number, y: number) {
  if (!menuItems(row).length) return
  search.activeKey = row.key
  aiError.value = ''
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
  /* Esc closes the search, as its X does */
  if (ev.key === 'Escape') {
    ev.preventDefault()
    emit('close')
    return
  }
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
  if (id === 'original') return void commit(row)
  if (id === 'here') return void showHere(row)
  /* t1 b6c742f0: an AI action opens the hit where it lives, then runs there */
  if (id.startsWith('ai-')) {
    aiError.value = await aiList.run(id, row)
    return
  }
  if (id === 'copy') {
    const href = originalHref(row, { self: viewerId.value, pathFor: localePath })
    if (href) await copyText(new URL(href, window.location.origin).href)
  }
}

/** a preview: the hit on the right, the list here. Its first route change
    is a new history entry, the next ones replace it, so Back leaves the
    search's walk in one step. */
async function preview(row: SearchRow) {
  search.activeKey = row.key
  const replace = search.previewing
  search.previewing = true
  await openRow(row, { replace })
}

/** a phone tap: the panel steps aside (open, hidden) and the hit takes the
    screen as a new history entry; Back to this page shows the list again */
async function tapOpen(row: SearchRow) {
  search.activeKey = row.key
  noteScroll()
  const from = route.fullPath
  search.stepAside(from)
  await openRow(row, { replace: false })
  /* nothing moved (a hit of this very page): the list stays in view */
  search.routeAt(route.fullPath === from ? from : '')
}

/** 022 §10 FR-051, SPL-6675: open for real - the search closes first, so the
    section's own left pane comes back. A message or file hit opens the way
    its card's "Open in channels view" does (owner HUM-10 msg 86f0ab8f): the
    place's list left, its topic at the top of the middle, the card at the
    top of the right pane (utils/parent-section-open.mjs). */
async function commit(row: SearchRow) {
  search.activeKey = row.key
  search.closePanel()
  if ((row.type === 'messages' || row.type === 'files') && row.msg_id) {
    const [m, p] = await Promise.all([import('~/utils/open-message.mjs'), import('~/utils/parent-section-open.mjs')])
    const out = await m.openMessage(row, {
      self: viewerId.value, api, router, localePath,
      openSection: (msg, deps) => p.openParentSection(msg, { ...deps, newestLast: newestLast.value, topicLevel: true, showPlace: true }),
    })
    if (out.ok || out.reason !== 'error') return
  }
  await openRow(row, { replace: false })
}

async function openRow(row: SearchRow, o: { replace: boolean }) {
  const to = searchTarget(row)
  if (!to) return
  const go = (path: string) => (o.replace ? router.replace(localePath(path)) : router.push(localePath(path)))
  /* lane A (CLE-77882): a message or file hit opens in its original place -
     its channel or DM, a reply in its thread - marked; a deleted / unknown /
     forbidden one raises the shell notice. Only a failure to resolve at all
     falls back to the old original (its topic page). */
  if ((row.type === 'messages' || row.type === 'files') && row.msg_id) {
    const out = await openMessage(row as MessageRef, { replace: o.replace })
    if (out.ok || out.reason !== 'error') return
  }
  if (isPlacedRow(row)) {
    const m = await import('~/utils/search-original.mjs')
    if (await m.openOriginal(row, { api, router, localePath, self: viewerId.value, fallback: topicPageOf(row) })) return
  }
  if ('topic' in to) return showHere(row)
  if ('tenant' in to) {
    if (api.mock) return
    if (row.current) return void go('/')
    if (to.tenant) {
      const hostUrl = await tenantHostUrl(to.tenant, localePath('/')) // SPL-959
      if (hostUrl) return void window.location.assign(hostUrl)
      const out = await authClient.switchTenant(to.tenant)
      if (out.ok) window.location.assign(localePath('/'))
    }
    return
  }
  if ('path' in to) return void go(to.path)
  /* a box: its messages, a new search in this panel */
  if ('search' in to) return void search.openPanel(to.search)
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
