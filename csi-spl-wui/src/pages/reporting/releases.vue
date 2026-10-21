<!-- Spec 143 2.2 (SPL-2787), tasks T022-T024: Reporting -> Releases, the
     delivery report over the release notes. The KPI strip, the filter bar,
     then the days newest first with their commits. Two reads per filter
     change: GET /v1/reporting/releases/daily (the day headers and the KPIs)
     and the first page of GET /v1/reporting/releases/commits; "Load more"
     reads the next page. A read that loses the race to a newer filter is
     dropped. Its own chunk: Nuxt loads this page only on /reporting/releases. -->
<template>
  <div class="reporting-releases" data-test="reporting-releases">
    <ReportingReleasesSummary :summary="summary" />
    <ReleasesFilterBar v-model:range="range" v-model:kinds="kinds" v-model:areas="areas" v-model:search="search" />

    <p v-if="state === 'loading' && !daily" class="muted" data-test="releases-loading">{{ t('reporting.releases.loading') }}</p>
    <p v-else-if="state === 'error'" class="rr-error" data-test="releases-error">
      {{ t('reporting.releases.error') }}
      <button type="button" class="btn" data-test="releases-retry" @click="load()">{{ t('reporting.releases.retry') }}</button>
    </p>
    <p v-else-if="daily && !groups.length" class="muted" data-test="releases-empty">{{ t('reporting.releases.empty') }}</p>

    <ReleasesDailyList v-if="groups.length" :groups="groups" />

    <div v-if="notes.length && total > 0" class="rr-more">
      <span class="muted" data-test="releases-shown">{{ t('reporting.releases.shown', { shown: notes.length, total }) }}</span>
      <button v-if="notes.length < total" type="button" class="btn" :disabled="busy" data-test="releases-more" @click="more()">{{ t('reporting.releases.load_more') }}</button>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import ReportingReleasesSummary from '~/components/reporting/ReportingReleasesSummary.vue'
import ReleasesFilterBar from '~/components/reporting/ReleasesFilterBar.vue'
import ReleasesDailyList from '~/components/reporting/ReleasesDailyList.vue'
import {
  mergeCommitPages, RELEASE_PAGE, RELEASE_RANGE_DEFAULT, releaseDayGroups, releaseQuery, releaseReportRead, releaseSummary, releaseWindow,
  type ReleaseCommit, type ReleaseCommits, type ReleaseDaily,
} from '~/utils/reporting-releases'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as Parameters<typeof releaseReportRead>[0]

const range = ref<string>(RELEASE_RANGE_DEFAULT)
const kinds = ref<string[]>([])
const areas = ref<string[]>([])
const search = ref('')

const daily = ref<ReleaseDaily | null>(null)
const notes = ref<ReleaseCommit[]>([])
const total = ref(0)
const days = ref(7)
const state = ref<'loading' | 'ok' | 'error'>('loading')
const busy = ref(false)

const summary = computed(() => (daily.value ? releaseSummary(daily.value, days.value) : null))
const groups = computed(() => releaseDayGroups(daily.value?.days, notes.value))

/* the window is fixed per load, so "Load more" pages the same commits */
let win = releaseWindow(RELEASE_RANGE_DEFAULT, Date.now())
const filter = () => ({ from: win.from, to: win.to, kinds: kinds.value, areas: areas.value, search: search.value })

let seq = 0
async function load() {
  const mine = ++seq
  win = releaseWindow(range.value, Date.now())
  busy.value = true
  state.value = 'loading'
  try {
    const [d, c] = await Promise.all([
      releaseReportRead<ReleaseDaily>(api, '/v1/reporting/releases/daily' + releaseQuery(filter())),
      releaseReportRead<ReleaseCommits>(api, '/v1/reporting/releases/commits' + releaseQuery({ ...filter(), limit: RELEASE_PAGE })),
    ])
    if (mine !== seq) return
    daily.value = d
    days.value = win.days
    notes.value = Array.isArray(c?.notes) ? c.notes : []
    total.value = typeof c?.total === 'number' ? c.total : notes.value.length
    state.value = 'ok'
  } catch {
    if (mine === seq) state.value = 'error'
  } finally {
    if (mine === seq) busy.value = false
  }
}

async function more() {
  const mine = seq
  busy.value = true
  try {
    const c = await releaseReportRead<ReleaseCommits>(api, '/v1/reporting/releases/commits' + releaseQuery({ ...filter(), limit: RELEASE_PAGE, offset: notes.value.length }))
    if (mine !== seq) return
    notes.value = mergeCommitPages(notes.value, c?.notes)
    if (typeof c?.total === 'number') total.value = c.total
  } catch {
    if (mine === seq) state.value = 'error'
  } finally {
    if (mine === seq) busy.value = false
  }
}

onMounted(() => {
  watch([range, kinds, areas, search], () => { void load() }, { immediate: true })
})
onBeforeUnmount(() => { seq++ })
</script>

<style scoped>
.reporting-releases { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.rr-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.rr-more { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
</style>
