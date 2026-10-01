<!-- 022 FR-020..025: global search, deep-linkable as /search?q=….
     CLE-77884 (owner, topic 635f8072): the grouped hits (search-v1 §4) are the
     LEFT panel's list, components/SearchSidePanel.vue - one listbox across all
     sections, highlights as text nodes, per-section "Load more". This page
     keeps the query, the help, the warnings and the errors; on a phone it
     renders that list itself. -->
<template>
  <div class="feed-col search-page" data-test="search-page">
    <header class="feed-header">
      <MobileBack />
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

      <!-- CLE-77884 (owner, topic 635f8072): the hits are the LEFT panel's
           list (components/SearchSidePanel.vue in the sidebar). On a phone
           this page IS that list, full screen; Back from a hit returns here. -->
      <LazySearchSidePanel v-else-if="result && stack.isMobile.value" in-page />
      <p v-else-if="result" class="muted search-left-hint" data-test="search-left-hint">
        {{ t('search.left_hint', { n: rows.length }, rows.length) }}
      </p>
    </div>
  </div>
</template>

<script setup lang="ts">
import ErrorNotice from '~/components/common/ErrorNotice.vue'
import { useLiveFeed } from '~/stores/live'
import { useSearchStore } from '~/stores/search'
import { useTopicStore } from '~/stores/topic'
import { useTopicRoute } from '~/composables/useTopicRoute'
import { operatorHelpRows, searchPath } from '~/utils/search.mjs'
import { flattenGroups } from '~/utils/search-results.mjs'
import { useMobileStack } from '~/composables/useMobileStack'

const { t, te } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const route = useRoute()
const search = useSearchStore()
const pane = useLiveFeed('pane')
const topic = useTopicStore()
const stack = useMobileStack()

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

/* a phone Back onto this page keeps the answer it left (and the list's
   chosen hit and scroll): only a NEW query runs */
watch(query, (q) => {
  if (q === search.q && search.activeKey && (search.result || search.loading)) return
  void search.run(q)
}, { immediate: true })

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
.search-left-hint { margin: 8px 0; }
.search-bad mark {
  background: var(--color-glow);
  color: inherit;
  border-radius: var(--radius-sm);
  padding: 0 1px;
}
.search-bad-q code { font-family: var(--font-mono); overflow-wrap: anywhere; }
/* SPL-993: phones. The query in the header gives up width to the title and
   the clip control (one line, ellipsis), and the example links are 44 px
   touch targets. */
@media (max-width: 820px) {
  .search-query { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .search-help a { display: block; min-height: var(--tap, 44px); padding-block: 10px; box-sizing: border-box; }
}
</style>
