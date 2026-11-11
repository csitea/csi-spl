<!-- Settings -> Cost allocation (SPL-5291, spec 143 costs-allocation.md;
     owner HUM-10, t1 41a74806, poll 0c5e94b4 C, poll 01cbbdea 1B 2B 3B): an
     estate Persons or Cloud item assigned to one workspace or split across
     several by percentage. The operator workspace's admin sets any split
     (GET|PUT /v1/operator/cost-allocations); a customer admin moves the share
     their workspaces hold between them (/v1/tenant/cost-allocations). A split
     holds for every month; the month picks only the amounts shown. Save is
     disabled until the rows sum to 100 % (the operator) or to what the
     admin's workspaces hold. Tokens are never split by hand (1B). Loaded with
     its route only (utils/cost-allocations.mjs). -->
<template>
  <div data-test="cost-alloc-root" :data-state="state" :data-door="view ? view.door : ''">
    <p v-if="state === 'loading'" class="muted">{{ t('common.loading') }}</p>
    <p v-else-if="state === 'none'" class="muted" data-test="cost-alloc-none">{{ t('tenant_settings.cost_alloc_nothing') }}</p>
    <p v-else-if="state === 'error'" class="ca-error" role="alert" data-test="cost-alloc-error">
      {{ t('tenant_settings.cost_alloc_error') }}
      <button type="button" class="btn" @click="reload()">{{ t('tenant_settings.cost_alloc_retry') }}</button>
    </p>
    <SettingsSection
      v-else-if="view"
      id="tenant-cost-alloc"
      :title="t('tenant_settings.cost_alloc_title')"
      data-test="tenant-settings-cost-alloc"
    >
      <p class="muted ca-hint">{{ view.door === 'tenant' ? t('tenant_settings.cost_alloc_hint_tenant') : t('tenant_settings.cost_alloc_hint') }}</p>
      <label class="ca-month">
        <span>{{ t('tenant_settings.cost_alloc_month') }}</span>
        <input v-model="month" type="month" data-test="cost-alloc-month" @change="reload()">
      </label>
      <section v-for="label in LABELS" :key="label" class="ca-label" :data-test="'cost-alloc-' + label">
        <h4>{{ t('tenant_settings.cost_alloc_' + label) }}</h4>
        <p v-if="!itemsOf(label).length" class="muted" data-test="cost-alloc-empty">{{ t('tenant_settings.cost_alloc_empty') }}</p>
        <ul v-else class="ca-items">
          <li v-for="it in itemsOf(label)" :key="keyOf(it)" class="ca-item" data-test="cost-alloc-item" :data-item="it.projectOrVendor + ' / ' + it.kind">
            <div class="ca-row">
              <span class="ca-name">{{ nameOf(it) }}</span>
              <span class="ca-amount" data-test="cost-alloc-amount">{{ amountOf(it) }}</span>
            </div>
            <div class="ca-row">
              <span class="ca-split" :class="{ muted: !it.shares.length }" data-test="cost-alloc-split">{{ splitOf(it) }}</span>
              <button v-if="editing !== keyOf(it)" type="button" class="btn ghost" :disabled="busy" data-test="cost-alloc-edit" @click="edit(it)">
                {{ t('tenant_settings.cost_alloc_edit') }}
              </button>
            </div>
            <form v-if="editing === keyOf(it)" class="ca-form" data-test="cost-alloc-form" novalidate @submit.prevent="save(it)">
              <p v-if="view.door === 'tenant'" class="muted ca-note" data-test="cost-alloc-held">{{ t('tenant_settings.cost_alloc_held', { pct: bpToPct(it.targetBp) }) }}</p>
              <p v-else class="muted ca-note">{{ t('tenant_settings.cost_alloc_remove_hint') }}</p>
              <div v-for="r in rows" :key="r.workspaceId" class="ca-share">
                <label :for="'ca-' + r.workspaceId">{{ r.name }}</label>
                <span class="ca-pct">
                  <input
                    :id="'ca-' + r.workspaceId"
                    v-model="r.pct"
                    type="text"
                    inputmode="decimal"
                    autocomplete="off"
                    placeholder="0"
                    :data-test="'cost-alloc-pct-' + r.workspaceId"
                  >
                  <span aria-hidden="true">%</span>
                </span>
              </div>
              <p class="ca-sum" :class="{ 'ca-sum--bad': !!check.err }" role="status" data-test="cost-alloc-sum">
                {{ t('tenant_settings.cost_alloc_sum', { sum: check.sumBp === null ? '—' : bpToPct(check.sumBp), target: bpToPct(it.targetBp) }) }}
              </p>
              <p v-if="check.err" class="ca-error" data-test="cost-alloc-form-error">{{ t('tenant_settings.' + check.err, { target: bpToPct(it.targetBp) }) }}</p>
              <p v-if="refused" class="ca-error" role="alert" data-test="cost-alloc-refused">{{ t('tenant_settings.cost_alloc_refused', { why: refused }) }}</p>
              <div class="ca-actions">
                <button type="submit" class="btn primary" :disabled="busy || !!check.err" data-test="cost-alloc-save">{{ t('tenant_settings.cost_alloc_save') }}</button>
                <button type="button" class="btn" :disabled="busy" data-test="cost-alloc-cancel" @click="editing = ''">{{ t('tenant_settings.cost_alloc_cancel') }}</button>
              </div>
            </form>
          </li>
        </ul>
      </section>
    </SettingsSection>
  </div>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { fleetLoadReadable } from '~/utils/fleet-load.mjs'
import { fmtMoney } from '~/utils/monitoring-tokens.mjs'
import {
  bpToPct, checkCostAllocRows, costAllocBody, costAllocItemsOf, costAllocKey, costAllocRows, costAllocSplitText,
  costAllocViewOf, probeCostAllocDoor,
} from '~/utils/cost-allocations.mjs'

/* the shapes of utils/cost-allocations.mjs costAllocViewOf and costAllocRows */
type Share = { workspaceId: string, bp: number, usdMicros: number | null, eurMicros: number | null }
type Item = {
  source: string, projectOrVendor: string, kind: string, origin: string, label: 'persons' | 'cloud',
  usdMicros: number | null, eurMicros: number | null, unpriced: boolean, shares: Share[], targetBp: number
}
type View = { month: string, door: 'operator' | 'tenant', items: Item[], workspaces: { id: string, name: string }[] }
type Row = { workspaceId: string, name: string, pct: string }
/* the lazy client's one paid method (spool-client-lazy.mjs fleetPaid): no new stub in the initial chunk */
type AllocApi = { fleetPaid: (op: 'alloc' | 'alloc_put', door: string, a?: unknown) => Promise<unknown> }

const LABELS = ['persons', 'cloud'] as const
const { t, locale } = useI18n({ useScope: 'global' })
const api = () => useSpoolApi() as unknown as AllocApi
const access = useAccessStore()
const state = ref<'loading' | 'ready' | 'none' | 'error'>('loading')
const view = ref<View | null>(null)
const month = ref(new Date().toISOString().slice(0, 7))
const editing = ref('')
const rows = ref<Row[]>([])
const refused = ref('')
const busy = ref(false)

const keyOf = (it: Item) => costAllocKey(it)
const itemsOf = (label: string) => costAllocItemsOf(view.value, label) as Item[]
/* an hr or cloud entry is named by its label; a GCP part by project and service */
const nameOf = (it: Item) => (it.source === 'cost_entry' ? it.projectOrVendor : it.projectOrVendor + ' · ' + it.kind)
function amountOf(it: Item) {
  if (view.value?.door === 'tenant') {
    const usd = it.shares.reduce((n, s) => n + (s.usdMicros || 0), 0)
    return fmtMoney(usd / 1e6, 'USD', locale.value)
  }
  return it.usdMicros === null || it.unpriced ? t('tenant_settings.cost_alloc_unpriced') : fmtMoney(it.usdMicros / 1e6, 'USD', locale.value)
}
const splitOf = (it: Item) => costAllocSplitText(it.shares, view.value?.workspaces || []) || t('tenant_settings.cost_alloc_not_split')
const check = computed(() => {
  const it = view.value?.items.find((x) => keyOf(x) === editing.value)
  return checkCostAllocRows(rows.value, it ? it.targetBp : undefined) as { sumBp: number | null, err: string }
})

/* the hub's own words when it refuses: its detail, else its token */
const hubWhy = (e: unknown) => {
  const err = e as { detail?: string, token?: string, message?: string }
  return String((err && (err.detail || err.token || err.message)) || '')
}

const list = (door: string, m: string) => api().fleetPaid('alloc', door, m)

async function reload() {
  try {
    if (!view.value) {
      const found = await probeCostAllocDoor(list, { operator: fleetLoadReadable(access.me) }, month.value)
      if (!found) {
        state.value = 'none'
        return
      }
      view.value = costAllocViewOf(found.body, found.door) as View
    } else {
      view.value = costAllocViewOf(await list(view.value.door, month.value), view.value.door) as View
    }
    state.value = 'ready'
  } catch {
    state.value = 'error'
  }
}

function edit(it: Item) {
  refused.value = ''
  rows.value = costAllocRows(it, view.value?.workspaces || []) as Row[]
  editing.value = keyOf(it)
}

async function save(it: Item) {
  if (check.value.err || !view.value) return
  busy.value = true
  refused.value = ''
  try {
    await api().fleetPaid('alloc_put', view.value.door, costAllocBody(it, rows.value))
    editing.value = ''
    await reload()
  } catch (e) {
    refused.value = hubWhy(e)
  } finally {
    busy.value = false
  }
}

onMounted(async () => {
  await access.load().catch(() => undefined)
  await reload()
})
</script>

<style scoped>
.ca-hint { margin: 0 0 10px; font-size: 0.8125rem; }
.ca-month { display: flex; flex-wrap: wrap; align-items: center; gap: 8px; margin-bottom: 12px; font-size: 0.875rem; }
.ca-label h4 { margin: 12px 0 6px; font-size: 0.875rem; }
.ca-items { list-style: none; margin: 0; padding: 0; display: flex; flex-direction: column; gap: 6px; }
.ca-item { border: 1px solid var(--color-border); border-radius: var(--radius-sm, 8px); padding: 8px 10px; min-width: 0; }
.ca-row { display: flex; flex-wrap: wrap; align-items: center; justify-content: space-between; gap: 4px 12px; min-width: 0; }
.ca-name { font-weight: 600; overflow-wrap: anywhere; min-width: 0; }
.ca-amount { font-variant-numeric: tabular-nums; white-space: nowrap; }
.ca-split { font-size: 0.8125rem; overflow-wrap: anywhere; min-width: 0; }
.ca-form { display: flex; flex-direction: column; gap: 6px; margin-top: 8px; padding-top: 8px; border-top: 1px solid var(--color-border); }
.ca-note { margin: 0; font-size: 0.8125rem; }
.ca-share { display: flex; align-items: center; justify-content: space-between; gap: 8px; min-width: 0; }
.ca-share label { overflow-wrap: anywhere; min-width: 0; }
.ca-pct { display: inline-flex; align-items: center; gap: 4px; flex: none; }
.ca-pct input { width: 5.5rem; text-align: end; font: inherit; box-sizing: border-box; }
.ca-sum { margin: 0; font-size: 0.875rem; font-variant-numeric: tabular-nums; }
.ca-sum--bad { color: var(--color-danger); }
.ca-error { margin: 0; color: var(--color-danger); overflow-wrap: anywhere; display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.ca-actions { display: flex; flex-wrap: wrap; gap: 8px; }
@media (max-width: 820px) {
  .ca-pct input { font-size: max(16px, 1rem); }
}
</style>
