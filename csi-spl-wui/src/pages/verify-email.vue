<!-- /verify-email?token=<hex64> — the link in the email_verification mail
     (spec 015 contracts/native-auth-v1.md §3). The token is held in memory,
     POSTed with the password, and dropped from the URL once posted
     (router.replace → history.replaceState), like /reset-password.

     The person confirms the password they signed up with (CLE-34986): the
     click proves the MAILBOX, not who chose the password, so without it
     anyone could register someone else's address with their own password
     and have the owner's click verify it. The hub refuses a verify without
     the password the link was issued for, and consumes nothing on a miss.

     Served from 200.html (not prerendered), so the token is read through
     useSettledQuery like /login's query. -->
<template>
  <div class="login-card" data-test="verify-email" :data-verify-state="state">
    <h1>{{ t('auth.verify.title') }}</h1>
    <p v-if="state === 'ok'" role="status" data-test="verify-email-ok">{{ t('auth.verify.ok') }}</p>
    <p v-else-if="token.missing.value && !held" class="login-error" role="alert">{{ t('auth.verify.missing') }}</p>
    <form v-else class="verify-email__form" novalidate @submit.prevent="submit">
      <label class="verify-email__field">
        <span>{{ t('auth.verify.password') }}</span>
        <input v-model="password" type="password" autocomplete="current-password" required data-test="verify-email-password">
      </label>
      <p v-if="error" class="login-error" role="alert" data-test="verify-email-error">{{ error }}</p>
      <p v-if="expired" class="muted">{{ t('auth.verify.expired_hint') }}</p>
      <button class="btn" type="submit" :disabled="busy || !held || !password" data-test="verify-email-submit">{{ t('auth.verify.title') }}</button>
    </form>
    <p><NuxtLink :to="localePath('/login')">{{ t('auth.go_to_sign_in') }}</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import type { NativeResult } from '~/utils/auth-client.mjs'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useAuthClient } from '~/composables/useAuthClient'
import { useAuthCopy } from '~/composables/useAuthCopy'

definePageMeta({ layout: 'login' })

const auth = useAuthClient()
const { t } = useI18n({ useScope: 'global' })
const localePath = useLocalePath()
const copy = useAuthCopy()

const route = useRoute()
const router = useRouter()
const token = useSettledQuery('token')
const held = ref('')
const password = ref('')
const busy = ref(false)
/* the failed call, rendered in the active locale (spec 021) */
const errorOut = ref<NativeResult | null>(null)
const error = computed(() => copy.nativeError(errorOut.value))
const expired = computed(() => errorOut.value?.error === 'verification_token_expired')
const state = ref<'form' | 'ok'>('form')

watch(token.value, (tok) => { if (tok && !held.value) held.value = tok }, { immediate: true })

async function submit() {
  if (busy.value || !held.value || !password.value) return
  errorOut.value = null
  busy.value = true
  try {
    const out = await auth.verifyEmail({ token: held.value, password: password.value })
    // §3: drop the token once posted (kept in memory for a wrong-password retry)
    if (route.query.token !== undefined) {
      const { token: _drop, ...rest } = route.query
      void router.replace({ query: rest })
    }
    if (out.ok) {
      state.value = 'ok'
      held.value = ''
      password.value = ''
      return
    }
    errorOut.value = out
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.verify-email__form { display: grid; gap: 10px; margin-top: 12px; min-width: 0; }
.verify-email__field { display: grid; gap: 4px; font-size: 0.8125rem; color: var(--color-muted); min-width: 0; }
.verify-email__field input {
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
