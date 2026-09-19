<!-- /reset-password?token=<hex64> — the link in the password_reset mail
     (spec 015 contracts/native-auth-v1.md §3). The token is held in memory,
     POSTed with the new password, and dropped from the URL once posted
     (router.replace → history.replaceState). A 204 sets the password and
     marks the email verified but opens no session: the person signs in. -->
<template>
  <div class="login-card" data-test="reset-password" :data-reset-state="state">
    <h1>New password</h1>
    <p v-if="state === 'ok'" role="status" data-test="reset-password-ok">Your password is set — sign in with it.</p>
    <p v-else-if="token.missing.value && !held" class="login-error" role="alert">This link carries no token — ask for a new reset link.</p>
    <form v-else class="reset-password__form" novalidate @submit.prevent="submit">
      <label class="reset-password__field">
        <span>New password</span>
        <input v-model="password" type="password" autocomplete="new-password" required data-test="reset-password-new">
      </label>
      <label class="reset-password__field">
        <span>Repeat it</span>
        <input v-model="repeat" type="password" autocomplete="new-password" required data-test="reset-password-repeat">
      </label>
      <p v-if="error" class="login-error" role="alert" data-test="reset-password-error">{{ error }}</p>
      <button class="btn" type="submit" :disabled="busy || !held" data-test="reset-password-submit">Set password</button>
    </form>
    <p><NuxtLink to="/login">Go to sign in</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { ref, watch } from 'vue'
import { nativeErrorMessage } from '~/utils/auth-client.mjs'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useAuthClient } from '~/composables/useAuthClient'

definePageMeta({ layout: 'login' })

const auth = useAuthClient()

const route = useRoute()
const router = useRouter()
const token = useSettledQuery('token')
const held = ref('')
const password = ref('')
const repeat = ref('')
const busy = ref(false)
const error = ref('')
const state = ref<'form' | 'ok'>('form')

watch(token.value, (tok) => { if (tok && !held.value) held.value = tok }, { immediate: true })

async function submit() {
  if (busy.value || !held.value) return
  error.value = ''
  if (password.value !== repeat.value) {
    error.value = 'The two passwords differ.'
    return
  }
  busy.value = true
  try {
    const out = await auth.resetPassword({ token: held.value, password: password.value })
    // §3: drop the token once posted (kept in memory for a too-short retry)
    if (route.query.token !== undefined) {
      const { token: _drop, ...rest } = route.query
      void router.replace({ query: rest })
    }
    if (out.ok) {
      state.value = 'ok'
      held.value = ''
      password.value = ''
      repeat.value = ''
      return
    }
    error.value = nativeErrorMessage(out)
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.reset-password__form { display: grid; gap: 10px; margin-top: 12px; min-width: 0; }
.reset-password__field { display: grid; gap: 4px; font-size: 13px; color: var(--color-muted); min-width: 0; }
.reset-password__field input {
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
