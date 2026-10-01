<!-- SocialAuthButtons — one sign-in control per enabled IdP, registry-driven
     (ported from the donor WUI, fitted to spec 010 contracts/auth-v1.md §4).

     The set of providers comes from the hub (GET /api/v1/auth/providers), in
     cnf order — NOT a hardcoded pair — so a provider the hub enables appears
     with zero WUI change. Each button is a plain <a> to the hub's start route
     on the auth base (the hub's API origin, NUXT_PUBLIC_AUTH_BASE; '' in lde,
     where the Nitro devProxy serves it same-origin): the OAuth dance is a full-page redirect, never fetch(),
     and no IdP SDK is loaded, so nothing is requested from an IdP until the
     visitor clicks.

     auth-v1 §4 asks for one LARGE primary button per provider with the words
     "Continue with <Provider>", so unlike the donor's icon-only marks the
     label is always visible; the brand logo sits beside it.

     Graceful degradation, but NOT silent. The list is fetched client-side and
     starts empty, so an unreachable registry renders the page fine with no
     buttons and no hydration mismatch — which also means the server HTML is
     identical whether sign-in works or is broken. The container is therefore
     ALWAYS rendered and carries the registry state for a monitor (a real
     browser is still needed to read it):

       data-social-auth-status  idle | ok | unavailable
       data-social-auth-count   how many buttons are shown

     `unavailable` means the hub could not be asked, and is also written to
     the error journal; `ok` with a count of 0 and no native sign-in is an env
     with auth off. -->
<template>
  <div
    class="social-auth"
    data-test="social-auth"
    :data-social-auth-status="status"
    :data-social-auth-count="providers.length"
  >
    <a
      v-for="p in providers"
      :key="p"
      class="btn social-auth__btn"
      :class="[`social-auth__btn--${p}`, { 'social-auth__btn--suggested': p === suggested }]"
      :data-test="`social-auth-${p}`"
      :data-suggested="p === suggested ? 'true' : undefined"
      :href="startHref(p, redirect, tenant, authBase, loginHint)"
      rel="nofollow"
    >
      <span class="social-auth__mark" aria-hidden="true">
        <svg
          v-if="p === 'google'"
          class="social-auth__logo"
          viewBox="0 0 24 24"
          data-test="social-logo-google"
        >
          <path fill="#4285F4" d="M22.56 12.25c0-.78-.07-1.53-.2-2.25H12v4.26h5.92c-.26 1.37-1.04 2.53-2.21 3.31v2.77h3.57c2.08-1.92 3.28-4.74 3.28-8.09z" />
          <path fill="#34A853" d="M12 23c2.97 0 5.46-.98 7.28-2.66l-3.57-2.77c-.98.66-2.23 1.06-3.71 1.06-2.86 0-5.29-1.93-6.16-4.53H2.18v2.84C3.99 20.53 7.7 23 12 23z" />
          <path fill="#FBBC05" d="M5.84 14.09c-.22-.66-.35-1.36-.35-2.09s.13-1.43.35-2.09V7.07H2.18C1.43 8.55 1 10.22 1 12s.43 3.45 1.18 4.93l2.85-2.22.81-.62z" />
          <path fill="#EA4335" d="M12 5.38c1.62 0 3.06.56 4.21 1.64l3.15-3.15C17.45 2.09 14.97 1 12 1 7.7 1 3.99 3.47 2.18 7.07l3.66 2.84c.87-2.6 3.3-4.53 6.16-4.53z" />
        </svg>
        <svg
          v-else-if="p === 'facebook'"
          class="social-auth__logo"
          viewBox="0 0 24 24"
          data-test="social-logo-facebook"
        >
          <path fill="currentColor" d="M22 12c0-5.52-4.48-10-10-10S2 6.48 2 12c0 4.84 3.44 8.87 8 9.8V15H8v-3h2V9.5C10 7.57 11.57 6 13.5 6H16v3h-2c-.55 0-1 .45-1 1v2h3v3h-3v6.95c5.05-.5 9-4.76 9-9.95z" />
        </svg>
        <svg
          v-else-if="p === 'microsoft'"
          class="social-auth__logo"
          viewBox="0 0 21 21"
          data-test="social-logo-microsoft"
        >
          <!-- Official MS-SymbolLockup (identity platform branding). -->
          <rect x="1" y="1" width="9" height="9" fill="#f25022" />
          <rect x="1" y="11" width="9" height="9" fill="#00a4ef" />
          <rect x="11" y="1" width="9" height="9" fill="#7fba00" />
          <rect x="11" y="11" width="9" height="9" fill="#ffb900" />
        </svg>
        <svg
          v-else-if="p === 'linkedin'"
          class="social-auth__logo"
          viewBox="0 0 72 72"
          data-test="social-logo-linkedin"
        >
          <!-- Official LinkedIn [in] Logo; fill is current LinkedIn Blue. -->
          <path fill="#0A66C2" d="M8 72h56c4.418 0 8-3.582 8-8V8c0-4.418-3.582-8-8-8H8C3.582 0 0 3.582 0 8v56c0 4.418 3.582 8 8 8z" />
          <path fill="#FFF" d="M62,62 L51.315625,62 L51.315625,43.8021149 C51.315625,38.8127542 49.4197917,36.0245323 45.4707031,36.0245323 C41.1746094,36.0245323 38.9300781,38.9261103 38.9300781,43.8021149 L38.9300781,62 L28.6333333,62 L28.6333333,27.3333333 L38.9300781,27.3333333 L38.9300781,32.0029283 C38.9300781,32.0029283 42.0260417,26.2742151 49.3825521,26.2742151 C56.7356771,26.2742151 62,30.7644705 62,40.051212 L62,62 Z M16.349349,22.7940133 C12.8420573,22.7940133 10,19.9296567 10,16.3970067 C10,12.8643566 12.8420573,10 16.349349,10 C19.8566406,10 22.6970052,12.8643566 22.6970052,16.3970067 C22.6970052,19.9296567 19.8566406,22.7940133 16.349349,22.7940133 Z M11.0325521,62 L21.769401,62 L21.769401,27.3333333 L11.0325521,27.3333333 L11.0325521,62 Z" />
        </svg>
        <span v-else>{{ providerName(p).charAt(0) }}</span>
      </span>
      <span class="social-auth__label">{{ label(p) }}</span>
    </a>
    <p
      v-if="status === 'ok' && !providers.length && !native"
      class="muted social-auth__none"
      data-test="social-auth-none"
    >{{ t('social_auth.not_available') }}</p>
    <p
      v-else-if="status === 'unavailable'"
      class="muted social-auth__none"
      data-test="social-auth-unavailable"
    >{{ t('auth.error.unavailable') }}</p>
  </div>
</template>

<script setup lang="ts">
import { onMounted, ref } from 'vue'
import {
  providerName,
  startHref,
} from '@/utils/auth-client.mjs'
import { noteError } from '@/composables/errorJournal.mjs'
import { useAuthBase, useAuthClient } from '@/composables/useAuthClient'

withDefaults(defineProps<{
  /** Post-login destination; auth-client's safeRedirect keeps it same-site. */
  redirect?: string
  /** Tenant to carry on start (auth-v1 §1); dropped unless a DNS label. */
  tenant?: string
  /** SPL-1231: the invited address, sent as login_hint (pre-selects the account). */
  loginHint?: string
  /** SPL-1231: the provider the invited address most likely owns, drawn emphasised. */
  suggested?: string
}>(), { redirect: '/', tenant: '', loginHint: '', suggested: '' })

const { t } = useI18n({ useScope: 'global' })
const authBase = useAuthBase()
const auth = useAuthClient()

type Status = 'idle' | 'ok' | 'unavailable'
const status = ref<Status>('idle')
const providers = ref<string[]>([])
// native-auth-v1: the registry also says whether email + password sign-in is
// on; then an empty social list is not "sign-in unavailable".
const native = ref(false)

// Client-only fetch keeps SSR and the first client render identical (empty),
// so there is never a hydration mismatch; the list appears after mount.
onMounted(async () => {
  const out = await auth.loadProviders()
  providers.value = out.providers
  native.value = out.native === true
  status.value = out.status as Status
  if (out.status === 'unavailable') {
    noteError({
      source: 'social-auth',
      method: 'GET',
      url: `${authBase}/api/v1/auth/providers`,
      status: Number(out.reason) || 0,
      message: `provider registry unavailable (${out.reason})`,
    })
  }
})

// Bespoke copy for the providers we ship marks for; any other IdP gets the
// generic "Continue with <Name>" — never a raw key.
function label(p: string): string {
  if (p === 'google' || p === 'facebook' || p === 'microsoft' || p === 'linkedin') return t(`social_auth.continue_${p}`)
  return t('social_auth.continue_generic', { provider: providerName(p) })
}
</script>

<style scoped>
.social-auth {
  /* One full-width column of large buttons (auth-v1 §4). min-width: 0 +
     max-width: 100% so nothing can widen the document on a narrow phone. */
  display: flex;
  flex-direction: column;
  gap: var(--spacing-sm);
  width: 100%;
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
}
.social-auth:empty {
  /* Always rendered so a monitor can read data-social-auth-status; with no
     children it must never cost the page a pixel of layout. */
  display: none;
}
.social-auth__btn {
  border-radius: var(--radius-sm);
  display: inline-flex;
  align-items: center;
  justify-content: center;
  gap: 0.6rem;
  min-height: 48px;
  width: 100%;
  min-width: 0;
  box-sizing: border-box;
  overflow: hidden;
  text-decoration: none;
}
/* SPL-1231: the button the invited address most likely signs in with. */
.social-auth__btn--suggested {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
}
.social-auth__btn--google {
  /* Google's own button language: white tile, coloured G, hairline grey. */
  border: 1px solid #dadce0;
  background: #fff;
  color: #1f1f1f;
}
.social-auth__btn--google:hover {
  background: #f8f9fa;
}
.social-auth__btn--facebook {
  /* Facebook brand blue; white f meets AA contrast on it. */
  border: 1px solid #1877f2;
  background: #1877f2;
  color: #fff;
}
.social-auth__btn--facebook:hover {
  background: #166fe0;
}
.social-auth__btn--microsoft {
  /* Microsoft identity platform light theme (FR-011): white, 1px #8C8C8C, text #5E5E5E. */
  border: 1px solid #8C8C8C;
  background: #fff;
  color: #5E5E5E;
}
.social-auth__btn--microsoft:hover {
  background: #f3f2f1;
}
.social-auth__btn--linkedin {
  /* LinkedIn brand: [in] mark in LinkedIn Blue #0A66C2 on white. */
  border: 1px solid #0A66C2;
  background: #fff;
  color: #0A66C2;
}
.social-auth__btn--linkedin:hover {
  background: #f3f6f8;
}
.social-auth__btn:focus-visible {
  outline: 2px solid var(--color-accent);
  outline-offset: 2px;
}
.social-auth__mark {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex-shrink: 0;
  width: 24px;
  height: 24px;
  font-weight: 700;
  line-height: 1;
}
.social-auth__logo {
  display: block;
  width: 24px;
  height: 24px;
}
.social-auth__label {
  min-width: 0;
  overflow: hidden;
  text-overflow: ellipsis;
  white-space: nowrap;
}
.social-auth__none {
  margin: 0;
}
</style>
