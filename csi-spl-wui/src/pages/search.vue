<!-- 022 FR-020..025: global search results, deep-linkable as /search?q=….
     Grouped sections (robots, users, channels, boxes, threads, files,
     messages; search-v1 §4), highlights from offsets rendered as text nodes,
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
                {{ label(row.from, row.from_box) }} → {{ label(row.to, row.to_box) }}
              </span>
              <span v-if="row.type === 'messages'" class="kind" :class="'kind-' + row.kind">{{ row.kind }}</span>
              <span v-if="row.type !== 'messages'" class="search-row__text">
                <template v-for="(s, i) in segs(row)" :key="i"><mark v-if="s.mark">{{ s.text }}</mark><template v-else>{{ s.text }}</template></template>
              </span>
              <span class="search-row__meta muted">{{ meta(row) }}</span>
            </div>
            <p v-if="row.type === 'messages'" class="search-row__snippet">
              <template v-for="(s, i) in segs(row)" :key="i"><mark v-if="s.mark">{{ s.text }}</mark><template v-else>{{ s.text }}</template></template>
            </p>
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
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useOmniboxStore } from '~/stores/omnibox'
import { useSearchStore } from '~/stores/search'
import { flattenGroups, highlightSegments, moveIndex, searchPath, searchTarget, type SearchRow } from '~/utils/search.mjs'

const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const route = useRoute()
const router = useRouter()
const search = useSearchStore()
const omnibox = useOmniboxStore()
const pane = useLiveFeed('pane')
const listEl = ref<HTMLElement | null>(null)
const active = ref(-1)

const examples = [
  'from:CLE-07 is:task',
  '"dry run" after:7d',
  'type:robot is:online',
  'title:migration',
  'type:file ext:pdf larger:1M',
  'has:code in:#lobby',
]

const query = computed(() => (typeof route.query.q === 'string' ? route.query.q : ''))
const result = computed(() => search.result)
const rows = computed(() => (result.value ? flattenGroups(result.value.groups) : []))
const indexByKey = computed(() => new Map(rows.value.map((r, i) => [r.key, i])))

function indexOf(row: SearchRow) { return indexByKey.value.get(row.key) ?? -1 }
function rowId(i: number) { return 'sr-' + i }
function segs(row: SearchRow) { return highlightSegments(row.display.text, row.display.highlights) }
function label(id: unknown, box: unknown) { return id ? String(id) + (box ? '@' + String(box) : '') : '—' }

function meta(row: SearchRow): string {
  const r = row as Record<string, any>
  switch (row.type) {
    case 'messages': return [r.channel ? '#' + r.channel : t('search.in_dm'), when(r.received_at || r.created_at)].filter(Boolean).join(' · ')
    case 'threads': return [r.channel ? '#' + r.channel : t('search.in_dm'), t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0), when(r.last_ts)].filter(Boolean).join(' · ')
    case 'files': return [label(r.from, r.from_box), r.bytes != null ? t('composer.file_bytes', { n: r.bytes }) : '', when(r.received_at)].filter(Boolean).join(' · ')
    case 'robots': return r.revoked ? t('search.revoked') : ''
    case 'users': return r.display_name && r.id ? String(r.id) : ''
    case 'channels': return r.count != null ? t('search.count_messages', { n: Number(r.count) || 0 }, Number(r.count) || 0) : ''
    case 'boxes': return Array.isArray(r.agents) ? r.agents.join(', ') : ''
    default: return ''
  }
}

function when(ts: unknown): string {
  const d = new Date(String(ts || ''))
  return Number.isNaN(d.getTime()) ? '' : d.toLocaleString()
}

const errorLine = computed(() => {
  const e = search.error
  if (!e) return ''
  if (e.status === 429) return t('search.rate_limited', { s: e.retryAfter || 60 })
  if (e.status === 503) return t('search.budget')
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
  el.focus()
})

function onKey(ev: KeyboardEvent) {
  if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(ev.key)) {
    ev.preventDefault()
    active.value = moveIndex(active.value, rows.value.length, ev.key)
    nextTick(() => document.getElementById(rowId(active.value))?.scrollIntoView({ block: 'nearest', inline: 'nearest' }))
    return
  }
  if (ev.key === 'Enter' && active.value >= 0) {
    ev.preventDefault()
    const row = rows.value[active.value]
    if (row) open(row)
  }
}

/** FR-023: message / file → its thread in the right pane at that message */
async function open(row: SearchRow) {
  active.value = indexOf(row)
  const to = searchTarget(row)
  if (!to) return
  if ('path' in to) return void router.push(localePath(to.path))
  if ('search' in to) return void router.push(localePath(searchPath(to.search)))
  await pane.open(to.thread)
  if (to.focus) focusMessage(to.focus)
}

function focusMessage(msgId: string, tries = 30) {
  const el = document.querySelector<HTMLElement>(`.live-pane [data-msg-id="${CSS.escape(msgId)}"]`)
  if (!el) {
    if (tries > 0) setTimeout(() => focusMessage(msgId, tries - 1), 100)
    return
  }
  // scroll only the pane's own list — scrollIntoView would also move the document under the bar
  const sc = el.closest<HTMLElement>('.feed-body')
  if (sc) sc.scrollTop += el.getBoundingClientRect().top - sc.getBoundingClientRect().top - sc.clientHeight / 3
  el.classList.add('search-focus')
  el.focus({ preventScroll: true })
  setTimeout(() => el.classList.remove('search-focus'), 2400)
}

useHead(() => ({ title: query.value ? `${t('search.title')}: ${query.value}` : t('search.title') }))
</script>

<style scoped>
.search-query {
  font-family: var(--font-mono);
  font-size: 13px;
  min-width: 0;
  overflow-wrap: anywhere;
}
.search-warnings, .search-help ul { list-style: none; padding: 0; margin: 0 0 12px; }
.search-help li { margin: 4px 0; }
.search-results { outline: none; min-width: 0; max-width: 100%; }
.search-results:focus-visible { outline: 2px solid var(--color-accent); outline-offset: 2px; border-radius: var(--radius); }
.search-group { margin: 0 0 16px; min-width: 0; }
.search-group__title {
  font-size: 11px;
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
.search-row.active { background: var(--color-surface-hover); }
.search-row__head { display: flex; align-items: center; gap: 8px; flex-wrap: wrap; min-width: 0; font-size: 14px; }
.search-row__who { font-weight: 600; min-width: 0; overflow-wrap: anywhere; }
.search-row__text { min-width: 0; overflow-wrap: anywhere; }
.search-row__meta { font-size: 12px; min-width: 0; overflow-wrap: anywhere; }
.search-row__snippet { margin: 4px 0 0; font-size: 14px; line-height: 1.45; overflow-wrap: anywhere; min-width: 0; }
.search-results mark, .search-bad mark {
  background: var(--color-glow);
  color: inherit;
  border-radius: 3px;
  padding: 0 1px;
}
.search-bad-q code { font-family: var(--font-mono); overflow-wrap: anywhere; }
.search-more { margin-top: 4px; }
</style>
