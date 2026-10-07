<!-- /reset-password?token=<hex64> — the link in the password_reset mail
     (spec 015 contracts/native-auth-v1.md §3). The token is held in memory,
     POSTed with the new password, and dropped from the URL once posted
     (router.replace → history.replaceState). A 200 (t1 ea0af569, owner HUM-10
     msg 2a57fe20: "open link, set new password, land in the app") sets the
     password AND signs the person in: the page adopts the session and goes
     into the app. A 204 (an older hub, or a sign-in the hub could not open)
     sets the password only: the person signs in. -->
<template>
  <div class="login-card" data-test="reset-password" :data-reset-state="state">
    <h1>{{ t('auth.reset.title') }}</h1>
    <p v-if="state === 'ok'" role="status" data-test="reset-password-ok">{{ t('auth.reset.ok') }}</p>
    <p v-else-if="token.missing.value && !held" class="login-error" role="alert">{{ t('auth.reset.missing') }}</p>
    <form v-else class="reset-password__form" novalidate @submit.prevent="submit">
      <label class="reset-password__field">
        <span>{{ t('auth.reset.new') }}</span>
        <input v-model="password" type="password" autocomplete="new-password" required data-test="reset-password-new">
      </label>
      <label class="reset-password__field">
        <span>{{ t('auth.reset.repeat') }}</span>
        <input v-model="repeat" type="password" autocomplete="new-password" required data-test="reset-password-repeat">
      </label>
      <p v-if="error" class="login-error" role="alert" data-test="reset-password-error">{{ error }}</p>
      <button class="btn" type="submit" :disabled="busy || !held" data-test="reset-password-submit">{{ t('auth.reset.submit') }}</button>
    </form>
    <p><NuxtLink :to="localePath('/login')">{{ t('auth.go_to_sign_in') }}</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { safeRedirect, type NativeResult } from '~/utils/auth-client.mjs'
import { useSessionStore, type SessionClaims } from '~/stores/session'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAuthCopy } from '~/composables/useAuthCopy'

definePageMeta({ layout: 'login' })

const auth = useAuthClient()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const copy = useAuthCopy()
const session = useSessionStore()

const route = useRoute()
const router = useRouter()
const token = useSettledQuery('token')
const held = ref('')
const password = ref('')
const repeat = ref('')
const busy = ref(false)
/* a catalogue key (local check) or the failed call, rendered in the active locale (spec 021) */
const errorKey = ref('')
const errorOut = ref<NativeResult | null>(null)
const error = computed(() => (errorKey.value ? t(errorKey.value) : copy.nativeError(errorOut.value)))
const state = ref<'form' | 'ok'>('form')

watch(token.value, (tok) => { if (tok && !held.value) held.value = tok }, { immediate: true })

async function submit() {
  if (busy.value || !held.value) return
  errorKey.value = ''
  errorOut.value = null
  if (password.value !== repeat.value) {
    errorKey.value = 'auth.reset.mismatch'
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
    if (out.ok && out.status === 200 && out.data && (out.data as SessionClaims).p) {
      const { redirect: to, ...claims } = out.data as SessionClaims & { redirect?: string }
      session.adopt(claims)
      held.value = ''
      password.value = ''
      repeat.value = ''
      await navigateTo(localePath(safeRedirect(to || '/')))
      return
    }
    if (out.ok) {
      state.value = 'ok'
      held.value = ''
      password.value = ''
      repeat.value = ''
      return
    }
    errorOut.value = out
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.reset-password__form { display: grid; gap: 10px; margin-top: 12px; min-width: 0; }
.reset-password__field { display: grid; gap: 4px; font-size: 0.8125rem; color: var(--color-muted); min-width: 0; }
.reset-password__field input {
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
