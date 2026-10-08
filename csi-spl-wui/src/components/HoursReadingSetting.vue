<!-- "Count my reading time" (Settings -> Behaviour, spec 107 section 1.2,
     T016): the signed-in member's switch for the active-tab minutes the
     hours suggestions count. The hub keeps it per workspace (PUT
     /api/v1/auth/preferences hours_reading, rdb 0078) and answers it as the
     `hours_reading` session claim; never picked = on. Optimistic like
     Keyboard shortcuts: the claim flips as the box is clicked and flips back
     with a status line when the hub refuses the save. The tab recorder
     (T012) reads the same claim. -->
<template>
  <div v-if="signedIn" class="hr-setting" data-test="hours-reading-setting">
    <label class="hr-setting__row">
      <input
        type="checkbox"
        data-testid="settings-hours-reading"
        :aria-describedby="hintId"
        :checked="on"
        :disabled="saving"
        @change="toggle(($event.target as HTMLInputElement).checked)"
      />
      <span class="hr-setting__label">{{ t('settings.hours_reading.label') }}</span>
    </label>
    <p :id="hintId" class="muted hr-setting__hint">{{ t('settings.hours_reading.hint') }}</p>
    <p v-if="status" class="hr-setting__status" role="status" aria-live="polite" data-testid="settings-hours-reading-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useSettingSave } from '~/composables/useSettingSave'
import { applyDebugPaneSetting } from '~/utils/debug-pane.mjs'
import { hoursReadingOn } from '~/utils/hours-settings.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()

const hintId = useId()
const signedIn = computed(() => session.state === 'in')
const on = computed(() => hoursReadingOn(session.claims?.hours_reading))
const { saving, status, run } = useSettingSave()

/* the Debug pane's optimistic boolean save: flip, save, revert on a refusal */
function toggle(want: boolean) {
  return run(() => applyDebugPaneSetting(want, {
    current: on.value,
    apply: (v: boolean) => session.setHoursReading(v),
    save: (v: boolean) => auth.saveHoursReading(v),
  }))
}

onMounted(() => { if (session.state === 'loading') void session.probe() })
</script>

<style scoped>
.hr-setting {
  display: grid;
  gap: 4px;
  min-width: 0;
  max-width: 100%;
}
.hr-setting__row {
  display: flex;
  align-items: center;
  gap: 8px;
  min-height: var(--tap, 44px);
  cursor: pointer;
}
.hr-setting__label {
  font-weight: 600;
}
.hr-setting__hint,
.hr-setting__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.hr-setting__status {
  color: var(--color-error);
}
</style>
