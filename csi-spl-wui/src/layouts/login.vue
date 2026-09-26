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
      <span class="login-bar__title" data-test="login-bar-title">{{ title }}</span>
      <LanguageSwitcher />
    </header>
    <div class="login-body">
      <slot />
    </div>
  </div>
</template>

<script setup lang="ts">
/* Async (CLE-34984): keeps @headlessui/vue out of the first download (TopBar.vue). */
const LanguageSwitcher = defineAsyncComponent(() => import('@/components/LanguageSwitcher.vue'))
import { loginBarTitle } from '~/utils/login-title.mjs'

const config = useRuntimeConfig()
const title = loginBarTitle(config.public.envName, import.meta.dev)
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
.login-bar__title {
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
  flex: 0 1 16rem;
  width: 100%;
  min-width: 0;
  max-width: 16rem;
}
.login-bar :deep(.lang-switcher__combobox) {
  width: 100%;
}
.login-body {
  position: relative;
  z-index: 1;
  flex: 1 1 auto;
  display: flex;
  flex-direction: column;
  justify-content: safe center;
  padding: 24px;
  min-width: 0;
  min-height: 0;
  max-width: 100%;
  box-sizing: border-box;
  overflow-x: clip;
  overflow-y: auto;
  overscroll-behavior: contain;
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
