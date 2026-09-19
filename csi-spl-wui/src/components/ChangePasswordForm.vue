<!-- ChangePasswordForm — native-auth-v1 §2 `password/change`, for a session
     with p:"password" only. A 204 clears the cookie, so the person signs in
     again with the new password. -->
<template>
  <form class="native-auth__form change-password" data-test="change-password" novalidate @submit.prevent="submit">
    <h2 class="change-password__title">Change password</h2>
    <label class="native-auth__field">
      <span>Current password</span>
      <input v-model="current" type="password" autocomplete="current-password" required data-test="change-password-current">
    </label>
    <label class="native-auth__field">
      <span>New password</span>
      <input v-model="next" type="password" autocomplete="new-password" required data-test="change-password-new">
    </label>
    <p v-if="error" class="login-error" role="alert" data-test="change-password-error">{{ error }}</p>
    <button class="btn" type="submit" :disabled="busy" data-test="change-password-submit">Change password</button>
  </form>
</template>

<script setup lang="ts">
import { ref } from 'vue'
import { createAuthClient, nativeErrorMessage } from '~/utils/auth-client.mjs'
import { useSessionStore } from '~/stores/session'

const emit = defineEmits<{ changed: [] }>()
const auth = createAuthClient()
const session = useSessionStore()
const current = ref('')
const next = ref('')
const busy = ref(false)
const error = ref('')

async function submit() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    const out = await auth.changePassword({ current: current.value, next: next.value })
    if (!out.ok) {
      error.value = nativeErrorMessage(out)
      if (out.error === 'unauthenticated') session.signedOut()
      return
    }
    current.value = ''
    next.value = ''
    session.signedOut()
    emit('changed')
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.change-password { display: grid; gap: 10px; margin-top: 18px; min-width: 0; }
.change-password__title { font-size: 15px; margin: 0; }
.native-auth__field { display: grid; gap: 4px; font-size: 13px; color: var(--color-muted); min-width: 0; }
.native-auth__field input {
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
  background: var(--color-composer);
  border: 1px solid var(--color-border);
  color: var(--color-fg);
  border-radius: 6px;
  padding: 6px 8px;
  min-height: var(--tap);
}
</style>
