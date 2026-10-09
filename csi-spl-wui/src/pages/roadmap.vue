<!-- Spec 112 WUI-1 (5, 5.1, 5.3 (b), 9): the roadmap, spec rows. One row per
     spec dir (no-tasks rows included), from /roadmap.json: written at
     generate time by src/node/roadmap/sync-roadmap.mjs from
     do_spl_spec_progress --json (the ONE rule, 5.1), FETCHED on mount and
     never imported (an imported JSON is inlined into a chunk; 9: zero bytes
     added to the initial chunk). The table loads as its own chunk
     (defineAsyncComponent, as calendar.vue does).
     ?when=week|month keeps the rows whose tasks.md changed in this ISO week
     or calendar month, in the viewer's zone (spec 089); the filter lives in
     the URL so a link reproduces it. /roadmap#spec-089 opens on that row.
     WUI-3 adds the workspace filter and the goal rows in its own files. -->
<template>
  <div class="feed-col roadmap-page" data-test="roadmap-page">
    <header class="feed-header">
      <MobileBack />
      <SectionClose side="start" />
      <h2 data-test="roadmap-heading">{{ t('roadmap.title') }}</h2>
      <span class="roadmap-spacer" />
      <SectionClose side="end" />
    </header>
    <div class="feed-body roadmap-body">
      <div class="roadmap-bar">
        <div class="roadmap-when" role="group" :aria-label="t('roadmap.when_label')" data-test="roadmap-when">
          <button
            v-for="w in WHENS"
            :key="w || 'all'"
            type="button"
            class="btn ghost"
            :data-test="`roadmap-when-${w || 'all'}`"
            :aria-pressed="when === w ? 'true' : 'false'"
            @click="setWhen(w)"
          >{{ t(`roadmap.when_${w || 'all'}`) }}</button>
        </div>
        <p v-if="state === 'ready'" class="muted roadmap-count" data-test="roadmap-count" :data-shown="rows.length" :data-total="specs.length">
          {{ t('roadmap.count', { shown: rows.length, total: specs.length }) }}
        </p>
      </div>
      <p v-if="state === 'loading'" class="muted" data-test="roadmap-loading">{{ t('common.loading') }}</p>
      <p v-else-if="state === 'error'" class="roadmap-error" role="alert" data-test="roadmap-error">{{ t('roadmap.error') }}</p>
      <p v-else-if="!rows.length" class="muted" data-test="roadmap-empty">{{ t(when ? 'roadmap.empty_window' : 'roadmap.empty') }}</p>
      <RoadmapSpecTable v-else :rows="rows" :focus="focus" />
      <p v-if="state === 'ready' && sha" class="muted roadmap-sha" data-test="roadmap-sha">{{ t('roadmap.rule_note') }} <code dir="ltr">{{ sha }}</code></p>
    </div>
  </div>
</template>

<script setup lang="ts">
import { isoDate } from '~/utils/date-iso.mjs'
import { roadmapRows, roadmapSpecs, roadmapWhen } from '~/utils/roadmap-rows.mjs'

/* the spec-row table is its own chunk, fetched on route entry (spec 112 9) */
const RoadmapSpecTable = defineAsyncComponent(() => import('~/components/RoadmapSpecTable.vue'))

interface RoadmapSpec {
  id: string
  title: string
  state: string
  x: number
  p: number
  o: number
  pct: number | null
  tasks_changed: string
}

const WHENS = ['', 'week', 'month'] as const

const { t } = useI18n({ useScope: 'global' })
const route = useRoute()
const router = useRouter()

const state = ref<'loading' | 'ready' | 'error'>('loading')
const specs = ref<RoadmapSpec[]>([])
const sha = ref('')

const when = computed(() => roadmapWhen(route.query.when))
const focus = computed(() => decodeURIComponent(String(route.hash || '').replace(/^#/, '')))
const rows = computed<RoadmapSpec[]>(() => roadmapRows(specs.value, when.value, isoDate(Date.now()), (iso: string) => isoDate(iso)))

async function setWhen(w: string) {
  if (w === when.value) return
  await router.replace({ query: { ...route.query, when: w || undefined }, hash: route.hash })
}

/* fetched, never imported: an imported JSON lands in a chunk (spec 112 9) */
onMounted(async () => {
  try {
    const res = await fetch('/roadmap.json', { cache: 'no-cache' })
    if (!res.ok) throw new Error(String(res.status))
    const doc = await res.json()
    specs.value = roadmapSpecs(doc) as RoadmapSpec[]
    sha.value = typeof doc?.sha === 'string' ? doc.sha.slice(0, 12) : ''
    state.value = 'ready'
  } catch {
    state.value = 'error'
  }
})

/* /roadmap#spec-089: scroll that row into view once the rows are there */
watch([rows, focus], () => {
  if (!focus.value) return
  nextTick(() => document.getElementById(focus.value)?.scrollIntoView({ block: 'center' }))
})

useHead(() => ({ title: t('roadmap.title') }))
</script>

<style scoped>
.roadmap-spacer { flex: 1 1 auto; }
.roadmap-body { min-width: 0; }
.roadmap-bar {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 0.5rem 1rem;
  margin-bottom: 0.75rem;
}
.roadmap-when {
  display: inline-flex;
  flex-wrap: wrap;
  gap: 0.25rem;
}
.roadmap-when .btn[aria-pressed='true'] {
  background: var(--color-selected);
  color: var(--color-fg);
}
.roadmap-count,
.roadmap-sha { margin: 0; }
.roadmap-sha { margin-top: 0.75rem; font-size: 0.75rem; }
.roadmap-error {
  margin: 0;
  color: var(--color-danger);
  overflow-wrap: anywhere;
}
@media (max-width: 820px) {
  .roadmap-when .btn { min-height: var(--tap, 44px); }
}
</style>
