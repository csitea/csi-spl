<template>
  <div class="login">
    <!-- Full-bleed wallpaper. The drift layer is larger than the viewport and
         clipped here, so the slow pan cannot widen the page. -->
    <div class="login-wallpaper" aria-hidden="true">
      <div class="login-wallpaper__drift" data-test="login-wallpaper">
        <!-- Short beads of light. Each path stays dark for most of its cycle. -->
        <svg class="login-signals" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true" data-test="login-signal">
          <path class="login-signal" pathLength="100" d="M 4 78 C 18 52, 36 90, 58 48 S 90 22, 98 36" />
          <path class="login-signal login-signal--late" pathLength="100" d="M 8 24 C 14 42, 6 60, 16 82" />
          <path class="login-signal login-signal--side" pathLength="100" d="M 96 16 C 78 34, 94 58, 72 80" />
          <path class="login-signal login-signal--warm" pathLength="100" d="M 10 94 C 32 68, 54 96, 92 70" />
          <path class="login-signal login-signal--warm login-signal--late" pathLength="100" d="M 24 34 C 42 18, 64 46, 90 24" />
        </svg>
      </div>
      <div class="login-wallpaper__drift login-wallpaper__drift--chip" data-test="login-wallpaper-chip"></div>
      <div class="login-wallpaper__drift login-wallpaper__drift--robot" data-test="login-wallpaper-robot"></div>
    </div>
    <!-- spec 021: the language switcher lives in the frame's header, the
         same end of the bar the app shell uses. -->
    <header class="login-bar" data-test="login-bar">
      <!-- SPL-1025 (owner, topic f8950b7f): the logo in place of the SPOOL-HUB
           text, as in the app's top bar (a click opens it at true size); a
           non-prd build still names its env beside it. Signed in, the tenant
           drop box follows: the desktop box above 820 px, the phone box
           (bottom sheet) below. -->
      <div class="login-bar__start">
        <span class="login-bar__title" data-test="login-bar-title">
          <button type="button" class="login-bar__logo" data-test="login-bar-logo" :aria-label="t('logo.open')" :title="title" @click="logoOpen = true">
            <img src="/logo.webp" alt="" width="28" height="28" decoding="async">
          </button>
          <span v-if="envTag" class="login-bar__env" data-test="login-bar-env">{{ envTag }}</span>
          <span class="sr-only">{{ title }}</span>
        </span>
        <LazyLogoDialog v-if="logoOpen" v-model:open="logoOpen" />
        <div v-if="tenantShown" class="login-bar__tenant" data-test="login-bar-tenant">
          <TenantDropBox />
          <TopBarTenant class="login-bar__tenant-phone" />
        </div>
      </div>
      <LanguageSwitcher />
    </header>
    <div class="login-body">
      <slot />
    </div>
  </div>
</template>

<script setup lang="ts">
/* Async: keeps @headlessui/vue out of the first download (TopBar.vue). */
const LanguageSwitcher = defineAsyncComponent(() => import('@/components/LanguageSwitcher.vue'))
import { loginBarTitle } from '~/utils/login-title.mjs'
import { useKeyboardInset } from '~/composables/useTouchUi'
import { useSessionStore } from '~/stores/session'
import { fixedTenantOption } from '~/utils/tenant-switcher.mjs'
/* Async: only a signed-in visitor sees them, so the sign-in page's first
   download stays as it was. */
const TenantDropBox = defineAsyncComponent(() => import('@/components/TenantDropBox.vue'))
const TopBarTenant = defineAsyncComponent(() => import('@/components/TopBarTenant.vue'))

const { t } = useI18n({ useScope: 'global' })
const config = useRuntimeConfig()
const title = loginBarTitle(config.public.envName, import.meta.dev)
/* spool-dev -> dev beside the logo; prd (spool-hub) shows the logo alone */
const envTag = title === 'spool-hub' ? '' : title.replace(/^spool-/, '')
const logoOpen = ref(false)
/* SPL-1025: signed in with a tenant named -> the tenant box; else the title */
const session = useSessionStore()
const tenantShown = computed(() => session.state === 'in' && fixedTenantOption(session.claims).id.length > 0)
/* the error page renders outside the route middleware that probes */
onMounted(() => { if (session.state === 'loading') void session.probe() })

/* SPL-993: with the on-screen keyboard open the form still fits. The body
   pads by the keyboard (--kb-inset, iOS does not resize the layout), and the
   field being typed in is kept in view whenever the keyboard moves. */
const kb = import.meta.client ? useKeyboardInset() : ref(0)
watch(kb, async () => {
  await nextTick()
  const el = document.activeElement as HTMLElement | null
  if (el && /^(INPUT|TEXTAREA|SELECT)$/.test(el.tagName) && el.closest('.login-body')) el.scrollIntoView({ block: 'nearest' })
})
</script>

<style scoped>
.login {
  display: flex;
  flex-direction: column;
  align-items: stretch;
  justify-content: flex-start;
  padding: 0;
  height: 100%;
  max-height: 100%;
  min-height: 0;
  overflow: hidden;
}
.login-bar {
  position: sticky;
  top: 0;
  z-index: var(--z-sticky, 40);
  display: flex;
  align-items: center;
  justify-content: space-between;
  gap: 12px;
  min-height: var(--top-bar-h);
  padding: 4px 12px;
  background: var(--color-sidebar);
  border-bottom: 1px solid var(--color-border);
  max-width: 100%;
  min-width: 0;
  box-sizing: border-box;
  flex-shrink: 0;
}
.login-bar__start { display: flex; align-items: center; gap: 4px; flex: 0 1 auto; min-width: 0; }
.login-bar__logo {
  display: inline-flex;
  align-items: center;
  justify-content: center;
  flex: 0 0 auto;
  padding: 0;
  border: 0;
  background: none;
  cursor: pointer;
  border-radius: var(--radius-sm);
}
.login-bar__logo img { display: block; width: 28px; height: 28px; border-radius: var(--radius-sm); }
.login-bar__env { margin-inline-start: 6px; }
.login-bar__tenant { display: flex; align-items: center; flex: 0 1 auto; min-width: 0; }
/* SPL-995 split: the phone box only at <= 820 px (TenantDropBox hides itself
   there). Two classes: the box's own display rule loads later (async chunk). */
.login-bar__tenant .login-bar__tenant-phone { display: none; }
@media (max-width: 820px) {
  .login-bar__tenant .login-bar__tenant-phone { display: flex; flex: 0 1 auto; min-width: var(--tap, 44px); max-width: min(20rem, 100%); }
  .login-bar__logo { min-width: var(--tap, 44px); min-height: var(--tap, 44px); }
}
.login-bar__title {
  display: inline-flex;
  align-items: center;
  flex: 0 0 auto;
  font-size: 0.9375rem;
  font-weight: 700;
  letter-spacing: 0.08em;
  text-transform: uppercase;
  color: var(--color-accent);
  white-space: nowrap;
}
/* The title keeps its full name. The language control gives up width on a
   phone so the two never collide or push the page sideways. */
.login-bar :deep(.lang-switcher) {
  /* Content-sized (the control shrink-wraps to the longest locale name,
     SPL-1184); it may still give up width on a phone, capped at 16rem. Do NOT
     force width:100% here — that overrode the control's own max-content width
     and left a wide dead gap after the language name. */
  flex: 0 1 auto;
  min-width: 0;
  max-width: 16rem;
}
.login-body {
  position: relative;
  z-index: 1;
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  /* Both axes centred (restores the pre-0c8a68d6 place-items:center). In a
     column flex justify-content is the vertical axis and align-items the
     horizontal one, so the fixed-width card needs align-items to sit centred
     instead of pinned to the start (left). `safe` keeps it top/left-anchored
     rather than clipped when the content is taller/wider than the body — e.g.
     a phone with the on-screen keyboard open. */
  justify-content: safe center;
  align-items: safe center;
  /* The card sits at the true viewport centre. The bar is in flow and eats
     --top-bar-h off the top, so an equal amount below it keeps the centre on
     the viewport middle (not the middle of the strip under the bar). `safe`
     falls back to the start, so once the card is taller than the room it
     top-aligns clear of the bar rather than being clipped. Phones drop this
     in the media queries below (keyboard-aware, top-aligned). */
  padding: 24px 24px calc(24px + var(--top-bar-h));
  min-width: 0;
  min-height: 0;
  max-width: 100%;
  box-sizing: border-box;
  overflow-x: clip;
  overflow-y: auto;
  overscroll-behavior: contain;
}
/* SPL-993: phones. A narrower frame around the card, the keyboard's height
   added below it, and 16 px fields so iOS does not zoom on focus. */
@media (max-width: 820px) {
  .login-body { padding-bottom: calc(24px + var(--kb-inset, 0px)); }
  .login-body :deep(input),
  .login-body :deep(textarea),
  .login-body :deep(select) { font-size: max(16px, 1rem); }
}
@media (max-width: 600px) {
  .login-body { padding: 12px 12px calc(12px + var(--kb-inset, 0px)); }
  .login-body :deep(.login-card) { padding: 20px 16px; }
}
/* The bar stays a solid strip. The picture shows in the field around the card. */
.login-wallpaper {
  position: fixed;
  inset: 0;
  z-index: 0;
  overflow: hidden;
  pointer-events: none;
}
.login-wallpaper__drift {
  position: absolute;
  inset: -8%;
  background: #060912 url('/login-wallpaper.webp') center / cover no-repeat;
  background-image: image-set(
    url('/login-wallpaper.avif') type('image/avif'),
    url('/login-wallpaper.webp') type('image/webp')
  );
  animation: login-wallpaper-drift 46s ease-in-out infinite alternate, login-wallpaper-hold 96s ease-in-out infinite;
}
.login-wallpaper__drift--chip {
  background-image: url('/login-wallpaper-chip.webp');
  background-image: image-set(
    url('/login-wallpaper-chip.avif') type('image/avif'),
    url('/login-wallpaper-chip.webp') type('image/webp')
  );
  animation: login-wallpaper-drift 54s ease-in-out infinite alternate-reverse, login-wallpaper-hold-b 96s ease-in-out infinite;
}
.login-wallpaper__drift--robot {
  background-image: url('/login-wallpaper-robot.webp');
  background-image: image-set(
    url('/login-wallpaper-robot.avif') type('image/avif'),
    url('/login-wallpaper-robot.webp') type('image/webp')
  );
  animation: login-wallpaper-drift 50s ease-in-out infinite alternate, login-wallpaper-hold-c 96s ease-in-out infinite;
}
@keyframes login-wallpaper-drift {
  from { transform: translate3d(-1.25%, -0.8%, 0) scale(1.06); }
  to { transform: translate3d(1.25%, 0.9%, 0) scale(1.1); }
}
/* Three pictures in turn. The fades overlap so the field never goes empty. */
@keyframes login-wallpaper-hold {
  0%, 28% { opacity: 1; }
  36%, 92% { opacity: 0; }
  100% { opacity: 1; }
}
@keyframes login-wallpaper-hold-b {
  0%, 28% { opacity: 0; }
  36%, 61% { opacity: 1; }
  69%, 100% { opacity: 0; }
}
@keyframes login-wallpaper-hold-c {
  0%, 61% { opacity: 0; }
  69%, 94% { opacity: 1; }
  100% { opacity: 0; }
}
@media (prefers-reduced-motion: reduce) {
  .login-wallpaper__drift {
    animation: none;
    transform: scale(1.06);
  }
  .login-wallpaper__drift--chip,
  .login-wallpaper__drift--robot {
    opacity: 0;
  }
  .login-signal {
    animation: none;
    opacity: 0;
  }
}
.login-signals {
  position: absolute;
  inset: 0;
  width: 100%;
  height: 100%;
  overflow: visible;
}
.login-signal {
  fill: none;
  stroke: #e7fbff;
  stroke-width: 2px;
  stroke-linecap: round;
  vector-effect: non-scaling-stroke;
  filter: drop-shadow(0 0 3px #7ef0ff) drop-shadow(0 0 8px rgba(70, 190, 255, 0.75));
  stroke-dasharray: 5 95;
  opacity: 0;
  animation: login-signal 17s ease-in-out infinite;
}
.login-signal--late { animation-duration: 21s; animation-delay: 8s; }
.login-signal--side { animation-duration: 19s; animation-delay: 4.5s; }
.login-signal--warm {
  stroke: #ffe3b0;
  filter: drop-shadow(0 0 3px #ffc56a) drop-shadow(0 0 8px rgba(255, 170, 70, 0.6));
  animation-duration: 23s;
  animation-delay: 12s;
}
.login-signal--warm.login-signal--late { animation-delay: 3s; animation-duration: 18s; }
@keyframes login-signal {
  0%, 64% { opacity: 0; stroke-dashoffset: 6; }
  70% { opacity: 0.92; }
  86% { opacity: 0.55; stroke-dashoffset: -94; }
  94%, 100% { opacity: 0; stroke-dashoffset: -100; }
}
@media (prefers-reduced-motion: reduce) {
  .login-signal {
    animation: none;
    opacity: 0;
  }
}
</style>
