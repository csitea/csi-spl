<!-- /verify-email?token=<hex64> — the link in the email_verification mail
     (spec 015 contracts/native-auth-v1.md §3). POSTs the token once, then
     drops it from the URL (router.replace → history.replaceState) so a reload,
     the history list or a shared screenshot never carries it.

     Served from 200.html (not prerendered), so the token is read through
     useSettledQuery like /login's query. -->
<template>
  <div class="login-card" data-test="verify-email" :data-verify-state="state">
    <h1>{{ t('auth.verify.title') }}</h1>
    <p v-if="state === 'pending'" class="muted">{{ t('auth.verify.pending') }}</p>
    <p v-else-if="state === 'ok'" role="status" data-test="verify-email-ok">{{ t('auth.verify.ok') }}</p>
    <p v-else-if="state === 'missing'" class="login-error" role="alert">{{ t('auth.verify.missing') }}</p>
    <p v-else-if="state === 'error'" class="login-error" role="alert" data-test="verify-email-error">{{ error }}</p>
    <p v-if="state === 'error' && expired" class="muted">{{ t('auth.verify.expired_hint') }}</p>
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
const state = ref<'pending' | 'ok' | 'error' | 'missing'>('pending')
/* the failed call, rendered in the active locale (spec 021) */
const errorOut = ref<NativeResult | null>(null)
const error = computed(() => copy.nativeError(errorOut.value))
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
  errorOut.value = out
  state.value = 'error'
}

watch(token.value, (tok) => { if (import.meta.client) void verify(tok) }, { immediate: true })
watch(token.missing, (m) => { if (m && !posted) state.value = 'missing' }, { immediate: true })
</script>
