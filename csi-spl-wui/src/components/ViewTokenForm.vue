<template>
  <div class="door-prompt" data-testid="view-door">
    <p class="muted">This tenant's threads need a member sign-in<template v-if="modes.token"> or a view token</template>.</p>
    <p v-if="modes.session">
      <a class="btn" :href="href">Sign in</a>
    </p>
    <form v-if="modes.token" class="create-row" @submit.prevent="onSave">
      <input
        v-model="token"
        type="password"
        autocomplete="off"
        placeholder="view token"
        aria-label="View token"
      >
      <button class="btn ghost" type="submit">Use</button>
    </form>
  </div>
</template>

<script setup lang="ts">
import { setViewToken, useSpoolApi } from '~/composables/useSpoolApi'
import { doorModes, signInHref } from '~/utils/live-follow.mjs'

/* view-v1 §2: the door prompt for a 401 view_door. The hub's detail names the
   ways in; no detail → both (sign in, view token). */
const props = defineProps<{ detail?: string }>()
const emit = defineEmits<{ saved: [] }>()
const token = ref('')
const route = useRoute()
const modes = computed(() => doorModes(props.detail))
const href = computed(() => signInHref(route.fullPath, useSpoolApi().tenant))

function onSave() {
  setViewToken(token.value)
  token.value = ''
  emit('saved')
}
</script>
