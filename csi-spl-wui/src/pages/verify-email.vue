<!-- /verify-email?token=<hex64> — the link in the email_verification mail
     (spec 015 contracts/native-auth-v1.md §3). POSTs the token once, then
     drops it from the URL (router.replace → history.replaceState) so a reload,
     the history list or a shared screenshot never carries it.

     Served from 200.html (not prerendered), so the token is read through
     useSettledQuery like /login's query. -->
<template>
  <div class="login-card" data-test="verify-email" :data-verify-state="state">
    <h1>Confirm email</h1>
    <p v-if="state === 'pending'" class="muted">Confirming…</p>
    <p v-else-if="state === 'ok'" role="status" data-test="verify-email-ok">Your email is confirmed — sign in.</p>
    <p v-else-if="state === 'missing'" class="login-error" role="alert">This link carries no token — open the link from the email again.</p>
    <p v-else-if="state === 'error'" class="login-error" role="alert" data-test="verify-email-error">{{ error }}</p>
    <p v-if="state === 'error' && expired" class="muted">Sign in again with your email and password to get a new link.</p>
    <p><NuxtLink to="/login">Go to sign in</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { computed, ref, watch } from 'vue'
import { nativeErrorMessage } from '~/utils/auth-client.mjs'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useAuthClient } from '~/composables/useAuthClient'

definePageMeta({ layout: 'login' })

const auth = useAuthClient()

const route = useRoute()
const router = useRouter()
const token = useSettledQuery('token')
const state = ref<'pending' | 'ok' | 'error' | 'missing'>('pending')
const error = ref('')
const code = ref('')
const expired = computed(() => code.value === 'verification_token_expired')
let posted = false

async function verify(tok: string) {
  if (posted || !tok) return
  posted = true
  const out = await auth.verifyEmail(tok)
  // §3: drop the token once posted
  const { token: _drop, ...rest } = route.query
  void router.replace({ query: rest })
  if (out.ok) {
    state.value = 'ok'
    return
  }
  code.value = out.error
  error.value = nativeErrorMessage(out)
  state.value = 'error'
}

watch(token.value, (tok) => { if (import.meta.client) void verify(tok) }, { immediate: true })
watch(token.missing, (m) => { if (m && !posted) state.value = 'missing' }, { immediate: true })
</script>
