<!-- SPL-5433 (spec 123 16.2; owner poll a82c0089 answer 2 B): the lock state
     of one month of hr lines: open until the 6th of the next month, then
     closed. The operator admin (admin = true) reopens it with a reason and
     closes it again; everyone else reads the state. -->
<template>
  <div class="hr-period" data-test="hr-period" :data-closed="state?.closed ? '1' : '0'">
    <span v-if="!state" class="muted">{{ month }}</span>
    <span v-else-if="state.closed" class="hr-closed" data-test="hr-period-closed">{{ t('expenses.hr.month_closed', { month }) }}</span>
    <span v-else data-test="hr-period-open">{{ t('expenses.hr.month_open', { month, day: closeDay }) }}</span>
    <span v-if="state && state.reopenReason && !state.closed" class="muted" data-test="hr-period-reason">{{ t('expenses.hr.reopened', { why: state.reopenReason }) }}</span>
    <template v-if="admin && state">
      <button v-if="!state.closed" type="button" class="btn" :disabled="busy" data-test="hr-period-close" @click="set('close')">{{ t('expenses.hr.close') }}</button>
      <template v-else>
        <input v-model="reason" type="text" maxlength="500" :placeholder="t('expenses.hr.reopen_reason')" :aria-label="t('expenses.hr.reopen_reason')" data-test="hr-period-reason-input">
        <button type="button" class="btn" :disabled="busy || !reason.trim()" data-test="hr-period-reopen" @click="set('reopen')">{{ t('expenses.hr.reopen') }}</button>
      </template>
    </template>
    <span v-if="refused" class="hr-closed" role="alert" data-test="hr-period-refused">{{ refused }}</span>
  </div>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { hrCloseDay, hrPeriodOf } from '~/utils/hr-costs.mjs'

type PeriodApi = { fleetPaid: (op: 'hr_period' | 'hr_period_set', a?: unknown, b?: unknown) => Promise<unknown> }
const props = defineProps<{ month: string, admin?: boolean }>()
const emit = defineEmits<{ (e: 'changed', closed: boolean): void }>()
const { t } = useI18n({ useScope: 'global' })
const api = () => useSpoolApi() as unknown as PeriodApi
const state = ref<ReturnType<typeof hrPeriodOf>>(null)
const reason = ref('')
const busy = ref(false)
const refused = ref('')
const closeDay = computed(() => hrCloseDay(props.month))

/* the old state stays drawn while the next month loads, and a read emits
   nothing: a bar that shrinks and grows, or a list reloaded under it, moved
   the row a phone was pressing (e2e SPL-4382 hr Delete at 390px) */
async function load() {
  if (!/^\d{4}-\d{2}$/.test(props.month)) { state.value = null; return }
  try {
    state.value = hrPeriodOf(await api().fleetPaid('hr_period', props.month))
  } catch { /* the hub's answer on a write is the control */ }
}
async function set(op: 'close' | 'reopen') {
  busy.value = true
  refused.value = ''
  try {
    state.value = hrPeriodOf(await api().fleetPaid('hr_period_set', props.month, { op, reason: reason.value.trim() }))
    reason.value = ''
    emit('changed', !!state.value?.closed)
  } catch (e) {
    const err = e as { detail?: string, token?: string, message?: string }
    refused.value = String(err?.detail || err?.token || err?.message || '')
  } finally {
    busy.value = false
  }
}
watch(() => props.month, () => { void load() }, { immediate: true })
</script>

<style scoped>
.hr-period { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; font-size: 0.875rem; }
.hr-closed { color: var(--color-danger); font-weight: 600; }
.hr-period input { min-width: 10rem; max-width: 20rem; font: inherit; }
</style>
