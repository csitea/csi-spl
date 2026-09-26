<!-- 022 FR-020..025: global search results, deep-linkable as /search?q=….
     Grouped sections (robots, users, channels, boxes, tenants, topics, files,
     messages, events, issues; search-v1 §4), highlights from offsets rendered as text nodes,
     one listbox across all sections (ArrowUp/Down wrap, Home/End, Enter
     opens), per-section "Load more" on that section's cursor. -->
<template>
  <div class="feed-col search-page" data-test="search-page">
    <header class="feed-header">
      <h2>{{ t('search.title') }}</h2>
      <code v-if="query" class="search-query" dir="ltr">{{ query }}</code>
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
            @click="open(row)"
            @mousemove="active = indexOf(row)"
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
            </div>
            <p v-if="row.type === 'messages'" class="search-row__snippet">
              <template v-for="(s, i) in segs(row)" :key="i"><mark v-if="s.mark">{{ s.text }}</mark><template v-else>{{ s.text }}</template></template>
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
  </div>
</template>

<script setup lang="ts">
import { ISSUE_CHANNEL } from '~/utils/parent-section.mjs'
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSearchStore } from '~/stores/search'
import { useTopicStore } from '~/stores/topic'
import { useTopicRoute } from '~/composables/useTopicRoute'
import { operatorHelpRows, searchPath, type SearchRow } from '~/utils/search.mjs'
import { flattenGroups, highlightSegments, moveIndex, rowAt, searchTarget } from '~/utils/search-results.mjs'
import { openThreadRow, scrollRowToTop } from '~/utils/pane-scroll.mjs'
import { shownPerson } from '~/utils/channel-feed.mjs'
import { useHumanNames } from '~/composables/useHumanNames'
import HumanName from '~/components/HumanName.vue'

const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
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

/* CLE-3427: the topic a hit opens is in the URL too, so a search result the
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
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleString()
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
  }
}

/** FR-023: message / file → its topic in the right pane at that message */
async function open(row: SearchRow) {
  active.value = indexOf(row)
  const to = searchTarget(row)
  if (!to) return
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
/* CLE-3427: a chosen row is a SELECTED item — the darker fill and the one
   3px marker bar of the shared treatment, not a lighter hover fill. */
.search-row.active { background: var(--color-selected); box-shadow: inset var(--select-bar-w) 0 0 var(--focus-ring); }
.search-row__head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; font-size: 0.875rem; }
.search-row__who { font-weight: 600; min-width: 0; overflow-wrap: anywhere; }
.search-row__text { min-width: 0; overflow-wrap: anywhere; }
.search-row__meta { font-size: 0.75rem; min-width: 0; overflow-wrap: anywhere; }
.search-row__snippet { margin: 4px 0 0; font-size: 0.875rem; line-height: 1.45; overflow-wrap: anywhere; min-width: 0; }
.search-results mark, .search-bad mark {
  background: var(--color-glow);
  color: inherit;
  border-radius: var(--radius-sm);
  padding: 0 1px;
}
.search-bad-q code { font-family: var(--font-mono); overflow-wrap: anywhere; }
.search-more { margin-top: 4px; }
</style>
