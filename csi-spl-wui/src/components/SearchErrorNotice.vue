<!-- SPL-1833 (owner HUM-10, t1 659e3927, msgs 090f687d, 9f8f842e, 4de3b04e):
     a search that times out or fails says ONE plain sentence - what happened
     and what to do - with a "Try again" button, in the results area, not the
     red error box. The technical part (HTTP status, the hub's error token and
     detail, how long the call took, the reference id) shows ONLY when the
     reader ticked the existing Debug pane setting (debugAudience.mjs, the
     same claim the DebugPanel at the bottom of the app reads).

     The reference id is still minted and journaled for every failure, debug
     pane or not, so the diagnostics panel and RUM keep the record; it is
     journaled `inline`, so the red top snackbar does not repeat it, and the
     reader sees the id only with the pane on. Technical text never passes
     through t().

     On demand (i18n-first-screen.mjs): its strings wait in the second
     catalogue. Until that catalogue is merged it says the core
     "Something went wrong" and offers no button (te() below), so no first
     paint ever shows a raw key. -->
<template>
  <div class="search-err" :data-test="testId" role="status" aria-live="polite">
    <p class="search-err__msg" :data-test="`${testId}-message`">{{ sentence }}</p>
    <button
      v-if="canRetry && te('search.err.retry')"
      type="button"
      class="btn search-err__retry"
      :data-test="`${testId}-retry`"
      @click="emit('retry')"
    >
      {{ t('search.err.retry') }}
    </button>
    <p v-if="debug" class="search-err__tech" dir="ltr" :data-test="`${testId}-tech`">
      <code>{{ techLine }}</code>
    </p>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref, watch } from 'vue'
import { extractErrorId, newClientErrorId, noteError } from '@/composables/errorJournal.mjs'
import { debugPanelVisibleFor } from '~/composables/debugAudience.mjs'
import { useSessionStore } from '~/stores/session'
import { SEARCH_BUDGET_S, searchErrorKind, type SearchError } from '~/stores/search'

const props = withDefaults(defineProps<{ error: SearchError, testId?: string }>(), { testId: 'search-error' })
const emit = defineEmits<{ retry: [] }>()

const { t, te } = useI18n({ useScope: 'global' })
const session = useSessionStore()

const debug = computed(() => session.state === 'in' && debugPanelVisibleFor(session.claims ?? null))
const kind = computed(() => searchErrorKind(props.error))
const sentence = computed(() => {
  if (!te('search.err.slow')) return t('error.title_other')
  switch (kind.value) {
    case 'slow': return t('search.err.slow')
    case 'busy': return t('search.rate_limited', { s: props.error.retryAfter || 60 })
    case 'offline': return t('search.unreachable')
    default: return t('search.err.failed')
  }
})
/* a 429 names its own wait; every other failure can be tried again at once */
const canRetry = computed(() => kind.value !== 'busy')

/* one id per distinct failure, after mount (never during a prerender) */
const refId = ref('')
function resolve() {
  const e = props.error
  const known = extractErrorId(e.raw)
  if (known) {
    refId.value = known
    return
  }
  refId.value = newClientErrorId()
  noteError({ source: 'search', message: sentence.value, error: e.raw, errorId: refId.value, inline: true })
}
onMounted(resolve)
watch(() => props.error, resolve)

const techLine = computed(() => {
  const e = props.error
  const parts = [`HTTP ${e.status || 'none'}`]
  if (e.token) parts.push(e.token)
  if (e.detail) parts.push(e.detail)
  if (e.ms > 0) parts.push(`${e.ms} ms`)
  if (kind.value === 'slow') parts.push(`budget ${SEARCH_BUDGET_S} s`)
  if (refId.value) parts.push(refId.value)
  return parts.join(' · ')
})
</script>

<style scoped>
.search-err { margin: 8px 0; }
.search-err__msg { margin: 0 0 8px; overflow-wrap: anywhere; }
.search-err__retry { min-height: var(--tap, 44px); }
.search-err__tech { margin: 8px 0 0; font-size: 0.8125rem; color: var(--color-muted, inherit); }
.search-err__tech code { font-family: var(--font-mono); overflow-wrap: anywhere; }
@media (min-width: 821px) { .search-err__retry { min-height: 0; } }
</style>
