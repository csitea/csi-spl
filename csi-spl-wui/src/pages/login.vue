<template>
  <div class="login-card">
    <h1>Spool</h1>
    <p v-if="error" class="login-error" role="alert">{{ error }}</p>
    <SocialAuthButtons class="idp" :redirect="redirect" :tenant="tenant" />
    <p v-if="session.state === 'unknown'" class="muted">Session unavailable — the hub did not answer.</p>
    <p v-if="session.state === 'in'" class="muted">
      Signed in as {{ session.label }} ·
      <button class="btn ghost" type="button" @click="session.logout()">Sign out</button>
    </p>
    <p><NuxtLink :to="redirect">Continue to threads</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { authErrorMessage, safeRedirect } from '~/utils/auth-client.mjs'
import SocialAuthButtons from '~/components/SocialAuthButtons.vue'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSettledQuery } from '~/composables/useSettledQuery'

definePageMeta({ layout: 'login' })

const route = useRoute()
const router = useRouter()
const session = useSessionStore()
const error = ref('')
/* /login is prerendered: its query only exists once hydration settles. */
const redirectQ = useSettledQuery('redirect')
const tenantQ = useSettledQuery('tenant')
const authError = useSettledQuery('auth_error')
const redirect = computed(() => safeRedirect(redirectQ.value.value || '/'))
/* auth-v1 §1: tenant is optional on start; send the one the viewer reads from */
const tenant = computed(() => tenantQ.value.value || useSpoolApi().tenant || '')

watch(authError.value, (code) => {
  if (!code) return
  error.value = authErrorMessage(code)
  // auth-v1 §2: drop auth_error so a reload does not repeat it; keep redirect
  const { auth_error: _drop, ...rest } = route.query
  void router.replace({ query: rest })
}, { immediate: true })

onMounted(() => { void session.probe() })
</script>
