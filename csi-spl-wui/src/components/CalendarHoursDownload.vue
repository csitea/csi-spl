<!-- Spec 107 v1.2 T015 (sections 5.4, 6.2; owner R11): the hours panel's
     Download tab, for a holder of hours.read. The period holding a picked
     day (default the shown day), CSV or XLSX, Final only on by default
     (GET /v1/hours/export, T009); the file keeps the hub's name. Its own
     lazy chunk. -->
<template>
  <form class="hours-dl" data-test="hours-download" @submit.prevent="go">
    <label class="hours-dl__field">
      <span>{{ t('hours_cal.dl_period') }}</span>
      <input v-model="day" type="date" required data-test="hours-dl-day">
    </label>
    <fieldset class="hours-dl__field hours-dl__formats">
      <legend>{{ t('hours_cal.dl_format') }}</legend>
      <label v-for="f in FORMATS" :key="f" class="hours-dl__choice">
        <input v-model="format" type="radio" name="hours-dl-format" :value="f" :data-test="'hours-dl-format-' + f">
        <span>{{ f.toUpperCase() }}</span>
      </label>
    </fieldset>
    <label class="hours-dl__choice">
      <input v-model="final" type="checkbox" data-test="hours-dl-final">
      <span>{{ t('hours_cal.dl_final') }}</span>
    </label>
    <button type="submit" class="btn" data-test="hours-dl-go" :disabled="busy || !day">{{ t('hours_cal.dl_go') }}</button>
    <p v-if="done" class="muted" data-test="hours-dl-done" :data-name="done.name" :data-type="done.type" :data-bytes="done.bytes" :data-lines="done.lines">{{ t('hours_cal.dl_done', { name: done.name }) }}</p>
    <p v-if="error" class="hours-dl__error" role="alert" data-test="hours-dl-error">{{ t('hours_cal.dl_failed') }}</p>
  </form>
</template>

<script setup lang="ts">
import { downloadTeamHours } from '~/utils/hours-team-api.mjs'
import { useSpoolApi } from '~/composables/useSpoolApi'

const FORMATS = ['csv', 'xlsx'] as const
const props = defineProps<{ focus: string, today: string }>()
const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()

const day = ref(props.focus)
const format = ref<'csv' | 'xlsx'>('csv')
const final = ref(true)
const busy = ref(false)
const error = ref(false)
const done = ref<{ name: string, type: string, bytes: number, lines: number } | null>(null)

async function go() {
  if (busy.value || !day.value) return
  busy.value = true
  error.value = false
  done.value = null
  try {
    const { blob, name } = await downloadTeamHours(api, day.value, format.value, final.value, props.today)
    const url = URL.createObjectURL(blob)
    const a = document.createElement('a')
    a.href = url
    a.download = name
    document.body.appendChild(a)
    a.click()
    a.remove()
    setTimeout(() => URL.revokeObjectURL(url), 1000)
    /* the line count is the CSV's (header included); an XLSX reads 0 */
    const lines = format.value === 'csv' ? (await blob.text()).split('\n').filter((l) => l.trim()).length : 0
    done.value = { name, type: blob.type, bytes: blob.size, lines }
  } catch {
    error.value = true
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.hours-dl { display: flex; flex-direction: column; gap: 10px; min-inline-size: 0; }
.hours-dl__field { display: flex; flex-direction: column; gap: 4px; margin: 0; padding: 0; border: 0; min-inline-size: 0; }
.hours-dl__field input[type=date] { min-block-size: 44px; font-size: 0.875rem; }
.hours-dl__formats { flex-direction: row; flex-wrap: wrap; gap: 12px; }
.hours-dl__formats legend { margin-block-end: 4px; }
.hours-dl__choice { display: inline-flex; align-items: center; gap: 6px; min-block-size: 44px; cursor: pointer; }
.hours-dl .btn { min-block-size: 44px; }
.hours-dl__error { margin: 0; color: var(--color-danger); }
</style>
