<template>
  <div class="notify-box">
    <button class="btn ghost" type="button" @click="notes.requestPush()">
      {{ notes.permission === 'granted' ? t('notify.alerts_on') : t('notify.enable_alerts') }}
    </button>
    <label class="muted">
      <input v-model="notes.chime" type="checkbox"> {{ t('notify.chime') }}
    </label>
  </div>
</template>

<script setup lang="ts">
import { useNotificationStore } from '~/stores/notification'

const notes = useNotificationStore()
const { t } = useI18n({ useScope: 'global' })
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
</style>
