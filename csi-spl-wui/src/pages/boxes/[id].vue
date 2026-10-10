<!-- CLE-77799 (owner 2026-09-30, topic 1fc29f99: "we should have a boxes section
     as well ... people use boxes and agents use boxes"): a box's card. Its id
     and machine tag, whether it is online, when it last checked in, and who is
     seated on it — BOTH the people (their browser / app sessions) AND the agents
     — each linked to their People / Agents card. Read from /v1/view/roster.
     Machines only (owner, t1 topic b3bf3d13): a link to the browser pseudo-box
     (/boxes/box-wui) is not a machine, so it goes back to the Boxes list.

     HUM-10 (t1 f77c9f87): "on the left most panel - the list of the boxes, on
     the second panel the list of the resources per box - agents, hardware, OS,
     RUN-TIMES ETC." and "on the right panel some statistics on those". The
     left pane is the sidebar's Boxes section; this page is the middle pane
     (the card plus its resources) and the right pane (BoxStatsPane, lazy). The
     selected resource is `?r=` (utils/box-resources.mjs). On a phone the two
     stack: a resource open is level 3, Back returns to the resources. -->
<template>
  <div class="feed-col" data-test="box-page" :data-resource="resource || undefined">
    <header class="feed-header">
      <MobileBack />
      <h2 class="box-head">
        <UiIcon name="server" :size="22" />
        <span>{{ heading }}</span>
      </h2>
    </header>
    <div class="feed-body box-panes" data-test="box-panes">
      <section class="box-card box-res" data-test="box-card" :aria-label="t('boxes.resources')">
        <div class="box-card__hero">
          <span class="box-card__glyph" aria-hidden="true"><UiIcon name="server" :size="34" /></span>
          <div class="box-card__heroText">
            <p class="box-card__name">{{ box.tag }}</p>
            <p class="box-card__kind" data-test="box-kind">{{ box.browser ? t('boxes.browser') : t('boxes.machine') }}</p>
            <p class="box-card__status" data-test="box-status">
              <span class="status-dot" :class="{ on: box.online }" aria-hidden="true" />
              {{ box.online ? t('people.online') : t('people.offline') }}
            </p>
          </div>
        </div>
        <dl class="box-card__facts">
          <dt>{{ t('boxes.id') }}</dt>
          <dd data-test="box-id"><code>{{ boxId }}</code></dd>
          <dt>{{ t('people.last_seen') }}</dt>
          <dd data-test="box-last-hello">{{ lastHello }}</dd>
          <!-- HUM-10 (t1 58857a17): people and agents are counted apart,
               each count a link to its own list below -->
          <dt>{{ t('boxes.seated') }}</dt>
          <dd class="box-card__seated" data-test="box-seated">
            <NuxtLink
              class="box-card__count"
              data-test="box-people-count"
              :data-count="box.people.length"
              :to="{ path: route.path, hash: '#' + SEATS_PEOPLE }"
              @click="showSeats(SEATS_PEOPLE)"
            >{{ t('boxes.people_n', box.people.length) }}</NuxtLink>
            <span class="muted" aria-hidden="true">·</span>
            <NuxtLink
              class="box-card__count"
              data-test="box-agents-count"
              :data-count="box.agents.length"
              :to="{ path: route.path, hash: '#' + SEATS_AGENTS }"
              @click="showSeats(SEATS_AGENTS)"
            >{{ t('boxes.agents_n', box.agents.length) }}</NuxtLink>
          </dd>
        </dl>

        <!-- NOW (owner ba10751d): the latest box-stats sample, a 5-minute
             tick - apart from the daily facts under Resources -->
        <section class="box-now" data-test="box-now" :aria-label="t('boxes.now_title')">
          <h3>{{ t('boxes.now_title') }}</h3>
          <template v-if="now">
            <p class="muted box-res__age" data-test="box-now-age" :title="isoDateTime(now.at)">{{ t('boxes.now_age', { age: ageOf(now.at) }) }}</p>
            <dl class="box-card__facts">
              <dt>{{ t('boxes.now_load') }}</dt>
              <dd data-test="box-now-load">{{ t('boxes.now_load_val', { load: formatLoad(now.load1), cpus: now.cpus }) }}</dd>
              <dt>{{ t('boxes.now_mem') }}</dt>
              <dd data-test="box-now-mem">{{ t('boxes.now_mem_val', { used: formatKB(now.memUsedKB), avail: formatKB(now.memAvailKB) }) }}</dd>
              <dt>{{ t('boxes.swap') }}</dt>
              <dd>{{ formatKB(now.swapUsedKB) }}</dd>
              <dt>{{ t('boxes.disk') }}</dt>
              <dd data-test="box-now-disk" :title="diskTitle(nowDisks, t)">{{ diskLine(lowestDisk(nowDisks), t) || '—' }}</dd>
              <dt>{{ t('boxes.now_agents') }}</dt>
              <dd data-test="box-now-agents">{{ now.agentsLive }}</dd>
            </dl>
          </template>
          <p v-else-if="stats.state === 'loading'" class="muted" data-test="box-now-loading">{{ t('app.loading') }}</p>
          <p v-else-if="stats.state === 'forbidden'" class="muted" data-test="box-now-forbidden">{{ t('boxes.stats_forbidden') }}</p>
          <p v-else-if="stats.state === 'failed'" class="muted" role="alert" data-test="box-now-failed">{{ t('boxes.stats_failed') }}</p>
          <p v-else class="muted" data-test="box-now-none">{{ t('boxes.now_none') }}</p>
        </section>

        <!-- HUM-10 (t1 05e0fa03): this box's own load band, admins of the
             operator workspace only (lazy; hidden for everyone else) -->
        <BoxLoadBand v-if="!box.browser" :box="boxId" :sample="latest" />

        <!-- the box's resources: each row opens its statistics on the right -->
        <nav class="box-res__list" :aria-label="t('boxes.resources')" data-test="box-resources">
          <h3>{{ t('boxes.resources') }}</h3>
          <p class="muted box-res__age" data-test="box-facts-age" :title="factsAt ? isoDateTime(factsAt) : undefined">{{ factsAge }}</p>
          <NuxtLink
            v-for="r in rows"
            :key="r.id"
            class="box-res__row"
            :class="{ 'is-active': resource === r.id }"
            :data-test="'box-resource-' + r.id"
            :aria-current="resource === r.id ? 'true' : undefined"
            :to="{ path: route.path, query: { r: r.id } }"
          >
            <UiIcon :name="r.icon" :size="20" />
            <span class="box-res__label">{{ t(r.label) }}</span>
            <span class="muted box-res__sum" :data-test="'box-resource-sum-' + r.id">{{ r.summary }}</span>
          </NuxtLink>
        </nav>

        <!-- the agents seated on this box -->
        <section :id="SEATS_AGENTS" class="box-card__seats" :class="{ 'is-target': seatsTarget === SEATS_AGENTS }" data-test="box-agents-list">
          <h3 tabindex="-1">{{ t('sidebar.agents') }} <span class="muted box-card__n">{{ box.agents.length }}</span></h3>
          <p v-if="box.agents.length === 0" class="muted" data-test="box-no-agents">{{ t('boxes.no_agents') }}</p>
          <NuxtLink
            v-for="a in box.agents"
            :key="a.label"
            class="box-seat"
            data-test="box-agent"
            :data-key="a.label"
            :to="localePath('/agents/' + encodeURIComponent(a.label))"
          >
            <UiIcon name="bot" :size="20" />
            <span class="status-dot" :class="{ on: a.online }" aria-hidden="true" />
            <span class="box-seat__label">{{ a.id }}</span>
            <span class="muted box-seat__kind">{{ t(agentKindLabelKey(a.id)) }}</span>
          </NuxtLink>
        </section>

        <!-- the people seated on this box (their WUI / app sessions) -->
        <section :id="SEATS_PEOPLE" class="box-card__seats" :class="{ 'is-target': seatsTarget === SEATS_PEOPLE }" data-test="box-people-list">
          <h3 tabindex="-1">{{ t('sidebar.people') }} <span class="muted box-card__n">{{ box.people.length }}</span></h3>
          <p v-if="box.people.length === 0" class="muted" data-test="box-no-people">{{ t('boxes.no_people') }}</p>
          <NuxtLink
            v-for="p in box.people"
            :key="p.label"
            class="box-seat"
            data-test="box-person"
            :data-key="p.id"
            :to="localePath('/people/' + encodeURIComponent(p.id))"
          >
            <SpoolAvatar :id="p.id" :box="p.box" :size="22" />
            <span class="status-dot" :class="{ on: p.online }" aria-hidden="true" />
            <HumanName class="box-seat__label" :id="p.id" :box="p.box" />
          </NuxtLink>
        </section>
      </section>

      <aside class="box-stats" data-test="box-stats" :aria-label="t('boxes.stats')">
        <BoxStatsPane
          v-if="resource"
          :resource="resource"
          :box="box"
          :detail="detail"
          :stats="stats"
        />
        <p v-else class="muted box-stats__pick" data-test="box-stats-pick">{{ t('boxes.stats_pick') }}</p>
      </aside>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { agentKindLabelKey } from '~/utils/agent-kind.mjs'
import { boxByID, isBrowserBox } from '~/utils/box-rows.mjs'
import { SEATS_AGENTS, SEATS_PEOPLE, seatsAnchorOf } from '~/utils/box-seats.mjs'
import {
  ageOf, agentCounts, agentStatRows, boxDisksOf, boxNetworkOf, boxOsOf, boxResourceOf, boxRuntimesOf, boxStatsOf, boxSystemOf,
  currentOf, diskLine, diskTitle, factsReportedAt, formatKB, formatLoad, formatMB, isBoxStatsForbidden, isNoBoxStats,
  latestBoxStat, lowestDisk, osLine,
} from '~/utils/box-resources.mjs'
import type { BoxStat, BoxStatHour } from '~/utils/box-resources.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useMobileStack } from '~/composables/useMobileStack'
import { useTopicStore } from '~/stores/topic'
import { useLiveFeed } from '~/stores/live'
import type { UiIconName } from '~/utils/uiIcons'

/* the right pane is its own chunk: fetched on the first resource opened */
const BoxStatsPane = defineAsyncComponent(() => import('@/components/BoxStatsPane.vue'))
/* the load band (t1 05e0fa03) is its own chunk too: most viewers never see it */
const BoxLoadBand = defineAsyncComponent(() => import('@/components/BoxLoadBand.vue'))

const route = useRoute()
const router = useRouter()
const roster = useRosterStore()
const localePath = useLocalePath()
const stack = useMobileStack()
const { t } = useI18n({ useScope: 'global' })

const boxId = computed(() => decodeURIComponent(String(route.params.id || '')))
const box = computed(() => boxByID(boxId.value, roster.people, roster.boxes))
const detail = computed(() => roster.boxes[boxId.value] || null)
const lastHello = computed(() => (box.value.lastHello ? isoDateTime(box.value.lastHello) : t('people.never_seen')))
const resource = computed(() => boxResourceOf(route.query.r))

/* GET /v1/tenant/box-stats for this box: the Hardware row's CPUs / memory and
   the right pane's history. 404 / 501 (a hub without box stats) = no history. */
type BoxStatsState = { state: 'loading' | 'ready' | 'empty' | 'forbidden' | 'failed', rows: BoxStat[], hours: BoxStatHour[] }
const stats = ref<BoxStatsState>({ state: 'loading', rows: [], hours: [] })
let seq = 0
async function loadStats(quiet = false) {
  const mine = ++seq
  const id = boxId.value
  /* a quiet refresh keeps what is shown until the new read lands */
  if (!quiet) stats.value = { state: 'loading', rows: [], hours: [] }
  if (!id || isBrowserBox(id)) { stats.value = { state: 'empty', rows: [], hours: [] }; return }
  try {
    const { rows, hours } = boxStatsOf(await useSpoolApi().boxStats({ box: id, since: '24h' }) as { rows?: unknown[], hours?: unknown[] } | null)
    if (mine !== seq) return
    stats.value = { state: rows.length || hours.length ? 'ready' : 'empty', rows, hours }
  } catch (e) {
    if (mine !== seq) return
    stats.value = { state: isNoBoxStats(e) ? 'empty' : isBoxStatsForbidden(e) ? 'forbidden' : 'failed', rows: [], hours: [] }
  }
}

const latest = computed(() => latestBoxStat(stats.value.rows, boxId.value))
const now = computed(() => currentOf(latest.value))
/* the Now Disk line (owner f5389813): the mount nearest full, every mount on hover */
const nowDisks = computed(() => boxDisksOf(latest.value))
const notReported = computed(() => t('boxes.not_reported'))
const factsAt = computed(() => factsReportedAt(detail.value))
/* the facts are a daily snapshot: say how old it is */
const factsAge = computed(() => (factsAt.value ? t('boxes.facts_age', { age: ageOf(factsAt.value) }) : t('boxes.facts_never')))
const rows = computed(() => [
  { id: 'agents', icon: 'bot' as UiIconName, label: 'boxes.res_agents', summary: agentsSummary() },
  { id: 'hardware', icon: 'server' as UiIconName, label: 'boxes.res_hardware', summary: hardwareLine() || notReported.value },
  { id: 'system', icon: 'history' as UiIconName, label: 'boxes.res_system', summary: systemLine() || notReported.value },
  { id: 'os', icon: 'settings' as UiIconName, label: 'boxes.res_os', summary: osLine(boxOsOf(detail.value)) || notReported.value },
  { id: 'runtimes', icon: 'list' as UiIconName, label: 'boxes.res_runtimes', summary: boxRuntimesOf(detail.value).map((r) => r.name).join(', ') || notReported.value },
  { id: 'network', icon: 'waves' as UiIconName, label: 'boxes.res_network', summary: (boxNetworkOf(detail.value)?.ips || []).join(', ') || notReported.value },
])
function agentsSummary() {
  const c = agentCounts(agentStatRows(box.value.agents, detail.value))
  return t('boxes.agents_sum', { total: c.total, online: c.online })
}
/* CPUs and memory: the daily snapshot first, else the latest box-stats sample */
function hardwareLine() {
  const sys = boxSystemOf(detail.value)
  if (sys && sys.cpus !== null && sys.memTotalMB !== null) return t('boxes.hardware_sum', { cpus: sys.cpus, mem: formatMB(sys.memTotalMB) })
  const hw = latest.value
  return hw ? t('boxes.hardware_sum', { cpus: hw.cpus, mem: formatKB(hw.mem_total_kb) }) : ''
}
function systemLine() {
  const sys = boxSystemOf(detail.value)
  return sys ? [sys.hostname, sys.state].filter(Boolean).join(' · ') : ''
}

/* on a phone the open resource names the page; otherwise the box tag */
const heading = computed(() => {
  const r = stack.isMobile.value && rows.value.find((x) => x.id === resource.value)
  return r ? `${box.value.tag} · ${t(r.label)}` : box.value.tag
})

/* a people / agents count (here or on the rail row) opens its list: the
   `#box-people` / `#box-agents` hash scrolls it into view and marks it. The
   feed body is the scroller, not the window, so the page does it itself;
   a click on the count already in the hash scrolls back to its list too. */
const seatsTarget = computed(() => seatsAnchorOf(route.hash))
function showSeats(id = seatsTarget.value) {
  if (!id) return
  void nextTick(() => {
    const el = document.getElementById(id)
    if (!el) return
    el.scrollIntoView({ block: 'start' })
    el.querySelector<HTMLElement>('h3')?.focus({ preventScroll: true })
  })
}
onMounted(() => showSeats())
watch(() => route.hash, () => { if (import.meta.client) showSeats() })
/* the first stats read grows "Now" above the lists: scroll to it again */
watch(() => stats.value.state, (state, was) => { if (was === 'loading' && state !== 'loading') showSeats() })

/* machines only: the browser box has no card, its old link lands on the list */
if (isBrowserBox(boxId.value)) void navigateTo(localePath('/boxes'), { replace: true })

/* the roster is already loaded for the DM list; refresh once so a deep link
   straight to this card (no sidebar visited yet) still has the seats. */
onMounted(() => { if (!roster.boxes[boxId.value] && box.value.userCount === 0) void roster.refresh() })
onMounted(() => { void loadStats() })
/* "Now" follows the box's 5-minute sample tick while the page is open */
let statsTimer: ReturnType<typeof setInterval> | null = null
onMounted(() => { statsTimer = setInterval(() => { if (document.visibilityState === 'visible') void loadStats(true) }, 5 * 60 * 1000) })
onUnmounted(() => { if (statsTimer) clearInterval(statsTimer) })
watch(boxId, () => { if (import.meta.client) void loadStats() })

/* three panes: no topic panel sits beside the box's two (as on /help) */
const topic = useTopicStore()
const livePane = useLiveFeed('pane')
function closeTopicPanel() {
  if (livePane.taskId) livePane.close()
  if (topic.open) topic.close()
}
watch(() => [livePane.taskId, topic.open], closeTopicPanel)
onMounted(closeTopicPanel)

/* a resource open on a phone is level 3; Back drops `?r=` (the
   tenant-settings pattern: replace once the popstate navigation finished) */
stack.rightPanel(
  () => stack.isMobile.value && boxResourceOf(router.currentRoute.value.query.r) !== '',
  () => {
    let done = false
    const go = () => {
      if (done) return
      done = true
      off()
      void navigateTo({ path: router.currentRoute.value.path, query: {} }, { replace: true })
    }
    const off = router.afterEach(() => { setTimeout(go, 0) })
    setTimeout(go, 250)
  },
)
</script>

<style scoped>
.box-head { display: flex; align-items: center; gap: 8px; min-width: 0; }
.box-head span { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
/* the middle (resources) and right (statistics) panes, side by side */
.box-panes {
  display: grid;
  grid-template-columns: minmax(260px, 380px) minmax(0, 1fr);
  align-items: start;
  min-width: 0;
}
.box-card { padding: 16px; display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.box-res { border-inline-end: 1px solid var(--color-border); min-height: 100%; }
.box-stats { min-width: 0; padding: 16px; }
.box-stats__pick { margin: 0; }
.box-card__hero { display: flex; align-items: center; gap: 14px; min-width: 0; }
.box-card__glyph {
  display: inline-flex; align-items: center; justify-content: center;
  width: 56px; height: 56px; border-radius: var(--radius-md); flex-shrink: 0;
  background: color-mix(in srgb, var(--color-accent) 14%, var(--color-surface));
  color: var(--color-accent);
}
.box-card__heroText { min-width: 0; }
.box-card__name { margin: 0; font-size: 1.1rem; font-weight: 700; overflow-wrap: anywhere; }
.box-card__kind { margin: 2px 0 0; font-weight: 600; color: var(--color-accent); }
.box-card__status { margin: 4px 0 0; display: flex; align-items: center; gap: 6px; color: var(--color-muted); font-size: 0.85rem; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--color-muted); flex-shrink: 0; }
.status-dot.on { background: var(--color-ok); }
.box-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.box-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.box-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.box-res__list h3, .box-card__seats h3 { margin: 0 0 6px; font-size: 0.9rem; display: flex; align-items: center; gap: 6px; }
.box-res__list { display: flex; flex-direction: column; gap: 2px; }
.box-res__row {
  display: flex; align-items: center; gap: 10px; min-width: 0;
  padding: 8px; border-radius: var(--radius-sm); color: inherit; text-decoration: none;
}
.box-res__row:hover { background: var(--color-surface-hover); }
.box-res__row.is-active {
  background: color-mix(in srgb, var(--color-accent) 14%, var(--color-surface));
  color: var(--color-fg);
}
.box-res__label { font-weight: 600; flex-shrink: 0; }
.box-res__age { margin: -4px 0 4px; font-size: 0.78rem; }
.box-now h3 { margin: 0 0 6px; font-size: 0.9rem; }
.box-now p { margin: 0; }
.box-res__sum { margin-inline-start: auto; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-size: 0.8rem; }
.box-card__n { font-weight: 400; font-size: 0.8rem; }
.box-card__seated { display: flex; flex-wrap: wrap; align-items: baseline; gap: 6px; }
.box-card__count { color: var(--color-accent); text-decoration: underline; text-underline-offset: 2px; }
.box-card__seats { scroll-margin-top: 8px; border-radius: var(--radius-sm); }
.box-card__seats.is-target { outline: 2px solid var(--focus-ring); outline-offset: 4px; }
/* an opened list can scroll to the top even when it is the last one */
.box-res:has(.box-card__seats.is-target) { padding-bottom: 60vh; }
.box-card__seats h3:focus { outline: none; }
.box-seat {
  display: flex; align-items: center; gap: 8px; min-width: 0;
  padding: 5px 6px; border-radius: var(--radius-sm); color: inherit; text-decoration: none;
}
.box-seat:hover { background: var(--color-surface-hover); }
.box-seat :deep(.spool-avatar) { border-radius: 50%; flex-shrink: 0; }
.box-seat__label { min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.box-seat__kind { margin-inline-start: auto; font-size: 0.75rem; flex-shrink: 0; }
/* a phone: ONE pane - the resources, or (a resource open) its statistics */
@media (max-width: 820px) {
  .box-panes { grid-template-columns: minmax(0, 1fr); }
  .box-res { border-inline-end: 0; }
  [data-resource] .box-res { display: none; }
  .feed-col:not([data-resource]) .box-stats { display: none; }
}
@media (max-width: 480px) {
  .box-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .box-card__facts dd + dt { margin-top: 8px; }
}
</style>
