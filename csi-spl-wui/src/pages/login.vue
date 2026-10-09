<template>
  <div class="login-card login-landing-card">
    <h1>{{ t('auth.login.where_humans_meet') }}</h1>
    <p v-if="error" class="login-error" role="alert">{{ error }}</p>
    <!-- HUM-10 fb8d109f: the session this browser held ended (expired or
         revoked), so say so plainly instead of a bare sign-in page -->
    <p v-if="ended" class="login-error" role="status" data-test="session-ended">{{ t('auth.native_error.unauthenticated') }}</p>
    <!-- SPL-1231: arriving from an invite, say which address was invited and
         which sign-in owns it, so the invitee does not bounce between providers. -->
    <div v-if="invited && session.state !== 'in'" class="login-invite-hint" role="note" data-test="login-invite-hint">
      <p data-test="login-invite-email">{{ t('auth.login.invited_as', { email: invited }) }}</p>
      <p class="muted" :data-test="`login-invite-use-${hinted || 'any'}`">{{ t(`auth.login.invited_use_${hinted || 'any'}`) }}</p>
    </div>
    <SocialAuthButtons class="idp" :redirect="socialRedirect" :tenant="tenant" :login-hint="invited" :suggested="hinted" />
    <NativeAuthForm v-if="session.state !== 'in'" :redirect="redirect" :tenant="tenant" :email="invited" />
    <!-- specs/077 T020: the demo intro, only while GET /v1/demo answers 200;
         Lazy: its own chunk, fetched only then. BELOW the sign-in buttons
         (owner HUM-10, 2026-10-05, msg 39c26092). -->
    <LazyDemoIntro v-if="demo && session.state !== 'in'" class="login-demo" :workspace="demo.workspace" :max-live="demo.maxLive" :redirect="redirect" />
    <p v-if="changed" class="muted" role="status" data-test="password-changed">{{ t('auth.login.password_changed') }}</p>
    <p v-if="session.state === 'unknown'" class="muted">{{ t('auth.login.session_unavailable') }}</p>
    <p v-if="session.state === 'in'" class="muted">
      {{ t('auth.login.signed_in_as', { who: session.label }) }} ·
      <NuxtLink :to="redirect">{{ t('auth.login.continue') }}</NuxtLink>
      ·
      <button class="btn ghost" type="button" @click="session.logout()">{{ t('auth.login.sign_out') }}</button>
    </p>
    <ChangePasswordForm v-if="session.state === 'in' && session.claims?.p === 'password'" @changed="changed = true" />
    <!-- W14 (spec 047): the help pages, also before sign-in -->
    <p class="muted login-help"><NuxtLink :to="localePath('/help')" data-test="login-help">{{ t('help.title') }}</NuxtLink></p>
  </div>
</template>

<script setup lang="ts">
import { hintedProvider, loginHintOf, safeRedirect } from '~/utils/auth-client.mjs'
import SocialAuthButtons from '~/components/SocialAuthButtons.vue'
import NativeAuthForm from '~/components/NativeAuthForm.vue'
import ChangePasswordForm from '~/components/ChangePasswordForm.vue'
import { useSessionStore } from '~/stores/session'
import { hostTenant, useSpoolApi } from '~/composables/useSpoolApi'
import { useSettledQuery } from '~/composables/useSettledQuery'
import { useAuthCopy } from '~/composables/useAuthCopy'
import { takeEarlyLoginFlag } from '~/utils/signed-out-hint.mjs'
import { loadDemo } from '~/utils/demo-info.mjs'
import { ENDED_QUERY, markSignedIn } from '~/utils/session-recover.mjs'

definePageMeta({ layout: 'login' })

const route = useRoute()
const router = useRouter()
const localePath = useLocalePath()
const session = useSessionStore()
const { t } = useI18n({ useScope: 'global' })
const copy = useAuthCopy()
/* spec 116 T7: the front page's search-engine head (robots, canonical, og, JSON-LD) */
usePublicSeo()
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
/* SPL-1231: ?login_hint=<the invited address> (the invite mail / copied link) */
const hintQ = useSettledQuery('login_hint')
const invited = computed(() => loginHintOf(hintQ.value.value))
const hinted = computed(() => hintedProvider(invited.value))
/* HUM-10 fb8d109f: ?ended=1 from the signed-out redirect (session-recover.mjs) */
const endedQ = useSettledQuery(ENDED_QUERY)
const ended = computed(() => endedQ.value.value === '1' && session.state !== 'in' && !error.value)
/* said once: a later visit to a bare /login on this browser is not an ending */
watch(ended, (on) => { if (on) markSignedIn(false) }, { immediate: true })
const redirect = computed(() => safeRedirect(redirectQ.value.value || '/'))
/* auth-v1 §1: tenant is optional on start; send the one the viewer reads from */
const tenant = computed(() => tenantQ.value.value || useSpoolApi().tenant || '')
/* SPL-959: the OAuth callback lands on the apex (its registered host). From a
   tenant host, the return path carries ?tenant=<t> so the apex hops back
   there (plugins/tenant-host.client.ts). Native sign-in stays on this host. */
const socialRedirect = computed(() => {
  const host = hostTenant()
  const apex = String(useRuntimeConfig().public.tenant || '')
  if (!host || host === apex) return redirect.value
  const [path, hash = ''] = redirect.value.split('#', 2)
  return path + (path.includes('?') ? '&' : '?') + 'tenant=' + host + (hash ? '#' + hash : '')
})

watch(authError.value, (code) => {
  if (!code) return
  errorCode.value = String(code)
  // auth-v1 §2: drop auth_error so a reload does not repeat it; keep redirect
  const { auth_error: _drop, ...rest } = route.query
  void router.replace({ query: rest })
}, { immediate: true })

/* specs/077 T020: the demo and its live limits; null (flag off, 404) = no
   intro. The mock tenant has no hub: it asks its own origin, which never
   answers a demo (e2e answers it in the browser). */
const demo = ref<{ workspace: string, maxLive: number } | null>(null)
onMounted(() => {
  void session.probe()
  const api = useSpoolApi()
  void loadDemo(api.mock ? '' : api.base).then((d) => { demo.value = d })
})

/* P3-02: the document-head script sent this tab here on this browser's
   "signed out" hint. A hint can be stale (signed in where the WUI did not
   see it): a session that reads 'in' goes on to the page asked for. */
let earlyLogin = import.meta.client && takeEarlyLoginFlag(window.sessionStorage)
if (earlyLogin) {
  watch(() => [session.state, redirectQ.settled.value] as const, ([s, settled]) => {
    if (!earlyLogin || !settled || s === 'loading') return
    earlyLogin = false
    if (s === 'in') void navigateTo(redirect.value, { replace: true })
  }, { immediate: true })
}
</script>

<style scoped>
.login-landing-card {
  width: min(880px, 100%);
  text-align: center;
}
/* A centered card still types from the start of the field. */
.login-invite-hint {
  margin: 0 auto 12px;
  max-width: 34rem;
}
.login-invite-hint p {
  margin: 4px 0;
}
/* the demo intro sits under the sign-in buttons: space above, not below */
.login-landing-card .login-demo {
  margin: 18px auto 0;
}
.login-landing-card :deep(input),
.login-landing-card :deep(textarea) {
  text-align: start;
}
</style>
