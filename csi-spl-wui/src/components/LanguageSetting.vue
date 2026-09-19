<!-- spec 021: the signed-in human's preferred language (Settings page,
     CLE-3402's section#settings-language). The donor's account page shape:
     the same searchable LocaleCombobox as the header switcher, a Save that
     writes the hub-side preferred_locale, and NO UI switch here — the hub
     mails in this language and plugins/preferred-locale.client.ts applies it
     after the next sign-in; the header switcher changes the current page.
     No props: loads (session claims) and saves (PUT /api/v1/auth/preferences)
     by itself. -->
<template>
  <div class="lang-setting" data-test="language-setting">
    <p id="settings-preferred-locale-label" class="lang-setting__label">
      {{ t('settings.language.label') }}
    </p>
    <div class="lang-setting__row">
      <LocaleCombobox
        v-model="preferredLocale"
        test-prefix="settings-preferred-locale"
        labelled-by="settings-preferred-locale-label"
        class="lang-setting__cbx"
      />
      <button
        class="btn"
        type="button"
        data-test="settings-preferred-locale-save"
        :disabled="saving || !signedIn || preferredLocale === stored"
        @click="savePreferredLocale"
      >
        {{ t('settings.language.save') }}
      </button>
    </div>
    <p class="muted lang-setting__hint">{{ t('settings.language.hint') }}</p>
    <p
      v-if="status"
      class="lang-setting__status"
      :class="{ 'lang-setting__status--error': statusError }"
      role="status"
      aria-live="polite"
      data-test="settings-preferred-locale-status"
    >
      {{ status }}
    </p>
  </div>
</template>

<script setup lang="ts">
import LocaleCombobox from '@/components/LocaleCombobox.vue'
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAuthCopy } from '~/composables/useAuthCopy'

const { t, locale } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const copy = useAuthCopy()

const signedIn = computed(() => session.state === 'in')
/** What the hub holds; '' = no preference stored yet (the UI locale is shown). */
const stored = computed(() => String(session.claims?.preferred_locale || ''))
const preferredLocale = ref(stored.value || locale.value)
watch(stored, (v) => { if (v) preferredLocale.value = v })

const saving = ref(false)
const status = ref('')
const statusError = ref(false)

async function savePreferredLocale() {
  if (!signedIn.value || saving.value) return
  saving.value = true
  status.value = ''
  const out = await auth.savePreferences({ preferred_locale: preferredLocale.value })
  saving.value = false
  if (out.ok) {
    session.setPreferredLocale(preferredLocale.value)
    statusError.value = false
    status.value = t('settings.language.saved')
    return
  }
  statusError.value = true
  status.value = copy.nativeError(out) || t('settings.language.failed')
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.lang-setting {
  display: grid;
  gap: 8px;
  min-width: 0;
  max-width: 100%;
}
.lang-setting__label {
  margin: 0;
  font-weight: 600;
}
.lang-setting__row {
  display: flex;
  flex-wrap: wrap;
  align-items: center;
  gap: 8px;
  min-width: 0;
}
.lang-setting__cbx {
  flex: 1 1 12rem;
  max-width: 20rem;
}
.lang-setting__hint,
.lang-setting__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.lang-setting__status--error {
  color: var(--color-error);
}
</style>
