<!-- Spec 143 2.2 (SPL-2787), tasks T022-T024: Reporting -> Releases, the
     delivery report over the release notes. The KPI strip, the filter bar,
     then the days newest first with their commits. Two reads per filter
     change: GET /v1/reporting/releases/daily (the day headers and the KPIs)
     and the first page of GET /v1/reporting/releases/commits; "Load more"
     reads the next page. The label cloud's counts are the daily answer's
     with no kind or area picked; while one is picked they stay those of the
     range and search, read once more without the picks only when the range
     or the search changed (spec 143 2.2.1). A read that loses the race to a newer filter is
     dropped. Its own chunk: Nuxt loads this page only on /reporting/releases.
     B-7 (spec 143 releases-projects.md section 7, SPL-5853): the projects
     are read once; the project and repo picks live in the URL
     (?project=&repo=, router.push, so Back undoes a pick), a stale one falls
     back to the default with router.replace, and the label cloud's cache key
     holds project and repo too, so a switch never shows the last project's
     counts. A workspace with no project shows the empty state, no filter bar. -->
<template>
  <div class="reporting-releases" data-test="reporting-releases">
    <ReportingReleasesSummary :summary="summary" />
    <ReleasesFilterBar
      v-if="state !== 'unconfigured'"
      v-model:range="range" v-model:kinds="kinds" v-model:areas="areas" v-model:search="search"
      :kind-counts="cloud?.kinds" :area-counts="cloud?.areas"
      :projects="projects?.projects" :project="project?.slug" :repo="pick.repo" :repo-counts="repoCounts"
      @update:project="pickProject" @update:repo="pickRepo"
    />

    <p v-if="state === 'unconfigured'" class="muted" data-test="releases-unconfigured">{{ t('reporting.releases.unconfigured') }}</p>
    <p v-else-if="state === 'loading' && !daily" class="muted" data-test="releases-loading">{{ t('reporting.releases.loading') }}</p>
    <p v-else-if="state === 'error'" class="rr-error" data-test="releases-error">
      {{ t('reporting.releases.error') }}
      <button type="button" class="btn" data-test="releases-retry" @click="load()">{{ t('reporting.releases.retry') }}</button>
    </p>
    <p v-else-if="daily && !groups.length" class="muted" data-test="releases-empty">{{ t('reporting.releases.empty') }}</p>

    <ReleasesDailyList v-if="groups.length && state !== 'unconfigured'" :groups="groups" :show-repo="multiRepo" />

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
  labelCounts, mergeCommitPages, RELEASE_PAGE, RELEASE_RANGE_DEFAULT, releaseDayGroups, releasePickOf, releasePickQuery, releaseProjectOf,
  releaseProjectsRead, releaseQuery, releaseReportRead, releaseSummary, releaseWindow,
  type ReleaseCommit, type ReleaseCommits, type ReleaseDaily, type ReleasePick, type ReleaseProjects,
} from '~/utils/reporting-releases'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi() as unknown as Parameters<typeof releaseReportRead>[0]
const route = useRoute()
const router = useRouter()

const range = ref<string>(RELEASE_RANGE_DEFAULT)
const kinds = ref<string[]>([])
const areas = ref<string[]>([])
const search = ref('')

const daily = ref<ReleaseDaily | null>(null)
const notes = ref<ReleaseCommit[]>([])
const total = ref(0)
const days = ref(7)
const state = ref<'loading' | 'ok' | 'error' | 'unconfigured'>('loading')
const busy = ref(false)
/* the label cloud's counts and the project + repo + range + search they were read for */
const cloud = ref<{ kinds: Record<string, number>, areas: Record<string, number> } | null>(null)
let cloudKey = ''
/* the repo pills' counts: every repo of the project, read without the repo pick */
const repoCounts = ref<Record<string, number> | null>(null)
let repoKey = ''

/* the workspace's projects, read once; null when the read failed (the URL is then taken as it is) */
const projects = ref<ReleaseProjects | null>(null)
const pick = ref<ReleasePick>({ project: '', repo: '' })
const project = computed(() => releaseProjectOf(projects.value, pick.value.project))
const multiRepo = computed(() => (project.value?.repos.length || 0) > 1)

const summary = computed(() => (daily.value ? releaseSummary(daily.value, days.value) : null))
const groups = computed(() => releaseDayGroups(daily.value?.days, notes.value))

/* the window is fixed per load, so "Load more" pages the same commits */
let win = releaseWindow(RELEASE_RANGE_DEFAULT, Date.now())
const filter = () => ({
  from: win.from, to: win.to, kinds: kinds.value, areas: areas.value, search: search.value, project: pick.value.project, repo: pick.value.repo,
})

/* a pick goes into the URL (router.push), the route watch below loads it */
function go(next: ReleasePick, replace = false) {
  const to = { query: releasePickQuery(route.query, next) as Record<string, string> }
  void (replace ? router.replace(to) : router.push(to))
}
function pickProject(slug: string) {
  areas.value = []
  go({ project: slug === projects.value?.default ? '' : slug, repo: '' })
}
const pickRepo = (repo: string) => go({ project: pick.value.project, repo })

/* the URL's pick, checked against the list; a stale one is replaced by the default */
function syncPick() {
  const { pick: next, stale } = releasePickOf(route.query, projects.value)
  if (next.project !== pick.value.project) areas.value = []
  if (next.project !== pick.value.project || next.repo !== pick.value.repo) pick.value = next
  if (stale) go(next, true)
}

/* the extra reads of one load: the cloud without the kind and area picks, the repo pills without the repo pick */
function sideReads(cKey: string, rKey: string) {
  const daily = (q: object) => releaseReportRead<ReleaseDaily>(api, '/v1/reporting/releases/daily' + releaseQuery({ ...filter(), ...q })).catch(() => null)
  const picked = kinds.value.length > 0 || areas.value.length > 0
  return Promise.all([
    picked && cKey !== cloudKey ? daily({ kinds: [], areas: [] }) : Promise.resolve(null),
    multiRepo.value && pick.value.repo && rKey !== repoKey ? daily({ repo: '' }) : Promise.resolve(null),
  ])
}

let seq = 0
async function load() {
  const mine = ++seq
  win = releaseWindow(range.value, Date.now())
  busy.value = true
  state.value = 'loading'
  try {
    const base = [pick.value.project, range.value, search.value.trim()].join('|')
    const key = base + '|' + pick.value.repo
    const rKey = [base, kinds.value.join(','), areas.value.join(',')].join('|')
    const picked = kinds.value.length > 0 || areas.value.length > 0
    const [d, c, [all, everyRepo]] = await Promise.all([
      releaseReportRead<ReleaseDaily>(api, '/v1/reporting/releases/daily' + releaseQuery(filter())),
      releaseReportRead<ReleaseCommits>(api, '/v1/reporting/releases/commits' + releaseQuery({ ...filter(), limit: RELEASE_PAGE })),
      sideReads(key, rKey),
    ])
    if (mine !== seq) return
    if (d?.configured === false) {
      state.value = 'unconfigured'
      return
    }
    const counted = picked ? all : d
    if (counted) {
      cloud.value = { kinds: labelCounts(counted.days, 'kinds'), areas: labelCounts(counted.days, 'areas') }
      cloudKey = key
    }
    const perRepo = pick.value.repo ? everyRepo : d
    if (perRepo) {
      repoCounts.value = labelCounts(perRepo.days, 'repos')
      repoKey = rKey
    }
    daily.value = d
    days.value = win.days
    notes.value = Array.isArray(c?.notes) ? c.notes : []
    total.value = typeof c?.total === 'number' ? c.total : notes.value.length
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    /* a stale pick the list did not catch (404 unknown_project / unknown_repo): back to the default, no error */
    if ((e as { status?: number })?.status === 404 && (pick.value.project || pick.value.repo)) go({ project: '', repo: '' }, true)
    else state.value = 'error'
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

onMounted(async () => {
  const mine = seq
  projects.value = await releaseProjectsRead(api).catch(() => null)
  if (mine !== seq) return
  if (projects.value && !projects.value.configured) {
    state.value = 'unconfigured'
    return
  }
  syncPick()
  watch(() => [route.query.project, route.query.repo], syncPick)
  watch([range, kinds, areas, search, pick], () => { void load() }, { immediate: true })
})
onBeforeUnmount(() => { seq++ })
</script>

<style scoped>
.reporting-releases { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.rr-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.rr-more { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 12px; }
</style>
