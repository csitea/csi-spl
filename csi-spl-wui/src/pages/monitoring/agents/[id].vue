<!-- CLE-77794 (owner 2026-09-30, topic 1fc29f99: "for the agents it should be
     clear are they antigravity, claude, grok etc."): an agent's card. Its kind
     (from the id prefix), the box it runs on, its liveness and the box's last
     hello, read from /v1/view/roster. A Message button opens the DM. The hub
     roster carries no model field, so no model line is shown.

     SPL-2075 (owner HUM-10, t1 dbf2f39b, msg fd5a2bf4): moved from
     /agents/<id@box> into Monitoring -> Agents, unchanged; the Monitoring
     page around it holds the header and Back, so the card names the agent
     in its own heading. The old path redirects here (pages/agents/[id].vue).

     SPL-3399 (owner HUM-10, t1 fb9b6e4b, msg f9e50fae: "in this view I
     should be able to click on the machine which will take me to this
     box"): the right pane of the Agents tab (pages/monitoring/agents.vue);
     its Box links to the Boxes tab at that box's card (#box-<id>).

     SPL-4206 (spec 153 3.9; owner HUM-10, t1 fb9b6e4b, msgs 78f2071b and
     470ae116): the card has tabs (utils/agent-card-tabs.mjs). Lanes, first
     and the default, lists the lanes this agent works on, read as the Lanes
     page reads them; each opens Monitoring -> Lanes with its row selected
     (?lane=<id@box>). The hub's lane row names no spawner, so a role seat
     lists only its own lane rows. Details holds the card above (?tab=details). -->
<template>
  <div class="monitoring-card" data-test="agent-page">
    <h3 class="agent-head">
      <UiIcon name="bot" :size="22" />
      <span>{{ agentId }}</span>
    </h3>
    <div class="agent-tabs" role="tablist" :aria-label="t('agents.tabs_label')" data-test="agent-tabs" @keydown="onTabKey">
      <button
        v-for="k in AGENT_CARD_TABS"
        :id="'agent-tab-' + k"
        :key="k"
        type="button"
        role="tab"
        class="agent-tabs__tab"
        :data-test="'agent-tab-' + k"
        :aria-selected="k === tab ? 'true' : 'false'"
        :aria-controls="'agent-panel-' + k"
        :tabindex="k === tab ? 0 : -1"
        @click="openTab(k)"
      >{{ t(TAB_KEYS[k]) }}</button>
    </div>
    <div v-if="tab === 'lanes'" id="agent-panel-lanes" role="tabpanel" aria-labelledby="agent-tab-lanes" class="agent-lanes" data-test="agent-lanes">
      <p v-if="lanesState === 'loading'" class="muted" data-test="agent-lanes-loading">{{ t('monitoring.lanes.loading') }}</p>
      <p v-else-if="lanesState === 'forbidden'" class="agent-lanes__error" data-test="agent-lanes-forbidden">{{ t('monitoring.lanes.forbidden') }}</p>
      <p v-else-if="lanesState === 'error'" class="agent-lanes__error" data-test="agent-lanes-error">{{ t('monitoring.lanes.error') }}</p>
      <p v-else-if="lanes.length === 0" class="muted" data-test="agent-lanes-empty">{{ t('agents.lanes_none') }}</p>
      <ul v-else class="agent-lanes__list">
        <li v-for="l in lanes" :key="laneName(l)" class="agent-lanes__row" data-test="agent-lane" :data-lane="laneName(l)">
          <NuxtLink class="agent-lanes__link" data-test="agent-lane-link" :to="localePath(laneDeepLink(l))"><code>{{ laneName(l) }}</code></NuxtLink>
          <span v-if="l.scope" class="agent-lanes__scope" :title="l.scope">{{ l.scope }}</span>
          <span v-if="l.topicTitle" class="muted agent-lanes__topic">{{ l.topicTitle }}</span>
          <span v-for="i in l.issues" :key="i.key" class="agent-lanes__issue">{{ i.key }}</span>
        </li>
      </ul>
    </div>
    <div v-else id="agent-panel-details" role="tabpanel" aria-labelledby="agent-tab-details">
      <div class="agent-card" data-test="agent-card">
        <div class="agent-card__hero">
          <span class="agent-card__glyph" aria-hidden="true"><UiIcon name="bot" :size="34" /></span>
          <div class="agent-card__heroText">
            <p class="agent-card__name">{{ agentId }}</p>
            <p class="agent-card__kind" data-test="agent-kind">{{ t(kindKey) }}</p>
            <p class="agent-card__status" data-test="agent-status">
              <span class="status-dot" :class="{ on: online, 'dot--idle': idle }" aria-hidden="true" />
              {{ online ? t('people.online') : idle ? t('people.not_running') : t('people.offline') }}
            </p>
          </div>
        </div>
        <dl class="agent-card__facts">
          <dt>{{ t('agents.kind') }}</dt>
          <dd>{{ t(kindKey) }}</dd>
          <dt>{{ t('agents.box') }}</dt>
          <dd data-test="agent-box"><NuxtLink v-if="box" class="agent-card__box" data-test="agent-box-link" :to="boxLink"><code>{{ box }}</code></NuxtLink></dd>
          <dt>{{ t('people.last_seen') }}</dt>
          <dd data-test="agent-last-seen">{{ lastHello }}</dd>
        </dl>
        <div class="agent-card__actions">
          <button type="button" class="btn" data-test="agent-message" @click="message">{{ t('people.message') }}</button>
        </div>
      </div>
    </div>
  </div>
</template>

<script setup lang="ts">
import { useRosterStore } from '~/stores/roster'
import { agentKindLabelKey } from '~/utils/agent-kind.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useOperatorPane } from '~/stores/operator-pane'
import { AGENT_CARD_TABS, agentCardTab, agentCardTabQuery } from '~/utils/agent-card-tabs.mjs'
import { agentLanes, fleetLanesOf, laneDeepLink, laneName, readLanes } from '~/utils/monitoring-lanes.mjs'

type LanesApi = { getFleetLanes: (own?: boolean) => Promise<unknown> }
type Lane = ReturnType<typeof fleetLanesOf>['lanes'][number]

const route = useRoute()
const roster = useRosterStore()
const localePath = useLocalePath()
const { t } = useI18n({ useScope: 'global' })

/* the route key is the agent's roster label id@box (a given CLI can run on more
   than one box, so the box is part of the identity). */
const label = computed(() => decodeURIComponent(String(route.params.id || '')))
const agentId = computed(() => label.value.split('@')[0] || label.value)
const box = computed(() => label.value.split('@')[1] || '')
const kindKey = computed(() => agentKindLabelKey(agentId.value))
const online = computed(() => roster.isOnline(agentId.value, box.value))
/* t1 bc1a43e1: its machine is online, the agent does not run */
const idle = computed(() => roster.isIdle(agentId.value, box.value))
const boxDetail = computed(() => roster.boxes[box.value] || { online: false, last_hello_at: '' })
/* the Boxes tab scrolls to and marks this box's card (pages/monitoring/boxes/index.vue) */
const boxLink = computed(() => localePath({ path: '/monitoring/boxes', hash: '#box-' + encodeURIComponent(box.value) }))
const lastHello = computed(() => (boxDetail.value.last_hello_at ? isoDateTime(boxDetail.value.last_hello_at) : t('people.never_seen')))

/* the open tab lives in ?tab= (none = Lanes), so a link opens the right one */
const TAB_KEYS: Record<string, string> = { lanes: 'agents.tab_lanes', details: 'agents.tab_details' }
const tab = computed(() => agentCardTab(route.query.tab))
function openTab(k: string) {
  if (k !== tab.value) void navigateTo({ path: route.path, query: agentCardTabQuery(route.query, k), hash: route.hash }, { replace: true })
}
/** Arrow keys move between the tabs (the WAI tabs pattern). */
function onTabKey(e: KeyboardEvent) {
  const step = e.key === 'ArrowRight' ? 1 : e.key === 'ArrowLeft' ? -1 : 0
  if (!step) return
  e.preventDefault()
  const n = AGENT_CARD_TABS.length
  const next = AGENT_CARD_TABS[(AGENT_CARD_TABS.indexOf(tab.value) + step + n) % n]!
  openTab(next)
  void nextTick(() => document.getElementById('agent-tab-' + next)?.focus())
}

/* the lanes, read once per card as the Lanes page reads them (fleet, else the workspace's own) */
const operator = useOperatorPane()
const allLanes = ref<Lane[]>([])
const lanesState = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const lanes = computed(() => agentLanes(allLanes.value, agentId.value, box.value))
const lanesRead = { own: false, operatorVisible: false }
async function loadLanes() {
  lanesRead.operatorVisible = operator.visible
  try {
    allLanes.value = fleetLanesOf(await readLanes(useSpoolApi() as unknown as LanesApi, lanesRead)).lanes
    lanesState.value = 'ok'
  } catch (e) {
    lanesState.value = (e as { status?: number })?.status === 403 ? 'forbidden' : 'error'
  }
}

onMounted(() => {
  if (!roster.boxes[box.value]) void roster.refresh()
  void loadLanes()
})

function message() {
  void navigateTo(localePath('/dm/' + encodeURIComponent(label.value)))
}
</script>

<style scoped>
.agent-head { display: flex; align-items: center; gap: 8px; min-width: 0; margin: 0; padding: 12px 16px 0; }
.agent-card { padding: 16px; max-width: 640px; display: flex; flex-direction: column; gap: 18px; min-width: 0; }
.agent-card__hero { display: flex; align-items: center; gap: 14px; min-width: 0; }
.agent-card__glyph {
  display: inline-flex; align-items: center; justify-content: center;
  width: 56px; height: 56px; border-radius: var(--radius-md); flex-shrink: 0;
  background: color-mix(in srgb, var(--color-accent) 14%, var(--color-surface));
  color: var(--color-accent);
}
.agent-card__heroText { min-width: 0; }
.agent-card__name { margin: 0; font-size: 1.1rem; font-weight: 700; overflow-wrap: anywhere; }
.agent-card__kind { margin: 2px 0 0; font-weight: 600; color: var(--color-accent); }
.agent-card__status { margin: 4px 0 0; display: flex; align-items: center; gap: 6px; color: var(--color-muted); font-size: 0.85rem; }
.status-dot { width: 8px; height: 8px; border-radius: 50%; background: var(--color-muted); flex-shrink: 0; }
.status-dot.on { background: var(--color-ok); }
.status-dot.dot--idle { background: transparent; box-shadow: inset 0 0 0 2px var(--color-muted); }
.agent-card__facts { display: grid; grid-template-columns: auto minmax(0, 1fr); gap: 6px 14px; margin: 0; }
.agent-card__facts dt { color: var(--color-muted); font-size: 0.8125rem; }
.agent-card__facts dd { margin: 0; overflow-wrap: anywhere; min-width: 0; }
.agent-card__actions { display: flex; gap: 8px; }
.agent-card__box { color: var(--color-accent); text-decoration: underline; text-underline-offset: 2px; }
.agent-tabs { display: flex; gap: 4px; padding: 8px 16px 0; border-bottom: 1px solid var(--color-border); overflow-x: auto; }
.agent-tabs__tab {
  padding: 6px 12px; border: 0; border-bottom: 3px solid transparent; background: transparent;
  color: var(--color-fg); font: inherit; cursor: pointer; white-space: nowrap;
}
.agent-tabs__tab:hover { background: var(--color-surface-hover); }
.agent-tabs__tab[aria-selected='true'] { border-bottom-color: var(--color-accent); font-weight: 600; }
.agent-lanes { padding: 16px; max-width: 640px; min-width: 0; }
.agent-lanes__error { color: var(--color-danger); }
.agent-lanes__list { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 8px; }
.agent-lanes__row { display: flex; flex-wrap: wrap; align-items: baseline; gap: 4px 10px; min-width: 0; padding: 8px 0; border-bottom: 1px solid var(--color-border); }
.agent-lanes__link { color: var(--color-accent); text-decoration: underline; text-underline-offset: 2px; font-weight: 600; }
.agent-lanes__scope, .agent-lanes__topic { min-width: 0; overflow-wrap: anywhere; }
.agent-lanes__issue { font-family: var(--font-mono); font-size: 0.8125rem; }
@media (max-width: 480px) {
  .agent-card__facts { grid-template-columns: minmax(0, 1fr); gap: 0; }
  .agent-card__facts dd + dt { margin-top: 8px; }
}
</style>
