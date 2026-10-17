<!-- Spec 140 4.2 + 4.4.1 T033 (SPL-2322): token burn per agent lane. Agent,
     kind, box, model, the last minute and the 5-minute mean (tokens/min, the
     burn badge from the fresh rate), today's tokens and cost, the status
     (Active, Idle, Not metered) and the last active minute. Sorted by the
     5-minute rate, highest first; a column header re-sorts it as numbers
     (never as text), a null (agy) always last; filtered by kind. -->
<template>
  <section class="tk-section" data-test="tokens-agents">
    <div class="tk-agents-head">
      <h3>{{ t('monitoring.tokens.agents_title') }}</h3>
      <label class="tk-filter">
        <span>{{ t('monitoring.tokens.filter') }}</span>
        <select v-model="vendor" data-test="tokens-agent-filter">
          <option value="">{{ t('monitoring.tokens.filter_all') }}</option>
          <option v-for="v in kinds" :key="v" :value="v">{{ kindLabel(v) }}</option>
        </select>
      </label>
    </div>
    <p v-if="rows.length === 0" class="muted" data-test="tokens-agents-empty">{{ t('monitoring.tokens.empty') }}</p>
    <div v-else class="tk-table-wrap">
      <table class="tk-table">
        <thead>
          <tr>
            <th scope="col" :aria-sort="ariaSort('agentId')"><button type="button" class="tk-sort" data-test="tokens-sort-agentId" @click="sortBy('agentId')">{{ t('monitoring.tokens.col_agent') }}{{ arrow('agentId') }}</button></th>
            <th scope="col">{{ t('monitoring.tokens.col_vendor') }}</th>
            <th scope="col">{{ t('monitoring.tokens.col_box') }}</th>
            <th scope="col">{{ t('monitoring.tokens.col_model') }}</th>
            <th scope="col" class="num" :aria-sort="ariaSort('rate1m')"><button type="button" class="tk-sort" data-test="tokens-sort-rate1m" @click="sortBy('rate1m')">{{ t('monitoring.tokens.col_rate1m') }}{{ arrow('rate1m') }}</button></th>
            <th scope="col" class="num" :aria-sort="ariaSort('rate')"><button type="button" class="tk-sort" data-test="tokens-sort-rate" @click="sortBy('rate')">{{ t('monitoring.tokens.col_rate') }}{{ arrow('rate') }}</button></th>
            <th scope="col" class="num" :aria-sort="ariaSort('todayTokens')"><button type="button" class="tk-sort" data-test="tokens-sort-todayTokens" @click="sortBy('todayTokens')">{{ t('monitoring.tokens.col_today') }}{{ arrow('todayTokens') }}</button></th>
            <th scope="col" class="num" :aria-sort="ariaSort('todayCost')"><button type="button" class="tk-sort" data-test="tokens-sort-todayCost" @click="sortBy('todayCost')">{{ t('monitoring.tokens.col_cost') }}{{ arrow('todayCost') }}</button></th>
            <th scope="col">{{ t('monitoring.tokens.col_status') }}</th>
            <th scope="col" :aria-sort="ariaSort('lastActive')"><button type="button" class="tk-sort" data-test="tokens-sort-lastActive" @click="sortBy('lastActive')">{{ t('monitoring.tokens.col_last') }}{{ arrow('lastActive') }}</button></th>
          </tr>
        </thead>
        <tbody>
          <tr v-for="a in rows" :key="a.agentId + '@' + a.box" data-test="tokens-agent-row" :data-agent="a.agentId" :data-vendor="a.vendor" :data-status="status(a)">
            <th scope="row">{{ a.agentId }}</th>
            <td :data-label="t('monitoring.tokens.col_vendor')">{{ kindLabel(a.vendor) }}</td>
            <td :data-label="t('monitoring.tokens.col_box')">{{ a.box || '—' }}</td>
            <td class="tk-model" :data-label="t('monitoring.tokens.col_model')">{{ a.model || '—' }}</td>
            <td class="num" :data-label="t('monitoring.tokens.col_rate1m')">{{ a.metered ? tokens(a.rate1m) : '—' }}</td>
            <td class="num" :data-label="t('monitoring.tokens.col_rate')" data-test="tokens-agent-rate">
              {{ a.metered ? t('monitoring.tokens.per_min', { n: tokens(a.rate) }) : '—' }}
              <BurnBadge :level="burnLevel(a.fresh)" />
            </td>
            <td class="num" :data-label="t('monitoring.tokens.col_today')" data-test="tokens-agent-today">{{ a.metered ? tokens(a.todayTokens) : '—' }}</td>
            <td class="num" :data-label="t('monitoring.tokens.col_cost')" data-test="tokens-agent-cost">
              <span v-if="!a.metered">—</span>
              <span v-else-if="!a.priced && (a.todayTokens || 0) > 0" class="tk-unpriced" :title="t('monitoring.tokens.not_priced_title')" data-test="tokens-not-priced">{{ t('monitoring.tokens.not_priced') }}</span>
              <template v-else>{{ money(a.todayCost) }}</template>
            </td>
            <td :data-label="t('monitoring.tokens.col_status')">
              <span v-if="status(a) === 'not_metered'" class="tk-badge tk-badge--warn" :title="t('monitoring.tokens.not_metered_title')" data-test="tokens-not-metered">{{ t('monitoring.tokens.status_not_metered') }}</span>
              <span v-else class="tk-badge" :class="{ 'tk-badge--on': status(a) === 'active' }">{{ t(status(a) === 'active' ? 'monitoring.tokens.status_active' : 'monitoring.tokens.status_idle') }}</span>
            </td>
            <td :data-label="t('monitoring.tokens.col_last')"><time :datetime="a.lastActive">{{ clock(a.lastActive) }}</time></td>
          </tr>
        </tbody>
      </table>
    </div>
  </section>
</template>

<script setup lang="ts">
import { agentStatus, burnLevel, fmtMoney, fmtTokens, sortAgents, TOKENS_VENDORS } from '~/utils/monitoring-tokens.mjs'
import { isoDateTime } from '~/utils/date-iso.mjs'
import BurnBadge from './BurnBadge.vue'

type Agent = {
  agentId: string, vendor: string, model: string, box: string, rate1m: number | null, rate: number | null, fresh: number | null,
  todayTokens: number | null, todayCost: number | null, metered: boolean, priced: boolean, lastActive: string,
}
const props = defineProps<{ agents: Agent[], currency: string, asOf: string }>()
const { t, te, locale } = useI18n({ useScope: 'global' })
const vendor = ref('')
const key = ref('rate')
const dir = ref<'asc' | 'desc'>('desc')
/* the kinds the filter offers: the hub's, plus any new one a lane names */
const kinds = computed(() => [...new Set([...TOKENS_VENDORS, ...props.agents.map((a) => a.vendor)])])
const rows = computed(() => sortAgents(props.agents, { vendor: vendor.value, key: key.value, dir: dir.value }) as Agent[])

function sortBy(k: string) {
  if (key.value === k) dir.value = dir.value === 'desc' ? 'asc' : 'desc'
  else {
    key.value = k
    dir.value = k === 'agentId' ? 'asc' : 'desc'
  }
}
const arrow = (k: string) => (key.value === k ? (dir.value === 'desc' ? ' ↓' : ' ↑') : '')
const ariaSort = (k: string) => (key.value === k ? (dir.value === 'desc' ? 'descending' : 'ascending') : undefined)
const status = (a: Agent) => agentStatus(a, props.asOf)
const tokens = (n: number | null) => fmtTokens(n, locale.value)
const money = (n: number | null) => fmtMoney(n, props.currency, locale.value)
const kindLabel = (v: string) => {
  const k = 'agents.kinds.' + (v === 'agy' ? 'antigravity' : v)
  return te(k) ? t(k) : v
}
/* the last active minute in the reader's zone: the time alone today, the day too before */
function clock(iso: string) {
  const at = isoDateTime(iso)
  if (!at) return '—'
  return at.slice(0, 10) === isoDateTime(new Date()).slice(0, 10) ? at.slice(11) : at
}
</script>

<style scoped src="./token-burn.css"></style>
<style scoped>
.tk-agents-head { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 6px 12px; margin-bottom: 6px; }
.tk-agents-head h3 { margin: 0; }
.tk-filter { display: flex; align-items: center; gap: 8px; font-size: 0.875rem; }
</style>
