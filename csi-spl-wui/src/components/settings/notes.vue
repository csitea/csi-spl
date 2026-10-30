<!-- Settings -> Notes (spec 155 section 2.8, build row B10, SPL-4331): the
     person's own copy of every note and the erase of all of them. Export
     downloads notes-<date>.json (archived notes too); Erase deletes every
     note after the person types the confirmation word, and the Notes list
     is read again so it shows none. Notes are the person's own (realm, D1),
     so the section is the same in every workspace. Its own chunk, with
     utils/notes-data.mjs: it never enters the initial download. -->
<template>
  <SettingsSection id="settings-notes" :title="t('notes.settings.title')" data-test="settings-notes">
    <div class="snotes" data-test="snotes" :data-busy="busy ? 'true' : 'false'">
      <div class="snotes__block">
        <p class="muted snotes__hint">{{ t('notes.settings.export_hint') }}</p>
        <div class="snotes__actions">
          <button type="button" class="btn" data-test="snotes-export" :disabled="busy" @click="doExport()">{{ t('notes.settings.export') }}</button>
        </div>
      </div>
      <div class="snotes__block snotes__erase">
        <p class="muted snotes__hint">{{ t('notes.settings.erase_hint') }}</p>
        <label class="snotes__confirm">
          <span>{{ t('notes.settings.erase_confirm', { word }) }}</span>
          <input
            v-model="typed"
            type="text"
            class="snotes__input"
            data-test="snotes-erase-word"
            autocomplete="off"
            autocapitalize="off"
            spellcheck="false"
            :disabled="busy"
            @keydown.enter.prevent="doErase()"
          >
        </label>
        <div class="snotes__actions">
          <button type="button" class="btn danger" data-test="snotes-erase" :disabled="busy || !confirmed" @click="doErase()">{{ t('notes.settings.erase') }}</button>
        </div>
      </div>
      <p v-if="said" class="snotes__result" :class="{ 'snotes__warn': warn }" role="status" data-test="snotes-result">{{ t(said) }}</p>
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useNotesStore } from '~/stores/notes'
import { saveBlob } from '~/utils/save-blob'
import { eraseConfirmed, eraseNotes, exportNotes } from '~/utils/notes-data.mjs'

const { t } = useI18n({ useScope: 'global' })
const api = useSpoolApi()
const notes = useNotesStore()
const busy = ref(false)
const typed = ref('')
const said = ref('')
const warn = ref(false)
const word = computed(() => t('notes.settings.erase_word'))
const confirmed = computed(() => eraseConfirmed(typed.value, word.value))

function say(key: string, isWarn = false) {
  said.value = key
  warn.value = isWarn
}

/* notes_off (section 6) says Notes are turned off; anything else says it failed */
const failKey = (e: unknown, key: string) => ((e as { token?: string })?.token === 'notes_off' ? 'notes.off' : key)

async function doExport() {
  if (busy.value) return
  busy.value = true
  say('')
  try {
    const { blob, name } = await exportNotes(api, notes)
    saveBlob(blob, name)
  } catch (e) {
    say(failKey(e, 'notes.settings.export_failed'), true)
  } finally {
    busy.value = false
  }
}

async function doErase() {
  if (busy.value || !confirmed.value) return
  busy.value = true
  say('')
  try {
    await eraseNotes(api, notes)
    typed.value = ''
    say('notes.settings.erased')
  } catch (e) {
    say(failKey(e, 'notes.settings.erase_failed'), true)
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.snotes { display: grid; gap: 16px; }
.snotes__block { display: grid; gap: 8px; }
.snotes__hint { margin: 0; }
.snotes__erase { border-top: 1px solid var(--color-border); padding-top: 14px; }
.snotes__confirm { display: grid; gap: 6px; max-width: 320px; }
.snotes__input { min-height: var(--tap, 44px); }
.snotes__actions { display: flex; flex-wrap: wrap; gap: 8px; }
.snotes__actions .btn { min-height: var(--tap, 44px); }
/* Erase stays off until the word is typed: it must look off, too */
.snotes__actions .btn:disabled { opacity: 0.5; cursor: not-allowed; }
.snotes__result { margin: 0; font-size: 0.875rem; }
.snotes__warn { color: var(--color-danger); }
</style>
