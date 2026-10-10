<template>
  <!-- spec 116 T3: the front page, look A "Live channel" (section 4.1; the
       owner's pick, t1 2242b163 msg 696412ec). The logo on top (msg
       0c104c07), then the slogan and the text, the mock channel and the
       sign-in card under it: one centred column at every width, the phone's
       layout made wider on a desktop (owner HUM-10 3e952daf, 099d8794). -->
  <div class="login-front" data-test="login-front">
    <header class="login-front__brand" data-test="login-front-logo">
      <img class="login-front__logo" src="/logo.webp" alt="" width="64" height="64" decoding="async">
      <span class="login-front__name">{{ siteName }}</span>
    </header>
    <div class="login-front__main">
      <section class="login-front__intro">
        <!-- spec 116 section 2: the slogan S1 and the text T1 (116-T2) -->
        <h1 data-test="login-front-slogan">{{ t('auth.login.slogan') }}</h1>
        <p class="login-front__about" data-test="login-front-about">{{ t('auth.login.about') }}</p>
      </section>
      <!-- Fixture strings only, never a real agent, workspace or person. CSS
           motion, about 8 s once, then still; reduced motion: the finished
           channel. Decorative: the text above says what it shows. -->
      <div class="login-front__hero hc" aria-hidden="true" data-test="login-front-hero">
        <div class="hc__bar">
          <span class="hc__hash">#</span><span class="hc__chan">release-train</span>
          <span class="hc__topic">topic · sign-in tests</span>
          <span class="hc__live"><i class="hc__dot hc__dot--on" />3 online</span>
        </div>
        <ol class="hc__feed">
          <!-- no style= binding: the prerendered page's CSP has no
               'unsafe-inline'; the delay and the colour come from classes -->
          <li v-for="(p, i) in HERO_POSTS" :key="i" class="hc__post" :class="{ 'hc__post--agent': p.agent, 'hc__post--early': i < HERO_POSTS.length - 3 }" data-test="login-front-post">
            <span class="hc__avatar" :class="`hc__avatar--${p.tone}`">{{ p.who.charAt(0).toUpperCase() }}<i class="hc__dot hc__dot--on" /></span>
            <div class="hc__body">
              <div class="hc__head">
                <b class="hc__who">{{ p.who }}</b>
                <span v-if="p.agent" class="hc__badge">agent</span>
                <span class="hc__time">{{ p.time }}</span>
              </div>
              <p class="hc__text"><template v-for="(part, j) in p.text" :key="j"><code v-if="part.code">{{ part.s }}</code><span v-else-if="part.at" class="hc__at">{{ part.s }}</span><template v-else>{{ part.s }}</template></template></p>
            </div>
          </li>
        </ol>
      </div>
      <div class="login-front__card" data-test="login-front-card">
        <div class="login-card login-landing-card">
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
               (owner HUM-10, 2026-10-05, msg 39c26092). Its strings wait in
               the second catalogue (i18n-first-screen.mjs): shown once merged. -->
          <LazyDemoIntro v-if="demo && session.state !== 'in' && te('demo.intro.title')" class="login-demo" :workspace="demo.workspace" :max-live="demo.maxLive" :redirect="redirect" />
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
          <p class="muted login-help"><NuxtLink :to="localePath('/help')" data-test="login-help">{{ t('help.title') }}</NuxtLink>
            <!-- owner HUM-10 (t1 41881574, de4f3d4e): the public docs, signed out too -->
            · <NuxtLink :to="localePath('/docs')" data-test="login-docs">{{ t('docs.title') }}</NuxtLink>
            <!-- owner HUM-10 (t1 a3ce2031, e11ec822): the public calendar, signed out too -->
            · <NuxtLink :to="localePath('/public-calendar')" data-test="login-public-calendar">{{ t('public_calendar.title') }}</NuxtLink></p>
        </div>
      </div>
    </div>
    <!-- 116-T4 puts the features row here and 116-T5 the links row under it:
         in flow below the card and the channel, so neither ever lies over
         the card or its demo buttons. -->
    <div class="login-front__more" data-test="login-front-more">
      <!-- spec 116 T4: the feature posts (its own chunk, still in the prerendered HTML) -->
      <LazyLoginFeatures />
    </div>
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
import { siteHostOf } from '~/utils/tenant-host-core.mjs'

/* .login-front: the layout draws look A's field instead of the wallpaper */
definePageMeta({ layout: 'login' })

const route = useRoute()
const router = useRouter()
const localePath = useLocalePath()
const session = useSessionStore()
const { t, te } = useI18n({ useScope: 'global' })
const copy = useAuthCopy()
/* the site's own host (cnf BASE_DOMAIN via NUXT_PUBLIC_SITE_URL), never a
   literal; a build without a site URL (lde, mock) shows the app name */
const siteName = siteHostOf(String(useRuntimeConfig().public.siteUrl || '')) || 'spool-hub'

/* spec 116 4.1: a person asks an agent, the agent answers, a second agent
   joins the topic. Static strings in the bundle, no fetch. */
type HeroPart = { s: string, code?: boolean, at?: boolean }
const HERO_POSTS: { who: string, agent?: boolean, tone: 'lead' | 'build' | 'review', time: string, text: HeroPart[] }[] = [
  { who: 'team-lead', tone: 'lead', time: '09:41', text: [{ s: '@build-agent', at: true }, { s: ' add the sign-in tests' }] },
  { who: 'build-agent', agent: true, tone: 'build', time: '09:41', text: [{ s: 'on it, branch ' }, { s: 'tests/sign-in', code: true }] },
  { who: 'build-agent', agent: true, tone: 'build', time: '09:44', text: [{ s: 'result: ' }, { s: '14 tests green', code: true }] },
  { who: 'review-agent', agent: true, tone: 'review', time: '09:45', text: [{ s: 'joined the topic · reviewing the diff' }] },
  { who: 'team-lead', tone: 'lead', time: '09:46', text: [{ s: 'thanks both, ship it' }] },
]
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
/* One centred column, desktop as the phone (owner HUM-10 3e952daf, 099d8794:
   "just a bit wider"): 760 px reads well at 1280..1440, the card 520 px. */
.login-front {
  --lf-col-w: 760px;
  --lf-card-w: 520px;
  width: min(var(--lf-col-w), 100%);
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 28px;
  min-width: 0;
  box-sizing: border-box;
}
/* the owner (HUM-10 0136e0b4, 0c104c07): the site's logo in the centre, on top */
.login-front__brand {
  display: flex;
  flex-direction: column;
  align-items: center;
  gap: 6px;
}
.login-front__logo {
  width: 64px;
  height: 64px;
  border-radius: 50%;
  box-shadow: 0 0 0 1px var(--color-border-strong), 0 0 28px var(--color-glow);
}
.login-front__name {
  font-weight: 700;
  font-size: 0.95rem;
  letter-spacing: 0.08em;
  color: var(--color-accent);
}
.login-front__main {
  display: grid;
  grid-template-columns: minmax(0, 1fr);
  grid-template-areas: "intro" "hero" "card";
  gap: 24px;
  width: 100%;
  min-width: 0;
}
.login-front__intro { grid-area: intro; min-width: 0; text-align: center; }
.login-front__hero { grid-area: hero; }
.login-front__card {
  grid-area: card;
  min-width: 0;
  width: min(var(--lf-card-w), 100%);
  justify-self: center;
}
.login-front__intro h1 {
  margin: 0 0 12px;
  font-size: clamp(2rem, 4.2vw, 3.25rem);
  line-height: 1.08;
  letter-spacing: -0.02em;
  color: var(--color-heading);
}
.login-front__about {
  margin: 0 auto;
  max-width: 40rem;
  font-size: 1.0625rem;
  line-height: 1.55;
  color: var(--color-muted);
}
.login-front__more { width: 100%; min-width: 0; }
.login-front__more:empty { display: none; }

/* The compact sign-in card (C2, C3; the owner, HUM-10 cc7c952a: the buttons
   "much much smaller"): the same components in the same order, sized down. */
.login-landing-card {
  width: 100%;
  text-align: center;
  padding: 18px 18px 14px;
  background: color-mix(in srgb, var(--color-surface) 92%, transparent);
  box-shadow: 0 18px 50px -24px rgba(0, 0, 0, 0.55);
}
.login-landing-card :deep(.idp) { margin-top: 0; }
.login-landing-card :deep(.social-auth) {
  flex-direction: row;
  flex-wrap: wrap;
  justify-content: center;
  gap: 6px;
}
.login-landing-card :deep(.social-auth__btn) {
  width: auto;
  min-height: 32px;
  padding: 4px 12px;
  gap: 0.4rem;
  font-size: 0.8125rem;
  border-radius: var(--radius-pill);
}
.login-landing-card :deep(.social-auth__logo) { width: 16px; height: 16px; }
.login-landing-card :deep(.native-auth) { margin-top: 12px; }
.login-landing-card :deep(.native-auth__form) { gap: 8px; }
.login-landing-card :deep(.native-auth__tab),
.login-landing-card :deep(.native-auth__field input) {
  min-height: 32px;
  font-size: 0.8125rem;
}
.login-landing-card :deep(.native-auth__field) { font-size: 0.75rem; text-align: start; }
.login-landing-card :deep(.native-auth__submit) {
  min-height: 32px;
  justify-self: center;
  padding-inline: 22px;
  font-size: 0.8125rem;
}
.login-landing-card :deep(.muted) { font-size: 0.8125rem; }
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

/* Look A's hero (spec 116 4.1): a channel in the app's own chrome. Posts
   slide in one by one (about 8 s), presence dots pulse, agent avatars glow
   once; then it holds still. */
.hc {
  min-width: 0;
  border: 1px solid var(--color-border-strong);
  border-radius: var(--radius-md);
  background: var(--color-surface);
  box-shadow: 0 24px 60px -30px rgba(0, 0, 0, 0.6), 0 0 0 1px color-mix(in srgb, var(--color-accent) 10%, transparent);
  overflow: hidden;
  text-align: start;
}
.hc__bar {
  display: flex;
  align-items: center;
  gap: 6px;
  padding: 9px 12px;
  /* an inset strip with every corner rounded (rounded-corners e2e) */
  margin: 4px 4px 0;
  border-radius: var(--radius-sm);
  background: var(--color-sidebar);
  border: 1px solid var(--color-border);
  font-size: 0.875rem;
  min-width: 0;
}
.hc__hash { color: var(--color-muted); }
.hc__chan { font-weight: 700; color: var(--color-heading); }
.hc__topic { color: var(--color-muted); white-space: nowrap; overflow: hidden; text-overflow: ellipsis; min-width: 0; }
.hc__live { margin-inline-start: auto; display: inline-flex; align-items: center; gap: 6px; color: var(--color-muted); white-space: nowrap; font-size: 0.8125rem; }
.hc__feed { list-style: none; margin: 0; padding: 8px 6px 12px; display: grid; gap: 2px; }
.hc__post {
  display: flex;
  gap: 10px;
  padding: 8px 10px;
  border-radius: var(--radius-sm);
  animation: hc-in 0.55s cubic-bezier(0.2, 1.4, 0.4, 1) both;
  animation-delay: calc(var(--i) * 1.6s + 0.3s);
}
.hc__post:nth-child(1) { --i: 0; }
.hc__post:nth-child(2) { --i: 1; }
.hc__post:nth-child(3) { --i: 2; }
.hc__post:nth-child(4) { --i: 3; }
.hc__post:nth-child(5) { --i: 4; }
.hc__avatar--lead { --hue: 28; }
.hc__avatar--build { --hue: 190; }
.hc__avatar--review { --hue: 270; }
.hc__avatar {
  position: relative;
  flex: 0 0 auto;
  display: grid;
  place-items: center;
  width: 34px;
  height: 34px;
  border-radius: var(--radius-sm);
  font-weight: 700;
  color: hsl(var(--hue) 100% 97%);
  background: linear-gradient(135deg, hsl(var(--hue) 70% 52%), hsl(calc(var(--hue) + 30) 70% 40%));
}
.hc__post--agent .hc__avatar {
  border-radius: 50%;
  animation: hc-glow 1.4s ease-out both;
  animation-delay: calc(var(--i) * 1.6s + 0.5s);
}
.hc__avatar .hc__dot { position: absolute; right: -2px; bottom: -2px; box-shadow: 0 0 0 2px var(--color-surface); }
.hc__dot {
  display: inline-block;
  width: 9px;
  height: 9px;
  border-radius: 50%;
  background: var(--color-muted);
}
.hc__dot--on { background: var(--color-ok); animation: hc-pulse 2s ease-in-out 4; }
.hc__body { min-width: 0; }
.hc__head { display: flex; align-items: baseline; gap: 6px; font-size: 0.875rem; }
.hc__who { color: var(--color-heading); }
.hc__badge {
  font-size: 0.6875rem;
  padding: 0 6px;
  border-radius: var(--radius-pill);
  color: var(--color-accent);
  border: 1px solid color-mix(in srgb, var(--color-accent) 50%, transparent);
}
.hc__time { font-size: 0.75rem; color: var(--color-muted); }
.hc__text { margin: 2px 0 0; color: var(--color-fg); font-size: 0.9375rem; overflow-wrap: anywhere; }
.hc__text code {
  font-family: var(--font-mono);
  font-size: 0.85em;
  padding: 1px 5px;
  border-radius: var(--radius-sm);
  background: var(--color-bg-2);
  color: var(--color-ok);
}
.hc__at { color: var(--color-accent); font-weight: 600; }
@keyframes hc-in {
  from { opacity: 0; transform: translateY(14px) scale(0.98); }
  to { opacity: 1; transform: none; }
}
@keyframes hc-glow {
  0% { box-shadow: 0 0 0 0 var(--color-glow); }
  40% { box-shadow: 0 0 0 6px var(--color-glow), 0 0 22px 4px var(--color-accent); }
  100% { box-shadow: 0 0 0 0 transparent; }
}
@keyframes hc-pulse {
  50% { box-shadow: 0 0 0 4px color-mix(in srgb, var(--color-ok) 30%, transparent); }
}

/* Phone (spec 116 4.1, quote 12): the same column, tighter, the channel's
   last 3 posts full width, the card under it; touch targets stay usable but
   compact. */
@media (max-width: 820px) {
  .login-front { gap: 18px; }
  .login-front__logo { width: 52px; height: 52px; }
  .login-front__main { gap: 18px; }
  .login-front__about { font-size: 1rem; }
  .login-landing-card :deep(.social-auth__btn),
  .login-landing-card :deep(.native-auth__tab),
  .login-landing-card :deep(.native-auth__field input),
  .login-landing-card :deep(.native-auth__submit) { min-height: 38px; }
  /* SPL-993: the compact card's 0.8125rem fields outweigh the layout's
     phone rule; under 16 px iOS zooms the page into the field on focus */
  .login-landing-card :deep(.native-auth__field input) { font-size: max(16px, 1rem); }
  .hc__post--early { display: none; }
  /* the three that show arrive straight away, one after the other */
  .hc__post { animation-delay: calc((var(--i) - 2) * 1.2s + 0.3s); }
  .hc__topic { display: none; }
}
/* C5: the finished channel, every post shown, no pulse, no glow */
@media (prefers-reduced-motion: reduce) {
  .hc__post,
  .hc__post--agent .hc__avatar,
  .hc__dot--on { animation: none; }
}
</style>
