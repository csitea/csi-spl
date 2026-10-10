<!-- HUM-10 (csitea topic 3e5b850b, msgs 04122960, bc6265da): "Install app"
     where the email link lands, not only in Settings. plugins/pwa.client.ts
     keeps Chrome's one install event (preventDefault suppresses Chrome's own
     mini-infobar), so without this strip someone arriving from the invite or
     sign-in email saw no install offer until they were signed in AND opened
     Settings -> Appearance.

     app.vue mounts it only once Chrome fired beforeinstallprompt, so Safari
     and Firefox never fetch this chunk (ci_home_gzip_kb). It shows while the
     event can prompt and the page is not the installed app (utils/pwa-install.mjs,
     the state Settings' "Apps on this phone" row reads); Install calls the
     kept event's prompt(). "Not now" is remembered on this device. -->
<template>
  <div
    v-if="shown"
    class="pwa-offer"
    role="region"
    :aria-label="t('pwa.offer.text')"
    data-test="pwa-install-offer"
    data-build-watch-ignore
  >
    <span class="pwa-offer__text">{{ t('pwa.offer.text') }}</span>
    <button type="button" class="btn pwa-offer__install" data-test="pwa-install-offer-install" @click="install">
      {{ t('settings.apps.install') }}
    </button>
    <button type="button" class="pwa-offer__later" data-test="pwa-install-offer-dismiss" @click="dismiss">
      {{ t('pwa.offer.later') }}
    </button>
  </div>
</template>

<script setup lang="ts">
import { onPwaInstallChange, promptPwaInstall, pwaInstallState } from '~/utils/pwa-install.mjs'

/** Set by "Not now": this device is not offered the install again. */
const DISMISS_KEY = 'spool:pwa-offer-off'

const { t } = useI18n({ useScope: 'global' })
const state = ref({ canPrompt: false, installed: false })
const dismissed = ref(true)
const shown = computed(() => !dismissed.value && state.value.canPrompt && !state.value.installed)

function remembered() {
  try { return localStorage.getItem(DISMISS_KEY) === '1' } catch { return false }
}

async function install() {
  await promptPwaInstall()
}

function dismiss() {
  dismissed.value = true
  try { localStorage.setItem(DISMISS_KEY, '1') } catch { /* private mode: this page only */ }
}

let off: (() => void) | null = null
onMounted(() => {
  dismissed.value = remembered()
  state.value = pwaInstallState()
  off = onPwaInstallChange((s: { canPrompt: boolean, installed: boolean }) => { state.value = s })
})
onBeforeUnmount(() => { off?.() })
</script>

<style scoped>
/* placed and drawn as BuildUpdateBar: a small strip under the top bar,
   covering nothing but itself */
.pwa-offer {
  position: fixed;
  top: calc(var(--top-bar-h) + 0.5rem);
  left: 0;
  right: 0;
  margin-inline: auto;
  width: fit-content;
  z-index: var(--z-banner);
  display: flex;
  align-items: center;
  flex-wrap: wrap;
  gap: 0.5rem 0.75rem;
  max-width: calc(100vw - 2rem);
  box-sizing: border-box;
  padding: 0.375rem 0.375rem 0.375rem 0.875rem;
  border: 1px solid var(--color-accent);
  border-radius: var(--radius-sm);
  background: color-mix(in srgb, var(--color-accent) 12%, var(--color-surface));
  color: var(--color-fg);
  box-shadow: var(--focus-3d);
  font-size: 0.875rem;
}
.pwa-offer__text { min-width: 0; overflow-wrap: anywhere; }
.pwa-offer__install,
.pwa-offer__later { flex: none; min-height: 2.25rem; }
.pwa-offer__later {
  border: 0;
  background: none;
  color: var(--color-fg);
  font-family: inherit;
  font-size: inherit;
  text-decoration: underline;
  cursor: pointer;
  padding: 0 0.5rem;
}
@media (pointer: coarse) {
  .pwa-offer__install,
  .pwa-offer__later { min-height: 2.75rem; }
}
</style>
