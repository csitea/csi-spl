<!-- 022 FR-020..025: global search results, deep-linkable as /search?q=….
     Grouped sections (robots, users, channels, boxes, tenants, topics, files,
     messages, events, issues; search-v1 §4), highlights from offsets rendered as text nodes,
     one listbox across all sections (ArrowUp/Down wrap, Home/End, Enter
     opens), per-section "Load more" on that section's cursor. -->
<template>
  <div class="feed-col search-page" data-test="search-page">
    <header class="feed-header">
      <MobileBack />
      <h2>{{ t('search.title') }}</h2>
      <code v-if="query" class="search-query" dir="ltr">{{ query }}</code>
      <!-- SPL-963: a message hit takes the middle pane's titles / 5 rows / full -->
      <LazyCardClipControl />
    </header>
    <div class="feed-body">
      <ul v-if="result && result.warnings.length" class="search-warnings" data-test="search-warnings">
        <li v-for="(w, i) in result.warnings" :key="i" class="muted">
          <code v-if="w.token" dir="ltr">{{ w.token }}</code> {{ w.detail }}
        </li>
      </ul>

      <section v-if="!query" class="search-help" data-test="search-help">
        <p class="muted">{{ t('search.help_intro') }}</p>
        <ul>
          <li v-for="ex in examples" :key="ex">
            <NuxtLink :to="localePath(searchPath(ex))"><code dir="ltr">/search {{ ex }}</code></NuxtLink>
          </li>
        </ul>
        <p class="muted">{{ t('search.help_operators') }}</p>
        <ul data-test="search-operator-help">
          <li v-for="row in helpRows" :key="row.op">
            <code dir="ltr">{{ row.example }}</code>
            <span v-if="te(row.hintKey)" class="muted"> · {{ t(row.hintKey) }}</span>
          </li>
        </ul>
      </section>

      <p v-else-if="search.loading" class="muted" data-test="search-loading" aria-live="polite">{{ t('search.loading') }}</p>

      <template v-else-if="search.error">
        <ViewTokenForm v-if="search.error.status === 401" :detail="search.error.detail" @saved="rerun" />
        <div v-else-if="search.error.token === 'bad_query'" class="search-bad" data-test="search-bad-query" role="alert">
          <p>{{ t('search.bad_query', { detail: search.error.detail }) }}</p>
          <p v-if="badAt" class="search-bad-q" dir="ltr"><code>{{ badAt.before }}<mark>{{ badAt.bad }}</mark>{{ badAt.after }}</code></p>
        </div>
        <ErrorNotice
          v-else
          :message="errorLine"
          :error="search.error.raw"
          source="search"
          test-id="search-error"
        />
      </template>

      <p v-else-if="result && !rows.length" class="muted" data-test="search-empty">{{ t('search.no_results') }}</p>

      <div
        v-else-if="result"
        ref="listEl"
        class="search-results"
        role="listbox"
        tabindex="0"
        data-test="search-results"
        :aria-label="t('search.results_label', { q: query })"
        :aria-activedescendant="active >= 0 ? rowId(active) : undefined"
        @keydown="onKey"
        @focus="active < 0 && rows.length && (active = 0)"
      >
        <section v-for="g in result.groups" :key="g.type" role="group" class="search-group" :data-group="g.type" :aria-labelledby="'sg-' + g.type">
          <h3 :id="'sg-' + g.type" class="search-group__title">{{ t('search.group.' + g.type) }}</h3>
          <div
            v-for="row in g.items"
            :id="rowId(indexOf(row))"
            :key="row.key"
            role="option"
            class="search-row"
            :class="{ active: indexOf(row) === active }"
            :aria-selected="indexOf(row) === active"
            :data-type="row.type"
            :data-key="row.key"
            :data-ts="rowAt(row) || undefined"
            @click="onRowClick(row)"
            @mousemove="active = indexOf(row)"
            @contextmenu="onRowContextMenu($event, row)"
            @pointerdown="pressDown($event, row)"
            @pointermove="longPress.move"
            @pointerup="longPress.up"
            @pointercancel="longPress.cancel"
          >
            <div class="search-row__head">
              <template v-if="row.type === 'robots' || row.type === 'users'">
                <SpoolAvatar :id="String(row.id || '')" :box="row.box ? String(row.box) : ''" :size="20" />
                <span class="dot" :class="{ on: row.online }" />
              </template>
              <span v-else-if="row.type === 'channels'" class="muted">#</span>
              <span v-else-if="row.type === 'boxes'" class="dot" :class="{ on: row.online }" />
              <span v-else-if="row.type === 'files'" aria-hidden="true">📎</span>
              <span v-if="row.type === 'messages'" class="search-row__who">
                <HumanName :id="String(row.from || '')" :box="row.from_box ? String(row.from_box) : ''" />
                <span aria-hidden="true"> → </span>
                <HumanName :id="String(row.to || '')" :box="row.to_box ? String(row.to_box) : ''" />
              </span>
              <span v-if="row.type === 'messages'" class="kind" :class="'kind-' + row.kind">{{ row.kind }}</span>
              <span v-if="row.type === 'users'" class="search-row__text" :title="String(row.id || '')">{{ userShown(row) }}</span>
              <span v-else-if="row.type !== 'messages'" class="search-row__text">
                <template v-for="(s, i) in segs(row)" :key="i"><mark v-if="s.mark">{{ s.text }}</mark><template v-else>{{ s.text }}</template></template>
              </span>
              <span class="search-row__meta muted">{{ meta(row) }}</span>
              <!-- 022 §10 FR-050: the row's right menu, also on right-click and a long press -->
              <button
                v-if="menuItems(row).length"
                type="button"
                tabindex="-1"
                class="icon-btn search-row__menu-btn"
                data-testid="search-row-menu-btn"
                aria-haspopup="menu"
                :aria-expanded="menu.row && menu.row.key === row.key ? 'true' : 'false'"
                :aria-label="t('search.menu.label')"
                :title="t('search.menu.label')"
                @click.stop="openMenuFromButton($event, row)"
                @contextmenu.stop.prevent="openMenuFromButton($event, row)"
              >
                <UiIcon name="menu" :size="16" />
              </button>
            </div>
            <p v-if="row.type === 'messages'" class="search-row__snippet" :class="listClipClass(clipMode)" data-test="search-msg-snippet" :data-clip-mode="clipMode">
              <!-- SPL-1009: a member in the snippet reads their name -->
              <template v-for="(s, i) in segs(row)" :key="i"><mark v-if="s.mark">{{ namedText(s.text, people.names.value) }}</mark><template v-else>{{ namedText(s.text, people.names.value) }}</template></template>
            </p>
            <p v-else-if="eventDetail(row)" class="search-row__snippet">{{ eventDetail(row) }}</p>
          </div>
          <button
            v-if="g.next"
            type="button"
            class="btn ghost search-more"
            :data-test="'search-more-' + g.type"
            :disabled="search.loadingMore === g.type"
            @click="search.more(g.type)"
          >
            {{ search.loadingMore === g.type ? t('search.loading') : t('search.load_more') }}
          </button>
        </section>
      </div>
    </div>
    <!-- mounted on open only: the menu is not in the initial JS (specs/027) -->
    <LazySearchRowMenu
      v-if="menu.row"
      :open="!!menu.row"
      :x="menu.x"
      :y="menu.y"
      :items="menuItems(menu.row)"
      @close="closeMenu"
      @escape="listEl?.focus({ preventScroll: true })"
      @choose="onMenuChoose"
    />
  </div>
</template>

<script setup lang="ts">
import { ISSUE_CHANNEL } from '~/utils/parent-section.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useLive } from '~/composables/useLive'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSearchStore } from '~/stores/search'
import { useTopicStore } from '~/stores/topic'
import { useTopicRoute } from '~/composables/useTopicRoute'
import { operatorHelpRows, searchPath, type SearchRow } from '~/utils/search.mjs'
import { flattenGroups, highlightSegments, isPlacedRow, moveIndex, originalHref, rowAt, searchRowMenuItems, searchTarget, topicPageOf } from '~/utils/search-results.mjs'
import { openThreadRow, scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { namedText, shownPerson } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import HumanName from '~/components/HumanName.vue'
import { useCardClip } from '~/composables/useCardClip'
import { listClipClass } from '~/utils/card-clip.mjs'
import { createLongPress } from '~/utils/touch-ui.mjs'
import { useCopyText } from '~/composables/useCopyText'
import { useAccessStore } from '~/stores/access'
import { useRosterStore } from '~/stores/roster'

const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const { mode: clipMode } = useCardClip()
const route = useRoute()
const router = useRouter()
const search = useSearchStore()
const api = useSpoolApi()
const authClient = useAuthClient()
const omnibox = useOmniboxStore()
const pane = useLiveFeed('pane')
const topic = useTopicStore()
const people = useHumanNames()
const listEl = ref<HTMLElement | null>(null)
const access = useAccessStore()
const roster = useRosterStore()
const liveIdentity = useLive().identity
/** the reader: the DM end that is not the peer (utils/parent-section.mjs) */
const viewerId = computed(() => String(access.me?.humanId || liveIdentity.value || roster.me?.id || ''))
const { copy: copyText } = useCopyText()

/* the topic a hit opens is in the URL too, so a search result the
   reader wants to show someone is one link, not "search this, then click the
   third row". The `q` parameter is untouched. */
useTopicRoute({
  open: async (target) => {
    topic.setTarget(target, null)
    await pane.open(target.taskId)
  },
  close: () => {
    topic.close()
    pane.close()
  },
})
const active = ref(-1)

const examples = [
  'from:CLE-07 is:task',
  '"dry run" after:7d',
  'type:robot is:online',
  'title:migration',
  'type:file ext:pdf larger:1M',
  'has:code in:#lobby',
  'type:channel name:dev',
  'type:tenant name:ops',
  'type:tenant csitea',
  'type:event fetch',
  'status:in_progress',
]
const helpRows = computed(() => operatorHelpRows(search.operators))

const query = computed(() => (typeof route.query.q === 'string' ? route.query.q : ''))
const result = computed(() => search.result)
const rows = computed(() => (result.value ? flattenGroups(result.value.groups) : []))
const indexByKey = computed(() => new Map(rows.value.map((r, i) => [r.key, i])))

function indexOf(row: SearchRow) { return indexByKey.value.get(row.key) ?? -1 }
function rowId(i: number) { return 'sr-' + i }
function segs(row: SearchRow) { return highlightSegments(row.display.text, row.display.highlights) }
function label(id: unknown, box: unknown) {
  const s = id ? String(id) : ''
  if (!s) return '—'
  return shownPerson(s, box ? String(box) : undefined, people.names.value)
}
function userShown(row: SearchRow) {
  const r = row as Record<string, unknown>
  const n = typeof r.display_name === 'string' ? r.display_name.trim() : ''
  if (n) return n
  return label(r.id, r.box)
}

/** Where a hit lives: #channel, the Issues label for an issue's discussion (SPL-68: `issues` is not a channel), or a DM. */
function place(channel: unknown): string {
  const c = String(channel || '')
  if (!c) return t('search.in_dm')
  return c === ISSUE_CHANNEL ? t('search.group.issues') : '#' + c
}

function meta(row: SearchRow): string {
  const r = row as Record<string, any>
  switch (row.type) {
    case 'messages': return [place(r.channel), when(r.received_at || r.created_at)].filter(Boolean).join(' · ')
    case 'topics': return [place(r.channel), t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0), when(r.last_ts)].filter(Boolean).join(' · ')
    case 'files': return [label(r.from, r.from_box), r.bytes != null ? t('composer.file_bytes', { n: r.bytes }) : '', when(r.received_at)].filter(Boolean).join(' · ')
    case 'robots': return r.revoked ? t('search.revoked') : ''
    case 'users': return ''
    case 'channels': return r.count != null ? t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0) : ''
    case 'boxes': return Array.isArray(r.agents) ? r.agents.join(', ') : ''
    case 'tenants': {
      const role = String(r.role || '')
      const roleLabel = role && te('role.' + role) ? t('role.' + role) : ''
      return [String(r.tenant_id || ''), roleLabel, r.current ? t('search.current_tenant') : ''].filter(Boolean).join(' · ')
    }
    case 'events': return [r.code || r.path || r.error_id, when(r.received_at)].filter(Boolean).join(' · ')
    case 'issues': {
      const status = r.status == null || r.status === '' ? '' : String(r.status)
      const priority = r.priority == null || r.priority === '' ? '' : String(r.priority)
      const assignee = r.assignee == null || r.assignee === '' ? '' : String(r.assignee)
      return [status, priority, assignee].filter((part) => part !== '').join(' · ')
    }
    default: return ''
  }
}

function when(ts: unknown): string {
  const d = new Date(String(ts || ''))
  return isoDateTime(d)
}

function eventDetail(row: SearchRow): string {
  if (row.type !== 'events') return ''
  const msg = String((row as Record<string, unknown>).message || '')
  return msg && msg !== row.display.text ? msg : ''
}

const errorLine = computed(() => {
  const e = search.error
  if (!e) return ''
  if (e.status === 429) return t('search.rate_limited', { s: e.retryAfter || 60 })
  if (e.status === 503) return t('search.budget')
  // status 0 = no HTTP answer the page may read (network, CORS on a hub without the route)
  if (!e.status && !e.token) return t('search.unreachable')
  return t('search.failed', { detail: e.detail || e.token || String(e.status || '') })
})

/** the bad token of a 400, marked inside the query (pos is a UTF-16 offset = String.slice) */
const badAt = computed(() => {
  const e = search.error
  const q = query.value
  if (!e || e.pos < 0 || e.pos > q.length) return null
  const n = Math.max(1, e.badToken.length)
  return { before: q.slice(0, e.pos), bad: q.slice(e.pos, e.pos + n) || ' ', after: q.slice(e.pos + n) }
})

function rerun() { void search.run(query.value) }

watch(query, (q) => {
  active.value = -1
  void search.run(q)
}, { immediate: true })

/* ArrowDown in the Omnibox (search mode) hands the focus to the list */
watch(() => omnibox.focusResults, () => {
  const el = listEl.value
  if (!el) return
  if (active.value < 0 && rows.value.length) active.value = 0
  el.focus({ preventScroll: true })
})

function onKey(ev: KeyboardEvent) {
  if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(ev.key)) {
    ev.preventDefault()
    active.value = moveIndex(active.value, rows.value.length, ev.key)
    nextTick(() => {
      const el = document.getElementById(rowId(active.value))
      const scroller = el?.closest<HTMLElement>('.feed-body')
      if (el && scroller) scrollRowToTop(scroller, el)
    })
    return
  }
  if (ev.key === 'Enter' && active.value >= 0) {
    ev.preventDefault()
    const row = rows.value[active.value]
    if (row) open(row)
    return
  }
  /* FR-050: the keyboard's own menu key (or Shift+F10) opens the row's menu */
  if ((ev.key === 'ContextMenu' || (ev.key === 'F10' && ev.shiftKey)) && active.value >= 0) {
    ev.preventDefault()
    const row = rows.value[active.value]
    const el = document.getElementById(rowId(active.value))
    if (!row || !el) return
    const r = el.getBoundingClientRect()
    openMenuAt(row, r.left + 16, r.top + 24)
  }
}

/* 022 §10 FR-050: the right menu of a row - right-click, the row button, a
   long press on a phone (the bottom sheet), or the menu key. */
const menu = reactive<{ row: SearchRow | null, x: number, y: number }>({ row: null, x: 0, y: 0 })
function menuItems(row: SearchRow | null) { return row ? searchRowMenuItems(row) : [] }
function openMenuAt(row: SearchRow, x: number, y: number) {
  if (!menuItems(row).length) return
  active.value = indexOf(row)
  menu.row = row
  menu.x = x
  menu.y = y
}
function closeMenu() { menu.row = null }
function onRowContextMenu(ev: MouseEvent, row: SearchRow) {
  if (!menuItems(row).length) return
  ev.preventDefault()
  openMenuAt(row, ev.clientX, ev.clientY)
}
function openMenuFromButton(ev: MouseEvent, row: SearchRow) {
  const btn = ev.currentTarget
  if (menu.row && menu.row.key === row.key) return closeMenu()
  if (!(btn instanceof HTMLElement)) return
  const r = btn.getBoundingClientRect()
  openMenuAt(row, r.left, r.bottom + 4)
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
function pressDown(ev: PointerEvent, row: SearchRow) {
  pressRow = row
  longPress.down(ev)
}
function onRowClick(row: SearchRow) {
  /* the finger that long-pressed lifts with a click: that click is the menu's */
  if (longPress.takeClick()) return
  void open(row)
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
    and marked (utils/search-original.mjs); every other row its FR-023 page. */
async function open(row: SearchRow) {
  active.value = indexOf(row)
  const to = searchTarget(row)
  if (!to) return
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

/** FR-050 Show here (the FR-023 preview): message / file → its topic in the
    right pane of this page at that message; topic → that topic. */
async function showHere(row: SearchRow) {
  active.value = indexOf(row)
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
  // The thread opens at the top. Focusing the hit does not move that pane or the document.
  openThreadRow(el)
  el.classList.add('search-focus')
  setTimeout(() => el.classList.remove('search-focus'), 2400)
}

useHead(() => ({ title: query.value ? `${t('search.title')}: ${query.value}` : t('search.title') }))
</script>

<style scoped>
.search-query {
  font-family: var(--font-mono);
  font-size: 0.8125rem;
  min-width: 0;
  overflow-wrap: anywhere;
}
.search-warnings, .search-help ul { list-style: none; padding: 0; margin: 0 0 12px; }
.search-help li { margin: 4px 0; overflow-wrap: anywhere; }
.search-help code { overflow-wrap: anywhere; }
.search-results { outline: none; min-width: 0; max-width: 100%; }
.search-results:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; border-radius: var(--radius); }
.search-group { margin: 0 0 16px; min-width: 0; }
.search-group__title {
  font-size: 0.6875rem;
  letter-spacing: 0.12em;
  text-transform: uppercase;
  color: var(--color-muted);
  margin: 0 0 4px;
}
.search-row {
  padding: 8px 10px;
  border-radius: var(--radius);
  cursor: pointer;
  min-width: 0;
  max-width: 100%;
}
/* a chosen row is a SELECTED item — the darker fill and the one
   3px marker bar of the shared treatment, not a lighter hover fill. */
.search-row.active { background: var(--color-selected); box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring); }
.search-row__head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; font-size: 0.875rem; }
.search-row__who { font-weight: 600; min-width: 0; overflow-wrap: anywhere; }
.search-row__text { min-width: 0; overflow-wrap: anywhere; }
.search-row__meta { font-size: 0.75rem; min-width: 0; overflow-wrap: anywhere; }
/* 022 §10 FR-050: the row's menu button, at the end of the head line; seen on
   hover, keyboard focus and the active row (always on a phone, below) */
.search-row__menu-btn { margin-inline-start: auto; flex: none; opacity: 0; }
.search-row:hover .search-row__menu-btn,
.search-row.active .search-row__menu-btn,
.search-row__menu-btn[aria-expanded='true'],
.search-row__menu-btn:focus-visible { opacity: 1; }
.search-row__snippet { margin: 4px 0 0; font-size: 0.875rem; line-height: 1.45; overflow-wrap: anywhere; min-width: 0; }
/* SPL-963: titles = one line, 5 rows = at most 5 lines, full = all of it */
.search-row__snippet.list-clip--titles { white-space: nowrap; overflow: hidden; text-overflow: ellipsis; overflow-wrap: normal; }
.search-row__snippet.list-clip--rows {
  display: -webkit-box;
  -webkit-box-orient: vertical;
  -webkit-line-clamp: 5;
  line-clamp: 5;
  overflow: hidden;
}
.search-results mark, .search-bad mark {
  background: var(--color-glow);
  color: inherit;
  border-radius: var(--radius-sm);
  padding: 0 1px;
}
.search-bad-q code { font-family: var(--font-mono); overflow-wrap: anywhere; }
.search-more { margin-top: 4px; }
/* SPL-993: phones. The query in the header gives up width to the title and
   the clip control (one line, ellipsis), and the example links are 44 px
   touch targets. */
@media (max-width: 820px) {
  .search-row__menu-btn { opacity: 1; min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
  .search-row { -webkit-touch-callout: none; }
  .search-query { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .search-help a { display: block; min-height: var(--tap, 44px); padding-block: 10px; box-sizing: border-box; }
}
</style>
