<template>
  <!-- owner, 2026-09-26: icons only, one row; the words are the hover text
       (title) and the screen-reader name (aria-label). -->
  <div class="notify-box" :class="'notify-box--' + placement" :data-testid="'notify-box-' + placement">
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

/* SPL-990: 'rail' is the sidebar's copy (desktop); 'menu' is the one in the
   phone avatar sheet. At <= 820 px the rail copy steps aside for it. */
withDefaults(defineProps<{ placement?: 'rail' | 'menu' }>(), { placement: 'rail' })
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
/* SPL-998: off is drawn exactly like the bell when off (the owner: "the same
   width and color as on the bell"), so there is no chime-only off rule */
.notify-glyph { display: block; }

/* SPL-990: at <= 820 px there is no collapsed rail any more (M1's level 1
   is full width) and the bell + chime live in the avatar sheet, so the
   rail's copy steps aside. Neither control is removed: both keep their
   accessible name in the menu copy. */
@media (max-width: 820px) {
  .notify-box--rail { display: none; }
  .notify-alerts, .notify-chime { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
</style>
