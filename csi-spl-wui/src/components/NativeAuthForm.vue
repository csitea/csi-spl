<!-- NativeAuthForm — email + password sign-in, register and forgot-password
     (spec 015 contracts/native-auth-v1.md §2, §4).

     Rendered only when GET /api/v1/auth/providers answers "native": true; with
     native off the component is an empty, invisible container (like
     SocialAuthButtons it is fetched client-side, so SSR and hydration agree).
     The container always carries data-native-auth = idle | on | off for a
     monitor.

     Resend is register again with the same email + password (§1): the
     "Send the link again" button re-posts what the person typed, because only
     the newest link verifies and it carries that call's password.

     debug_token (lde/dev only, §1) is shown as a dev link and never relied on. -->
<template>
  <div class="native-auth" data-test="native-auth" :data-native-auth="status">
    <form v-if="status === 'on'" class="native-auth__form" novalidate @submit.prevent="submit">
      <div class="native-auth__tabs" role="tablist">
        <button
          v-for="m in MODES"
          :key="m.id"
          type="button"
          role="tab"
          class="native-auth__tab"
          :class="{ 'is-active': mode === m.id }"
          :aria-selected="mode === m.id"
          :data-test="`native-auth-tab-${m.id}`"
          @click="setMode(m.id)"
        >{{ m.label }}</button>
      </div>

      <label v-if="mode === 'register'" class="native-auth__field">
        <span>Name (optional)</span>
        <input v-model="name" type="text" autocomplete="name" data-test="native-auth-name">
      </label>
      <label class="native-auth__field">
        <span>Email</span>
        <input v-model="email" type="email" autocomplete="email" required data-test="native-auth-email">
      </label>
      <label v-if="mode !== 'forgot'" class="native-auth__field">
        <span>Password</span>
        <input
          v-model="password"
          type="password"
          :autocomplete="mode === 'register' ? 'new-password' : 'current-password'"
          required
          data-test="native-auth-password"
        >
      </label>

      <p v-if="error" class="login-error" role="alert" data-test="native-auth-error">{{ error }}</p>
      <p v-if="notice" class="native-auth__notice" role="status" data-test="native-auth-notice">{{ notice }}</p>
      <p v-if="debugHref" class="native-auth__debug" data-test="native-auth-debug">
        dev: <NuxtLink :to="debugHref">{{ debugLabel }}</NuxtLink>
      </p>

      <button class="btn native-auth__submit" type="submit" :disabled="busy" data-test="native-auth-submit">
        {{ SUBMIT[mode] }}
      </button>
      <button
        v-if="canResend"
        class="btn ghost"
        type="button"
        :disabled="busy"
        data-test="native-auth-resend"
        @click="resend"
      >Send the link again</button>
    </form>
  </div>
</template>

<script setup lang="ts">
import { computed, onMounted, ref } from 'vue'
import { createAuthClient, nativeErrorMessage, safeRedirect, type NativeResult } from '~/utils/auth-client.mjs'
import { useSessionStore, type SessionClaims } from '~/stores/session'

const props = withDefaults(defineProps<{
  redirect?: string
  tenant?: string
}>(), { redirect: '/', tenant: '' })

type Mode = 'login' | 'register' | 'forgot'
const MODES: { id: Mode, label: string }[] = [
  { id: 'login', label: 'Sign in' },
  { id: 'register', label: 'Create account' },
  { id: 'forgot', label: 'Forgot password' },
]
const SUBMIT: Record<Mode, string> = { login: 'Sign in', register: 'Create account', forgot: 'Send reset link' }

const auth = createAuthClient()
const session = useSessionStore()
const status = ref<'idle' | 'on' | 'off'>('idle')
const mode = ref<Mode>('login')
const email = ref('')
const password = ref('')
const name = ref('')
const busy = ref(false)
const error = ref('')
const notice = ref('')
const lastError = ref('')
const debugHref = ref('')
const debugLabel = ref('')

/* resend = register again (§1); offered where the §4 copy promises it */
const canResend = computed(() => ['email_unverified', 'verification_token_expired'].includes(lastError.value)
  || (mode.value === 'register' && notice.value !== ''))

onMounted(async () => {
  const out = await auth.loadProviders()
  status.value = out.native ? 'on' : 'off'
})

function setMode(m: Mode) {
  mode.value = m
  error.value = ''
  notice.value = ''
  lastError.value = ''
  debugHref.value = ''
}

function fail(out: NativeResult) {
  lastError.value = out.error
  error.value = nativeErrorMessage(out)
}

function showDebug(out: NativeResult, path: string, label: string) {
  const tok = out.data && typeof out.data.debug_token === 'string' ? out.data.debug_token : ''
  debugHref.value = tok ? `${path}?token=${encodeURIComponent(tok)}` : ''
  debugLabel.value = label
}

async function register() {
  const out = await auth.register({ email: email.value, password: password.value, name: name.value || undefined })
  if (!out.ok) return fail(out)
  notice.value = out.data && out.data.status === 'registered'
    ? 'Account created — sign in.'
    : 'Check your inbox: we sent a link to confirm your email.'
  showDebug(out, '/verify-email', 'open the verify link')
}

async function submit() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  notice.value = ''
  lastError.value = ''
  debugHref.value = ''
  try {
    if (mode.value === 'login') {
      const out = await auth.login({ email: email.value, password: password.value, tenant: props.tenant, redirect: props.redirect })
      if (!out.ok) return fail(out)
      const { redirect: to, ...claims } = (out.data || {}) as SessionClaims & { redirect?: string }
      session.adopt(claims)
      password.value = ''
      await navigateTo(safeRedirect(to || props.redirect))
    } else if (mode.value === 'register') {
      await register()
    } else {
      const out = await auth.forgotPassword(email.value)
      if (!out.ok) return fail(out)
      notice.value = 'If that address has an account, a reset link is on its way.'
      showDebug(out, '/reset-password', 'open the reset link')
    }
  } finally {
    busy.value = false
  }
}

async function resend() {
  if (busy.value) return
  busy.value = true
  error.value = ''
  try {
    await register()
  } finally {
    busy.value = false
  }
}
</script>

<style scoped>
.native-auth { margin-top: 18px; min-width: 0; max-width: 100%; }
.native-auth:empty { display: none; }
.native-auth__form { display: grid; gap: 10px; min-width: 0; }
.native-auth__tabs { display: flex; flex-wrap: wrap; gap: 4px; }
.native-auth__tab {
  flex: 1 1 auto;
  min-height: var(--tap);
  border: 1px solid var(--color-border);
  border-radius: 8px;
  background: transparent;
  color: var(--color-muted);
  cursor: pointer;
}
.native-auth__tab.is-active { color: var(--color-fg); background: var(--color-surface-hover); font-weight: 600; }
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
.native-auth__submit { min-height: var(--tap); }
.native-auth__notice, .native-auth__debug { margin: 0; }
</style>
