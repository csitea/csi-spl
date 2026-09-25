<!-- ChangePasswordForm — native-auth-v1 §2 `password/change`, for a session
     with p:"password" only. A 204 clears the cookie, so the person signs in
     again with the new password. -->
<template>
  <form class="native-auth__form change-password" data-test="change-password" novalidate @submit.prevent="submit">
    <h2 class="change-password__title">{{ t('auth.change_password.title') }}</h2>
    <label class="native-auth__field">
      <span>{{ t('auth.change_password.current') }}</span>
      <input v-model="current" type="password" autocomplete="current-password" required data-test="change-password-current">
    </label>
    <label class="native-auth__field">
      <span>{{ t('auth.change_password.new') }}</span>
      <input v-model="next" type="password" autocomplete="new-password" required data-test="change-password-new">
    </label>
    <p v-if="error" class="login-error" role="alert" data-test="change-password-error">{{ error }}</p>
    <button class="btn" type="submit" :disabled="busy" data-test="change-password-submit">{{ t('auth.change_password.submit') }}</button>
  </form>
</template>

<script setup lang="ts">
import { computed, ref } from 'vue'
import type { NativeResult } from '~/utils/auth-client.mjs'
import { useSessionStore } from '~/stores/session'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAuthCopy } from '~/composables/useAuthCopy'

const emit = defineEmits<{ changed: [] }>()
const auth = useAuthClient()
const session = useSessionStore()
const current = ref('')
const next = ref('')
const busy = ref(false)
const { t } = useI18n({ useScope: 'global' })
const copy = useAuthCopy()
/* the failed call, rendered in the active locale (spec 021) */
const errorOut = ref<NativeResult | null>(null)
const error = computed(() => copy.nativeError(errorOut.value))

async function submit() {
  if (busy.value) return
  busy.value = true
  errorOut.value = null
  try {
    const out = await auth.changePassword({ current: current.value, next: next.value })
    if (!out.ok) {
      errorOut.value = out
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
.change-password__title { font-size: 0.9375rem; margin: 0; }
.native-auth__field { display: grid; gap: 4px; font-size: 0.8125rem; color: var(--color-muted); min-width: 0; }
.native-auth__field input {
  min-width: 0;
  max-width: 100%;
  box-sizing: border-box;
  background: var(--color-composer);
  border: 1px solid var(--color-border);
  color: var(--color-fg);
  border-radius: var(--radius-sm);
  padding: 6px 8px;
  min-height: var(--tap);
}
</style>
