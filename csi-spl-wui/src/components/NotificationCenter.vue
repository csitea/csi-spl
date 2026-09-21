<template>
  <div class="notify-box">
    <button
      class="btn ghost notify-alerts"
      type="button"
      data-testid="notify-alerts"
      :aria-label="alertsLabel"
      :title="alertsLabel"
      @click="notes.requestPush()"
    >
      <UiIcon class="notify-glyph" name="bell" :size="18" />
      <span class="notify-text">{{ alertsLabel }}</span>
    </button>
    <label class="muted notify-chime" :title="t('notify.chime')">
      <input v-model="notes.chime" type="checkbox" :aria-label="t('notify.chime')">
      <span class="notify-text">{{ t('notify.chime') }}</span>
    </label>
  </div>
</template>

<script setup lang="ts">
import { useNotificationStore } from '~/stores/notification'

const notes = useNotificationStore()
const { t } = useI18n({ useScope: 'global' })
const alertsLabel = computed(() => (notes.permission === 'granted' ? t('notify.alerts_on') : t('notify.enable_alerts')))
</script>

<style scoped>
.notify-box {
  padding: 8px 16px;
  display: grid;
  gap: 6px;
  max-width: 100%;
  min-width: 0;
  overflow-wrap: anywhere;
}
.notify-alerts {
  display: flex;
  align-items: center;
  justify-content: center;
  gap: 6px;
}
/* The glyph is the narrow-rail form only; with the label present it would be
   a second, redundant signal. */
.notify-glyph { display: none; }
.notify-chime {
  display: flex;
  align-items: center;
  gap: 6px;
  min-width: 0;
}

/* CLE-3433 — the collapsed rail (main.css hides `.sidebar h2`, the nav
   labels, `.create-row` and the version stamp at the same breakpoint).
   This box was never given that treatment, so at 800px and below the words
   "enable alerts" were laid out inside a 40px-wide button with
   `overflow-wrap: anywhere` and came out as a COLUMN OF SINGLE LETTERS —
   measured on the deployed dev build 28ec27b: the button rendered 40px wide
   by 234px tall at every viewport from 390px to 768px. That column, next to
   an unlabelled channel rail, is what "completely broken" looks like on a
   phone. In the rail the control becomes a bell icon that keeps its
   accessible name through aria-label/title, and the chime keeps its
   checkbox; neither is removed, because a phone is where push matters most. */
@media (max-width: 800px) {
  .notify-box { padding: 8px 4px; justify-items: center; }
  .notify-text { display: none; }
  .notify-glyph { display: block; }
  .notify-alerts {
    min-width: var(--tap);
    min-height: var(--tap);
    padding: 6px;
  }
  .notify-chime { justify-content: center; gap: 0; }
}
</style>
