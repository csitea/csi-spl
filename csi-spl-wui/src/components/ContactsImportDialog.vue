<!-- Spec 154 B17 (11.2): import contacts from a CSV file. The dry run gives the
     preview, Import writes. Loaded on the first opening from the People panel,
     so the first paint never carries it (C47). A skipped row shows its line and
     reason only, never a value (C12). -->
<template>
  <UiDialog :open="open" :title="t('contacts.import.title')" size="sm" @update:open="emit('update:open', $event)">
    <div class="contacts-import" data-test="contacts-import">
      <p class="muted">{{ t('contacts.import.hint') }}</p>
      <input
        v-if="!done"
        type="file"
        accept=".csv,text/csv"
        data-test="contacts-import-file"
        :aria-label="t('contacts.import.hint')"
        :disabled="busy"
        @change="onPick"
      >
      <p v-if="busy" class="muted" role="status" data-test="contacts-import-busy">{{ t('common.loading') }}</p>
      <p v-if="error" class="invite-error" role="alert" data-test="contacts-import-error">{{ error }}</p>

      <template v-if="answer">
        <dl class="contacts-import__counts" data-test="contacts-import-counts">
          <template v-for="row in counts" :key="row.key">
            <dt>{{ t(row.label) }}</dt>
            <dd :data-test="'contacts-import-' + row.key">{{ row.n }}</dd>
          </template>
        </dl>
        <ul v-if="answer.skipped.length" class="contacts-import__skipped" data-test="contacts-import-skipped">
          <li v-for="s in answer.skipped" :key="s.line">{{ t('contacts.import.skip_line', { line: s.line, reason: t(contactsSkipKey(s.code)) }) }}</li>
        </ul>
      </template>

      <div class="contacts-import__actions">
        <button type="button" class="btn ghost" data-test="contacts-import-close" @click="emit('update:open', false)">{{ t(done ? 'common.close' : 'common.cancel') }}</button>
        <button v-if="!done" type="button" class="btn" data-test="contacts-import-start" :disabled="busy || !answer?.would_add" @click="start">{{ t('contacts.import.start') }}</button>
      </div>
    </div>
  </UiDialog>
</template>

<script setup lang="ts">
import { useSpoolApi } from '~/composables/useSpoolApi'
import { contactsImport, contactsImportErrorKey, contactsSkipKey } from '~/utils/contacts-client.mjs'
import { withSessionRetry } from '~/utils/live-follow.mjs'

interface ImportAnswer {
  rows: number
  would_add?: number
  added?: number
  already_there: number
  already_there_by_phone: number
  deleted_here: number
  file_duplicates: number
  skipped: Array<{ line: number, code: string }>
  photos_ignored: number
}

defineProps<{ open: boolean }>()
const emit = defineEmits<{ 'update:open': [boolean] }>()

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const file = shallowRef<File | null>(null)
const answer = shallowRef<ImportAnswer | null>(null)
const busy = ref(false)
const done = ref(false)
const error = ref('')

/* a count of 0 is no news, except the one the button acts on */
const counts = computed(() => {
  const a = answer.value
  if (!a) return []
  const rows = [
    { key: 'rows', label: 'contacts.import.rows', n: a.rows },
    done.value
      ? { key: 'added', label: 'contacts.import.added', n: a.added ?? 0 }
      : { key: 'would-add', label: 'contacts.import.would_add', n: a.would_add ?? 0 },
  ]
  const more = [
    { key: 'already-there', label: 'contacts.import.already_there', n: a.already_there + a.already_there_by_phone },
    { key: 'deleted-here', label: 'contacts.import.deleted_here', n: a.deleted_here },
    { key: 'file-duplicates', label: 'contacts.import.file_duplicates', n: a.file_duplicates },
    { key: 'skipped', label: 'contacts.import.skipped', n: a.skipped.length },
    { key: 'photos-ignored', label: 'contacts.import.photos_ignored', n: a.photos_ignored },
  ]
  return [...rows, ...more.filter((r) => r.n > 0)]
})

async function send(dryRun: boolean) {
  busy.value = true
  error.value = ''
  try {
    answer.value = await withSessionRetry(api, () => contactsImport(api, file.value as File, { dryRun }))
    return true
  } catch (e) {
    answer.value = null
    error.value = t(contactsImportErrorKey(e))
    return false
  } finally {
    busy.value = false
  }
}

async function onPick(ev: Event) {
  const input = ev.target as HTMLInputElement
  file.value = input.files?.[0] ?? null
  answer.value = null
  error.value = ''
  /* cleared on a refusal, so the same file, once fixed, fires change again */
  if (file.value && !(await send(true))) input.value = ''
}

async function start() {
  done.value = await send(false)
}
</script>

<style scoped>
.contacts-import { display: flex; flex-direction: column; gap: 12px; }
.contacts-import input[type="file"] { max-width: 100%; }
.contacts-import__counts { display: grid; grid-template-columns: 1fr auto; gap: 4px 16px; margin: 0; }
.contacts-import__counts dd { margin: 0; font-variant-numeric: tabular-nums; text-align: end; }
.contacts-import__skipped { max-height: 10rem; margin: 0; padding-inline-start: 1.25rem; overflow-y: auto; font-size: 0.8125rem; }
.contacts-import__actions { display: flex; justify-content: flex-end; gap: 8px; }
@media (max-width: 820px) { .contacts-import__actions .btn { min-height: var(--tap, 44px); } }
</style>
