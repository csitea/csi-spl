<template>
  <div class="login-card login-landing-card">
    <h1>{{ t('auth.login.where_humans_meet') }}</h1>
    <p v-if="error" class="login-error" role="alert">{{ error }}</p>
    <SocialAuthButtons class="idp" :redirect="redirect" :tenant="tenant" />
    <NativeAuthForm v-if="session.state !== 'in'" :redirect="redirect" :tenant="tenant" />
    <p v-if="changed" class="muted" role="status" data-test="password-changed">{{ t('auth.login.password_changed') }}</p>
    <p v-if="session.state === 'unknown'" class="muted">{{ t('auth.login.session_unavailable') }}</p>
    <p v-if="session.state === 'in'" class="muted">
      {{ t('auth.login.signed_in_as', { who: session.label }) }} ·
      <NuxtLink :to="redirect">{{ t('auth.login.continue') }}</NuxtLink>
      ·
      <button class="btn ghost" type="button" @click="session.logout()">{{ t('auth.login.sign_out') }}</button>
    </p>
    <ChangePasswordForm v-if="session.state === 'in' && session.claims?.p === 'password'" @changed="changed = true" />
    <img
      class="login-landing"
      src="/login-landing.png"
      width="1214"
      height="490"
      :alt="t('auth.login.where_humans_meet')"
      data-test="login-landing"
    >
  </div>
</template>

<script setup lang="ts">
import { safeRedirect } from '~/utils/auth-client.mjs'
import SocialAuthButtons from '~/components/SocialAuthButtons.vue'
import NativeAuthForm from '~/components/NativeAuthForm.vue'
import ChangePasswordForm from '~/components/ChangePasswordForm.vue'
import { useSessionStore } from '~/stores/session'
import { useSpoolApi } from '~/composables/useSpoolApi'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useAuthCopy } from '~/composables/useAuthCopy'

definePageMeta({ layout: 'login' })

const route = useRoute()
const router = useRouter()
const session = useSessionStore()
const { t } = useI18n({ useScope: 'global' })
const copy = useAuthCopy()
/* the auth_error code, rendered in the active locale (spec 021) */
const errorCode = ref('')
const error = computed(() => copy.authError(errorCode.value))
/* 015 §2 password/change 204 clears the cookie: say why the form went away.
   Settings sets the same flag, then this page replaces that screen. */
const changedFromSettings = useState('settings-password-changed', () => false)
const changed = ref(changedFromSettings.value)
if (changedFromSettings.value) changedFromSettings.value = false
/* /login is prerendered: its query only exists once hydration settles. */
const redirectQ = useSettledQuery('redirect')
const tenantQ = useSettledQuery('tenant')
const authError = useSettledQuery('auth_error')
const redirect = computed(() => safeRedirect(redirectQ.value.value || '/'))
/* auth-v1 §1: tenant is optional on start; send the one the viewer reads from */
const tenant = computed(() => tenantQ.value.value || useSpoolApi().tenant || '')

watch(authError.value, (code) => {
  if (!code) return
  errorCode.value = String(code)
  // auth-v1 §2: drop auth_error so a reload does not repeat it; keep redirect
  const { auth_error: _drop, ...rest } = route.query
  void router.replace({ query: rest })
}, { immediate: true })

onMounted(() => { void session.probe() })
</script>

<style scoped>
.login-landing-card {
  width: min(880px, 100%);
  padding-bottom: 0;
  overflow: hidden;
  text-align: center;
}
/* A centered card still types from the start of the field. */
.login-landing-card :deep(input),
.login-landing-card :deep(textarea) {
  text-align: start;
}
.login-landing {
  display: block;
  width: calc(100% + 48px);
  max-width: none;
  height: auto;
  margin: 16px -24px 0;
}
</style>
