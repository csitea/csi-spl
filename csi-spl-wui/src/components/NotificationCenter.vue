<template>
  <div class="notify-box">
    <button class="btn ghost" type="button" @click="notes.requestPush()">
      {{ notes.permission === 'granted' ? 'alerts on' : 'enable alerts' }}
    </button>
    <label class="muted">
      <input v-model="notes.chime" type="checkbox"> chime
    </label>
  </div>
</template>

<script setup lang="ts">
import { useNotificationStore } from '~/stores/notification'

const notes = useNotificationStore()
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
