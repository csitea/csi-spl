<!-- "Interests" (Settings → Profile): the signed-in human's own free-text
     interests (CLE-77794). The hub keeps it per human (humans.interests, rdb
     0086, PUT /api/v1/auth/preferences interests) and every tenant member reads
     it on /v1/view/roster, so it shows on the person's card in the People
     section. Not optimistic: the value changes once the hub stored it; the form
     refuses locally what the hub would (up to 1000 characters). -->
<template>
  <form v-if="signedIn" class="interests" data-test="interests-setting" novalidate @submit.prevent="save">
    <label class="interests__label" for="settings-interests">{{ t('settings.interests.label') }}</label>
    <textarea
      id="settings-interests"
      v-model="draft"
      class="interests__input"
      rows="3"
      maxlength="1000"
      name="interests"
      spellcheck="true"
      data-test="settings-interests"
      aria-describedby="settings-interests-hint"
      :placeholder="t('settings.interests.placeholder')"
      :aria-invalid="invalid ? 'true' : undefined"
      :disabled="saving"
      @input="status = ''"
    />
    <div class="interests__row">
      <p id="settings-interests-hint" class="muted interests__hint">{{ t('settings.interests.hint') }}</p>
      <button type="submit" class="btn" data-test="settings-interests-save" :disabled="saving || !changed">
        {{ t('settings.interests.save') }}
      </button>
    </div>
    <p
      v-if="status"
      class="interests__status"
      :class="{ 'interests__status--error': failed }"
      role="status"
      aria-live="polite"
      data-test="settings-interests-status"
    >
      {{ status }}
    </p>
  </form>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useRosterStore } from '~/stores/roster'
import { useAuthClient } from '~/composables/useAuthClient'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const roster = useRosterStore()
const auth = useAuthClient()

const signedIn = computed(() => session.state === 'in')
const selfId = computed(() => roster.self?.id || '')
const current = computed(() => String(roster.humansDetail[selfId.value]?.interests || ''))
const draft = ref(current.value)
const saving = ref(false)
const status = ref('')
const failed = ref(false)
const invalid = computed(() => draft.value.length > 1000)
const changed = computed(() => draft.value.trim() !== current.value.trim())

/* the roster loads after this section mounts; fill an untouched field when it
   arrives (and after a save refreshes it). */
watch(current, (now, before) => { if (draft.value === before) draft.value = now })
onMounted(() => { if (!selfId.value) void roster.refresh() })

async function save() {
  if (!signedIn.value || saving.value || !changed.value) return
  saving.value = true
  status.value = ''
  try {
    await auth.saveInterests(draft.value)
    await roster.refresh()
    failed.value = false
    status.value = t('settings.interests.saved')
    draft.value = current.value
  } catch (e) {
    failed.value = true
    const tok = (e && typeof e === 'object' && 'token' in e) ? String((e as { token?: unknown }).token || '') : ''
    status.value = tok === 'invalid_interests' ? t('settings.interests.invalid') : t('settings.interests.failed')
  } finally {
    saving.value = false
  }
}
</script>

<style scoped>
.interests { display: flex; flex-direction: column; gap: 6px; margin-top: 14px; min-width: 0; }
.interests__label { font-size: 0.8125rem; font-weight: 600; }
.interests__input {
  width: 100%;
  max-width: 100%;
  box-sizing: border-box;
  background: var(--color-composer);
  border: 1px solid var(--color-border);
  color: var(--color-fg);
  border-radius: var(--radius-sm);
  padding: 8px;
  font: inherit;
  resize: vertical;
}
.interests__input[aria-invalid="true"] { border-color: var(--color-danger); }
.interests__row { display: flex; align-items: flex-start; justify-content: space-between; gap: 12px; flex-wrap: wrap; }
.interests__hint { font-size: 0.6875rem; margin: 0; flex: 1; min-width: 0; }
.interests__status { margin: 0; font-size: 0.75rem; color: var(--color-ok); }
.interests__status--error { color: var(--color-danger); }
</style>
