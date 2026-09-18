<template>
  <form class="create-row" @submit.prevent="onSave">
    <input
      v-model="token"
      type="password"
      autocomplete="off"
      placeholder="view token"
      aria-label="View token"
    >
    <button class="btn ghost" type="submit">Use</button>
  </form>
</template>

<script setup lang="ts">
import { setViewToken } from '~/composables/useSpoolApi'

const emit = defineEmits<{ saved: [] }>()
const token = ref('')

function onSave() {
  setViewToken(token.value)
  token.value = ''
  emit('saved')
}
</script>
