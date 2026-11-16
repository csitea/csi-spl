<!-- "Name and phone" (Settings → Profile): the signed-in human's own first
     name, last name and phone (SPL-5707, spec 154 section 12.5; they replace
     the single "Display name" field). The hub keeps them per human
     (humans.first_name / last_name / phone, rdb 0287; PUT
     /api/v1/auth/preferences first_name, last_name, phone; GET
     /api/v1/auth/profile reads them back) and writes display_name as the
     join, which it answers as the session's `name` (user menu, profile card).
     Other members see the two names and the phone on the member card; in a
     name-only workspace (t1) the names only.

     Not optimistic: the name changes in the WUI once the hub stored it
     (utils/display-name.ts applyProfile), and the form refuses locally what
     the hub would (a first name; each part up to 100 characters on one line;
     the phone as + and the country code). -->
<template>
  <form v-if="signedIn" class="display-name" data-test="display-name-setting" novalidate @submit.prevent="save">
    <p class="display-name__label">{{ t('settings.display_name.label') }}</p>
    <div class="display-name__grid">
      <label for="settings-first-name">{{ t('contacts.first_name') }}</label>
      <input
        id="settings-first-name"
        v-model="draft.first"
        class="display-name__input"
        type="text"
        name="first_name"
        autocomplete="given-name"
        spellcheck="false"
        data-test="settings-first-name"
        aria-describedby="settings-display-name-hint"
        :aria-invalid="badName ? 'true' : undefined"
        :disabled="saving"
        @input="status = ''"
      />
      <label for="settings-last-name">{{ t('contacts.last_name') }}</label>
      <input
        id="settings-last-name"
        v-model="draft.last"
        class="display-name__input"
        type="text"
        name="last_name"
        autocomplete="family-name"
        spellcheck="false"
        data-test="settings-last-name"
        aria-describedby="settings-display-name-hint"
        :aria-invalid="badName ? 'true' : undefined"
        :disabled="saving"
        @input="status = ''"
      />
      <label for="settings-phone">{{ t('contacts.phone') }}</label>
      <input
        id="settings-phone"
        v-model="draft.phone"
        class="display-name__input"
        type="tel"
        name="phone"
        autocomplete="tel"
        inputmode="tel"
        spellcheck="false"
        placeholder="+358 40 123 4567"
        data-test="settings-phone"
        aria-describedby="settings-display-name-hint"
        :aria-invalid="badPhone ? 'true' : undefined"
        :disabled="saving"
        @input="status = ''"
      />
    </div>
    <div class="display-name__row">
      <p id="settings-display-name-hint" class="muted display-name__hint">{{ t('settings.display_name.hint') }}</p>
      <button type="submit" class="btn" data-test="settings-display-name-save" :disabled="saving || !changed">
        {{ t('settings.display_name.save') }}
      </button>
    </div>
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
import { applyProfile, splitDisplayName, validNamePart, validPhone, type ProfileFields } from '~/utils/display-name'
import { useHumanNames } from '~/composables/useHumanNames'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const people = useHumanNames()

const signedIn = computed(() => session.state === 'in')
/* What the hub holds: GET profile; before it answers (or in the mock, which
   has no hub) the session name split by the hub's own rule. */
const stored = ref<ProfileFields | null>(null)
const current = computed<ProfileFields>(() => stored.value || { ...splitDisplayName(session.claims?.name), phone: '' })
const draft = reactive<ProfileFields>({ ...current.value })
const saving = ref(false)
const status = ref('')
const failed = ref(false)
const badName = computed(() => (draft.first !== '' && !validNamePart(draft.first).ok) || (draft.last.trim() !== '' && !validNamePart(draft.last).ok))
const badPhone = computed(() => draft.phone.trim() !== '' && !validPhone(draft.phone).ok)
const same = (a: ProfileFields, b: ProfileFields) => a.first.trim() === b.first.trim() && a.last.trim() === b.last.trim() && a.phone.trim() === b.phone.trim()
const changed = computed(() => !same(draft, current.value))

// A read that lands after mount (or a save elsewhere) refills untouched fields.
watch(current, (now, before) => { if (same(draft, before)) Object.assign(draft, now) })

async function load() {
  const res = await auth.getProfile()
  if (!res.ok || !res.data) return
  const d = res.data
  stored.value = { first: d.first_name || '', last: d.last_name || '', phone: d.phone || '' }
}

async function save() {
  if (!signedIn.value || saving.value) return
  saving.value = true
  status.value = ''
  let res: Awaited<ReturnType<typeof applyProfile>>
  try {
    res = await applyProfile({ ...draft }, {
      current: current.value,
      save: (v: ProfileFields) => auth.saveProfile(v),
      apply: (name: string) => session.setName(name),
    })
  } finally {
    saving.value = false
  }
  failed.value = !res.ok
  if (res.ok) {
    if (res.v) stored.value = { ...res.v }
    Object.assign(draft, current.value)
    status.value = t('settings.display_name.saved')
    /* the lists and cards show the new name without a reload */
    void people.refresh()
    return
  }
  const code = (res.out as { error?: string } | undefined)?.error
  if (res.reason === 'invalid_phone' || code === 'invalid_phone') status.value = t('settings.display_name.invalid_phone')
  else if (res.reason === 'invalid_name' || code === 'invalid_name') status.value = t('settings.display_name.invalid')
  else status.value = t('settings.display_name.failed')
}

// The settings page can mount before the app's session probe has run; start it here.
onMounted(() => {
  if (session.state === 'loading') void session.probe()
  void load()
})
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
  margin: 0;
  font-weight: 600;
}
.display-name__grid {
  display: grid;
  grid-template-columns: minmax(0, max-content) minmax(0, 1fr);
  align-items: center;
  gap: 6px 10px;
  min-width: 0;
}
.display-name__row {
  display: flex;
  align-items: flex-start;
  justify-content: space-between;
  gap: 8px;
  flex-wrap: wrap;
  min-width: 0;
}
.display-name__row .display-name__hint {
  flex: 1 1 220px;
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
