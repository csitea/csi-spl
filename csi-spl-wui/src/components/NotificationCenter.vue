<template>
  <!-- owner, 2026-09-26: icons only, one row; the words are the hover text
       (title) and the screen-reader name (aria-label). -->
  <div class="notify-box" :class="'notify-box--' + placement" :data-testid="'notify-box-' + placement">
    <button
      class="icon-btn notify-alerts"
      type="button"
      data-testid="notify-alerts"
      :class="{ on: alertsWanted, 'notify-alerts--warn': warn }"
      :data-state="notes.alertStatus"
      :aria-label="alertsLabel"
      :title="bellTitle"
      @click="notes.toggleAlerts()"
    >
      <UiIcon class="notify-glyph" :name="alertsWanted ? 'bell' : 'bell-off'" :size="18" />
      <!-- HUM-24 (311427c6): on, but the browser cannot alert (not asked, blocked, iOS tab) -->
      <span v-if="warn" class="notify-warn-dot" aria-hidden="true" />
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
/* the bell is the reader's switch; the dot says the browser does not follow it */
const warn = computed(() => ['ask', 'blocked', 'install', 'unsupported'].includes(notes.alertStatus))
const alertsLabel = computed(() => (alertsWanted.value ? t('notify.alerts_on') : t('notify.enable_alerts')))
const bellTitle = computed(() => (warn.value ? `${alertsLabel.value}: ${t(`notify.state_${notes.alertStatus}`)}` : alertsLabel.value))
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
.notify-alerts { position: relative; }
.notify-warn-dot {
  position: absolute;
  top: 4px;
  right: 4px;
  width: 8px;
  height: 8px;
  border-radius: 50%;
  background: var(--color-warn);
}

/* SPL-990: at <= 820 px there is no collapsed rail any more (M1's level 1
   is full width) and the bell + chime live in the avatar sheet, so the
   rail's copy steps aside. Neither control is removed: both keep their
   accessible name in the menu copy. */
@media (max-width: 820px) {
  .notify-box--rail { display: none; }
  .notify-alerts, .notify-chime { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
</style>
