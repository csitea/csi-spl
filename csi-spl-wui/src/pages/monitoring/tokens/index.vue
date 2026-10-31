<!-- Spec 140 4 T030-T034 (SPL-2322, owner HUM-10, t1 e8ae0aad): Monitoring ->
     Tokens, the fleet's live token burn from GET /v1/operator/fleet-tokens.
     The KPI strip, the burn per agent type and per agent lane, a window pick.
     For admins of the operator workspace only: the tab shows to them alone
     (utils/monitoring-tabs.mjs) and anyone else reaching the URL sees the
     hub's 403 as a sentence, never a table.
     Refresh (4.3): every 30 s while this tab is open AND the browser tab is
     visible (a hidden tab makes no call; it catches up when shown), plus a
     Refresh button. The age of the last answer: amber after 45 s, the red
     "Data stale" badge after 90 s (a failed poll keeps the last rows).
     SPL-2567: under the tables, the Paid card (the operator's paid items and
     the effective price per token), read once, never polled. -->
<template>
  <div class="monitoring-tokens" data-test="tokens-page">
    <div class="tk-head">
      <label class="tk-window">
        <span>{{ t('monitoring.tokens.window') }}</span>
        <select v-model="win" data-test="tokens-window">
          <option v-for="w in TOKENS_WINDOWS" :key="w" :value="w">{{ t('monitoring.tokens.window_' + w) }}</option>
        </select>
      </label>
      <button type="button" class="btn tk-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="tokens-refresh" @click="load()">
        <span v-if="busy" class="tk-spin" aria-hidden="true" />{{ t('monitoring.tokens.refresh') }}
      </button>
      <span v-if="view" class="tk-age" :data-stale="stale" data-test="tokens-age">
        <span v-if="stale === 'amber'" class="tk-dot" aria-hidden="true" data-test="tokens-stale-amber" />
        {{ t('monitoring.tokens.updated', { n: lag }) }}
      </span>
      <span v-if="view && stale === 'red'" class="tk-stale" role="status" data-test="tokens-stale-red">{{ t('monitoring.tokens.stale_red') }}</span>
    </div>

    <p v-if="state === 'loading' && !view" class="muted" data-test="tokens-loading">{{ t('monitoring.tokens.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="tk-error" data-test="tokens-forbidden">{{ t('monitoring.tokens.forbidden') }}</p>
    <p v-else-if="state === 'error' && !view" class="tk-error" data-test="tokens-error">
      {{ t('monitoring.tokens.error') }}
      <button type="button" class="btn" data-test="tokens-retry" @click="load()">{{ t('monitoring.tokens.retry') }}</button>
    </p>

    <template v-if="view && state !== 'forbidden'">
      <MonitoringTokensSummary :summary="view.summary" :currency="view.currency" />
      <VendorBurnTable :vendors="view.vendors" :currency="view.currency" />
      <AgentBurnTable :agents="view.agents" :currency="view.currency" :as-of="view.asOf" />
      <!-- SPL-2567: the paid items and the effective price, its own chunk; the wrapper keeps the async component off a bare v-if -->
      <div class="tk-lazy"><PaidItemsCard /></div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { countedRead, gateMe, operatorReadable } from '~/utils/read-gates.mjs'
import { fleetTokensOf, lagSeconds, staleLevel, tokensShouldPoll, TOKENS_DEFAULT_WINDOW, TOKENS_POLL_MS, TOKENS_WINDOWS } from '~/utils/monitoring-tokens.mjs'
import MonitoringTokensSummary from '~/components/monitoring/token-burn/MonitoringTokensSummary.vue'
import VendorBurnTable from '~/components/monitoring/token-burn/VendorBurnTable.vue'
import AgentBurnTable from '~/components/monitoring/token-burn/AgentBurnTable.vue'

/* SPL-2567: the Paid card is its own chunk, fetched once the burn has loaded */
const PaidItemsCard = defineAsyncComponent(() => import('~/components/monitoring/token-burn/PaidItemsCard.vue'))

type TokensApi = { getFleetTokens: (window?: string) => Promise<unknown> }
type TokensView = ReturnType<typeof fleetTokensOf>

const { t } = useI18n({ useScope: 'global' })
const win = ref(TOKENS_DEFAULT_WINDOW)
const view = ref<TokensView | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const busy = ref(false)
/* when the last answer arrived (ms), and a clock that ticks the age while visible */
const fetchedAt = ref(0)
const now = ref(Date.now())
const lag = computed(() => (fetchedAt.value ? lagSeconds(fetchedAt.value, now.value) : 0))
const stale = computed(() => staleLevel(lag.value))

const access = useAccessStore()
let seq = 0
async function load() {
  const mine = ++seq
  busy.value = true
  try {
    /* SPL-4453: only a reader /v1/view/me may name the operator admin sends the read */
    const readable = operatorReadable(await gateMe(access))
    if (mine !== seq) return
    if (!readable) {
      view.value = null
      state.value = 'forbidden'
      return
    }
    const api = useSpoolApi() as unknown as TokensApi & { mock?: boolean }
    const body = await countedRead(api, '/v1/operator/fleet-tokens', () => api.getFleetTokens(win.value))
    if (mine !== seq) return
    view.value = fleetTokensOf(body)
    fetchedAt.value = Date.now()
    now.value = fetchedAt.value
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    const err = e as { status?: number }
    if (err && err.status === 403) {
      view.value = null
      state.value = 'forbidden'
    } else state.value = 'error'
  } finally {
    if (mine === seq) busy.value = false
  }
}

let poll: ReturnType<typeof setInterval> | null = null
let clock: ReturnType<typeof setInterval> | null = null
const visible = () => tokensShouldPoll(document.visibilityState)
function onVisibility() {
  if (!visible()) return
  now.value = Date.now()
  /* shown again after a hidden spell: catch up at once if a poll was missed */
  if (state.value !== 'forbidden' && (!fetchedAt.value || now.value - fetchedAt.value >= TOKENS_POLL_MS)) void load()
}

onMounted(() => {
  watch(win, () => { void load() }, { immediate: true })
  poll = setInterval(() => {
    if (visible() && state.value !== 'forbidden') void load()
  }, TOKENS_POLL_MS)
  clock = setInterval(() => {
    if (visible()) now.value = Date.now()
  }, 1000)
  document.addEventListener('visibilitychange', onVisibility)
})
onBeforeUnmount(() => {
  if (poll) clearInterval(poll)
  if (clock) clearInterval(clock)
  document.removeEventListener('visibilitychange', onVisibility)
  seq++
})
</script>

<style scoped>
.monitoring-tokens { display: flex; flex-direction: column; gap: 14px; min-width: 0; }
.tk-head { display: flex; flex-wrap: wrap; align-items: center; gap: 8px 16px; }
.tk-window { display: flex; align-items: center; gap: 8px; }
.tk-refresh { display: inline-flex; align-items: center; gap: 6px; }
.tk-spin { width: 0.75rem; height: 0.75rem; border: 2px solid var(--color-border); border-top-color: var(--color-fg); border-radius: 50%; animation: tk-spin 0.8s linear infinite; }
@keyframes tk-spin { to { transform: rotate(360deg); } }
@media (prefers-reduced-motion: reduce) { .tk-spin { animation: none; } }
.tk-age { display: inline-flex; align-items: center; gap: 6px; color: var(--color-muted); font-size: 0.875rem; }
.tk-age[data-stale="amber"] { color: var(--color-warn); }
.tk-dot { width: 0.5rem; height: 0.5rem; border-radius: 50%; background: var(--color-warn); }
.tk-stale { padding: 0 8px; border-radius: var(--radius-pill); background: var(--color-danger); color: var(--color-danger-fg); font-size: 0.8125rem; font-weight: 600; }
.tk-lazy { display: contents; }
.tk-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
</style>
