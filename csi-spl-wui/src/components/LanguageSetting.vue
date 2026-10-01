<!-- spec 021: the signed-in human's preferred language (Settings page,
     CLE-3402's section#settings-language). The same searchable LocaleCombobox
     as the header switcher, and a Save that writes the hub-side
     preferred_locale — the hub mails in this language and
     plugins/preferred-locale.client.ts opens the WUI in it after the next
     sign-in.

     Save ALSO switches the interface on the spot (owner 2026-09-23). It did
     not until then, copied from the donor's account page, and that is the bug
     the owner reported: a control labelled "language", with a Save, that
     leaves every string on the page in the old language is indistinguishable
     from a broken one. The switch is the same navigation the header control
     makes (useLocaleSwitch — the URL prefix stays the single source of truth),
     so the two surfaces cannot disagree, and the page re-rendering in the
     chosen language IS the confirmation.

     Order matters: the hub write is awaited FIRST and a failure aborts the
     switch, so the UI never claims a preference the hub did not accept (an
     unsupported locale answers 400, auth-v1 preferences).

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
import { useLocaleSwitch } from '~/composables/useLocaleSwitch'

const { t, locale } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const copy = useAuthCopy()
const { switchTo } = useLocaleSwitch()

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
  const want = preferredLocale.value
  const out = await auth.savePreferences({ preferred_locale: want })
  saving.value = false
  if (out.ok) {
    session.setPreferredLocale(want)
    statusError.value = false
    status.value = t('settings.language.saved')
    // Show this page in the language just chosen. `replace` so Back returns
    // to wherever the human came from rather than to this same page in the
    // language they just moved away from.
    await switchTo(want, true)
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
/* SPL-993: the combobox arrow is a 44 px target on a touch screen.
   CLE-77887 (owner, topic 9417ccf3: "on mobile the language switcher is too
   narrow"): on a phone the field takes the whole column and Save its own row
   below it, instead of both squeezed side by side; the open list follows the
   field's width, so every language name shows whole. */
@media (max-width: 820px) {
  .lang-setting :deep(.locale-cbx__button) { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
  .lang-setting__cbx { flex: 1 1 100%; max-width: none; }
  .lang-setting__row .btn { min-height: var(--tap, 44px); }
}
</style>
