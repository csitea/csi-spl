<template>
  <!-- owner, 2026-09-26: icons only, one row; the words are the hover text
       (title) and the screen-reader name (aria-label). -->
  <div class="notify-box">
    <button
      class="icon-btn notify-alerts"
      type="button"
      data-testid="notify-alerts"
      :class="{ on: alertsWanted }"
      :aria-label="alertsLabel"
      :title="alertsLabel"
      @click="notes.toggleAlerts()"
    >
      <UiIcon class="notify-glyph" :name="alertsWanted ? 'bell' : 'bell-off'" :size="18" />
    </button>
    <button
      class="icon-btn notify-chime"
      type="button"
      data-testid="notify-chime"
      :class="{ on: notes.chime }"
      :aria-pressed="notes.chime"
      :aria-label="chimeLabel"
      :title="chimeLabel"
      @click="notes.chime = !notes.chime"
    >
      <UiIcon class="notify-glyph" :name="notes.chime ? 'music' : 'music-off'" :size="18" />
    </button>
  </div>
</template>

<script setup lang="ts">
import { useNotificationStore } from '~/stores/notification'

const notes = useNotificationStore()
const { t } = useI18n({ useScope: 'global' })
const alertsWanted = computed(() => notes.alertsEnabled)
const chimeLabel = computed(() => (notes.chime ? t('notify.chime_on') : t('notify.chime_off')))
const alertsLabel = computed(() => (alertsWanted.value ? t('notify.alerts_on') : t('notify.enable_alerts')))
</script>

<style scoped>
.notify-box {
  display: inline-flex;
  align-items: center;
  gap: 4px;
  min-width: 0;
}
.notify-alerts, .notify-chime {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  min-width: var(--tap, 32px);
  min-height: var(--tap, 32px);
  padding: 6px;
  opacity: 0.6;
}
.notify-alerts.on, .notify-chime.on { opacity: 1; color: var(--color-accent); }
/* off keeps the same ink as the bell, at full strength, so the slash reads */
.notify-chime:not(.on) { opacity: 1; color: var(--color-fg); }
.notify-glyph { display: block; }

/* CLE-3433 - the collapsed rail (<= 800px). The controls were text buttons
   that wrapped into a column of single letters at 40px wide; they are icons
   now at every width, so the rail only stacks them. Neither is removed: a
   phone is where push matters most, and both keep their accessible name. */
@media (max-width: 800px) {
  .notify-box { flex-direction: column; }
}
</style>
