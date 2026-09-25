<!-- "Display name" (CLE-34968, Settings → Profile): the signed-in human's own
     shown name. The hub keeps it per human (humans.display_name, PUT
     /api/v1/auth/preferences display_name) and answers it as the session's
     `name`, which the user menu and the profile card render.

     Not optimistic: the name changes in the WUI once the hub stored it
     (utils/display-name.mjs), and the form refuses locally what the hub would
     (1..200 characters, one line, no control character). -->
<template>
  <form v-if="signedIn" class="display-name" data-test="display-name-setting" novalidate @submit.prevent="save">
    <label class="display-name__label" for="settings-display-name">{{ t('settings.display_name.label') }}</label>
    <div class="display-name__row">
      <input
        id="settings-display-name"
        v-model="draft"
        class="display-name__input"
        type="text"
        name="display_name"
        autocomplete="name"
        spellcheck="false"
        data-test="settings-display-name"
        aria-describedby="settings-display-name-hint"
        :aria-invalid="invalid ? 'true' : undefined"
        :disabled="saving"
        @input="status = ''"
      />
      <button type="submit" class="btn" data-test="settings-display-name-save" :disabled="saving || !changed">
        {{ t('settings.display_name.save') }}
      </button>
    </div>
    <p id="settings-display-name-hint" class="muted display-name__hint">{{ t('settings.display_name.hint') }}</p>
    <p
      v-if="status"
      class="display-name__status"
      :class="{ 'display-name__status--error': failed }"
      role="status"
      aria-live="polite"
      data-test="settings-display-name-status"
    >
      {{ status }}
    </p>
  </form>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { applyDisplayName, validDisplayName } from '~/utils/display-name.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()

const signedIn = computed(() => session.state === 'in')
const current = computed(() => String(session.claims?.name || ''))
const draft = ref(current.value)
const saving = ref(false)
const status = ref('')
const failed = ref(false)
const invalid = computed(() => draft.value !== '' && !validDisplayName(draft.value).ok)
const changed = computed(() => draft.value.trim() !== current.value.trim())

// A probe that lands after mount (or a save elsewhere) refills an untouched field.
watch(current, (now, before) => { if (draft.value === before) draft.value = now })

async function save() {
  if (!signedIn.value || saving.value) return
  saving.value = true
  status.value = ''
  const res = await applyDisplayName(draft.value, {
    current: current.value,
    save: (name: string) => auth.saveDisplayName(name),
    apply: (name: string) => session.setName(name),
  })
  saving.value = false
  failed.value = !res.ok
  if (res.ok) {
    draft.value = res.name
    status.value = t('settings.display_name.saved')
    return
  }
  const code = (res.out as { error?: string } | undefined)?.error
  status.value = res.reason === 'invalid' || code === 'invalid_display_name'
    ? t('settings.display_name.invalid')
    : t('settings.display_name.failed')
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.display-name {
  display: grid;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
  margin-top: 14px;
}
.display-name__label {
  font-weight: 600;
}
.display-name__row {
  display: flex;
  gap: 8px;
  flex-wrap: wrap;
  min-width: 0;
}
.display-name__input {
  flex: 1 1 220px;
  min-width: 0;
  min-height: var(--tap, 44px);
  padding: 6px 10px;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-sm, 8px);
  background: var(--color-surface);
  color: var(--color-text);
  font: inherit;
}
.display-name__input[aria-invalid='true'] {
  border-color: var(--color-error);
}
.display-name__hint,
.display-name__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.display-name__hint {
  font-size: 0.8125rem;
}
.display-name__status--error {
  color: var(--color-error);
}
</style>
