<!-- Settings → Appearance → "Time zone" (CLE-77908, owner topic 07b84fd7:
     "default shuold be browser zone , but the uesrs should be able to
     overwrite it by their personal settings , PER TENANT"). Every time the WUI
     prints, and every ISO time with a zone written inside a message, reads in
     this zone. Kept per workspace on the hub (time_zone, rdb 0078); the first
     option clears it back to the browser's zone. Optimistic like the other
     settings: the claim flips on pick and flips back when the hub refuses. -->
<template>
  <div v-if="signedIn" class="tz-setting" data-test="time-zone-setting">
    <label :for="`${uid}-tz`" class="tz-setting__label">{{ t('settings.time_zone.label') }}</label>
    <select
      :id="`${uid}-tz`"
      class="tz-setting__select"
      :value="current"
      :disabled="saving"
      :aria-describedby="`${uid}-tz-hint`"
      data-test="time-zone-select"
      @change="pick(($event.target as HTMLSelectElement).value)"
    >
      <option value="">{{ t('settings.time_zone.browser', { zone: browser || 'UTC' }) }}</option>
      <option v-for="z in zones" :key="z" :value="z">{{ z }}</option>
    </select>
    <p :id="`${uid}-tz-hint`" class="muted tz-setting__hint">{{ t('settings.time_zone.hint') }}</p>
    <p v-if="status" class="tz-setting__status" role="status" aria-live="polite" data-test="time-zone-status">{{ status }}</p>
  </div>
</template>

<script setup lang="ts">
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAuthCopy } from '~/composables/useAuthCopy'
import { browserTimeZone, isKnownTimeZone, knownTimeZones } from '~/utils/date-iso.mjs'

const { t } = useI18n({ useScope: 'global' })
const session = useSessionStore()
const auth = useAuthClient()
const copy = useAuthCopy()

const uid = useId()
const signedIn = computed(() => session.state === 'in')
const saving = ref(false)
const status = ref('')
const browser = import.meta.client ? browserTimeZone() : ''
const zones = import.meta.client ? knownTimeZones() : []
/* a stored zone this browser does not know shows as the browser's (the
   clocks fall back to it too) */
const current = computed(() => {
  const z = String(session.claims?.time_zone || '')
  return z && isKnownTimeZone(z) ? z : ''
})

async function pick(want: string) {
  if (!signedIn.value || saving.value) return
  const before = session.claims?.time_zone ?? null
  const next = want || null
  if (next === before) return
  saving.value = true
  status.value = ''
  session.setTimeZone(next)
  try {
    const res = await auth.saveTimeZone(next)
    if (!res.ok) {
      session.setTimeZone(before)
      status.value = copy.nativeError(res as Parameters<typeof copy.nativeError>[0]) || t('settings.language.failed')
    }
  } catch {
    session.setTimeZone(before)
    status.value = t('settings.language.failed')
  } finally {
    saving.value = false
  }
}
</script>

<style scoped>
.tz-setting {
  display: grid;
  gap: 6px;
  min-width: 0;
  max-width: 100%;
}
.tz-setting__label { font-weight: 600; }
.tz-setting__select {
  min-height: var(--tap, 44px);
  max-width: 100%;
  min-width: 0;
}
.tz-setting__hint,
.tz-setting__status {
  margin: 0;
  overflow-wrap: anywhere;
}
.tz-setting__status { color: var(--color-error); }
</style>
