<!-- Spec 181 row B13 (gap G14; Q-17 B, Q-18 C): Monitoring -> Invoices, the
     owner's overdue list from GET /v1/operator/invoices/overdue. A private
     workspace's monthly invoice is paid by bank transfer, due 14 days net
     (Q-19 A); one unpaid past its due date is listed here, oldest due date
     first, and the owner decides each case by hand: the page decides
     nothing, the workspace keeps working. When the transfer arrives, Mark
     paid (POST /v1/operator/invoices/{id}/{month}/paid, after a confirm)
     marks it paid; the hub writes the audit row and the row leaves the list.
     For admins of the operator workspace only: the tab shows to them alone
     (utils/monitoring-tabs.mjs) and anyone else reaching the URL sees the
     hub's 403 as a sentence, never a table. No timer: a Refresh button. -->
<template>
  <div class="monitoring-invoices" data-test="invoices-page">
    <ClientOnly>
      <Teleport to="#monitoring-head-actions" defer>
        <button type="button" class="btn iv-refresh" :aria-busy="busy ? 'true' : 'false'" :disabled="busy" data-test="invoices-refresh" @click="load()">
          <UiIcon name="refresh" class="mh-icon" /><span class="mh-label">{{ t('monitoring.tokens.refresh') }}</span>
        </button>
      </Teleport>
    </ClientOnly>

    <p class="muted iv-hint">{{ t('monitoring.invoices.hint') }}</p>
    <p v-if="notice" class="iv-notice" role="status" data-test="invoices-notice">{{ notice }}</p>

    <p v-if="state === 'loading' && !view" class="muted" data-test="invoices-loading">{{ t('monitoring.invoices.loading') }}</p>
    <p v-else-if="state === 'forbidden'" class="iv-error" data-test="invoices-forbidden">{{ t('monitoring.invoices.forbidden') }}</p>
    <p v-else-if="state === 'error' && !view" class="iv-error" data-test="invoices-error">
      {{ t('monitoring.invoices.error') }}
      <button type="button" class="btn" data-test="invoices-retry" @click="load()">{{ t('monitoring.tokens.retry') }}</button>
    </p>

    <template v-if="view && state !== 'forbidden'">
      <p v-if="view.invoices.length === 0" class="muted" data-test="invoices-empty">{{ t('monitoring.invoices.empty') }}</p>
      <div v-else class="iv-table-wrap">
        <table class="iv-table" :aria-label="t('monitoring.invoices.table_label')" data-test="invoices-table">
          <thead>
            <tr>
              <th scope="col">{{ t('monitoring.invoices.col_workspace') }}</th>
              <th scope="col">{{ t('monitoring.invoices.col_month') }}</th>
              <th scope="col" class="num">{{ t('monitoring.invoices.col_total') }}</th>
              <th scope="col">{{ t('monitoring.invoices.col_due') }}</th>
              <th scope="col" class="num">{{ t('monitoring.invoices.col_overdue') }}</th>
              <th scope="col">{{ t('monitoring.invoices.col_reminded') }}</th>
              <th scope="col"><span class="iv-sr">{{ t('monitoring.invoices.col_action') }}</span></th>
            </tr>
          </thead>
          <tbody>
            <tr v-for="inv in view.invoices" :key="inv.workspace + '/' + inv.month" data-test="invoices-row" :data-workspace="inv.workspace" :data-month="inv.month">
              <th scope="row" data-test="invoices-workspace">
                {{ inv.workspaceName || inv.workspace }}
                <span v-if="inv.workspaceName" class="iv-id">{{ inv.workspace }}</span>
              </th>
              <td :data-label="t('monitoring.invoices.col_month')">{{ inv.month }}</td>
              <td class="num" :data-label="t('monitoring.invoices.col_total')" data-test="invoices-total">{{ money(inv) }}</td>
              <td :data-label="t('monitoring.invoices.col_due')">{{ inv.dueOn || DASH }}</td>
              <td class="num" :data-label="t('monitoring.invoices.col_overdue')" data-test="invoices-days">{{ inv.daysOverdue }}</td>
              <td :data-label="t('monitoring.invoices.col_reminded')">{{ inv.remindedAt ? inv.remindedAt.slice(0, 10) : t('monitoring.invoices.not_reminded') }}</td>
              <td>
                <button type="button" class="btn" :disabled="marking !== ''" :aria-busy="marking === inv.workspace + '/' + inv.month ? 'true' : 'false'" data-test="invoices-mark-paid" @click="markPaid(inv)">
                  {{ t('monitoring.invoices.mark_paid') }}
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </template>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useAccessStore } from '~/stores/access'
import { gateMe, operatorReadable } from '~/utils/read-gates.mjs'
/* types only: the module itself loads in load(), so its chunk is the page's own dependency and not one
   more name in the entry chunk's route table (ci_initial_gzip_kb, perf-budgets.json) */
import type { invoiceMoney, overdueInvoicesOf } from '~/utils/monitoring-invoices.mjs'

/* the lazy client's one paid method (spool-client-lazy.mjs fleetPaid): no new stub in the initial chunk */
type InvoicesApi = {
  fleetPaid: (op: 'invoices_overdue' | 'invoice_paid', workspace?: string, month?: string) => Promise<unknown>
}
type InvoicesView = ReturnType<typeof overdueInvoicesOf>
type Row = InvoicesView['invoices'][number]

const DASH = '—'
const { t, locale } = useI18n({ useScope: 'global' })
const view = ref<InvoicesView | null>(null)
const state = ref<'loading' | 'ok' | 'forbidden' | 'error'>('loading')
const busy = ref(false)
const marking = ref('')
const notice = ref('')
const api = () => useSpoolApi() as unknown as InvoicesApi
const mi = shallowRef<{ invoiceMoney: typeof invoiceMoney, overdueInvoicesOf: typeof overdueInvoicesOf } | null>(null)
const money = (inv: Row) => mi.value?.invoiceMoney(inv.totalMicros, inv.currency, locale.value) || DASH

const access = useAccessStore()
let seq = 0
async function load() {
  const mine = ++seq
  busy.value = true
  try {
    if (!operatorReadable(await gateMe(access))) {
      if (mine !== seq) return
      view.value = null
      state.value = 'forbidden'
      return
    }
    const [body, m] = await Promise.all([api().fleetPaid('invoices_overdue'), mi.value || import('~/utils/monitoring-invoices.mjs')])
    if (mine !== seq) return
    mi.value = m
    view.value = m.overdueInvoicesOf(body)
    state.value = 'ok'
  } catch (e) {
    if (mine !== seq) return
    if ((e as { status?: number })?.status === 403) {
      view.value = null
      state.value = 'forbidden'
    } else state.value = 'error'
  } finally {
    if (mine === seq) busy.value = false
  }
}

async function markPaid(inv: Row) {
  const name = inv.workspaceName || inv.workspace
  if (!confirm(t('monitoring.invoices.confirm', { workspace: name, month: inv.month, total: money(inv) }))) return
  marking.value = inv.workspace + '/' + inv.month
  notice.value = ''
  try {
    await api().fleetPaid('invoice_paid', inv.workspace, inv.month)
    notice.value = t('monitoring.invoices.marked', { workspace: name, month: inv.month })
  } catch (e) {
    const token = (e as { token?: string })?.token
    notice.value = token === 'already_paid' ? t('monitoring.invoices.already_paid') : t('monitoring.invoices.mark_failed')
  } finally {
    marking.value = ''
  }
  await load()
}

onMounted(() => { void load() })
onBeforeUnmount(() => { seq++ })
</script>

<style scoped>
.monitoring-invoices { display: flex; flex-direction: column; gap: 12px; min-width: 0; }
.iv-hint { margin: 0; }
.iv-notice { margin: 0; font-weight: 600; }
.iv-refresh { display: inline-flex; align-items: center; gap: 6px; }
.iv-error { color: var(--color-danger); display: flex; flex-wrap: wrap; align-items: center; gap: 8px; }
.iv-table-wrap { overflow-x: auto; max-width: 100%; }
.iv-table { border-collapse: collapse; width: 100%; font-size: 0.875rem; }
.iv-table th, .iv-table td { padding: 6px 8px; border-bottom: 1px solid var(--color-border); text-align: start; vertical-align: top; }
.iv-table tbody th { font-weight: 600; }
.iv-table .num { text-align: end; white-space: nowrap; font-variant-numeric: tabular-nums; }
.iv-id { display: block; font-weight: 400; color: var(--color-muted); font-family: var(--font-mono); font-size: 0.75rem; }
.iv-sr { position: absolute; width: 1px; height: 1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; }
@media (max-width: 600px) {
  .iv-table thead { display: none; }
  .iv-table tr { display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 2px 12px; padding: 6px 0; border-bottom: 1px solid var(--color-border); }
  .iv-table th, .iv-table td { border-bottom: 0; padding: 0 4px; }
  .iv-table tr > :first-child { grid-column: 1 / -1; }
  .iv-table .num { text-align: start; white-space: normal; }
  .iv-table td[data-label]::before { content: attr(data-label) ": "; color: var(--color-muted); }
}
</style>
