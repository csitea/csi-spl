<!-- "Debug pane" (Settings → Appearance): the signed-in human's own
     switch for the diagnostics panel at the bottom of the app
     (components/common/DebugPanel.vue). The hub keeps it per human
     (humans.diagnostics_enabled, PUT /api/v1/auth/preferences) and answers it
     as the `diagnostics_enabled` session claim, which is the panel's whole
     gate.

     The toggle is optimistic: the session claim flips first, so the panel
     appears or disappears as the box is clicked, and flips back with a status
     line when the hub refuses the save (utils/debug-pane.mjs). -->
<template>
  <div v-if="signedIn" class="debug-pane" data-test="debug-pane-setting">
    <label class="debug-pane__row">
      <input
        type="checkbox"
        data-test="settings-debug-pane"
        aria-describedby="settings-debug-pane-hint"
        :checked="on"
        :disabled="saving"
        @change="toggle(($event.target as HTMLInputElement).checked)"
      />
      <span class="debug-pane__label">{{ t('settings.debug_pane.label') }}</span>
    </label>
    <p id="settings-debug-pane-hint" class="muted debug-pane__hint">{{ t('settings.debug_pane.hint') }}</p>
    <p
      v-if="status"
      class="debug-pane__status"
      role="status"
      aria-live="polite"
      data-test="settings-debug-pane-status"
    >
      {{ status }}
    </p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useSettingSave } from '~/composables/useSettingSave'
import { diagnosticsGranted } from '@/composables/debugAudience.mjs'
import { applyDebugPaneSetting } from '~/utils/debug-pane.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()

const signedIn = computed(() => session.state === 'in')
const on = computed(() => diagnosticsGranted(session.claims))
const { saving, status, run } = useSettingSave()

function toggle(want: boolean) {
  return run(() => applyDebugPaneSetting(want, {
    current: on.value,
    apply: (v: boolean) => session.setDiagnosticsEnabled(v),
    save: (v: boolean) => auth.saveDiagnostics(v),
  }))
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.debug-pane {
  display: grid;
  gap: 4px;
  min-width: 0;
  max-width: 100%;
}
.debug-pane__row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  cursor: pointer;
}
.debug-pane__label {
  font-weight: 600;
}
.debug-pane__hint,
.debug-pane__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.debug-pane__status {
  color: var(--color-error);
}
</style>
