<!-- SPL-5546 (spec 123 16.5; owner HUM-10, csitea 720fa031: the labels "in
     the language of the interface", from a "language aware table" with "a
     master language"): one cost entry's label in other languages. The
     master language's label is the entry's own text, the item's key, shown
     and never edited here; every other language is a row the accountant
     adds, edits or removes, saved at once with PATCH .../{id}/labels.
     SPL-6203 (spec 123 16.6.4, row L6; owner answer 2 d: readers see the
     machine draft at once, marked unreviewed): each row says who wrote it,
     machine translated and not yet reviewed, reviewed, or corrected by hand,
     and a hand row made from an older master text is marked stale; the
     languages with no row yet are named as waiting, and a removed row is
     said to be made again by machine on the next fill. -->
<template>
  <details class="ce-labels" data-test="cost-labels" @toggle="onToggle">
    <summary data-test="cost-labels-toggle">{{ t('expenses.entries.labels_toggle', { n: rows.length }) }}</summary>
    <p class="muted" data-test="cost-labels-master">{{ t('expenses.entries.labels_master', { lang: langName(master), label: entry.label }) }}</p>
    <form class="ce-labels-form" novalidate @submit.prevent="save">
      <div v-for="(r, i) in rows" :key="i" class="ce-labels-row" data-test="cost-label-row">
        <select v-model="r.locale" :aria-label="t('expenses.entries.labels_locale')" :disabled="readonly" data-test="cost-label-locale">
          <option v-for="l in choices" :key="l.code" :value="l.code">{{ l.name }}</option>
        </select>
        <input v-model="r.text" type="text" maxlength="100" :aria-label="t('expenses.entries.labels_text')" :disabled="readonly" data-test="cost-label-text">
        <span v-if="costLabelMark(entry, r)" class="ce-labels-mark" :data-mark="costLabelMark(entry, r)" data-test="cost-label-mark">{{ t('expenses.entries.labels_mark_' + costLabelMark(entry, r)) }}</span>
        <span v-if="costLabelStale(entry, r)" class="ce-labels-stale" data-test="cost-label-stale">{{ t('expenses.entries.labels_stale') }}</span>
        <button v-if="!readonly" type="button" class="btn" data-test="cost-label-remove" @click="rows.splice(i, 1)">{{ t('expenses.entries.labels_remove') }}</button>
      </div>
      <p v-if="waiting.length" class="muted" data-test="cost-labels-waiting">{{ t('expenses.entries.labels_waiting', { langs: waiting.map(langName).join(', ') }) }}</p>
      <p v-if="removed.length" class="muted" role="status" data-test="cost-labels-removed">{{ t('expenses.entries.labels_removed', { langs: removed.map(langName).join(', ') }) }}</p>
      <div v-if="!readonly" class="ce-labels-actions">
        <button type="button" class="btn" :disabled="!free.length" data-test="cost-label-add" @click="add">{{ t('expenses.entries.labels_add') }}</button>
        <button type="submit" class="btn" :disabled="busy" data-test="cost-label-save">{{ t('expenses.entries.labels_save') }}</button>
        <span v-if="problem" class="ce-labels-err" role="alert" data-test="cost-label-error">{{ t('expenses.entries.' + problem) }}</span>
        <span v-else-if="refused" class="ce-labels-err" role="alert" data-test="cost-label-refused">{{ refused }}</span>
        <span v-else-if="saved" class="muted" role="status" data-test="cost-label-saved">{{ t('expenses.entries.labels_saved') }}</span>
      </div>
    </form>
  </details>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { checkCostLabelRows, costLabelMark, costLabelRows, costLabelsBody, costLabelsRemoved, costLabelStale, costLabelsWaiting } from '~/utils/cost-entries.mjs'

type Entry = { id: string, label: string, labels: Record<string, string>, labelOrigins?: Record<string, string>, staleLocales?: string[] }
type LabelsApi = { fleetPaid: (op: 'entry_labels', a: string, b: unknown) => Promise<unknown> }
const props = defineProps<{ entry: Entry, master: string, readonly?: boolean }>()
const emit = defineEmits<{ (e: 'saved'): void }>()
const { t, locales } = useI18n({ useScope: 'global' })
const all = computed(() => (locales.value as Array<{ code: string, name?: string }>).map((l) => ({ code: l.code, name: l.name || l.code })))
const langName = (code: string) => all.value.find((l) => l.code === code)?.name || code
const choices = computed(() => all.value.filter((l) => l.code !== props.master))
const rows = ref<Array<{ locale: string, text: string }>>([])
const free = computed(() => choices.value.filter((l) => !rows.value.some((r) => r.locale === l.code)))
const waiting = computed(() => costLabelsWaiting(props.entry, props.master, all.value.map((l) => l.code)))
const removed = computed(() => costLabelsRemoved(props.entry, rows.value, props.master))
const problem = ref('')
const refused = ref('')
const saved = ref(false)
const busy = ref(false)

function reset() {
  rows.value = costLabelRows(props.entry, props.master)
  problem.value = refused.value = ''
  saved.value = false
}
function onToggle(ev: Event) {
  if ((ev.target as HTMLDetailsElement).open) reset()
}
function add() {
  const next = free.value[0]
  if (next) rows.value.push({ locale: next.code, text: '' })
}
async function save() {
  refused.value = ''
  saved.value = false
  problem.value = checkCostLabelRows(rows.value, props.master, all.value.map((l) => l.code))
  if (problem.value) return
  busy.value = true
  try {
    await (useSpoolApi() as unknown as LabelsApi).fleetPaid('entry_labels', props.entry.id, costLabelsBody(rows.value))
    saved.value = true
    emit('saved')
  } catch (e) {
    const err = e as { detail?: string, token?: string, message?: string }
    refused.value = String(err?.detail || err?.token || err?.message || '')
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.ce-labels summary { cursor: pointer; font-size: 0.8125rem; }
.ce-labels-form { display: flex; flex-direction: column; gap: 6px; margin-top: 4px; }
.ce-labels-row, .ce-labels-actions { display: flex; flex-wrap: wrap; gap: 6px; align-items: center; }
.ce-labels-row input { flex: 1 1 12rem; min-width: 0; font: inherit; }
.ce-labels-row select { min-width: 0; max-width: 12rem; font: inherit; }
.ce-labels-err { color: var(--color-danger); }
.ce-labels-mark, .ce-labels-stale { font-size: 0.75rem; padding: 0 6px; border-radius: var(--radius-pill); border: 1px solid var(--color-border); }
.ce-labels-mark[data-mark='machine'], .ce-labels-stale { color: var(--color-warn); border-color: currentColor; }
.ce-labels-mark[data-mark='hand'], .ce-labels-mark[data-mark='reviewed'] { color: var(--color-ok); border-color: currentColor; }
</style>
