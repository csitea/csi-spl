<!-- Settings -> Notifications (owner, 2026-09-26: "those enable alerts, chime
     settings should be in the personal settings of each user"). The same
     notification store as the icon row at the foot of the left pane, so the
     two always agree. Browser alerts are a permission of THIS browser; the
     chime is kept per browser as well (loadChime / saveChime). -->
<template>
  <SettingsSection id="settings-notifications" :title="t('settings.notifications')" data-test="settings-notifications">
    <div class="settings__row">
      <span>{{ t('notify.enable_alerts') }}</span>
      <button
        type="button"
        class="btn"
        data-test="settings-notify-alerts"
        :aria-pressed="alertsWanted"
        @click="notes.toggleAlerts()"
      >
        <UiIcon :name="alertsWanted ? 'bell' : 'bell-off'" :size="18" />
        {{ alertsWanted ? t('notify.alerts_on') : t('notify.enable_alerts') }}
      </button>
    </div>
    <div class="settings__row">
      <label for="settings-chime">{{ t('notify.chime') }}</label>
      <input id="settings-chime" v-model="notes.chime" type="checkbox" data-test="settings-notify-chime">
    </div>
  </SettingsSection>
</template>

<script setup lang="ts">
import SettingsSection from '~/components/SettingsSection.vue'
import { useNotificationStore } from '~/stores/notification'

const { t } = useI18n({ useScope: 'global' })
const notes = useNotificationStore()
const alertsWanted = computed(() => notes.alertsEnabled)
</script>

<style scoped>
.settings__row {
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  flex-wrap: wrap;
  min-height: var(--tap, 44px);
}
.settings__row .btn { display: inline-flex; align-items: center; gap: 6px; }
</style>
